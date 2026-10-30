#!/usr/bin/env bash
#
# stop_fault.sh
#
# Stops a running fault-injection process on a remote AP, using the
# pidfile convention adopted across flap_test.sh, dns_fault_test.sh,
# wan_packet_loss_test.sh, and cpufill_test_busyloop.sh.
#
# Does NOT depend on pkill or killall being present on the target --
# both are commonly absent from OpenWrt's default BusyBox build (this is
# exactly the "pkill: not found" error that prompted this script). Uses
# only `cat`, `kill`, and `rm`, which are always present.
#
# USAGE:
#   ./stop_fault.sh <fault_name> [user@host]
#
#   fault_name must match the pidfile naming convention:
#     /tmp/fault_<fault_name>.pid
#
# EXAMPLES:
#   ./stop_fault.sh flap                          # stops on default AP1
#   ./stop_fault.sh flap root@192.168.1.101        # stops on AP2
#   ./stop_fault.sh dns root@192.168.1.101
#   ./stop_fault.sh cpufill root@192.168.1.101
#   ./stop_fault.sh wan_packet_loss root@192.168.1.101
#   ./stop_fault.sh all root@192.168.1.101         # stops every known fault type
#
set -euo pipefail

DEFAULT_TARGET="root@192.168.1.100"
FAULT_NAME="${1:-}"
TARGET="${2:-$DEFAULT_TARGET}"

if [[ -z "$FAULT_NAME" ]]; then
    echo "Usage: $0 <fault_name|all> [user@host]"
    echo "Known fault names: flap, dns, cpufill, wan_packet_loss"
    exit 1
fi

if [[ "$TARGET" == *"@"* ]]; then
    AP_USER="${TARGET%%@*}"
    AP_HOST="${TARGET#*@}"
else
    AP_USER="root"
    AP_HOST="$TARGET"
fi

SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes)

stop_one() {
    local name="$1"
    local pidfile="/tmp/fault_${name}.pid"

    echo "Stopping '${name}' on ${AP_USER}@${AP_HOST}..."

    ssh "${SSH_OPTS[@]}" "${AP_USER}@${AP_HOST}" "sh -c '
        if [ ! -f ${pidfile} ]; then
            echo \"  no pidfile at ${pidfile} -- nothing running (or already stopped)\"
            exit 0
        fi
        PID=\$(cat ${pidfile})
        if [ -z \"\$PID\" ]; then
            echo \"  pidfile ${pidfile} is empty, removing it\"
            rm -f ${pidfile}
            exit 0
        fi
        if kill -0 \"\$PID\" 2>/dev/null; then
            kill \"\$PID\" 2>/dev/null
            sleep 1
            if kill -0 \"\$PID\" 2>/dev/null; then
                echo \"  PID \$PID did not exit cleanly, sending SIGKILL\"
                kill -9 \"\$PID\" 2>/dev/null || true
            fi
            echo \"  stopped PID \$PID\"
        else
            echo \"  PID \$PID from pidfile is not running (stale pidfile)\"
        fi
        rm -f ${pidfile}
    '"
}

if [[ "$FAULT_NAME" == "all" ]]; then
    for name in flap dns cpufill wan_packet_loss; do
        stop_one "$name"
    done
    echo ""
    echo "Also restoring any interface that may have been left in a down state"
    echo "by an interrupted flap test (safe no-op if nothing was mid-flap):"
    ssh "${SSH_OPTS[@]}" "${AP_USER}@${AP_HOST}" "ip link set dev phy0-ap0 up 2>/dev/null || true"
else
    stop_one "$FAULT_NAME"
fi
