#!/usr/bin/env bash
#
# ap_outage_test.sh - device/link availability fault, done from AP1's side
#
# Cuts the forwarding path between AP1's wired side and its mesh link to AP2
# for a fixed time, then puts it back. Seen from the gateway, AP2 becomes
# unreachable (ping and SSH fail, Prometheus 'up' goes to 0) and then recovers.
# AP2's clients lose their upstream connection for the same time.
#
# HOW
#   AP1's mesh interface (phy1-mesh0) is a port of the bridge br-lan. The test
#   takes that one port out of the bridge, then puts it back:
#       ip link set dev <mesh_if> nomaster          (outage)
#       ip link set dev <mesh_if> master <bridge>   (restore)
#   The radio link and the mesh peering stay up, so no radio restarts and the
#   restore is quick and predictable. Nothing on AP2 is touched.
#
# WHY ON AP1
#   AP1 is wired to the gateway, so the control path never depends on the link
#   being cut, and the change is a runtime setting only: a reboot of AP1 clears
#   it.
#
# WHAT IT DOES AND DOES NOT SHOW
#   Reachability of AP2 is lost and restored. The mesh peer link itself stays
#   up, so a panel that counts mesh peers will not change. Say so in the thesis.
#
# SAFETY (three independent ways the port is put back)
#   1. The normal path: cut, sleep, restore.
#   2. A TERM/INT trap: ./stop_fault.sh apoutage <AP1 target> restores it.
#   3. A watchdog that restores it at <down_seconds> + 40 s even if the main
#      process is killed outright.
# If AP1 cannot ping AP2 within 60 s of the restore, the script restarts AP1's
# mesh radio (netifd re-adds the interface to the bridge), and as a last resort
# restarts the network. AP1 is wired, so both are safe.
#
# USAGE
#   ./ap_outage_test.sh [down_seconds] [user@ap1] [mesh_if] [victim_ip]
#
#   down_seconds  How long the path stays cut. Default 30. Allowed 5-3600.
#   user@ap1      The AP that does the cutting. Default root@192.168.1.100.
#   mesh_if       Mesh interface on AP1. Default: auto-detected.
#   victim_ip     AP2's address, used for checks. Default 192.168.1.101.
#
# STOP EARLY
#   ./stop_fault.sh apoutage root@192.168.1.100
#
set -euo pipefail

DEFAULT_TARGET="root@192.168.1.100"
DOWN_SECS="${1:-30}"
TARGET="${2:-$DEFAULT_TARGET}"
MESH_IFACE="${3:-}"
VICTIM_IP="${4:-192.168.1.101}"
PIDFILE="/tmp/fault_apoutage.pid"
REMOTE_LOGFILE="/tmp/ap_outage_test.log"
REMOTE_SCRIPT_PATH="/tmp/ap_outage_remote.sh"

case "$DOWN_SECS" in ''|*[!0-9]*) echo "ERROR: down_seconds must be a whole number." >&2; exit 1 ;; esac
if [ "$DOWN_SECS" -lt 5 ] || [ "$DOWN_SECS" -gt 3600 ]; then
  echo "ERROR: down_seconds must be between 5 and 3600." >&2; exit 1
fi

if [[ "$TARGET" == *"@"* ]]; then AP_USER="${TARGET%%@*}"; AP_HOST="${TARGET#*@}"
else AP_USER="root"; AP_HOST="$TARGET"; fi
[[ -n "$AP_HOST" ]] || { echo "ERROR: could not parse a host from '${TARGET}'." >&2; exit 1; }

SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes)
rssh() { ssh "${SSH_OPTS[@]}" "${AP_USER}@${AP_HOST}" "$@"; }

echo "Checking connectivity to ${AP_USER}@${AP_HOST} (the AP that cuts the path)..."
rssh 'echo ok' >/dev/null 2>&1 || { echo "ERROR: could not reach ${AP_USER}@${AP_HOST} via SSH with key auth." >&2; exit 1; }
echo "Connectivity OK."

EXISTING_PID=$(rssh "cat ${PIDFILE} 2>/dev/null || true")
if [[ -n "$EXISTING_PID" ]]; then
  RUNNING=$(rssh "kill -0 ${EXISTING_PID} 2>/dev/null && echo yes || echo no")
  if [[ "$RUNNING" == "yes" ]]; then
    echo "ERROR: an AP outage test is already running on ${AP_HOST} (PID ${EXISTING_PID})." >&2
    echo "Stop it first: ./stop_fault.sh apoutage ${AP_USER}@${AP_HOST}" >&2; exit 1
  fi
fi

if [[ -z "$MESH_IFACE" ]]; then
  MESH_IFACE=$(rssh "iw dev 2>/dev/null | awk '/Interface/{i=\$2} /type mesh point/{print i; exit}'" || true)
fi
[[ -n "$MESH_IFACE" ]] || { echo "ERROR: no mesh interface found on ${AP_HOST}. Pass it as the third argument." >&2; exit 1; }

BRIDGE=$(rssh "basename \"\$(readlink \${NETROOT:-/sys/class/net}/${MESH_IFACE}/master 2>/dev/null)\" 2>/dev/null" || true)
if [[ -z "$BRIDGE" || "$BRIDGE" == "." ]]; then
  echo "ERROR: ${MESH_IFACE} on ${AP_HOST} is not a bridge port, so there is nothing to cut." >&2
  echo "Check: ls -l /sys/class/net/${MESH_IFACE}/master" >&2; exit 1
