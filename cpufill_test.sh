#!/usr/bin/env bash
#
# cpufill_test.sh
#
# Remotely induces a controlled CPU-load fault on an OpenWrt AP, for testing
# the "AP Resource Health" panel's CPU indicator (70%/90% thresholds,
# Harchol-Balter; PASTRAMI 2024; Agarwal et al.). Drives average CPU
# utilisation on the AP toward a target percentage, holds it there for a
# configurable duration, then cleans up automatically without needing a
# follow-up command.
#
# Same detached, self-cleaning design as memfill_test.sh: the load-and-hold
# loop runs AS A DETACHED BACKGROUND PROCESS ON THE AP ITSELF, so the
# controlling SSH session returns immediately rather than blocking your
# terminal for the full duration.
#
# THIS AP IS SINGLE-CORE (confirmed from its own node_exporter output --
# only "cpu0" exists). The script therefore only ever needs one busy-loop
# process to drive that single core. If this is ever run against a
# multi-core device instead, the busy-loop section would need to spawn one
# loop per core to have the same effect on the (1 - idle_rate) aggregate
# the panel actually reads -- noted here rather than silently assumed away.
#
# HOW THE TARGET PERCENTAGE IS APPROXIMATED
#   There is no direct "set CPU to exactly X%" primitive on a minimal
#   BusyBox image (no confirmed stress-ng, and the `timeout` applet is not
#   guaranteed compiled in either, so this deliberately avoids depending on
#   either). Instead, for targets below 95%, the script alternates a `yes`
#   busy-loop with plain whole-second `sleep` in a fixed 10-second duty
#   cycle (e.g. targeting 70% runs busy for 7s, idle for 3s, repeated).
#   Because the dashboard panel reads CPU usage via a 5-minute rate()
#   window, this coarse, whole-second duty cycle averages out cleanly over
#   that window without needing any sub-second timing precision. This is an
#   approximation, not an exact figure -- verify the actual achieved value
#   against the live panel on your first run, the same way every other
#   fault script in this set has been empirically checked rather than
#   assumed to work.
#   For targets 95% and above, the script skips duty-cycling entirely and
#   runs `yes` continuously for the full duration, which reliably pegs the
#   single core at ~100% -- the simplest, most precise way to test the red
#   band specifically.
#
# USAGE (local):
#   ./cpufill_test.sh <target_percent> <duration_minutes>
#
# USAGE (remote, over SSH):
#   ./cpufill_test.sh <target_percent> <duration_minutes> [user@]<host>
#   ./cpufill_test.sh 80 10 192.168.1.100
#   (bare host defaults to root@<host>, matching this project's AP convention)
#
# EXAMPLES:
#   ./cpufill_test.sh 80 10                  # local: ~80% avg CPU, hold 10 min (tests orange)
#   ./cpufill_test.sh 95 5 192.168.1.100       # remote: continuous max load, hold 5 min (tests red)
#
# SAFETY: this does not touch memory, disk, or the network -- only CPU
# scheduling. It will make the AP's web UI and SSH session feel sluggish
# while active (expected, that is the point), but should not by itself
# cause dropped connections. As with memfill_test.sh, if you need to test
# conditions more severe than this script allows, do it with a monitor
# attached locally, not over SSH.
#
set -euo pipefail

TARGET_PCT="${1:?Usage: cpufill_test.sh <target_percent> <duration_minutes> [user@host]}"
DURATION_MIN="${2:?Usage: cpufill_test.sh <target_percent> <duration_minutes> [user@host]}"
REMOTE_TARGET="${3:-}"

MAXLOAD_THRESHOLD_PCT=95
LOGFILE="/tmp/cpufill_test.log"
MARKER="cpufill_test_busyloop"   # kept as a human-readable log/marker string only --
                                  # no longer used for pkill -f matching, see PIDFILE below
PIDFILE="/tmp/fault_cpufill.pid" # matches stop_fault.sh's /tmp/fault_<name>.pid
                                  # convention, so ./stop_fault.sh cpufill <host> works

