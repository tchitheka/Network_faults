#!/usr/bin/env bash
#
# memfill_test.sh
#
# Remotely induces a controlled memory-availability fault on an OpenWrt AP,
# for testing the "Memory pressure" indicator panel described in Chapter 3
# (Phase Three fault-injection methodology). Fills a tmpfs mount to drive
# available memory down to a target percentage, holds it there for a
# configurable duration, then cleans up automatically without needing a
# follow-up command.
#
# The fill-and-hold loop runs AS A DETACHED BACKGROUND PROCESS ON THE AP
# ITSELF (same pattern as flap_test.sh: plain `&` backgrounding with
# redirected stdin/stdout/stderr, no nohup - not guaranteed to be a
# compiled BusyBox applet on minimal OpenWrt images, and unnecessary
# anyway since a non-interactive ash session doesn't forward SIGHUP to
# background children). This means the controlling SSH session returns
# immediately rather than blocking your terminal for the full duration.
#
# USAGE (local):
#   ./memfill_test.sh <target_available_percent> <duration_minutes>
#
# USAGE (remote, over SSH):
#   ./memfill_test.sh <target_available_percent> <duration_minutes> [user@]<host>
#   ./memfill_test.sh 15 10 192.168.1.100
#   (bare host defaults to root@<host>, matching this project's AP convention)
#
# EXAMPLES:
#   ./memfill_test.sh 15 10                  # local: drive to 15% available, hold 10 min
#   ./memfill_test.sh 30 5 192.168.1.100       # remote: 30% available, hold 5 min, auto-clears
#
# PIDFILE: the fill-and-hold shell on the AP writes its PID to
# /tmp/fault_memfill.pid, so the runner can see it is running and
#   ./stop_fault.sh memfill root@192.168.1.101
# can stop it (also clean up with: rm -f /mnt/memfill/fill_*; umount /mnt/memfill).
#
# SAFETY: target_available_percent is floored at 8% regardless of what you
# pass in. Going much lower risks the kernel OOM killer taking out hostapd
# or dropbear (your SSH access) instead of your fill process, on embedded
# hardware with only tens to low hundreds of MB of total RAM. If you need
# to test conditions more severe than 8% available, do it with a monitor
# attached locally, not over SSH.
#
set -euo pipefail

TARGET_PCT="${1:?Usage: memfill_test.sh <target_available_percent> <duration_minutes> [user@host]}"
DURATION_MIN="${2:?Usage: memfill_test.sh <target_available_percent> <duration_minutes> [user@host]}"
REMOTE_TARGET="${3:-}"

SAFETY_FLOOR_PCT=8
MOUNT="/mnt/memfill"
LOGFILE="/tmp/memfill_test.log"

if [ "$TARGET_PCT" -lt "$SAFETY_FLOOR_PCT" ]; then
    echo "ERROR: requested target ${TARGET_PCT}% is below the safety floor of ${SAFETY_FLOOR_PCT}%." >&2
    echo "Refusing to run - this risks the OOM killer taking out hostapd/dropbear" >&2
    echo "(your SSH access) instead of your fill process." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Remote command: local bash variables (TARGET_PCT, DURATION_MIN, MOUNT,
# LOGFILE) are substituted directly into this heredoc's literal text at
# construction time here, on the controlling machine - not re-parsed or
# re-injected at runtime on the AP. \$-escaped variables are the only ones
# evaluated remotely, when the AP actually runs the script.
# ---------------------------------------------------------------------------
REMOTE_CMD=$(cat <<EOF
sh -c '
  MOUNT="${MOUNT}"
  LOGFILE="${LOGFILE}"
  TARGET_PCT=${TARGET_PCT}
  DURATION_MIN=${DURATION_MIN}

  echo \$\$ > /tmp/fault_memfill.pid
  mkdir -p "\$MOUNT"
  mountpoint -q "\$MOUNT" 2>/dev/null || mount -t tmpfs -o size=100% tmpfs "\$MOUNT"

  echo "[\$(date +%H:%M:%S)] memfill_test starting: target=\${TARGET_PCT}% available, hold=\${DURATION_MIN}min" > "\$LOGFILE"

  TOTAL_KB=\$(awk "/MemTotal/{print \\\$2}" /proc/meminfo)
  TARGET_AVAIL_KB=\$(( TOTAL_KB * TARGET_PCT / 100 ))

  i=0
  while true; do
    AVAIL_KB=\$(awk "/MemAvailable/{print \\\$2}" /proc/meminfo)
    if [ "\$AVAIL_KB" -le "\$TARGET_AVAIL_KB" ]; then
      echo "[\$(date +%H:%M:%S)] target reached: \${AVAIL_KB}kB available (target was \${TARGET_AVAIL_KB}kB)" >> "\$LOGFILE"
      break
    fi
    i=\$((i + 1))
    dd if=/dev/zero of="\$MOUNT/fill_\${i}" bs=1M count=5 2>/dev/null
    sleep 1
  done

  echo "[\$(date +%H:%M:%S)] holding at target for \${DURATION_MIN} minute(s)..." >> "\$LOGFILE"
  sleep \$((DURATION_MIN * 60))

  rm -f "\$MOUNT"/fill_*
  umount "\$MOUNT" 2>/dev/null || true
  AVAIL_KB_AFTER=\$(awk "/MemAvailable/{print \\\$2}" /proc/meminfo)
  rm -f /tmp/fault_memfill.pid
  echo "[\$(date +%H:%M:%S)] auto-cleanup complete: \${AVAIL_KB_AFTER}kB available" >> "\$LOGFILE"
' > ${LOGFILE} 2>&1 < /dev/null &
echo "launched with PID \$!"
EOF
)

echo ""
echo "Scheduling memory fault (target=${TARGET_PCT}% available, auto-clears after ${DURATION_MIN} minute(s))..."

if [ -z "$REMOTE_TARGET" ]; then
    echo "Running locally..."
    eval "$REMOTE_CMD"
else
    if [[ "$REMOTE_TARGET" != *"@"* ]]; then
        REMOTE_TARGET="root@${REMOTE_TARGET}"
    fi
    echo "Running remotely on ${REMOTE_TARGET} via SSH..."
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${REMOTE_TARGET}" "${REMOTE_CMD}"
fi

echo ""
echo "Fault scheduled. No further commands needed, cleanup happens automatically."
echo ""
echo "Check progress:"
if [ -n "$REMOTE_TARGET" ]; then
    echo "  ssh ${REMOTE_TARGET} 'cat ${LOGFILE}'"
    echo "  ssh ${REMOTE_TARGET} 'cat /proc/meminfo | head -3'"
else
    echo "  cat ${LOGFILE}"
    echo "  cat /proc/meminfo | head -3"
fi
echo ""
echo "To cancel early instead of waiting for auto-cleanup:"
if [ -n "$REMOTE_TARGET" ]; then
    echo "  ssh ${REMOTE_TARGET} 'rm -f ${MOUNT}/fill_*; umount ${MOUNT}'"
else
    echo "  rm -f ${MOUNT}/fill_*; umount ${MOUNT}"
fi
