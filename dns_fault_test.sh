#!/usr/bin/env bash
#
# dns_fault_test.sh — DNS resolution fault-injection tool
#
# Generates a controlled burst of DNS queries against a deliberately
# non-existent domain, to exercise the "Name Resolution (DNS Health)"
# panel's node_dns_failure_ratio indicator under realistic client-side
# load. Can run directly on the local machine (e.g. the gateway itself)
# or be dispatched over SSH to run on a remote client station -- the
# same local/remote dispatch pattern already used by throughputtest.bash
# and memfill_test.sh elsewhere in this fault-injection tool set.
#
# USAGE
#   ./dns_fault_test.sh <minutes> [user@remote_host] [wrong_domain]
#
# ARGUMENTS
#   minutes           Required. How long to run the fault condition, in
#                      whole minutes.
#   user@remote_host   Optional. If given, the test runs on this remote
#                      host via SSH instead of locally. Omit to run
#                      locally on the current machine.
#   wrong_domain       Optional. A domain to query that must NOT exist.
#                      If omitted, a built-in default under the .invalid
#                      TLD is used -- RFC 2606 reserves .invalid
#                      specifically for addresses guaranteed to never
#                      resolve, so the default doesn't depend on nobody
#                      having accidentally registered a "real" domain
#                      that happened to look fake.
#
# EXAMPLES
#   ./dns_fault_test.sh 5
#       Run locally for 5 minutes against the built-in default domain.
#
#   ./dns_fault_test.sh 5 takondwa@192.168.1.50
#       Run for 5 minutes on the remote station via SSH.
#
#   ./dns_fault_test.sh 5 takondwa@192.168.1.50 my-broken-test.example
#       Run remotely, querying a specific non-existent domain instead.
#
# DESIGN NOTES
#   - Every query uses a fresh, randomised subdomain rather than
#     repeatedly querying the exact same name. Most resolvers apply
#     RFC 2308 negative caching to NXDOMAIN responses; without this,
#     repeat queries for one fixed non-existent name would increasingly
#     be served straight out of cache rather than genuinely round-
#     tripping to the upstream resolver, understating the fault
#     condition instead of exercising it realistically.
#   - Remote execution blocks until the test completes, rather than
#     backgrounding and returning immediately (unlike flap_test.sh,
#     which specifically has to background because it toggles the very
#     interface the SSH control connection itself depends on). This
#     script never touches the network interface, so blocking is safe,
#     and it means the caller's terminal reports completion at the
#     right time either way, local or remote.
#   - The script pipes its own source over SSH and re-invokes itself
#     with an internal flag on the far end, rather than duplicating the
#     query-loop logic inside a separate heredoc. One implementation,
#     used both locally and remotely, so there is nothing to keep in
#     sync between two copies of the same logic.

set -u

DEFAULT_DOMAIN="cwn-fault-test.invalid"   # RFC 2606: .invalid is reserved,
                                           # guaranteed to never resolve
QUERY_INTERVAL_SECONDS=2                  # time between individual queries
LOG_FILE="${DNS_FAULT_TEST_LOG:-/tmp/dns_fault_test.log}"

usage() {
  echo "Usage: $0 <minutes> [user@remote_host] [wrong_domain]" >&2
  echo "  minutes           required, positive whole number" >&2
  echo "  user@remote_host  optional; omit to run locally" >&2
  echo "  wrong_domain      optional; defaults to ${DEFAULT_DOMAIN}" >&2
  exit 1
}

require_positive_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    0) return 1 ;;
    *) return 0 ;;
  esac
}

random_token() {
  # Prefer /dev/urandom; fall back to PID+timestamp on minimal systems
  # (e.g. some Android/Termux or BusyBox environments) where od/hexdump
  # against /dev/urandom may not behave the same way.
  local tok
  tok=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  if [ -z "$tok" ]; then
    tok="$$$(date +%s 2>/dev/null)"
  fi
  echo "$tok"
}

run_query_loop() {
  # $1 = minutes, $2 = domain, $3 = log file
  local minutes="$1" domain="$2" log="$3"
  local end_ts count=0 token query_name resolver=""

  if command -v dig >/dev/null 2>&1; then
    resolver="dig"
  elif command -v nslookup >/dev/null 2>&1; then
    resolver="nslookup"
  elif command -v host >/dev/null 2>&1; then
    resolver="host"
  else
    err_msg="$(date '+%Y-%m-%d %H:%M:%S') ERROR: none of dig/nslookup/host found on this machine -- cannot generate DNS queries"
    echo "$err_msg" >> "$log"
    echo "$err_msg" >&2
    return 1
  fi

  # Pidfile on the machine that runs the loop, so the runner (and
  # stop_fault.sh dns) can see it is running and stop it.
  PIDFILE="${DNS_FAULT_PIDFILE:-/tmp/fault_dns.pid}"
  echo $$ > "$PIDFILE"
  trap 'rm -f "$PIDFILE"' EXIT
  trap 'exit 0' TERM INT

  end_ts=$(( $(date +%s) + minutes * 60 ))
  echo "$(date '+%Y-%m-%d %H:%M:%S') starting DNS fault test: ${minutes}m, resolver=${resolver}, target=*.${domain}" >> "$log"

  while [ "$(date +%s)" -lt "$end_ts" ]; do
    token=$(random_token)
    query_name="${token}.${domain}"
    case "$resolver" in
      dig)      dig +time=2 +tries=1 "$query_name" >/dev/null 2>>"$log" ;;
      nslookup) nslookup "$query_name" >/dev/null 2>>"$log" ;;
      host)     host "$query_name" >/dev/null 2>>"$log" ;;
    esac
    count=$((count + 1))
    sleep "$QUERY_INTERVAL_SECONDS" &
    wait $!
  done

  echo "$(date '+%Y-%m-%d %H:%M:%S') finished DNS fault test: ${count} queries issued against *.${domain}" >> "$log"
  echo "Done. ${count} queries issued. Log: ${log}"
}

# --- Internal re-invocation mode: used when this script has been piped
# to a remote host over SSH and needs to run the loop there directly. ---
if [ "${1:-}" = "--run-loop" ]; then
  shift
  run_query_loop "$1" "$2" "$3"
  exit $?
fi

# --- Normal entry point ---
MINUTES="${1:-}"
[ -z "$MINUTES" ] && usage
require_positive_int "$MINUTES" || { echo "Error: <minutes> must be a positive whole number." >&2; usage; }

REMOTE_HOST="${2:-}"
WRONG_DOMAIN="${3:-$DEFAULT_DOMAIN}"

if [ -z "$REMOTE_HOST" ]; then
  echo "Running locally for ${MINUTES} minute(s) against *.${WRONG_DOMAIN}"
  run_query_loop "$MINUTES" "$WRONG_DOMAIN" "$LOG_FILE"
else
  echo "Dispatching to ${REMOTE_HOST} for ${MINUTES} minute(s) against *.${WRONG_DOMAIN}"
  # Pipe this script's own source to the remote host and re-invoke it
  # there with --run-loop, so the exact same query-loop implementation
  # runs on both ends -- nothing to duplicate or keep in sync.
  ssh "$REMOTE_HOST" bash -s -- --run-loop "$MINUTES" "$WRONG_DOMAIN" "$LOG_FILE" < "$0"
  ssh_status=$?
  if [ $ssh_status -ne 0 ]; then
    echo "Error: remote execution on ${REMOTE_HOST} failed (exit ${ssh_status}). Check SSH connectivity and that dig/nslookup/host is installed there." >&2
    exit $ssh_status
  fi
fi
