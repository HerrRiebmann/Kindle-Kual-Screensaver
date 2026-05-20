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
killall -CONT powerd 2>/dev/null
killall -CONT mesquite 2>/dev/null
lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
lipc-set-prop com.lab126.pillow disableEnablePillow enable 2>/dev/null
lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null

# Clear any pending RTC wake alarm
[ -e /sys/class/rtc/rtc0/wakealarm ] && echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null