if [ "$TARGET_PCT" -lt 1 ] || [ "$TARGET_PCT" -gt 100 ]; then
    echo "ERROR: <target_percent> must be between 1 and 100." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Remote command: local bash variables (TARGET_PCT, DURATION_MIN, LOGFILE,
# MARKER, MAXLOAD_THRESHOLD_PCT) are substituted directly into this
# heredoc's literal text at construction time here, on the controlling
# machine - not re-parsed or re-injected at runtime on the AP. \$-escaped
# variables are the only ones evaluated remotely, when the AP actually
# runs the script. Same pattern as memfill_test.sh, for consistency.
# ---------------------------------------------------------------------------
REMOTE_CMD=$(cat <<EOF
sh -c '
  LOGFILE="${LOGFILE}"
  MARKER="${MARKER}"
  TARGET_PCT=${TARGET_PCT}
  DURATION_MIN=${DURATION_MIN}
  MAXLOAD_THRESHOLD_PCT=${MAXLOAD_THRESHOLD_PCT}

  echo "[\$(date +%H:%M:%S)] cpufill_test starting: target=\${TARGET_PCT}% CPU, hold=\${DURATION_MIN}min" > "\$LOGFILE"

  END_TS=\$(( \$(date +%s) + DURATION_MIN * 60 ))

  PIDFILE="${PIDFILE}"
  CURRENT_YPID_FILE="/tmp/\${MARKER}.current_ypid"

  if [ "\$TARGET_PCT" -ge "\$MAXLOAD_THRESHOLD_PCT" ]; then
    echo "[\$(date +%H:%M:%S)] target >= \${MAXLOAD_THRESHOLD_PCT}%, running continuous max-load (no duty cycling)" >> "\$LOGFILE"
    (
      trap "kill \\\$YPID 2>/dev/null; rm -f \$CURRENT_YPID_FILE; exit 0" TERM INT
      yes > /dev/null 2>&1 &
      YPID=\$!
      echo \$YPID > "\$CURRENT_YPID_FILE"
      wait \$YPID
    ) &
  else
    BUSY_SEC=\$(( TARGET_PCT / 10 ))
    [ "\$BUSY_SEC" -lt 1 ] && BUSY_SEC=1
    [ "\$BUSY_SEC" -gt 9 ] && BUSY_SEC=9
    SLEEP_SEC=\$(( 10 - BUSY_SEC ))
    echo "[\$(date +%H:%M:%S)] duty-cycling: busy=\${BUSY_SEC}s / sleep=\${SLEEP_SEC}s per 10s cycle" >> "\$LOGFILE"
    (
      trap "kill \\\$YPID 2>/dev/null; rm -f \$CURRENT_YPID_FILE; exit 0" TERM INT
      while true; do
        yes > /dev/null 2>&1 &
        YPID=\$!
        echo \$YPID > "\$CURRENT_YPID_FILE"
        sleep \$BUSY_SEC &
        wait \$!
        kill \$YPID 2>/dev/null
        wait \$YPID 2>/dev/null
        rm -f "\$CURRENT_YPID_FILE"
        sleep \$SLEEP_SEC &
        wait \$!
      done
    ) &
  fi
  DRIVER_PID=\$!
  echo \$DRIVER_PID > "\$PIDFILE"

  sleep \$((DURATION_MIN * 60)) &
  wait \$!

  # Auto-cleanup (normal completion, not an early cancel): TERM the driver,
  # which via its own trap also kills whatever yes child is currently
  # running -- no pkill dependency anywhere in this path.
  kill \$DRIVER_PID 2>/dev/null || true
  sleep 1
  if [ -f "\$CURRENT_YPID_FILE" ]; then
    kill "\$(cat \$CURRENT_YPID_FILE)" 2>/dev/null || true
    rm -f "\$CURRENT_YPID_FILE"
  fi
  rm -f "\$PIDFILE"

  echo "[\$(date +%H:%M:%S)] auto-cleanup complete: CPU load generator stopped" >> "\$LOGFILE"
' > ${LOGFILE} 2>&1 < /dev/null &
echo "launched with PID \$!"
EOF
)

echo ""
echo "Scheduling CPU fault (target=${TARGET_PCT}%, auto-clears after ${DURATION_MIN} minute(s))..."

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
    echo "  ssh ${REMOTE_TARGET} 'top -bn1 | head -5'   # confirm actual achieved load"
else
    echo "  cat ${LOGFILE}"
    echo "  top -bn1 | head -5"
fi
echo ""
echo "To cancel early instead of waiting for auto-cleanup:"
if [ -n "$REMOTE_TARGET" ]; then
    echo "  ./stop_fault.sh cpufill ${REMOTE_TARGET}"
else
    echo "  kill \$(cat ${PIDFILE}) 2>/dev/null; rm -f ${PIDFILE}"
    echo "  (stop_fault.sh assumes an SSH target; for local runs, use the kill command above)"
fi
