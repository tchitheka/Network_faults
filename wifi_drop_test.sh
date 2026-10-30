#!/bin/sh
#
# wifi_drop_test.sh — Local Wi-Fi drop-ratio fault-injection tool
#
# Induces controlled packet loss on AP1's station-facing radio interface
# (phy0-ap0) using netem's `loss` parameter, to exercise the Wi-Fi half
# of the "Network Health Check" panel's drop-ratio indicator.
#
# Written in POSIX sh, not bash: the AP runs OpenWrt, whose default
# shell is BusyBox ash, not bash. This script is designed to work
# whether run directly on the AP (already SSH'd in) or dispatched from
# the gateway/workstation over SSH -- both paths execute the exact same
# POSIX-compatible code.
#
# --------------------------------------------------------------------
# AN OPEN TECHNICAL QUESTION -- READ BEFORE RELYING ON THIS SCRIPT
# --------------------------------------------------------------------
# The panel reads node_network_transmit_drop_total / receive_drop_total
# on phy0-ap0, which node_exporter sources from /proc/net/dev's own
# per-interface drop counters. netem's `loss` mechanism drops packets
# at the qdisc layer, before they reach the driver, by calling the
# kernel's qdisc_drop() path. Whether that specific drop path also
# increments the *device-level* tx_dropped/rx_dropped counters that
# /proc/net/dev (and therefore this Prometheus metric) exposes, as
# opposed to only the qdisc's own internal stats visible via
# `tc -s qdisc show`, was not something I could verify without live
# access to this exact kernel/qdisc combination. It is the expected,
# commonly-documented behaviour on modern Linux, but "expected" is not
# "confirmed" -- the first thing this script does after applying the
# fault is print the exact commands to check both data sources
# side by side, so you can confirm empirically on the very first run
# whether this mechanism actually moves the metric it is meant to.
#
# --------------------------------------------------------------------
# THRESHOLD (from the panel's own query)
# --------------------------------------------------------------------
#   100 * (tx_drops + rx_drops) / (tx_drops + rx_drops + tx_pkts + rx_pkts) > bool 1
#
#   Any drop ratio above 1% of attempted TX+RX packets on phy0-ap0
#   flips the Wi-Fi flag. Like the WAN loss script, this is a single
#   binary cutoff, not a multi-level threshold.
#
# USAGE
#   Dispatched from elsewhere (gateway/workstation):
#     ./wifi_drop_test.sh <loss_percent> <minutes> [user@ap_host]
#
#   Run directly on the AP itself (already SSH'd in):
#     ./wifi_drop_test.sh <loss_percent> <minutes>
#
#   Clear a stuck rule:
#     ./wifi_drop_test.sh --clear [user@ap_host]
#
# ARGUMENTS
#   loss_percent   Required. Packet loss percentage on phy0-ap0.
#   minutes        Required. Duration before automatic clearing.
#   user@ap_host   Optional. If given (and this invocation is NOT
#                  already running on the AP), dispatches over SSH.
#                  Default target if omitted: root@192.168.1.100
#                  (AP1's known address throughout this deployment).
#
# EXAMPLES
#   ./wifi_drop_test.sh 15 5
#       15% loss on phy0-ap0 for 5 minutes, dispatched to the default
#       AP address over SSH.
#
#   ./wifi_drop_test.sh 15 5 root@192.168.1.100
#       Same, with the AP address stated explicitly.
#
# PREREQUISITE ON THE AP
#   Minimal OpenWrt images often do not ship tc/netem by default:
#     opkg update && opkg install tc kmod-sched
#   This script checks for `tc` and fails with that exact instruction
#   if it is missing, rather than failing unclearly partway through.
#
# SAFETY
#   Affects ALL traffic the AP sends to and receives from every
#   connected station on phy0-ap0, not just one test client -- same
#   scope caveat as the WAN-side script, one level down the topology.
#   Same cleanup discipline as the other fault-injection scripts in
#   this set: clears any pre-existing rule before applying a new one,
#   traps EXIT/INT/TERM with an explicit exit after cleanup, and polls
#   in short intervals rather than one long sleep.

IFACE="phy0-ap0"
DEFAULT_AP_HOST="root@192.168.1.100"
LOG_FILE="${WIFI_DROP_TEST_LOG:-/tmp/wifi_drop_test.log}"

