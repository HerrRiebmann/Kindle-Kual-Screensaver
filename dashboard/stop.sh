#!/bin/sh

BASEDIR="/mnt/us/extensions/dashboard"
PIDFILE="$BASEDIR/pid"
FBINK="$BASEDIR/bin/fbink"
LOG="$BASEDIR/stop.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

log "=== stop.sh starting ==="

# --- 0. Kill the dashboard process ---
if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE")
    log "Killing dashboard PID $PID"

    for child in $(ps -o pid,ppid 2>/dev/null | awk -v p="$PID" '$2==p {print $1}'); do
        kill "$child" 2>/dev/null
    done

    kill "$PID" 2>/dev/null
    sleep 2

    if kill -0 "$PID" 2>/dev/null; then
        log "PID $PID still alive, force-killing"
        kill -9 "$PID" 2>/dev/null
    fi

    rm -f "$PIDFILE"
    log "Dashboard process killed"
else
    log "No pidfile found, nothing to kill"
fi

# === RESTORE SYSTEM STATE ===
# Critical: powerd has been frozen for hours/days. If we merely thaw it,
# its stale idle timer fires immediately (screensaver → black screen →
# deep sleep) before we can restore anything else. Therefore we RESTART
# powerd as the very first step so it starts with a fresh idle timer.

# --- 1. Restart powerd FIRST (fresh idle timer) ---
# This must happen before ANY other restore step. A stale powerd will
# black out the screen within seconds of being thawed.
log "Step 1: Restarting powerd (reset idle timer)"
killall -CONT powerd 2>/dev/null   # unfreeze so 'stop' works
sleep 1
stop powerd 2>/dev/null
sleep 2
start powerd 2>/dev/null
sleep 3
log "Step 1: powerd restarted, pid=$(pidof powerd 2>/dev/null || echo 'NOT RUNNING')"

# powerd is now in a clean "awake" state. Block screensaver while we
# continue restoring so it doesn't fire during the remaining steps.
lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null

# --- 2. Clear RTC wake alarm ---
log "Step 2: Clearing RTC wake alarm"
[ -e /sys/class/rtc/rtc0/wakealarm ] && echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null

# --- 3. Restore WiFi ---
log "Step 3: Restoring WiFi"
if ! ifconfig wlan0 >/dev/null 2>&1; then
    log "wlan0 missing, loading WiFi module"
    for mod in ath6kl_sdio wlcore_sdio wl18xx ar6003 brcmfmac 8189fs mlan; do
        modprobe "$mod" 2>/dev/null && break
    done
    sleep 3
    if ifconfig wlan0 >/dev/null 2>&1; then
        log "wlan0 restored"
    else
        log "WARNING: wlan0 still missing"
    fi
else
    log "wlan0 already present"
fi
killall wpa_supplicant 2>/dev/null
pidof wifid >/dev/null 2>&1 || start wifid 2>/dev/null
sleep 1
lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null

# --- 4. Restore power management + frontlight ---
log "Step 4: Restoring power mgmt + frontlight"
echo 1 > /sys/power/hibernate_allowed 2>/dev/null
for bp in /sys/class/backlight/*/bl_power; do
    [ -e "$bp" ] && echo 0 > "$bp" 2>/dev/null
done
lipc-set-prop com.lab126.powerd flEnable 1 2>/dev/null

# --- 5. Thaw blanket + mesquite, re-enable Pillow ---
log "Step 5: Thawing blanket + mesquite, enabling Pillow"
killall -CONT blanket 2>/dev/null
killall -CONT mesquite 2>/dev/null
sleep 1
lipc-set-prop com.lab126.pillow disableEnablePillow enable 2>/dev/null
sleep 1
lipc-set-prop com.lab126.blanket load active_status_bar 2>/dev/null
lipc-set-prop com.lab126.blanket load screensaver 2>/dev/null

# --- 6. Restart stopped services ---
log "Step 6: Restarting stopped services"
start otaupd 2>/dev/null
start phd 2>/dev/null
start tmd 2>/dev/null
start webreader 2>/dev/null
start todo 2>/dev/null
start archive 2>/dev/null
start searchd 2>/dev/null
start fastmetrics 2>/dev/null

# --- 7. Restore framebuffer to 32bpp + trigger home screen ---
log "Step 7: Restoring framebuffer to 32bpp + home screen"
if [ -x "$BASEDIR/bin/fbdepth" ]; then
    $BASEDIR/bin/fbdepth -d 32 2>/dev/null
fi
sleep 1
# Trigger home screen redraw (now that mesquite is running + fb is 32bpp)
lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home 2>/dev/null
sleep 2

# --- 8. Release screensaver prevention ---
# powerd now has a fresh idle timer; normal screensaver timeout applies.
log "Step 8: Releasing preventScreenSaver"
lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null

log "=== stop.sh complete ==="