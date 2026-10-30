#!/usr/bin/env bash
#
# qoe_delay_test.sh — Connection Speed (QoE) fault-injection tool
#
# Induces controlled additional latency on the gateway's WAN-facing
# interface using Linux's netem queueing discipline, to exercise the
# "Connection Speed (QoE)" panel's node_qoe_rtt_p90_ms indicator.
#
# MUST run on the gateway itself, as root (or via sudo). Not the AP,
# not a station. See the header comment block below for exactly why.
#
# --------------------------------------------------------------------
# WHY THIS INTERFACE, AND ONLY THIS ONE
# --------------------------------------------------------------------
# node_qoe_rtt_p90_ms is computed by latency.py, running as a cron job
# on the gateway. Each run pings 8.8.8.8 and 1.1.1.1 directly from the
# gateway (20 probes each, via fping) and computes the 90th percentile
# of the pooled RTT samples. That probe traffic's entire path is:
#
#   gateway --(wlx90de80e8fae5, WAN)--> internet --> 8.8.8.8 / 1.1.1.1
#
# It never touches the AP, never touches a station, and never touches
# the gateway's LAN-facing interface (eno1). Adding delay anywhere on
# the AP (br-lan, eth0, phy0-ap0) or on eno1 would genuinely degrade
# the LAN-side hop, a real and useful thing to test separately, but it
# is traffic this specific probe never travels through, so it would
# have zero effect on this panel. Only wlx90de80e8fae5 sits on the
# probe's actual path.
#
# --------------------------------------------------------------------
# THRESHOLDS (from the panel's own PromQL query)
# --------------------------------------------------------------------
#   clamp_min(clamp_max(floor((300 - node_qoe_rtt_p90_ms) / 150), 2), 0)
#
#   P90 RTT        Verdict   Panel text
#   0    - 150ms   2 (green) Healthy
#   150  - 300ms   1 (orange) "Elevated -- some users may notice delays"
#   >300ms         0 (red)    Critical
#
#   These boundaries are added ON TOP of whatever the real baseline
#   latency to 8.8.8.8/1.1.1.1 already is, not measured from zero.
#   Check the panel (or run one `fping -C5 8.8.8.8`) immediately before
#   choosing --delay, so baseline + delay lands where you actually
#   intend rather than landing one band over by accident.
#
# --------------------------------------------------------------------
# SAFETY
# --------------------------------------------------------------------
# This delays ALL traffic the gateway itself sends to the internet
# during the test, not just the probe traffic -- it is a genuine
# interface-level change, which is what makes it a faithful fault
# test. The script therefore:
#   - clears any pre-existing netem rule on the target interface
#     before applying a new one, so repeated runs never stack delays
#     on top of each other;
#   - installs a cleanup trap on EXIT, INT, and TERM, so the rule is
#     removed even if the script is killed, Ctrl+C'd, or the SSH
#     session drops mid-test;
#   - auto-expires after the requested duration with no further
#     action needed.
#
# USAGE
#   sudo ./qoe_delay_test.sh <extra_delay_ms> <minutes> [jitter_ms] [interface]
#
# ARGUMENTS
#   extra_delay_ms   Required. Additional latency, in milliseconds,
#                    added on top of the current real latency.
#   minutes          Required. How long to hold the fault before
#                    automatically clearing it.
#   jitter_ms        Optional. Random variance around extra_delay_ms,
#                    to simulate real instability rather than a flat,
#                    unnaturally constant added delay. Default: 0.
#   interface        Optional. Default: wlx90de80e8fae5 (this
#                    gateway's current WAN interface). Override only
#                    if that adapter has since been renamed/replaced.
#
# EXAMPLES
#   sudo ./qoe_delay_test.sh 200 5
#       Push toward the orange "Elevated" band for 5 minutes.
#
#   sudo ./qoe_delay_test.sh 400 5 50
#       Push toward the red "Critical" band, with +/-50ms jitter.

set -u

DEFAULT_IFACE="wlx90de80e8fae5"
LOG_FILE="${QOE_DELAY_TEST_LOG:-/tmp/qoe_delay_test.log}"

