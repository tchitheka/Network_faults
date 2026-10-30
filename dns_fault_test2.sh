#!/usr/bin/env bash
#
# dns_fault_test.sh
#
# Generate repeated DNS failures by attempting to fetch a non-existent
# HTTPS domain every few seconds.
#
# Usage:
#
#   ./dns_fault_test.sh
#
#   ./dns_fault_test.sh 5
#
#   ./dns_fault_test.sh 5 takondwa@192.168.1.11
#
#   ./dns_fault_test.sh 10 takondwa@192.168.1.11 fake.domain.invalid
#

##############################################################################

MINUTES="${1:-10}"
REMOTE="$2"
DOMAIN="${3:-www.nadns.yakond.net}"
INTERVAL=4

##############################################################################

run_local() {

    local END=$((SECONDS + MINUTES*60))
    local COUNT=0

    echo
    echo "=================================================="
    echo " DNS Fault Injection"
    echo "=================================================="
    echo "Host      : $(hostname)"
    echo "Domain    : $DOMAIN"
    echo "Duration  : ${MINUTES} minute(s)"
    echo "Interval  : ${INTERVAL}s"
    echo "Started   : $(date)"
    echo "=================================================="
    echo

    while [ "$SECONDS" -lt "$END" ]
    do
        COUNT=$((COUNT+1))

        printf "[%03d] %s : " \
            "$COUNT" \
            "$(date '+%F %T')"

        wget \
            --tries=1 \
            --timeout=5 \
            -O /dev/null \
            "https://${DOMAIN}" \
            >/dev/null 2>&1

        echo "ExitCode=$?"

        sleep "$INTERVAL"

    done

    echo
    echo "Finished."
    echo "Iterations : $COUNT"
    echo

}

##############################################################################

run_remote() {

    echo
    echo "Dispatching to $REMOTE"
    echo "Duration : ${MINUTES} minute(s)"
    echo "Domain   : ${DOMAIN}"
    echo

    ssh -t "$REMOTE" "
SECONDS=0
END=\$((SECONDS+${MINUTES}*60))
COUNT=0

echo
echo '=================================================='
echo ' DNS Fault Injection'
echo '=================================================='
echo Host: \$(hostname)
echo Domain: ${DOMAIN}
echo Duration: ${MINUTES}' minute(s)'
echo Interval: ${INTERVAL}' seconds'
echo Started: \$(date)
echo '=================================================='
echo

while [ \$SECONDS -lt \$END ]
do

    COUNT=\$((COUNT+1))

    printf '[%03d] %s : ' \
        \$COUNT \
        \"\$(date '+%F %T')\"

    wget \
        --tries=1 \
        --timeout=5 \
        -O /dev/null \
        https://${DOMAIN} \
        >/dev/null 2>&1

    echo ExitCode=\$?

    sleep ${INTERVAL}

done

echo
echo Finished.
echo Iterations: \$COUNT
"

}

##############################################################################

if ! [[ "$MINUTES" =~ ^[0-9]+$ ]]; then
    echo "Usage:"
    echo
    echo "  $0 [minutes] [user@host] [invalid-domain]"
    exit 1
fi

##############################################################################

if [ -z "$REMOTE" ]; then
    run_local
else
    run_remote
fi