fi
echo "Mesh interface on ${AP_HOST}: ${MESH_IFACE} (bridge port of ${BRIDGE})"

#REMOTE-BEGIN
REMOTE_SCRIPT=$(cat <<'REMOTE'
#!/bin/sh
# Runs ON AP1. Args: down_seconds iface bridge victim_ip pidfile logfile
DOWN="$1"; IFACE="$2"; BR="$3"; VIP="$4"; PIDFILE="$5"; LOG="$6"
NETROOT="${NETROOT:-/sys/class/net}"
WATCHDOG_MARGIN=40
RESTORE_WAIT=60
log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; logger -t ap_outage "$*"; }
member() { [ -L "$NETROOT/$IFACE/master" ]; }
reach() { ping -c 1 -W 1 "$VIP" > /dev/null 2>&1; }
cut() { ip link set dev "$IFACE" nomaster; }
restore() { member || ip link set dev "$IFACE" master "$BR"; }
echo "[$(date +%H:%M:%S)] remote script started (pid $$)" >> "$LOG"
echo $$ > "$PIDFILE"
trap '' HUP
WD=""
trap 'log "stopped by signal, restoring"; [ -n "$WD" ] && kill "$WD" 2>/dev/null; rm -f "$PIDFILE"; ( restore ) < /dev/null > /dev/null 2>&1 & exit 0' TERM INT
( sleep $((DOWN + WATCHDOG_MARGIN)); restore; logger -t ap_outage "watchdog restored the bridge port" ) &
WD=$!
if reach; then R0=yes; else R0=no; fi
log "start: cutting ${IFACE} out of ${BR} for ${DOWN}s (AP2 reachable from AP1 before: ${R0}; watchdog at $((DOWN + WATCHDOG_MARGIN))s)"
cut
i=0
while [ "$i" -lt 10 ] && reach; do i=$((i + 1)); sleep 1; done
if reach; then log "WARNING: AP2 still reachable from AP1 ${i}s after the cut"; else log "cut effective: AP2 unreachable from AP1 after ${i}s"; fi
sleep "$DOWN" &
wait $!
restore
log "restore requested (bridge port: $(member && echo yes || echo no))"
i=0; ok=0
while [ "$i" -lt "$RESTORE_WAIT" ]; do
  if member && reach; then ok=1; break; fi
  i=$((i + 1)); sleep 1
done
if [ "$ok" = 0 ]; then
  log "AP2 not back after ${RESTORE_WAIT}s: restarting AP1's mesh radio (AP1 is wired, so this is safe)"
  RADIO=$(uci -q show wireless | sed -n "s/^\(wireless\.[^.=]*\)\.mode='mesh'$/\1/p" | head -n1)
  [ -n "$RADIO" ] && RADIO=$(uci -q get "$RADIO.device")
  if [ -n "$RADIO" ]; then wifi down "$RADIO" >> "$LOG" 2>&1; sleep 2; wifi up "$RADIO" >> "$LOG" 2>&1; fi
  i=0
  while [ "$i" -lt 60 ]; do
    if member && reach; then ok=1; break; fi
    i=$((i + 1)); sleep 1
  done
fi
if [ "$ok" = 0 ]; then
  log "still not back: restarting the network service"
  /etc/init.d/network restart >> "$LOG" 2>&1
fi
if [ "$ok" = 1 ]; then log "restored: AP2 reachable again after ${i}s"; else log "WARNING: AP2 still not reachable"; fi
kill "$WD" 2>/dev/null
rm -f "$PIDFILE"
log "complete"
REMOTE
)
#REMOTE-END

echo ""
echo "Launching on ${AP_HOST}: cutting ${MESH_IFACE} out of ${BRIDGE} for ${DOWN_SECS}s, then restoring automatically..."
printf '%s\n' "$REMOTE_SCRIPT" | rssh \
  "cat > ${REMOTE_SCRIPT_PATH} && chmod +x ${REMOTE_SCRIPT_PATH} && { if command -v setsid >/dev/null 2>&1; then setsid sh ${REMOTE_SCRIPT_PATH} ${DOWN_SECS} ${MESH_IFACE} ${BRIDGE} ${VICTIM_IP} ${PIDFILE} ${REMOTE_LOGFILE} > /dev/null 2>&1 < /dev/null & else sh ${REMOTE_SCRIPT_PATH} ${DOWN_SECS} ${MESH_IFACE} ${BRIDGE} ${VICTIM_IP} ${PIDFILE} ${REMOTE_LOGFILE} > /dev/null 2>&1 < /dev/null & fi; } ; echo launched"

sleep 4
if command -v ping >/dev/null 2>&1; then
  if ping -c 2 -W 1 "${VICTIM_IP}" >/dev/null 2>&1; then
    echo "" >&2
    echo "WARNING: ${VICTIM_IP} still answers 4 s after launch, so the outage may not have started." >&2
    echo "Check on AP1: cat ${REMOTE_LOGFILE}" >&2
  else
    echo "Outage in progress: ${VICTIM_IP} has stopped answering."
  fi
fi
echo ""
echo "Detached on ${AP_HOST}. It restores itself after ${DOWN_SECS}s."
echo "To stop early:  ./stop_fault.sh apoutage ${AP_USER}@${AP_HOST}"
echo "Check afterwards: ssh ${AP_USER}@${AP_HOST} 'cat ${REMOTE_LOGFILE}'"