usage() {
  echo "Usage: $0 <extra_delay_ms> <minutes> [jitter_ms] [interface]" >&2
  echo "  extra_delay_ms  required, positive whole number (ms)" >&2
  echo "  minutes         required, positive whole number" >&2
  echo "  jitter_ms       optional, whole number (ms); default 0" >&2
  echo "  interface       optional; default ${DEFAULT_IFACE}" >&2
  echo "" >&2
  echo "Thresholds (added on top of current real latency):" >&2
  echo "  ~150-300ms total P90 RTT -> orange 'Elevated' verdict" >&2
  echo "  >300ms total P90 RTT     -> red 'Critical' verdict" >&2
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

DELAY_MS="${1:-}"
MINUTES="${2:-}"
JITTER_MS="${3:-0}"
IFACE="${4:-$DEFAULT_IFACE}"

# --clear as a standalone first argument: remove any existing rule and exit,
# without needing to specify delay/minutes. Useful if a previous run was
# killed in a way the trap somehow didn't catch (e.g. `kill -9`, which no
# trap can intercept), so there is always a simple, explicit way back out.
# This MUST be checked before the numeric validation below, since "--clear"
# is not a valid delay value and would otherwise always be rejected first.
if [ "${1:-}" = "--clear" ]; then
  if ! command -v tc >/dev/null 2>&1; then
    echo "Error: 'tc' (iproute2) not found." >&2
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
  CLEAR_IFACE="${2:-$DEFAULT_IFACE}"
  tc qdisc del dev "$CLEAR_IFACE" root 2>/dev/null
  echo "Cleared any netem rule on ${CLEAR_IFACE}."
  exit 0
fi

[ -z "$DELAY_MS" ] && usage
[ -z "$MINUTES" ] && usage
require_nonneg_int "$DELAY_MS" || { echo "Error: <extra_delay_ms> must be a non-negative whole number." >&2; usage; }
[ "$DELAY_MS" -gt 0 ] || { echo "Error: <extra_delay_ms> must be greater than zero (use --clear to just remove an existing rule)." >&2; usage; }
require_nonneg_int "$MINUTES" || { echo "Error: <minutes> must be a positive whole number." >&2; usage; }
[ "$MINUTES" -gt 0 ] || { echo "Error: <minutes> must be greater than zero." >&2; usage; }
require_nonneg_int "$JITTER_MS" || { echo "Error: [jitter_ms] must be a non-negative whole number." >&2; usage; }

if ! command -v tc >/dev/null 2>&1; then
  echo "Error: 'tc' (iproute2) not found. Install it (e.g. apt install iproute2) before running this script." >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    echo "Re-running with sudo (tc qdisc changes require root)..."
    exec sudo "$0" "$@"
  else
    echo "Error: this must run as root, and sudo is not available. Re-run as root directly." >&2
    exit 1
  fi
fi

if ! ip link show "$IFACE" >/dev/null 2>&1; then
  echo "Error: interface '${IFACE}' does not exist on this machine." >&2
  echo "Check the current WAN interface name with: ip -br link show" >&2
  exit 1
fi

cleanup() {
  tc qdisc del dev "$IFACE" root 2>/dev/null
  log "cleared netem rule on ${IFACE}"
}
# EXIT alone is not enough: bash's default behaviour after an INT/TERM
# trap handler *returns* is to resume execution where the script was
# interrupted, not to terminate. Without an explicit exit here, Ctrl+C
# would correctly clear the qdisc rule (safe) but then silently resume
# the polling loop for the rest of the duration (confusing -- the
# terminal would appear to hang rather than actually stopping).
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 129' HUP

# Clear any leftover rule from a prior run before applying a new one,
# so repeated invocations never stack delays on top of each other.
tc qdisc del dev "$IFACE" root 2>/dev/null

if [ "$JITTER_MS" -gt 0 ]; then
  NETEM_SPEC="delay ${DELAY_MS}ms ${JITTER_MS}ms"
else
  NETEM_SPEC="delay ${DELAY_MS}ms"
fi

echo "Applying netem on ${IFACE}: ${NETEM_SPEC}, for ${MINUTES} minute(s)."
echo "This delays ALL traffic the gateway sends to the internet during the test, not just the QoE probe."
log "applying netem on ${IFACE}: ${NETEM_SPEC}, duration=${MINUTES}m"

if ! tc qdisc add dev "$IFACE" root netem $NETEM_SPEC 2>>"$LOG_FILE"; then
  echo "Error: failed to apply netem rule. Check ${LOG_FILE} for details." >&2
  exit 1
fi

echo "Active. Will auto-clear in ${MINUTES} minute(s). Ctrl+C clears it immediately."

# Poll in short (1s) increments rather than blocking in one long sleep.
# A single `sleep $((MINUTES*60))` leaves bash waiting on a child process;
# depending on how this script is invoked (foreground terminal vs a
# background job, as tested during development), a signal sent to the
# script's own PID does not always interrupt that wait promptly, which
# would leave the trap-based cleanup unreliable -- exactly the failure
# mode this script cannot afford, given it is actively degrading the
# gateway's real internet connection for the duration of the test. Short
# sleeps mean bash re-checks for pending signals/traps roughly once a
# second throughout, so Ctrl+C (or any kill signal) is honoured promptly
# regardless of how the script was launched.
end_ts=$(( $(date +%s) + MINUTES * 60 ))
while [ "$(date +%s)" -lt "$end_ts" ]; do
  sleep 1
done

echo "Duration elapsed."
# cleanup() runs automatically via the EXIT trap from here.
