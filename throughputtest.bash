#!/usr/bin/env bash
#
# throughputtest.bash
#
# Dynamically-sized upload/download throughput test against the public
# tele2 speedtest server, for Phase Three bandwidth saturation
# fault-injection testing (T1 in Chapter 3's indicator table).
#
# Upload size is fully dynamic: a local file of the exact requested size
# is generated and PUT to upload.php.
#
# Download size is fully dynamic too, even though tele2 only hosts fixed
# preset file sizes: curl's --range option is used to pull only the
# first N MB out of their largest hosted file (default 1000MB.zip) and
# discard it, rather than being limited to whatever exact sizes tele2
# happens to host.
#
# USAGE (local):
#   ./throughputtest.bash <upload_MB> <download_MB>
#
# USAGE (remote, over SSH):
#   ./throughputtest.bash <upload_MB> <download_MB> [user@]<host>
#   ./throughputtest.bash <upload_MB> <download_MB> 192.168.1.100
#   (bare host defaults to root@<host>, matching this project's AP convention)
#
# USAGE (override the download source URL, e.g. if Tele2 changes their file
# naming again, or to point at a different speedtest mirror entirely):
#   ./throughputtest.bash <upload_MB> <download_MB> [user@host|-] <download_url>
#   ./throughputtest.bash 100 500 - http://speedtest.tele2.net/10GB.zip
#   ./throughputtest.bash 100 500 192.168.1.100 http://speedtest.belwue.net/1000G
#   (use "-" for the 3rd argument to run locally while still overriding the URL)
#
# EXAMPLES:
#   ./throughputtest.bash 200 20                  # local: 200MB up, 20MB down
#   ./throughputtest.bash 200 20 192.168.1.100     # same, run on the AP over SSH
#   ./throughputtest.bash 50 50 takondwa@100.x.y.z # explicit user@host (e.g. Tailscale IP)
#
# NOTE ON EMBEDDED/BUSYBOX TARGETS: if running this against an OpenWrt AP
# or similarly stripped-down device, confirm its curl actually supports
# -T and --range before relying on results - BusyBox's own minimal wget
# applet does NOT support these, and some OpenWrt images ship BusyBox
# wget under the `curl` name via symlink with reduced functionality.
# Check first with: ssh <host> 'curl --version'
# If curl there is missing --range support, this script will fail loudly
# on the download half rather than silently producing wrong numbers.
#
set -euo pipefail

UPLOAD_MB="${1:?Usage: throughputtest.bash <upload_MB> <download_MB> [user@host] [download_url]}"
DOWNLOAD_MB="${2:?Usage: throughputtest.bash <upload_MB> <download_MB> [user@host] [download_url]}"
REMOTE_TARGET="${3:-}"
DOWNLOAD_URL_OVERRIDE="${4:-}"
if [ "$REMOTE_TARGET" = "-" ]; then
    REMOTE_TARGET=""
fi

SPEEDTEST_HOST="speedtest.tele2.net"
UPLOAD_URL="http://${SPEEDTEST_HOST}/upload.php"
# NOTE: Tele2's file naming uses GB, not MB, above 100MB - there is no
# "1000MB.zip". Confirmed current file set as of this writing: 1MB, 10MB,
# 100MB, 1GB, 10GB, 50GB, 100GB, 1000GB (all suffixed .zip). 10GB.zip is
# used as the range-request source here to comfortably cover download
# tests up to several GB; if Tele2 changes their naming again, override
# with the optional 4th script argument (see usage below) rather than
# editing this file.
DOWNLOAD_SOURCE_FILE="10GB.zip"
DOWNLOAD_URL="http://${SPEEDTEST_HOST}/${DOWNLOAD_SOURCE_FILE}"
if [ -n "$DOWNLOAD_URL_OVERRIDE" ]; then
    DOWNLOAD_URL="$DOWNLOAD_URL_OVERRIDE"
fi

# ---------------------------------------------------------------------------
# The actual test logic, defined as a single self-contained script body so
# it can be executed either directly (local run) or piped over SSH via
# `ssh host bash -s` (remote run) without needing to copy a file first.
# ---------------------------------------------------------------------------
read -r -d '' TEST_SCRIPT_BODY <<'INNER_SCRIPT' || true
set -euo pipefail

UPLOAD_MB="$1"
DOWNLOAD_MB="$2"
UPLOAD_URL="$3"
DOWNLOAD_URL="$4"

TMP_UPLOAD_FILE="$(mktemp /tmp/throughputtest_upload.XXXXXX)"
cleanup() { rm -f "$TMP_UPLOAD_FILE"; }
trap cleanup EXIT

log() { echo "[$(date +%H:%M:%S)] $*"; }

log "=== Throughput test starting: upload=${UPLOAD_MB}MB, download=${DOWNLOAD_MB}MB ==="

# --- Sanity check: confirm curl supports what we need before testing ---
if ! curl --help all 2>&1 | grep -q -- '-T, --upload-file'; then
    echo "ERROR: this curl does not support -T/--upload-file. Cannot run upload test." >&2
    exit 1
fi
if ! curl --help all 2>&1 | grep -q -- '-r, --range'; then
    echo "ERROR: this curl does not support -r/--range. Cannot run dynamic-size download test." >&2
    exit 1
fi

