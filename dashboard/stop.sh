#!/bin/sh

BASEDIR="/mnt/us/extensions/dashboard"
PIDFILE="$BASEDIR/pid"
FBINK="$BASEDIR/bin/fbink"

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

# Safety net: restore critical state even if the subshell trap didn't fire.
# Order matters! Hardware state first, then UI framework, then processes.

# --- 1. Thaw powerd (manages all hardware) ---
killall -CONT powerd 2>/dev/null
sleep 1

# --- 2. Clear any pending RTC wake alarm ---
[ -e /sys/class/rtc/rtc0/wakealarm ] && echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null

# --- 3. Restore framebuffer to native bit depth BEFORE any UI draws ---
# auto.sh forces 8bpp via fbdepth; the framework expects 32bpp.
if [ -x "$BASEDIR/bin/fbdepth" ]; then
    $BASEDIR/bin/fbdepth -d 32 2>/dev/null
fi

# --- 4. Wake e-ink controller ---
# After suspend cycles the controller is powered off and won't push
# framebuffer changes to the panel. A clear+flash wakes it up.
if [ -x "$FBINK" ]; then
    $FBINK -c -f 2>/dev/null
fi

# --- 5. Re-enable frontlight hardware ---
for bp in /sys/class/backlight/*/bl_power; do
    [ -e "$bp" ] && echo 0 > "$bp" 2>/dev/null   # FB_BLANK_UNBLANK = 0
done
lipc-set-prop com.lab126.powerd flEnable 1 2>/dev/null

# --- 6. Restore power management settings ---
# NOTE: Do NOT set preventScreenSaver 0 yet! powerd's inactivity timer
# has been running the entire time auto.sh was active (hours/days).
# If we allow screensaver now, powerd immediately triggers sleep.
# We'll reset the idle timer and release the screensaver lock at the end.
echo 1 > /sys/power/hibernate_allowed 2>/dev/null

# --- 7. Re-enable WiFi ---
lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null

# --- 8. Thaw blanket, re-enable Pillow, reload modules ---
killall -CONT blanket 2>/dev/null
sleep 1
lipc-set-prop com.lab126.pillow disableEnablePillow enable 2>/dev/null
lipc-set-prop com.lab126.blanket load screensaver 2>/dev/null
lipc-set-prop com.lab126.blanket load active_status_bar 2>/dev/null

# --- 9. Restart services that were stopped by auto.sh ---
start otaupd 2>/dev/null
start phd 2>/dev/null
start tmd 2>/dev/null
start webreader 2>/dev/null
start todo 2>/dev/null
start archive 2>/dev/null
start searchd 2>/dev/null

# --- 10. Thaw mesquite LAST so it redraws into a fully prepared fb ---
killall -CONT mesquite 2>/dev/null

# Give mesquite + blanket time to redraw the home screen and status bar
sleep 5

# --- 11. Final full-screen refresh to push everything to the e-ink panel ---
if [ -x "$FBINK" ]; then
    $FBINK -f -s 2>/dev/null
fi

# --- 12. Reset powerd idle timer, THEN allow screensaver ---
# Simulate user activity so powerd starts counting from zero.
# Without this, powerd would immediately trigger sleep because the
# accumulated idle time (from hours of auto.sh) exceeds the threshold.
lipc-set-prop com.lab126.powerd wakeUp 1 2>/dev/null
lipc-send-event com.lab126.powerd wakeUp 2>/dev/null
# Now it's safe to allow the screensaver again
lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null