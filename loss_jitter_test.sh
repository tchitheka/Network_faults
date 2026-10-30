#!/usr/bin/env bash
#
# loss_jitter_test.sh - packet loss plus delay variation (jitter) fault
#
# Adds random packet loss AND jitter to the gateway's WAN interface with
# Linux netem, for the "Packet loss and jitter" scenario. Same approach and
# same safeguards as qoe_delay_test.sh and wan_packet_loss_test.sh, which
# this script is modelled on. Run it on the gateway, as root (or via sudo).
# Never run it together with those two: they share the interface's one
# netem qdisc.
#
# USAGE
#   sudo ./loss_jitter_test.sh <loss_percent> <jitter_ms> <minutes> [interface] [base_delay_ms]
#   sudo ./loss_jitter_test.sh --clear [interface]
#
#   loss_percent   Packet loss, 1-50 (whole number).
#   jitter_ms      Random variation in delay, whole ms, 1 or more.
#   minutes        How long to hold the fault before it clears itself.
#   interface      Default enx00e04c507970 (the gateway WAN interface).
#   base_delay_ms  Mean added delay. Default: the same as jitter_ms. netem
#                  cannot go below zero delay, so a jitter of J needs a mean
#                  of at least J for the spread to be real.
#
# EXAMPLES
#   sudo ./loss_jitter_test.sh 10 50 5     # 10% loss, 50 ms +/- 50 ms, 5 minutes
#   sudo ./loss_jitter_test.sh --clear
#
# SAFETY
#   Clears any existing netem rule first (no stacking), removes the rule on
#   EXIT/INT/TERM/HUP, and expires by itself after the requested time.
#   `--clear` is the explicit way out if the script was killed with -9.
#
set -u

DEFAULT_IFACE="enx00e04c507970"
LOG_FILE="${LOSS_JITTER_TEST_LOG:-/tmp/loss_jitter_test.log}"

usage() {
  echo "Usage: $0 <loss_percent> <jitter_ms> <minutes> [interface] [base_delay_ms]" >&2
  echo "       $0 --clear [interface]" >&2
  exit 1
}
isint() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then exec sudo "$0" "$@"; fi
    echo "Error: this must run as root, and sudo is not available." >&2; exit 1
  fi
}

if [ "${1:-}" = "--clear" ]; then
  command -v tc >/dev/null 2>&1 || { echo "Error: 'tc' (iproute2) not found." >&2; exit 1; }
  need_root "$@"
  tc qdisc del dev "${2:-$DEFAULT_IFACE}" root 2>/dev/null
  echo "Cleared any netem rule on ${2:-$DEFAULT_IFACE}."
  exit 0
fi

LOSS="${1:-}"; JITTER="${2:-}"; MINUTES="${3:-}"; IFACE="${4:-$DEFAULT_IFACE}"; BASE="${5:-$JITTER}"

isint "$LOSS" && [ "$LOSS" -ge 1 ] && [ "$LOSS" -le 50 ] || { echo "Error: <loss_percent> must be a whole number from 1 to 50." >&2; usage; }
isint "$JITTER" && [ "$JITTER" -ge 1 ] || { echo "Error: <jitter_ms> must be a whole number, 1 or more." >&2; usage; }
isint "$MINUTES" && [ "$MINUTES" -ge 1 ] || { echo "Error: <minutes> must be a whole number, 1 or more." >&2; usage; }
isint "$BASE" && [ "$BASE" -ge 1 ] || { echo "Error: <base_delay_ms> must be a whole number, 1 or more." >&2; usage; }

command -v tc >/dev/null 2>&1 || { echo "Error: 'tc' (iproute2) not found. apt install iproute2" >&2; exit 1; }
need_root "$@"
ip link show "$IFACE" >/dev/null 2>&1 || { echo "Error: interface '${IFACE}' does not exist. Check: ip -br link show" >&2; exit 1; }

cleanup() { tc qdisc del dev "$IFACE" root 2>/dev/null; log "cleared netem rule on ${IFACE}"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

tc qdisc del dev "$IFACE" root 2>/dev/null
SPEC="delay ${BASE}ms ${JITTER}ms loss ${LOSS}%"
echo "Applying netem on ${IFACE}: ${SPEC}, for ${MINUTES} minute(s)."
echo "This affects ALL traffic the gateway sends to the internet during the test."
log "applying netem on ${IFACE}: ${SPEC}, duration=${MINUTES}m"
if ! tc qdisc add dev "$IFACE" root netem $SPEC 2>>"$LOG_FILE"; then
  echo "Error: failed to apply netem rule. Check ${LOG_FILE}." >&2; exit 1
fi
echo "Active. Will auto-clear in ${MINUTES} minute(s). Ctrl+C clears it immediately."
end_ts=$(( $(date +%s) + MINUTES * 60 ))
while [ "$(date +%s)" -lt "$end_ts" ]; do sleep 1; done
echo "Duration elapsed."
