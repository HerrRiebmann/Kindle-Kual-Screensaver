#!/bin/sh

BASEDIR="/mnt/us/extensions/dashboard"

# Load configuration
if [ -e "$BASEDIR/config.sh" ]; then
	. $BASEDIR/config.sh
fi

LOG=/mnt/us/dashboard_test.log
FBINK="$BASEDIR/bin/fbink"

echo "=== Test Start: $(date) ===" > $LOG

# 1. Prevent screensaver
echo "--- preventScreenSaver ---" >> $LOG
lipc-set-prop com.lab126.powerd preventScreenSaver 1 >> $LOG 2>&1
echo "Exit code: $?" >> $LOG

# 2. Disable Pillow (UI overlay)
echo "--- Disable Pillow ---" >> $LOG
lipc-set-prop com.lab126.pillow disableEnablePillow disable >> $LOG 2>&1
echo "Exit code: $?" >> $LOG

sleep 2

# 3. Test wget
echo "--- wget test ---" >> $LOG
wget -q -O "$IMG" "http://${DASHBOARD_HOST}:${DASHBOARD_PORT}/" >> $LOG 2>&1
echo "wget exit code: $?" >> $LOG
ls -l "$IMG" >> $LOG 2>&1

# 4. Test fbink
echo "--- fbink test ---" >> $LOG
$FBINK -g file="$IMG" >> $LOG 2>&1
echo "fbink exit code: $?" >> $LOG

# 5. Full refresh
echo "--- fbink full refresh ---" >> $LOG
$FBINK -f >> $LOG 2>&1
echo "fbink -f exit code: $?" >> $LOG

# 6. Second fbink draw (after refresh)
echo "--- fbink second draw ---" >> $LOG
$FBINK -g file="$IMG" >> $LOG 2>&1
echo "fbink exit code: $?" >> $LOG

# 7. Re-enable Pillow
echo "--- Re-enable Pillow ---" >> $LOG
lipc-set-prop com.lab126.pillow disableEnablePillow enable >> $LOG 2>&1
echo "Exit code: $?" >> $LOG

echo "=== Test End: $(date) ===" >> $LOG
#/mnt/us/extensions/dashboard/bin/fbink -g file=/mnt/us/bg_ss00.png >> $LOG 2>&1
#echo "done" >> $LOG