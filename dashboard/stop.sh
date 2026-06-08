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
# Core insight: powerd has accumulated hours/days of idle time while frozen.
# wakeUp events do NOT reset this internal counter. The ONLY reliable fix
# is to restart powerd entirely so it starts with a fresh idle timer.

# --- 1. Restore framebuffer to 32bpp BEFORE thawing UI ---
log "Step 1: Restoring framebuffer to 32bpp"
if [ -x "$BASEDIR/bin/fbdepth" ]; then
    $BASEDIR/bin/fbdepth -d 32 2>/dev/null
fi

# --- 2. Thaw powerd temporarily for lipc calls ---
log "Step 2: Thawing powerd temporarily"
killall -CONT powerd 2>/dev/null
sleep 1

# Block screensaver while we're restoring (powerd still has stale state)
lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null

# --- 3. Clear RTC wake alarm ---
log "Step 3: Clearing RTC wake alarm"
[ -e /sys/class/rtc/rtc0/wakealarm ] && echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null

# --- 4. Restore WiFi ---
log "Step 4: Restoring WiFi"
if ! ifconfig wlan0 >/dev/null 2>&1; then
    log "wlan0 missing, loading WiFi module"
    for mod in wlcore_sdio wl18xx ar6003 brcmfmac 8189fs mlan; do
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

# --- 5. Restore power management + frontlight ---
log "Step 5: Restoring power mgmt + frontlight"
echo 1 > /sys/power/hibernate_allowed 2>/dev/null
for bp in /sys/class/backlight/*/bl_power; do
    [ -e "$bp" ] && echo 0 > "$bp" 2>/dev/null
done
lipc-set-prop com.lab126.powerd flEnable 1 2>/dev/null

# --- 6. Thaw + re-enable blanket/Pillow ---
log "Step 6: Thawing blanket + enabling Pillow"
killall -CONT blanket 2>/dev/null
sleep 1
lipc-set-prop com.lab126.pillow disableEnablePillow enable 2>/dev/null
sleep 1
lipc-set-prop com.lab126.blanket load active_status_bar 2>/dev/null
lipc-set-prop com.lab126.blanket load screensaver 2>/dev/null

# --- 7. Restart stopped services ---
log "Step 7: Restarting stopped services"
start otaupd 2>/dev/null
start phd 2>/dev/null
start tmd 2>/dev/null
start webreader 2>/dev/null
start todo 2>/dev/null
start archive 2>/dev/null
start searchd 2>/dev/null

# --- 8. Thaw mesquite ---
log "Step 8: Thawing mesquite"
killall -CONT mesquite 2>/dev/null
sleep 1

# --- 9. RESTART powerd to reset its internal idle timer ---
# This is the critical step. wakeUp events do NOT reset powerd's internal
# idle counter. After being frozen for hours, powerd will immediately
# trigger screensaver (= black screen + touch disabled) the moment
# preventScreenSaver is released. The only reliable fix is a full restart.
log "Step 9: Restarting powerd (fresh idle timer)"
stop powerd 2>/dev/null
sleep 2
start powerd 2>/dev/null
sleep 3
log "Step 9: powerd restarted, pid=$(pidof powerd 2>/dev/null || echo 'NOT RUNNING')"

# After restart, powerd is in clean "awake" state with normal screensaver
# timeout (typically 5-10 minutes). No need for preventScreenSaver hacks.

# --- 10. Trigger home screen redraw ---
# powerd restart may have triggered a screen update; ensure home screen
# is properly drawn.
log "Step 10: Triggering home screen redraw"
lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home 2>/dev/null

log "=== stop.sh complete ==="