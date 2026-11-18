# ThinkPad T400 fingerprint reader on Debian 13

This fixes fprintd always answering **`verify-no-match`** on the ThinkPad T400, even with the finger you just enrolled. It's a guide plus a patched libfprint.

It is meant for the **UPEK TouchStrip, USB ID `147e:2016`**, a swipe sensor. The same chip is used in the T400, T400s, T500, W500, X200, X200s, X201, T410, T410s, T510 and X220. It applies to Debian 13 "trixie" (libfprint 1.94.9, fprintd 1.94.5). The patches also apply to libfprint 1.94.10 (Debian testing) and current upstream.

## TL;DR

```sh
sudo apt install git fprintd libpam-fprintd usbutils
git clone https://github.com/matias3009/fingerprint-t400-specific.git
cd fingerprint-t400-specific
./t400-fprint.sh info                      # check the sensor and which driver it uses
./build-patched-libfprint.sh               # build + install the patched libfprint (~10 min)
fprintd-delete "$USER"                     # throw away the old enrollment
sudo ./t400-fprint.sh set --stages 8       # record 8 swipes instead of 5
fprintd-enroll                             # as your normal user, NOT with sudo
fprintd-verify                             # should now say verify-match
./t400-fprint.sh calibrate                 # optional: measure scores and tune
```

---

## Why it fails

libfprint doesn't compare fingerprint images directly. It extracts *minutiae*, the points where ridges end or split. It then scores how well the minutiae of the new swipe line up with each of the enrolled swipes, using the NBIS "bozorth3" matcher. A swipe counts as a match only if the score reaches a threshold.

