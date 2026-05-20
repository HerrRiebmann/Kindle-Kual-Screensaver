#!/bin/sh

BASEDIR="/mnt/us/extensions/dashboard"
PIDFILE="$BASEDIR/pid"

if [ -f "$PIDFILE" ]; then
    PID=$(cat "$PIDFILE")

    # Kill child processes first (sleep, update.sh, curl, etc.)
    # so the subshell isn't blocked waiting on a foreground child.
    for child in $(ps -o pid,ppid 2>/dev/null | awk -v p="$PID" '$2==p {print $1}'); do
        kill "$child" 2>/dev/null
    done

    # Now kill the subshell itself – trap should fire
    kill "$PID" 2>/dev/null

    # Give the trap handler a moment to run
    sleep 2

    # Force-kill if still alive
    kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null

    rm -f "$PIDFILE"
fi

# Safety net: restore critical state even if the subshell trap didn't fire

# Thaw ALL frozen processes first so they can respond to state changes
killall -CONT blanket 2>/dev/null
killall -CONT powerd 2>/dev/null
killall -CONT mesquite 2>/dev/null

# Clear any pending RTC wake alarm
[ -e /sys/class/rtc/rtc0/wakealarm ] && echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null

# Restore framebuffer to native bit depth (usually 32bpp).
# auto.sh forces 8bpp via fbdepth; the framework expects the native depth.
BASEDIR="/mnt/us/extensions/dashboard"
if [ -x "$BASEDIR/bin/fbdepth" ]; then
    $BASEDIR/bin/fbdepth -d 32 2>/dev/null
fi

# Re-enable frontlight hardware (user can adjust brightness from settings)
for bp in /sys/class/backlight/*/bl_power; do
    [ -e "$bp" ] && echo 0 > "$bp" 2>/dev/null   # FB_BLANK_UNBLANK = 0
done
lipc-set-prop com.lab126.powerd flEnable 1 2>/dev/null

# Re-enable Pillow UI overlay
lipc-set-prop com.lab126.pillow disableEnablePillow enable 2>/dev/null

# Reload blanket modules (screensaver + status bar)
lipc-set-prop com.lab126.blanket load screensaver 2>/dev/null
lipc-set-prop com.lab126.blanket load active_status_bar 2>/dev/null

# Allow screensaver again
lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null

# Re-enable WiFi
lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null

# Restart services that were stopped by auto.sh
start otaupd 2>/dev/null
start phd 2>/dev/null
start tmd 2>/dev/null
start webreader 2>/dev/null
start todo 2>/dev/null
start archive 2>/dev/null
start searchd 2>/dev/null

# Give blanket/pillow a moment to redraw, then trigger a full screen refresh
# to clear the stale fbink image and show the normal Kindle UI
sleep 3
if [ -x "$BASEDIR/bin/fbink" ]; then
    $BASEDIR/bin/fbink -c -f 2>/dev/null
fi