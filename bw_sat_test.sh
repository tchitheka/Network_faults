#!/usr/bin/env bash
#
# bw_sat_test.sh - bandwidth saturation fault, entirely on the local network
#
# Runs an iperf3 transfer from the station (192.168.1.11) to an iperf3 server
# on the gateway (192.168.1.1), so the load never touches the Internet. The
# traffic crosses AP1's eth0 (AP1 is the wired link to the gateway), which is
# exactly what the utilisation panel measures:
#
#   upload   = rate(node_network_transmit_bytes_total{device="eth0"}) on AP1
#              = traffic going from the stations to the gateway
#   download = rate(node_network_receive_bytes_total{device="eth0"}) on AP1
#              = traffic going from the gateway to the stations
#
# Run this on the gateway. It needs iperf3 on the gateway and on the station:
#   sudo apt install iperf3
#
# USAGE
#   ./bw_sat_test.sh <rate_mbps> <minutes> [user@station] [direction] [server_ip]
#
#   rate_mbps    Target rate in Mbit/s (iperf3 -b). Pick it from the WAN
#                capacity variable on the dashboard: the panel shows
#                rate / capacity x 100, so rate = capacity x wanted %.
#   minutes      How long to transfer. Whole minutes, 1-120.
#   user@station Where the iperf3 client runs. Default takondwa@192.168.1.11.
#   direction    up (default), down, or both.
#   server_ip    The gateway's LAN address. Default 192.168.1.1.
#
# EXAMPLES
#   ./bw_sat_test.sh 50 5                      # 50 Mbit/s upload for 5 minutes
#   ./bw_sat_test.sh 50 5 takondwa@192.168.1.11 down
#
# The client writes its PID to /tmp/fault_bwsat.pid on the station, so
#   ./stop_fault.sh bwsat takondwa@192.168.1.11
# stops it, and the runner can see whether it is running. The command blocks
# until the transfer ends (like dns_fault_test.sh).
#
set -u

RATE="${1:-}"; MINUTES="${2:-}"
STATION="${3:-takondwa@192.168.1.11}"
DIR="${4:-up}"
SERVER_IP="${5:-192.168.1.1}"
PIDFILE="/tmp/fault_bwsat.pid"
LOG="/tmp/bw_sat.log"

usage() { echo "Usage: $0 <rate_mbps> <minutes> [user@station] [up|down|both] [server_ip]" >&2; exit 1; }
isnum() { case "$1" in ''|*[!0-9]*) return 1;; 0) return 1;; *) return 0;; esac; }

isnum "$RATE" || { echo "Error: rate_mbps must be a positive whole number." >&2; usage; }
isnum "$MINUTES" || { echo "Error: minutes must be a positive whole number." >&2; usage; }
[ "$MINUTES" -le 120 ] || { echo "Error: minutes must be 120 or less." >&2; usage; }
case "$DIR" in up) FLAG="";; down) FLAG="-R";; both) FLAG="--bidir";; *) echo "Error: direction must be up, down or both." >&2; usage;; esac
SECS=$((MINUTES * 60))

command -v iperf3 >/dev/null 2>&1 || { echo "Error: iperf3 is not installed on the gateway (sudo apt install iperf3)." >&2; exit 1; }

# Server on the gateway: start one if none is listening on 5201.
if ! (command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ':5201 '); then
  iperf3 -s -D >/dev/null 2>&1
  sleep 1
fi

echo "Starting iperf3 from ${STATION} to ${SERVER_IP}: ${DIR}, ${RATE} Mbit/s, ${MINUTES} minute(s)"
ssh -o BatchMode=yes -o ConnectTimeout=5 "$STATION" "command -v iperf3 >/dev/null 2>&1 || { echo 'Error: iperf3 is not installed on the station.' >&2; exit 3; }
iperf3 -c ${SERVER_IP} -t ${SECS} -b ${RATE}M ${FLAG} -i 10 > ${LOG} 2>&1 &
P=\$!
echo \$P > ${PIDFILE}
wait \$P
RC=\$?
rm -f ${PIDFILE}
tail -n 4 ${LOG}
exit \$RC"
rc=$?
if [ $rc -ne 0 ] && [ $rc -ne 143 ] && [ $rc -ne 130 ]; then
  echo "Error: the transfer on ${STATION} ended with exit ${rc}. Check ${LOG} there (is the iperf3 server reachable on ${SERVER_IP}:5201?)." >&2
  exit $rc
fi
echo "Done."