The T400 sensor is a narrow swipe strip. libfprint stitches the image together from hundreds of thin lines, so the result is small and a bit distorted, with few minutiae. Genuine matches from this sensor often score only **15–40**. This is a known, still-open upstream problem: [libfprint issue #299](https://gitlab.freedesktop.org/libfprint/libfprint/-/issues/299), "False-negatives occur unmanageably often for 147e:2016".

`147e:2016` exists in two hardware revisions, and libfprint uses a different driver for each:

| `bcdDevice` | libfprint driver | Stock threshold | Patched default |
|---|---|---|---|
| `0.01` | `upeksonly` | **40**, the generic default, too high for this sensor | **25** |
| `0.02` | `upektc_img` | 20 | 20 |

With revision 0.01 and the stock threshold of 40, almost every genuine swipe is rejected. That's the "no match even with the same finger" you're seeing. Upstream already lowered the threshold to 25 for the sibling sensor `147e:1001` for exactly this reason, but never did it for `147e:2016`.

### What the patches change

There are two small patches in [`patches/`](patches):

1. **`image-device`: tunable at runtime.** libfprint reads two environment variables when an image-based reader is opened. They work for both drivers above, and for every other image-based reader.
   - `LIBFPRINT_BZ3_THRESHOLD` (1–200): the score needed for a match.
   - `LIBFPRINT_ENROLL_STAGES` (1–20): the number of swipes recorded at enrollment. Each extra swipe is stored as another sample, and a verify succeeds if *any* sample matches. More samples means fewer false rejections.

   When either variable is set, a line is logged to the journal. Invalid values are ignored with a warning.
2. **`upeksonly`: threshold 25 for `147e:2016`.** This is the same value upstream uses for the 147e:1001, and close to the 20 that `upektc_img` uses for revision 0.02 of this same USB ID.

You set the variables with a systemd drop-in for `fprintd.service`. `t400-fprint.sh` writes it for you.

---

## Step 0: check the hardware

```sh
./t400-fprint.sh info
```

You can also check by hand:

```sh
lsusb -d 147e:2016 -v 2>/dev/null | grep -E "idProduct|bcdDevice"
```

- **No device listed:** the reader is turned off in the BIOS. Press F1 at boot, then go to *Security → I/O Port Access → Fingerprint Reader → Enabled*. Also check *Security → Fingerprint*.
- **`bcdDevice 0.01`:** the `upeksonly` driver. This is the case the patch fixes most.
- **`bcdDevice 0.02`:** the `upektc_img` driver. Its threshold is already 20, so improvements come mostly from more enroll stages, a better swiping technique and calibration (steps 1, 3 and 4).

## Step 1: things to check before rebuilding

These are free, and they matter with the patched version too.

- **Enroll and verify as the same user.** `sudo fprintd-enroll` enrolls the finger for **root**. Run `fprintd-enroll` and `fprintd-verify` as your normal user, and check with `fprintd-list $USER`.
- **Swipe the same way every time:**
  - Put the **first crease (joint) of your finger** on the strip, with the finger flat and centred over the sensor.
  - Pull it toward you in one smooth movement of about **one second**. Don't flick it, and don't crawl.
  - Keep the same angle each time, straight along the finger.
  - When enrolling, keep the technique the same but vary the position slightly, a little left or right of centre, so the samples cover more of the finger.
- **Dry or cold skin** gives poor images. Clean the strip and warm your finger. A finger that is slightly damp (not wet) often works better.
- If fprintd answers `enroll-swipe-too-short`, `verify-swipe-too-short` or `verify-finger-not-centered`, the swipe wasn't usable. That's different from `no-match`.

## Step 2: build and install the patched libfprint

```sh
./build-patched-libfprint.sh
```

The script:

1. Works out which libfprint version apt installs, `1:1.94.9-1` on Debian 13.
2. Downloads the exact Debian source package, using `apt-get source` if `deb-src` is enabled and `deb.debian.org` otherwise.
3. Adds the patches as Debian quilt patches and checks that they apply cleanly.
4. Gives the package a local version, `1:1.94.9-1+t400.1`.
5. Installs the build dependencies through a `libfprint-build-deps` meta package (removable later with `sudo apt purge libfprint-build-deps`) and builds the `.deb` packages.
6. Installs them, runs `apt-mark hold` so a normal `apt upgrade` doesn't silently bring back the broken version, and restarts fprintd.

The build happens in `~/libfprint-t400-build`. On a Core 2 Duo it takes about 5–15 minutes. Options:

- `--no-install`: only build.
- `--run-tests`: also run libfprint's test suite.
- `--version V`: patch a specific Debian version.

> When Debian publishes a new libfprint, `apt` will list it as held back. Run the script again to rebuild the patched version on top of the new one.

## Step 3: enroll again

Old enrollments still work, but make a fresh one so you get the extra samples:

```sh
fprintd-delete "$USER"
sudo ./t400-fprint.sh set --stages 8     # 8 swipes per enrollment. 10 is fine too.
fprintd-enroll                           # default finger is right-index-finger
fprintd-enroll -f left-index-finger      # optional: a second finger
fprintd-verify
```

## Step 4: measure and tune the threshold

If `fprintd-verify` still fails sometimes, measure instead of guessing:

```sh
./t400-fprint.sh calibrate               # swipe your ENROLLED finger 5 times
./t400-fprint.sh calibrate --impostor    # swipe fingers that are NOT enrolled 5 times
```

During calibration, the script:

- turns on libfprint's debug log;
- temporarily sets an impossible threshold, so every enrolled sample is scored and every swipe says "no-match" (that's expected);
- reads the best score of each swipe from the journal.

It restores your settings when it finishes, then prints a summary like this:

```
Enrolled finger : 5 swipes, best scores min 18 / median 27 / max 40
Other fingers   : 5 swipes, best scores min 7 / median 9 / max 14
Suggested threshold: 21   ->  sudo ./t400-fprint.sh set --threshold 21
```

> **Security:** the threshold is the only thing that keeps other fingers out. Pick a value comfortably **above** the best score a wrong finger reached. Don't go below about 15 without measuring wrong fingers first. If real and wrong fingers score about the same, improve the enrollment (steps 1 and 3) rather than lowering the threshold. Keep a password fallback in any case. This sensor is a convenience, not strong security.

Other commands:

```sh
sudo ./t400-fprint.sh debug on        # keep logging scores: sudo journalctl -fu fprintd | grep score
sudo ./t400-fprint.sh debug off
sudo ./t400-fprint.sh set --threshold default --stages default
sudo ./t400-fprint.sh reset           # remove all tuning
```

<details>
<summary>Doing it by hand, without the script</summary>

```ini
# /etc/systemd/system/fprintd.service.d/t400-tuning.conf
[Service]
Environment=LIBFPRINT_BZ3_THRESHOLD=25
Environment=LIBFPRINT_ENROLL_STAGES=8
# to see the scores in `journalctl -u fprintd`:
# Environment="G_MESSAGES_DEBUG=libfprint-print libfprint-image_device"
```

```sh
sudo systemctl daemon-reload && sudo systemctl stop fprintd   # it restarts on demand
```
</details>

## Step 5: use it for login and sudo

```sh
sudo apt install libpam-fprintd
sudo pam-auth-update      # tick "Fingerprint authentication"
```

GDM, LightDM, sudo, polkit and the lock screen will then offer the fingerprint, with the password as fallback.

---

## Looking at the raw image (for debugging)

The build keeps libfprint's `img-capture` example. It saves exactly what the sensor delivers after libfprint has stitched it together:

```sh
sudo systemctl stop fprintd
sudo ~/libfprint-t400-build/tools/img-capture /tmp/finger.pgm    # swipe once
xdg-open /tmp/finger.pgm
```

A good image shows clear ridges over most of its height. If it's mostly smeared, squashed or stretched no matter how you swipe, the problem is in image capture, not the threshold. Please report that upstream and attach the image.

## Going back to stock

```sh
sudo ./t400-fprint.sh reset
sudo apt-mark unhold libfprint-2-2 gir1.2-fprint-2.0
sudo apt install --allow-downgrades libfprint-2-2=1:1.94.9-1    # gir1.2-fprint-2.0 too, if installed
sudo apt purge libfprint-build-deps     # build dependencies, if you no longer need them
```

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `No devices available` | Reader turned off in the BIOS (step 0), or a different chip. Check `lsusb`. |
| `verify-no-match` every time | Threshold too high (step 2), poor enrollment (steps 1 and 3), or wrong user (step 1). |
| `*-swipe-too-short` / `not-centered` | Swipe slower and more centred, starting at the first joint. |
| Other fingers are accepted | Threshold too low. Run `calibrate --impostor` and raise it. |
| `t400-fprint.sh set` has no effect | The stock libfprint is still installed. Check `./t400-fprint.sh info`, which should say `Patched libfprint: yes`. |
| Can't get the build dependencies, or apt has broken packages | Run `sudo apt update`, then `sudo apt -f install`, and rerun the script. |

## What was tested

- The patches build without warnings against libfprint 1.94.9. The full libfprint test suite passes: 30 OK, 2 skipped, as without the patch.
- The patches apply cleanly to 1.94.10 and current upstream `master`.
- Both drivers were tested on an emulated `147e:2016` reader (umockdev), revision 0.01 for `upeksonly` and 0.02 for `upektc_img`:
  - the defaults are 25 and 20, with 5 stages;
  - `LIBFPRINT_BZ3_THRESHOLD` and `LIBFPRINT_ENROLL_STAGES` overrides are applied, and the device reports the new stage count (fprintd listens for that change);
  - invalid values are ignored with a warning.
- `build-patched-libfprint.sh` was run end to end against the real Debian `libfprint_1.94.9-1` source package, producing `libfprint-2-2_1.94.9-1+t400.1_amd64.deb`.
- **Not tested:** real T400 hardware. The best threshold for your finger and sensor is something only `calibrate` on your machine can tell you.

Feedback from real T400 runs is welcome: open an issue and include the `calibrate` summary.
