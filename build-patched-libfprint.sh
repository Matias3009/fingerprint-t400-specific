#!/usr/bin/env bash
#
# Build and install a patched libfprint for Debian 13 (trixie) that makes the
# UPEK 147e:2016 fingerprint reader of the ThinkPad T400 (also T500, X200,
# W500, T410, X201, ...) usable with fprintd.
#
# What it does:
#   1. downloads the Debian source of the libfprint version apt would install
#   2. adds the patches from ./patches as Debian quilt patches
#   3. gives the package a local version (e.g. 1:1.94.9-1+t400.1)
#   4. installs the build dependencies and builds the .deb packages
#   5. installs them, puts them on hold so apt does not undo the fix, and
#      restarts fprintd
#
# Usage: ./build-patched-libfprint.sh [--no-install] [--run-tests] [--version V]
#
#   --no-install   only build, do not install/hold/restart anything
#   --run-tests    run the libfprint test suite during the build (slower)
#   --version V    Debian version to patch, e.g. 1:1.94.9-1 (default: the
#                  candidate version from apt-cache policy)
#
# Environment: WORK_DIR (default ~/libfprint-t400-build), MIRROR
#              (default https://deb.debian.org/debian)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="$HERE/patches"
WORK_DIR="${WORK_DIR:-$HOME/libfprint-t400-build}"
MIRROR="${MIRROR:-https://deb.debian.org/debian}"
LOCAL_SUFFIX="+t400.1"
INSTALL=1
RUN_TESTS=0
DEB_VERSION=""

msg()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --no-install) INSTALL=0 ;;
    --run-tests)  RUN_TESTS=1 ;;
    --version)    shift; DEB_VERSION="${1:-}"; [ -n "$DEB_VERSION" ] || die "--version needs a value" ;;
    -h|--help)    sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *)            die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

ls "$PATCH_DIR"/*.patch >/dev/null 2>&1 || die "no patches found in $PATCH_DIR"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  command -v sudo >/dev/null || die "sudo is needed (or run this script as root)"
  SUDO="sudo"
fi

if [ -r /etc/os-release ]; then
  . /etc/os-release
  if [ "${ID:-}" != "debian" ]; then
    warn "this script was written for Debian 13, you are running ${PRETTY_NAME:-unknown}"
  fi
fi

# --- 1. Which version? -------------------------------------------------------
if [ -z "$DEB_VERSION" ]; then
  DEB_VERSION="$(apt-cache policy libfprint-2-2 | awk '/Candidate:/ {print $2}')"
  [ -n "$DEB_VERSION" ] && [ "$DEB_VERSION" != "(none)" ] \
    || die "could not find libfprint-2-2 in apt, use --version"
fi
# If our own build is already installed, patch the Debian version it is based on
DEB_VERSION="${DEB_VERSION%%+t400*}"
VER_NOEPOCH="${DEB_VERSION#*:}"
NEW_VERSION="${DEB_VERSION}${LOCAL_SUFFIX}"
NEW_VER_NOEPOCH="${NEW_VERSION#*:}"
msg "Patching libfprint $DEB_VERSION -> $NEW_VERSION"

# --- 2. Tools ----------------------------------------------------------------
msg "Installing packaging tools"
$SUDO apt-get update
$SUDO apt-get install -y --no-install-recommends \
  build-essential devscripts equivs dpkg-dev quilt curl ca-certificates

# --- 3. Source ---------------------------------------------------------------
BUILD_DIR="$WORK_DIR/$VER_NOEPOCH"
SRC_DIR="$BUILD_DIR/libfprint-src"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

msg "Downloading the Debian source package"
if apt-get source --download-only "libfprint=$DEB_VERSION" >/dev/null 2>&1; then
  echo "Downloaded with apt-get source (deb-src is enabled)"
else
  echo "deb-src is not enabled, downloading from $MIRROR"
  DSC="libfprint_${VER_NOEPOCH}.dsc"
  curl -fsSLO "$MIRROR/pool/main/libf/libfprint/$DSC" \
    || die "could not download $DSC (if this version left the mirror, try MIRROR=https://snapshot.debian.org/archive/debian/<date>)"
  # Download every file listed in the .dsc; dpkg-source checks their checksums.
  for f in $(awk '/^Files:/ {f=1; next} /^[^ ]/ {f=0} f && NF==3 {print $3}' "$DSC"); do
    curl -fsSLO "$MIRROR/pool/main/libf/libfprint/$f" || die "could not download $f"
  done
fi
dpkg-source -x "libfprint_${VER_NOEPOCH}.dsc" "$SRC_DIR"
cd "$SRC_DIR"

# --- 4. Patches --------------------------------------------------------------
msg "Adding the T400 patches"
mkdir -p debian/patches
touch debian/patches/series
for p in "$PATCH_DIR"/*.patch; do
  name="t400-$(basename "$p")"
  cp "$p" "debian/patches/$name"
  echo "$name" >> debian/patches/series
done
QUILT_PATCHES=debian/patches quilt push -a --fuzz=0 >/dev/null \
  || die "the patches do not apply to libfprint $DEB_VERSION"
QUILT_PATCHES=debian/patches quilt pop -a >/dev/null
rm -rf .pc
cat debian/patches/series

# --- 5. Version --------------------------------------------------------------
DIST="$(dpkg-parsechangelog -S Distribution)"
{
  printf 'libfprint (%s) %s; urgency=medium\n\n' "$NEW_VERSION" "$DIST"
  printf '  * Local build for the UPEK 147e:2016 reader of ThinkPad T400 & co:\n'
  printf '    - image devices: LIBFPRINT_BZ3_THRESHOLD / LIBFPRINT_ENROLL_STAGES\n'
  printf '    - upeksonly: lower bz3 threshold for 147e:2016 to 25\n\n'
  printf ' -- Local build <root@localhost>  %s\n\n' "$(date -R)"
  cat debian/changelog
} > debian/changelog.new
mv debian/changelog.new debian/changelog

# --- 6. Build dependencies ---------------------------------------------------
msg "Installing build dependencies"
# equivs-build puts the package in $TMPDIR when that is set, where
# mk-build-deps does not find it: build it in the current directory instead.
(cd "$BUILD_DIR" && env -u TMPDIR mk-build-deps -i -r ${SUDO:+-s "$SUDO"} \
   -t "apt-get -y --no-install-recommends" "$SRC_DIR/debian/control")
rm -f "$BUILD_DIR"/libfprint-build-deps_*

# --- 7. Build ----------------------------------------------------------------
msg "Building (this takes a few minutes on a T400)"
if [ "$RUN_TESTS" -eq 1 ]; then
  export DEB_BUILD_OPTIONS="parallel=$(nproc)"
else
  export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
fi
dpkg-buildpackage -B -us -uc

# Keep the image capture example: handy to see what the sensor produces
mkdir -p "$WORK_DIR/tools"
cp obj-*/examples/img-capture "$WORK_DIR/tools/" 2>/dev/null || true

