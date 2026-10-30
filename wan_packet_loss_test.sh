#!/usr/bin/env bash
#
# wan_packet_loss_test.sh — WAN packet loss fault-injection tool
#
# Induces controlled packet loss on the gateway's WAN-facing interface
# using netem's `loss` parameter, to exercise the WAN half of the
# "Network Health Check" panel's node_qoe_packet_loss_ratio indicator.
#
# MUST run on the gateway itself, as root (or via sudo).
#
# --------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS SEPARATELY FROM qoe_delay_test.sh
# --------------------------------------------------------------------
# qoe_delay_test.sh applies netem `delay` to the same interface, but
# delay alone does not drop packets -- it only holds them in the egress
# queue longer. node_qoe_packet_loss_ratio is computed entirely by
# latency.py's own fping-based loss counting, a software measurement of
# how many of its probes never got a reply in time, not a kernel
# counter. netem's `loss` parameter is the correct, direct mechanism:
# it probabilistically drops packets at the qdisc layer before they
# ever reach the driver, which will cause a real, controllable
# fraction of fping's own probes to genuinely go unanswered.
#
# --------------------------------------------------------------------
# THRESHOLD (from the panel's own query)
# --------------------------------------------------------------------
#   node_qoe_packet_loss_ratio{job="gw-latency"} * 100 > bool 1
#
#   Any loss ratio above 1% flips the WAN flag from 0 to 1, which
#   (combined with the Wi-Fi flag) drives the panel to verdict 2
#   ("Internet issue") if the Wi-Fi side is clear, or verdict 3 if
#   both sides are faulted at once. There is no multi-level WAN
#   threshold here, unlike the QoE RTT panel -- this is a single,
#   binary cutoff.
#
# USAGE
#   sudo ./wan_packet_loss_test.sh <loss_percent> <minutes> [interface]
#   sudo ./wan_packet_loss_test.sh --clear [interface]
#
# ARGUMENTS
#   loss_percent   Required. Packet loss percentage to induce (e.g. 15
#                  for 15%). Comfortably above 1 will flip the WAN flag;
#                  values above ~30-40% start to risk the gateway's own
#                  fping probes themselves failing so completely that
#                  latency.py records zero RTT samples for the window
#                  (see the NO_DATA_SENTINEL_MS note below).
#   minutes        Required. How long to hold the fault before
#                  automatically clearing it.
#   interface      Optional. Default: wlx90de80e8fae5 (this gateway's
#                  current WAN interface). Override only if that
#                  adapter has since been renamed or replaced.
#
# EXAMPLES
#   sudo ./wan_packet_loss_test.sh 15 5
#       15% packet loss for 5 minutes -- comfortably flips the WAN
#       flag without starving latency.py of every RTT sample.
#
#   sudo ./wan_packet_loss_test.sh --clear
#       Manual escape hatch if a previous run's cleanup didn't fire.
#
# NOTE ON INTERACTION WITH latency.py'S OWN SENTINEL
#   If loss_percent is high enough that fping gets zero replies across
#   an entire run, latency.py writes NO_DATA_SENTINEL_MS (99999) for
#   RTT, which correctly drives the separate QoE RTT panel to its worst
#   state too -- expected and fine, not a bug, if you are deliberately
#   testing a severe combined outage. If you want to isolate JUST the
#   packet-loss half without also tripping the RTT panel, keep
#   loss_percent low enough that most probes still get through
#   (10-20% is a reasonable starting point).
#
# SAFETY
#   Same discipline as qoe_delay_test.sh: clears any pre-existing
#   netem rule before applying a new one (never stacks), installs a
#   cleanup trap on EXIT/INT/TERM that explicitly exits afterward
#   (bash's default post-trap behaviour is to resume execution, not
#   terminate -- this bit qoe_delay_test.sh during development and is
#   deliberately avoided here from the start), and polls in short
#   intervals rather than one long sleep, so the trap is checked
#   promptly regardless of how the script was invoked.

set -u

DEFAULT_IFACE="wlx90de80e8fae5"
LOG_FILE="${WAN_LOSS_TEST_LOG:-/tmp/wan_packet_loss_test.log}"

usage() {
  echo "Usage: $0 <loss_percent> <minutes> [interface]" >&2
  echo "       $0 --clear [interface]" >&2
  echo "  loss_percent  required, whole number 1-100" >&2
  echo "  minutes       required, positive whole number" >&2
  echo "  interface     optional; default ${DEFAULT_IFACE}" >&2
  exit 1
}

require_nonneg_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

ensure_tc_and_root() {
  if ! command -v tc >/dev/null 2>&1; then
    echo "Error: 'tc' (iproute2) not found. Install it (e.g. apt install iproute2) before running this script." >&2
    exit 1
  fi
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo "$0" "$@"
    else
      echo "Error: this must run as root, and sudo is not available." >&2
      exit 1
    fi
  fi
}

# --clear MUST be checked before numeric validation -- an earlier
# fault-injection script in this same set (qoe_delay_test.sh) initially
# placed this check after validation, which made --clear unreachable
# since "--clear" always failed the numeric check first. Fixed here
# from the start rather than repeating that bug.
if [ "${1:-}" = "--clear" ]; then
  ensure_tc_and_root "$@"
  CLEAR_IFACE="${2:-$DEFAULT_IFACE}"
  tc qdisc del dev "$CLEAR_IFACE" root 2>/dev/null
  echo "Cleared any netem rule on ${CLEAR_IFACE}."
  exit 0
fi

LOSS_PCT="${1:-}"
MINUTES="${2:-}"
IFACE="${3:-$DEFAULT_IFACE}"

[ -z "$LOSS_PCT" ] && usage
[ -z "$MINUTES" ] && usage
require_nonneg_int "$LOSS_PCT" || { echo "Error: <loss_percent> must be a whole number." >&2; usage; }
[ "$LOSS_PCT" -ge 1 ] && [ "$LOSS_PCT" -le 100 ] || { echo "Error: <loss_percent> must be between 1 and 100." >&2; usage; }
require_nonneg_int "$MINUTES" || { echo "Error: <minutes> must be a positive whole number." >&2; usage; }
[ "$MINUTES" -gt 0 ] || { echo "Error: <minutes> must be greater than zero." >&2; usage; }

ensure_tc_and_root "$@"

if ! ip link show "$IFACE" >/dev/null 2>&1; then
  echo "Error: interface '${IFACE}' does not exist on this machine." >&2
  echo "Check the current WAN interface name with: ip -br link show" >&2
  exit 1
fi

cleanup() {
  tc qdisc del dev "$IFACE" root 2>/dev/null
  log "cleared netem rule on ${IFACE}"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 129' HUP

tc qdisc del dev "$IFACE" root 2>/dev/null

echo "Applying netem on ${IFACE}: loss ${LOSS_PCT}%, for ${MINUTES} minute(s)."
echo "This drops ${LOSS_PCT}% of ALL traffic the gateway sends to the internet during the test, not just the QoE probe."
log "applying netem on ${IFACE}: loss ${LOSS_PCT}%, duration=${MINUTES}m"

if ! tc qdisc add dev "$IFACE" root netem loss "${LOSS_PCT}%" 2>>"$LOG_FILE"; then
  echo "Error: failed to apply netem rule. Check ${LOG_FILE} for details." >&2
  exit 1
fi

echo "Active. Will auto-clear in ${MINUTES} minute(s). Ctrl+C clears it immediately."
end_ts=$(( $(date +%s) + MINUTES * 60 ))
while [ "$(date +%s)" -lt "$end_ts" ]; do
  sleep 1
done

echo "Duration elapsed."