# --- Upload test ---
log "Generating ${UPLOAD_MB}MB local file for upload..."
# fallocate reserves the space without writing every byte to disk, which
# matters on resource-constrained storage (SD cards, OpenWrt flash) - but
# not every filesystem supports it (notably some embedded/flash
# filesystems), so fall back to dd if it fails rather than assuming.
if command -v fallocate >/dev/null 2>&1 && fallocate -l "${UPLOAD_MB}M" "$TMP_UPLOAD_FILE" 2>/dev/null; then
    log "File generated via fallocate (fast path)."
else
    log "fallocate unavailable or unsupported on this filesystem, falling back to dd..."
    dd if=/dev/zero of="$TMP_UPLOAD_FILE" bs=1M count="$UPLOAD_MB" status=none
fi

log "Uploading ${UPLOAD_MB}MB to ${UPLOAD_URL}..."
UPLOAD_RESULT=$(curl -s -T "$TMP_UPLOAD_FILE" "$UPLOAD_URL" -o /dev/null \
    -w '%{time_total} %{speed_upload} %{size_upload}')
UP_TIME=$(echo "$UPLOAD_RESULT" | awk '{print $1}')
UP_SPEED_BPS=$(echo "$UPLOAD_RESULT" | awk '{print $2}')
UP_BYTES=$(echo "$UPLOAD_RESULT" | awk '{print $3}')
UP_MBPS=$(awk -v b="$UP_SPEED_BPS" 'BEGIN { printf "%.2f", (b * 8) / 1000000 }')

log "Upload complete: ${UP_BYTES} bytes in ${UP_TIME}s => ${UP_MBPS} Mbps"

# --- Download test (dynamic size via range request) ---
DOWNLOAD_BYTES=$((DOWNLOAD_MB * 1024 * 1024))
RANGE_END=$((DOWNLOAD_BYTES - 1))

log "Downloading first ${DOWNLOAD_MB}MB (range 0-${RANGE_END}) from ${DOWNLOAD_URL}..."
DOWNLOAD_RESULT=$(curl -s -r "0-${RANGE_END}" "$DOWNLOAD_URL" -o /dev/null \
    -w '%{time_total} %{speed_download} %{size_download} %{http_code}')
DOWN_TIME=$(echo "$DOWNLOAD_RESULT" | awk '{print $1}')
DOWN_SPEED_BPS=$(echo "$DOWNLOAD_RESULT" | awk '{print $2}')
DOWN_BYTES=$(echo "$DOWNLOAD_RESULT" | awk '{print $3}')
HTTP_CODE=$(echo "$DOWNLOAD_RESULT" | awk '{print $4}')
DOWN_MBPS=$(awk -v b="$DOWN_SPEED_BPS" 'BEGIN { printf "%.2f", (b * 8) / 1000000 }')

if [ "$HTTP_CODE" = "206" ]; then
    log "Server confirmed partial content (HTTP 206) - range request honored correctly."
elif [ "$HTTP_CODE" = "200" ]; then
    echo "WARNING: server returned HTTP 200, not 206, for a range request." >&2
    echo "         This usually means the server ignored the range header and" >&2
    echo "         sent the ENTIRE file rather than just the requested ${DOWNLOAD_MB}MB." >&2
    echo "         Reported speed/size below may reflect the full file, not the" >&2
    echo "         requested slice - verify with the byte-count check below." >&2
else
    echo "WARNING: server returned HTTP ${HTTP_CODE} for the range request." >&2
    echo "         Requested size may exceed the source file, or the server" >&2
    echo "         does not support range requests at all. Results may be invalid." >&2
fi

# Independent sanity check: confirm the bytes actually received match what
# was requested, regardless of what the HTTP status code claimed.
if [ "$DOWN_BYTES" -ne "$DOWNLOAD_BYTES" ]; then
    echo "WARNING: requested ${DOWNLOAD_BYTES} bytes but received ${DOWN_BYTES} bytes." >&2
    echo "         Throughput figure below reflects the bytes actually transferred," >&2
    echo "         not the ${DOWNLOAD_MB}MB you asked for - treat this run's result" >&2
    echo "         with caution." >&2
fi

log "Download complete: ${DOWN_BYTES} bytes in ${DOWN_TIME}s => ${DOWN_MBPS} Mbps"

echo ""
echo "=== Summary ==="
printf "%-12s %10s MB   %8ss   %8s Mbps\n" "Upload:"   "$UPLOAD_MB"   "$UP_TIME"   "$UP_MBPS"
printf "%-12s %10s MB   %8ss   %8s Mbps\n" "Download:" "$DOWNLOAD_MB" "$DOWN_TIME" "$DOWN_MBPS"
INNER_SCRIPT

# ---------------------------------------------------------------------------
# Dispatch: run locally, or pipe the script body over SSH to run remotely
# ---------------------------------------------------------------------------
if [ -z "$REMOTE_TARGET" ]; then
    echo "Running locally..."
    bash -c "$TEST_SCRIPT_BODY" _ "$UPLOAD_MB" "$DOWNLOAD_MB" "$UPLOAD_URL" "$DOWNLOAD_URL"
else
    if [[ "$REMOTE_TARGET" != *"@"* ]]; then
        REMOTE_TARGET="root@${REMOTE_TARGET}"
    fi
    echo "Running remotely on ${REMOTE_TARGET} via SSH..."
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$REMOTE_TARGET" \
        bash -s -- "$UPLOAD_MB" "$DOWNLOAD_MB" "$UPLOAD_URL" "$DOWNLOAD_URL" <<< "$TEST_SCRIPT_BODY"
fi