usage() {
  echo "Usage: $0 <loss_percent> <minutes> [user@ap_host]" >&2
  echo "       $0 --clear [user@ap_host]" >&2
  echo "  loss_percent  required, whole number 1-100" >&2
  echo "  minutes       required, positive whole number" >&2
  echo "  user@ap_host  optional; default ${DEFAULT_AP_HOST}; omit to run locally on the AP" >&2
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

# --------------------------------------------------------------------
# The actual fault logic. Identical whether invoked locally on the AP
# or piped there over SSH -- one implementation, nothing to keep in
# sync between two copies.
# --------------------------------------------------------------------
run_local() {
  loss_pct="$1"
  minutes="$2"

  if ! command -v tc >/dev/null 2>&1; then
    echo "Error: 'tc' not found on this AP. Install it with:" >&2
    echo "  opkg update && opkg install tc kmod-sched" >&2
    exit 1
  fi

  if ! ip link show "$IFACE" >/dev/null 2>&1; then
    echo "Error: interface '${IFACE}' does not exist on this AP." >&2
    echo "Check current interfaces with: ip -br link show" >&2
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

  echo "Applying netem on ${IFACE}: loss ${loss_pct}%, for ${minutes} minute(s)."
  echo "This affects ALL stations connected to this radio, not just one test client."
  log "applying netem on ${IFACE}: loss ${loss_pct}%, duration=${minutes}m"

  if ! tc qdisc add dev "$IFACE" root netem loss "${loss_pct}%" 2>>"$LOG_FILE"; then
    echo "Error: failed to apply netem rule. Check ${LOG_FILE} for details." >&2
    exit 1
  fi

  echo ""
  echo "VERIFY THE MECHANISM WORKED (see the header comment on this script"
  echo "for why this check matters -- it is not guaranteed, only expected):"
  echo "  tc -s qdisc show dev ${IFACE}          # qdisc's own drop count"
  echo "  cat /proc/net/dev | grep ${IFACE}       # device-level drop column"
  echo "Compare both against the Prometheus metric from the gateway:"
  echo "  curl -s 'http://localhost:9090/api/v1/query?query=node_network_transmit_drop_total%7Bjob%3D%22openwrt-ap1-node%22%2Cdevice%3D%22${IFACE}%22%7D'"
  echo ""
  echo "Active. Will auto-clear in ${minutes} minute(s). Ctrl+C clears it immediately."

  end_ts=$(( $(date +%s) + minutes * 60 ))
  while [ "$(date +%s)" -lt "$end_ts" ]; do
    sleep 1
  done

  echo "Duration elapsed."
}

# --------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------
if [ "${1:-}" = "--clear" ]; then
  AP_HOST="${2:-$DEFAULT_AP_HOST}"
  if [ -f /etc/openwrt_release ]; then
    tc qdisc del dev "$IFACE" root 2>/dev/null
    echo "Cleared any netem rule on ${IFACE} (running locally on the AP)."
  else
    echo "Dispatching clear to ${AP_HOST}..."
    ssh "$AP_HOST" "tc qdisc del dev ${IFACE} root 2>/dev/null; echo 'Cleared any netem rule on ${IFACE}.'"
  fi
  exit 0
fi

LOSS_PCT="${1:-}"
MINUTES="${2:-}"
AP_HOST="${3:-$DEFAULT_AP_HOST}"

[ -z "$LOSS_PCT" ] && usage
[ -z "$MINUTES" ] && usage
require_nonneg_int "$LOSS_PCT" || { echo "Error: <loss_percent> must be a whole number." >&2; usage; }
if [ "$LOSS_PCT" -lt 1 ] || [ "$LOSS_PCT" -gt 100 ]; then
  echo "Error: <loss_percent> must be between 1 and 100." >&2; usage
fi
require_nonneg_int "$MINUTES" || { echo "Error: <minutes> must be a positive whole number." >&2; usage; }
[ "$MINUTES" -gt 0 ] || { echo "Error: <minutes> must be greater than zero." >&2; usage; }

# /etc/openwrt_release is a reliable, standard marker present on every
# OpenWrt install -- used here to detect "we are already on the AP"
# rather than assuming based on how the script was invoked.
if [ -f /etc/openwrt_release ]; then
  echo "Running locally on the AP for ${MINUTES} minute(s) against ${LOSS_PCT}% loss on ${IFACE}."
  run_local "$LOSS_PCT" "$MINUTES"
else
  echo "Dispatching to ${AP_HOST} for ${MINUTES} minute(s) against ${LOSS_PCT}% loss on ${IFACE}."
  # Pipe this script's own source to the AP and re-invoke it there via
  # its own local-execution path -- one implementation, used both
  # locally and remotely, matching the same self-piping approach used
  # in dns_fault_test.sh, just targeting `sh` instead of `bash` since
  # the AP does not have bash available by default.
  ssh "$AP_HOST" sh -s -- "$LOSS_PCT" "$MINUTES" < "$0"
  ssh_status=$?
  if [ $ssh_status -ne 0 ]; then
    echo "Error: remote execution on ${AP_HOST} failed (exit ${ssh_status}). Check SSH connectivity and that tc/kmod-sched is installed there." >&2
    exit $ssh_status
  fi
fi
