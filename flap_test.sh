#!/usr/bin/env bash
#
# flap_test.sh
#
# Remotely induces a controlled sequence of link flaps on an OpenWrt AP,
# for testing the "Link flaps (1h)" / "Link stability" indicator panels
# described in Chapter 3 (Phase Three fault-injection methodology).
#
# The flap loop runs AS A DETACHED BACKGROUND PROCESS ON THE AP ITSELF,
# not inside this SSH session. This is deliberate: toggling the AP's own
# wireless interface down will normally kill the very SSH session used to
# issue the command, which would otherwise abort the loop after one cycle.
#
# STOPPING AN IN-PROGRESS RUN:
#   Use stop_fault.sh, which reads the pidfile this script writes:
#     ./stop_fault.sh flap root@192.168.1.101
#   A trap inside the remote loop ensures that if the stop signal arrives
#   while the interface is mid-"down", it is brought back up immediately
#   rather than left down until the next scheduled "up" step.
#
# USAGE:
#   ./flap_test.sh [iterations] [down_seconds] [up_seconds] [user@host]
#
#   The target defaults to root@192.168.1.100 (AP1) if omitted, so every
#   existing invocation that only ever targeted AP1 keeps working unchanged.
#   To target a different node (e.g. AP2), pass it as the fourth argument,
#   matching the same trailing user@host convention already used by
#   wifi_drop_test.sh and stop_fault.sh, so all three are called the same way.
#
# EXAMPLES:
#   ./flap_test.sh                                    # AP1, defaults: 12 cycles, 2s down, 5s up
#   ./flap_test.sh 5 3 20                              # AP1, 5 cycles, 3s down, 20s up
#   ./flap_test.sh 12 2 5 root@192.168.1.101           # AP2, same cycle pattern as the default
#   ./flap_test.sh 5 3 20 root@192.168.1.101           # AP2, 5 cycles, 3s down, 20s up
#
# REQUIREMENTS (pick one, per target host):
#   A) SSH key auth already set up to root@AP_HOST (recommended, most reliable)
#   B) sshpass installed locally AND the AP's sshd configured with
#      PermitEmptyPasswords yes (see note at bottom of this file)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration - edit the default below only if you want a different
# fallback target; everything else should be left as-is and driven by
# the command-line arguments instead.
# ---------------------------------------------------------------------------
DEFAULT_TARGET="root@192.168.1.100"
IFACE="phy0-ap0"
REMOTE_LOGFILE="/tmp/flap_test.log"
PIDFILE="/tmp/fault_flap.pid"

ITERATIONS="${1:-12}"
DOWN_SECS="${2:-2}"
UP_SECS="${3:-5}"
TARGET="${4:-$DEFAULT_TARGET}"

# ---------------------------------------------------------------------------
# Split TARGET into AP_USER / AP_HOST. Accepts either "user@host" or a bare
# "host" (in which case the user defaults to root, same as before).
# ---------------------------------------------------------------------------
if [[ "$TARGET" == *"@"* ]]; then
    AP_USER="${TARGET%%@*}"
    AP_HOST="${TARGET#*@}"
else
    AP_USER="root"
    AP_HOST="$TARGET"
fi

if [[ -z "$AP_HOST" ]]; then
    echo "ERROR: could not parse a host from '${TARGET}'. Expected 'user@host' or 'host'." >&2
    exit 1
fi

SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes)

# ---------------------------------------------------------------------------
# Preflight: confirm the AP is reachable before scheduling anything
# ---------------------------------------------------------------------------
echo "Checking connectivity to ${AP_USER}@${AP_HOST}..."
if ! ssh "${SSH_OPTS[@]}" "${AP_USER}@${AP_HOST}" 'echo ok' > /dev/null 2>&1; then
    echo "ERROR: could not reach ${AP_USER}@${AP_HOST} via SSH with key auth."
    echo ""
    echo "If this AP truly has no password and no SSH key is set up yet, run:"
    echo "  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_ap -N ''"
    echo "  ssh-copy-id -i ~/.ssh/id_ed25519_ap.pub ${AP_USER}@${AP_HOST}"
    echo ""
    echo "If sshd on the AP is configured with PermitEmptyPasswords yes and you"
    echo "genuinely want empty-password auth instead, install sshpass and rerun"
    echo "this script after uncommenting the sshpass block near the bottom."
    exit 1
fi
echo "Connectivity OK."

