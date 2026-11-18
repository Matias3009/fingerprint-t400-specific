#!/usr/bin/env bash
#
# Helper for the UPEK 147e:2016 fingerprint reader (ThinkPad T400 & co).
#
#   t400-fprint.sh info                      show sensor, driver, versions, settings
#   t400-fprint.sh set [--threshold N] [--stages N]
#                                            tune matching (needs the patched libfprint)
#   t400-fprint.sh reset                     remove all tuning, back to defaults
#   t400-fprint.sh debug on|off              log libfprint match scores to the journal
#   t400-fprint.sh calibrate [--impostor] [-n COUNT] [-f FINGER]
#                                            measure the match scores of your swipes
#                                            and suggest a threshold
#
# "set", "reset" and "debug" change a systemd drop-in for fprintd.service and
# use sudo. "calibrate" must run as the user whose fingers are enrolled.

set -euo pipefail

DROPIN_DIR=/etc/systemd/system/fprintd.service.d
DROPIN="$DROPIN_DIR/t400-tuning.conf"
DEBUG_DOMAINS="libfprint-print libfprint-image_device"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/t400-fprint"

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"

# ---------------------------------------------------------------------------
# Drop-in handling
# ---------------------------------------------------------------------------
cur_value() {  # $1 = variable name -> prints its value from the drop-in, if any
  [ -r "$DROPIN" ] || return 0
  sed -n "s/^Environment=\"\{0,1\}$1=\([^\"]*\)\"\{0,1\}$/\1/p" "$DROPIN" | tail -n1
}

write_dropin() {  # $1 threshold, $2 stages, $3 debug (on/off)
  local thr="$1" stg="$2" dbg="$3"
  if [ -z "$thr" ] && [ -z "$stg" ] && [ "$dbg" != on ]; then
    $SUDO rm -f "$DROPIN"
    $SUDO rmdir "$DROPIN_DIR" 2>/dev/null || true
  else
    {
      echo "# Written by t400-fprint.sh - tuning for the UPEK 147e:2016 reader"
      echo "[Service]"
      [ -n "$thr" ] && echo "Environment=LIBFPRINT_BZ3_THRESHOLD=$thr"
      [ -n "$stg" ] && echo "Environment=LIBFPRINT_ENROLL_STAGES=$stg"
      [ "$dbg" = on ] && echo "Environment=\"G_MESSAGES_DEBUG=$DEBUG_DOMAINS\""
      true
    } | $SUDO install -D -m 0644 /dev/stdin "$DROPIN"
  fi
  $SUDO systemctl daemon-reload
  # fprintd is D-Bus activated: stopping it is enough, it restarts on demand
  # with the new environment.
  $SUDO systemctl stop fprintd.service 2>/dev/null || true
}

cur_debug() { [ -n "$(cur_value G_MESSAGES_DEBUG)" ] && echo on || echo off; }

check_num() {  # name value min max
  [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge "$3" ] && [ "$2" -le "$4" ] \
    || die "$1 must be a number between $3 and $4"
}