cd "$BUILD_DIR"
DEBS=()
for pkg in libfprint-2-2 gir1.2-fprint-2.0 libfprint-2-dev libfprint-2-tests; do
  deb="$(ls "${pkg}_${NEW_VER_NOEPOCH}"_*.deb 2>/dev/null | head -n1 || true)"
  [ -n "$deb" ] || continue
  # Always install the library; others only if the stock one is installed,
  # since they depend on the exact same library version.
  if [ "$pkg" = libfprint-2-2 ] || dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
    DEBS+=("$BUILD_DIR/$deb")
  fi
done
[ ${#DEBS[@]} -gt 0 ] || die "build finished but libfprint-2-2_${NEW_VER_NOEPOCH}_*.deb was not found"
msg "Built packages:"
printf '  %s\n' "${DEBS[@]}"

if [ "$INSTALL" -eq 0 ]; then
  echo
  echo "Not installing (--no-install). To install later:"
  echo "  sudo apt-get install ${DEBS[*]}"
  exit 0
fi

# --- 8. Install --------------------------------------------------------------
msg "Installing the patched packages"
$SUDO apt-get install -y --allow-downgrades "${DEBS[@]}"
HOLD=()
for d in "${DEBS[@]}"; do HOLD+=("$(dpkg-deb -f "$d" Package)"); done
$SUDO apt-mark hold "${HOLD[@]}"
$SUDO systemctl try-restart fprintd.service 2>/dev/null || true

msg "Done! libfprint $(dpkg-query -W -f='${Version}' libfprint-2-2) is installed and on hold."
cat <<EOF

Next steps (see README.md):
  1. Delete the old, unusable enrollment:     fprintd-delete "\$USER"
  2. Optionally use more enroll swipes:       sudo $HERE/t400-fprint.sh set --stages 8
  3. Enroll again (as your user, no sudo):    fprintd-enroll
  4. Test it:                                 fprintd-verify
  5. Measure your match scores / tune:        $HERE/t400-fprint.sh calibrate

To go back to the stock Debian package:
  sudo apt-mark unhold ${HOLD[*]}
  sudo apt-get install --allow-downgrades $(for p in "${HOLD[@]}"; do printf '%s=%s ' "$p" "$DEB_VERSION"; done)
EOF
