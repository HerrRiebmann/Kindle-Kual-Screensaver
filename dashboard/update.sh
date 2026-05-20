#!/bin/sh

BASEDIR="/mnt/us/extensions/dashboard"
FBINK="$BASEDIR/bin/fbink"
LOG="$BASEDIR/dashboard.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

# Load configuration
if [ -e "$BASEDIR/config.sh" ]; then
	. $BASEDIR/config.sh
fi

URL="http://${DASHBOARD_HOST}:${DASHBOARD_PORT}/"

# Get battery status
POWERD_OUTPUT=$(/usr/bin/powerd_test -s)
batteryLevel=$(echo "$POWERD_OUTPUT" | awk -F: '/Battery Level/ {print substr($2, 1, length($2)-1) + 0}')
isCharging=$(echo "$POWERD_OUTPUT" | awk -F: '/Charging/ {print substr($2,2,length($2))}')

FULL_URL="${URL}?batteryLevel=${batteryLevel}&isCharging=${isCharging}"
log "update: wget $FULL_URL -> $IMG"

wget -q -O "$IMG" "$FULL_URL" 2>>"$LOG"
RC=$?
log "update: wget exit code=$RC, file size=$(wc -c < "$IMG" 2>/dev/null || echo 0) bytes"

if [ $RC -eq 0 ] && [ -s "$IMG" ]; then
    $FBINK -q -f -g file="$IMG"
    log "update: fbink displayed image (full refresh)"
else
    log "update: FAILED (wget rc=$RC or empty file)"
fi