is_patched() { dpkg-query -W -f='${Version}' libfprint-2-2 2>/dev/null | grep -q '+t400'; }

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_info() {
  echo "== Sensor"
  if ! command -v lsusb >/dev/null; then
    echo "lsusb not found (sudo apt install usbutils)"
  elif ! lsusb -d 147e:2016 >/dev/null 2>&1; then
    echo "No UPEK 147e:2016 sensor found. Is it enabled in the BIOS (Security > I/O Port Access)?"
    lsusb | grep -iE "upek|fingerprint|147e:|0483:2016|138a:|08ff:" || true
  else
    lsusb -d 147e:2016
    local bcd="" d
    for d in /sys/bus/usb/devices/*; do
      if [ "$(cat "$d/idVendor" 2>/dev/null)" = 147e ] && [ "$(cat "$d/idProduct" 2>/dev/null)" = 2016 ]; then
        bcd="$(cat "$d/bcdDevice")"; break
      fi
    done
    case "$bcd" in
      0001) echo "Revision 0.01 -> libfprint driver: upeksonly  (stock threshold 40, patched 25)" ;;
      0002) echo "Revision 0.02 -> libfprint driver: upektc_img (threshold 20)" ;;
      *)    echo "Revision '$bcd' -> not handled by libfprint 1.94 (only 0.01 and 0.02 are)" ;;
    esac
  fi

  echo; echo "== Packages"
  dpkg-query -W -f='${Package} ${Version}\n' libfprint-2-2 fprintd libpam-fprintd 2>/dev/null || true
  if is_patched; then echo "Patched libfprint: yes"; else echo "Patched libfprint: NO (run ./build-patched-libfprint.sh)"; fi
  apt-mark showhold 2>/dev/null | grep -E 'fprint' | sed 's/^/On hold: /' || true

  echo; echo "== Tuning ($DROPIN)"
  if [ -r "$DROPIN" ]; then grep '^Environment' "$DROPIN"; else echo "none (driver defaults)"; fi

  echo; echo "== Enrolled fingers for $USER"
  fprintd-list "$USER" 2>/dev/null | sed -n '/Fingerprints for user/,$p' || echo "fprintd-list failed"
}

cmd_set() {
  local thr stg
  thr="$(cur_value LIBFPRINT_BZ3_THRESHOLD)"; stg="$(cur_value LIBFPRINT_ENROLL_STAGES)"
  [ $# -gt 0 ] || die "usage: set [--threshold N|default] [--stages N|default]"
  while [ $# -gt 0 ]; do
    case "$1" in
      --threshold) thr="${2:-}"; shift ;;
      --stages)    stg="${2:-}"; shift ;;
      *) die "unknown option $1" ;;
    esac
    shift
  done
  [ "$thr" = default ] && thr=""
  [ "$stg" = default ] && stg=""
  [ -z "$thr" ] || check_num threshold "$thr" 1 200
  [ -z "$stg" ] || check_num stages "$stg" 1 20
  is_patched || echo "Note: the stock libfprint ignores these settings, build the patched one first." >&2
  write_dropin "$thr" "$stg" "$(cur_debug)"
  echo "Saved. threshold=${thr:-driver default} stages=${stg:-driver default}"
  [ -z "$stg" ] || echo "Re-enroll (fprintd-delete \$USER; fprintd-enroll) for the new stage count to matter."
}

cmd_reset() {
  write_dropin "" "" off
  echo "Tuning removed, fprintd uses the driver defaults again."
}

cmd_debug() {
  case "${1:-}" in
    on|off) ;;
    *) die "usage: debug on|off" ;;
  esac
  write_dropin "$(cur_value LIBFPRINT_BZ3_THRESHOLD)" "$(cur_value LIBFPRINT_ENROLL_STAGES)" "$1"
  echo "Debug logging $1."
  [ "$1" = off ] || echo "Watch the scores with: sudo journalctl -fu fprintd | grep score"
}

cmd_calibrate() {
  local kind=genuine count=5 finger=() i
  while [ $# -gt 0 ]; do
    case "$1" in
      --impostor) kind=impostor ;;
      -n) count="${2:-}"; shift ;;
      -f) finger=(-f "${2:-}"); shift ;;
      *) die "unknown option $1" ;;
    esac
    shift
  done
  check_num count "$count" 1 50
  [ "$(id -u)" -ne 0 ] || die "run calibrate as your normal user (the one with enrolled fingers), not root"
  command -v fprintd-verify >/dev/null || die "fprintd is not installed"
  fprintd-list "$USER" 2>/dev/null | grep -q ' - #' || die "no fingers enrolled for $USER, run fprintd-enroll first"

  # Remember the settings, then: debug on + impossible threshold, so every
  # enrolled sample gets scored and we see the best score of each swipe.
  local old_thr old_stg old_dbg
  old_thr="$(cur_value LIBFPRINT_BZ3_THRESHOLD)"
  old_stg="$(cur_value LIBFPRINT_ENROLL_STAGES)"
  old_dbg="$(cur_debug)"
  restore() { echo; echo "Restoring previous settings..."; write_dropin "$old_thr" "$old_stg" "$old_dbg"; }
  trap restore EXIT
  trap 'exit 130' INT TERM

  if is_patched; then
    write_dropin 200 "$old_stg" on
    echo "Matching is disabled during calibration: every swipe will say 'no-match', that is expected."
  else
    write_dropin "" "$old_stg" on
    echo "Stock libfprint: matching stops at the first good sample, so scores of matched swipes are a lower bound."
  fi

  mkdir -p "$CACHE_DIR"
  local out="$CACHE_DIR/$kind.txt" tmp scores best
  : > "$out"
  tmp="$(mktemp)"
  echo
  if [ "$kind" = genuine ]; then
    echo ">>> Swipe an ENROLLED finger, $count times, the same way you did when enrolling."
  else
    echo ">>> Swipe fingers that are NOT enrolled (other fingers, other people), $count times."
  fi

  for i in $(seq 1 "$count"); do
    echo; echo "--- Swipe $i/$count"
    local since; since="$(date +%s)"
    fprintd-verify "${finger[@]}" 2>&1 | tee "$tmp" | grep -E "result|Swipe|swipe|finger" || true
    sleep 1
    scores="$($SUDO journalctl -u fprintd.service --since "@$since" -o cat 2>/dev/null \
              | grep -oE 'score [0-9]+/' | grep -oE '[0-9]+' || true)"
    if [ -z "$scores" ]; then
      echo "    no score logged (swipe not accepted: too short/fast, or centred badly). Not counted."
      continue
    fi
    best="$(printf '%s\n' "$scores" | sort -n | tail -n1)"
    echo "    best score: $best   (all samples: $(printf '%s ' $scores))"
    echo "$best" >> "$out"
  done
  rm -f "$tmp"

  echo
  summarize
}

stats() {  # file -> "n min median max"
  sort -n "$1" | awk '{a[NR]=$1} END {if (NR) printf "%d %d %d %d", NR, a[1], a[int((NR+1)/2)], a[NR]}'
}

summarize() {
  local g="$CACHE_DIR/genuine.txt" i="$CACHE_DIR/impostor.txt" gs is
  [ -s "$g" ] && gs="$(stats "$g")" || gs=""
  [ -s "$i" ] && is="$(stats "$i")" || is=""
  echo "================ Calibration summary ================"
  [ -n "$gs" ] && set -- $gs && echo "Enrolled finger : $1 swipes, best scores min $2 / median $3 / max $4"
  [ -n "$is" ] && set -- $is && echo "Other fingers   : $1 swipes, best scores min $2 / median $3 / max $4"
  if [ -n "$gs" ] && [ -n "$is" ]; then
    local gmed imax sugg
    gmed="$(echo "$gs" | cut -d' ' -f3)"; imax="$(echo "$is" | cut -d' ' -f4)"
    if [ "$gmed" -gt $((imax + 3)) ]; then
      sugg=$(( (gmed + imax + 1) / 2 ))
      [ "$sugg" -ge $((imax + 3)) ] || sugg=$((imax + 3))
      echo
      echo "Suggested threshold: $sugg   ->  sudo $0 set --threshold $sugg"
      echo "(above every score a wrong finger reached, below most of your real swipes)"
    else
      echo
      echo "Real and wrong fingers score about the same: lowering the threshold would let"
      echo "other fingers in. Improve the enrollment instead (see README: swiping technique,"
      echo "more enroll stages) and calibrate again."
    fi
  elif [ -n "$gs" ]; then
    echo
    echo "Now measure fingers that are NOT enrolled, so a safe threshold can be suggested:"
    echo "  $0 calibrate --impostor"
  else
    echo "Now measure your enrolled finger:  $0 calibrate"
  fi
}

case "${1:-}" in
  info)      shift; cmd_info "$@" ;;
  set)       shift; cmd_set "$@" ;;
  reset)     shift; cmd_reset "$@" ;;
  debug)     shift; cmd_debug "$@" ;;
  calibrate) shift; cmd_calibrate "$@" ;;
  summary)   summarize ;;
  -h|--help|help|"") sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
  *) die "unknown command '$1' (see --help)" ;;
esac