# ---------------------------------------------------------------------------
# Warn, don't silently overwrite, if a flap test is already running on
# this target -- launching a second one on top of a live pidfile would
# make stop_fault.sh only able to stop whichever PID the file last held.
# ---------------------------------------------------------------------------
EXISTING_PID=$(ssh "${SSH_OPTS[@]}" "${AP_USER}@${AP_HOST}" "cat ${PIDFILE} 2>/dev/null || true")
if [[ -n "$EXISTING_PID" ]]; then
    IS_RUNNING=$(ssh "${SSH_OPTS[@]}" "${AP_USER}@${AP_HOST}" "kill -0 ${EXISTING_PID} 2>/dev/null && echo yes || echo no")
    if [[ "$IS_RUNNING" == "yes" ]]; then
        echo "ERROR: a flap test is already running on ${AP_HOST} (PID ${EXISTING_PID})."
        echo "Stop it first: ./stop_fault.sh flap ${AP_USER}@${AP_HOST}"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Remote command: a nohup'd, disowned background loop on the AP.
# Every step is logged to syslog (visible via logread) and to a logfile,
# so progress can be checked after the controlling SSH session returns.
# A trap ensures a stop signal (from stop_fault.sh) always leaves the
# interface up, even if it arrives mid-"down" cycle.
# ---------------------------------------------------------------------------
REMOTE_CMD=$(cat <<EOF
sh -c '
  echo \$\$ > ${PIDFILE}
  trap "ip link set dev ${IFACE} up; rm -f ${PIDFILE}; logger -t flap_test \"stopped by signal, interface restored\"; exit 0" TERM INT
  echo "[\$(date +%H:%M:%S)] flap_test starting: ${ITERATIONS} cycles, down=${DOWN_SECS}s up=${UP_SECS}s on ${IFACE}" | tee -a ${REMOTE_LOGFILE}
  logger -t flap_test "starting: ${ITERATIONS} cycles on ${IFACE}"
  for i in \$(seq 1 ${ITERATIONS}); do
    logger -t flap_test "cycle \$i/${ITERATIONS}: down"
    echo "[\$(date +%H:%M:%S)] cycle \$i/${ITERATIONS}: down" >> ${REMOTE_LOGFILE}
    ip link set dev ${IFACE} down
    sleep ${DOWN_SECS} &
    wait \$!
    ip link set dev ${IFACE} up
    logger -t flap_test "cycle \$i/${ITERATIONS}: up"
    echo "[\$(date +%H:%M:%S)] cycle \$i/${ITERATIONS}: up" >> ${REMOTE_LOGFILE}
    sleep ${UP_SECS} &
    wait \$!
  done
  logger -t flap_test "flap_test complete"
  echo "[\$(date +%H:%M:%S)] flap_test complete" >> ${REMOTE_LOGFILE}
  rm -f ${PIDFILE}
' > ${REMOTE_LOGFILE} 2>&1 < /dev/null &
echo "launched with PID \$!"
EOF
)

echo ""
echo "Launching flap loop on ${AP_HOST} (${ITERATIONS} cycles, down=${DOWN_SECS}s, up=${UP_SECS}s)..."
ssh "${SSH_OPTS[@]}" "${AP_USER}@${AP_HOST}" "${REMOTE_CMD}"

TOTAL_SECS=$(( ITERATIONS * (DOWN_SECS + UP_SECS) ))
echo ""
echo "Flap loop launched and detached from this SSH session, it will keep"
echo "running on the AP even if this connection drops during a 'down' cycle."
echo ""
echo "Target: ${AP_USER}@${AP_HOST}"
echo "Estimated total duration: ${TOTAL_SECS}s (~$(( TOTAL_SECS / 60 )) min)"
echo ""
echo "To stop this run early:"
echo "  ./stop_fault.sh flap ${AP_USER}@${AP_HOST}"
echo ""
echo "Check progress once the AP is reachable again:"
echo "  ssh ${AP_USER}@${AP_HOST} 'cat ${REMOTE_LOGFILE}'"
echo "  ssh ${AP_USER}@${AP_HOST} 'logread | grep flap_test'"
echo ""
echo "Check the kernel counter directly:"
echo "  ssh ${AP_USER}@${AP_HOST} 'cat /sys/class/net/${IFACE}/carrier_changes'"

# ---------------------------------------------------------------------------
# ALTERNATIVE: empty-password auth via sshpass, instead of SSH keys.
# Only use this if the AP's sshd has PermitEmptyPasswords yes configured
# (not the OpenWrt default). Requires: apt/brew install sshpass
#
# Replace every `ssh "${SSH_OPTS[@]}"` call above with:
#   sshpass -p '' ssh "${SSH_OPTS[@]}"
# ---------------------------------------------------------------------------
