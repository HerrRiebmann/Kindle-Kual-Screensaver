#!/bin/sh

BASEDIR="/mnt/us/extensions/dashboard"
PIDFILE="$BASEDIR/pid"
FBINK="$BASEDIR/bin/fbink"

# Load configuration
if [ -e "$BASEDIR/config.sh" ]; then
	. $BASEDIR/config.sh
fi

# Kill existing instance if running
if [ -f "$PIDFILE" ]; then
    kill $(cat "$PIDFILE") 2>/dev/null
    rm -f "$PIDFILE"
fi

# Turn off frontlight completely to save power
# flIntensity 0 only dims; flEnable 0 actually powers off the LED driver
lipc-set-prop com.lab126.powerd flIntensity 0
lipc-set-prop com.lab126.powerd flEnable 0

# 7th gen Kindle: lipc alone leaves a residual glow because the LM3630A
# LED driver keeps a minimum current. Write 0 directly to the sysfs
# backlight brightness to fully shut off the hardware.
for bl in /sys/class/backlight/*/brightness; do
	[ -e "$bl" ] && echo 0 > "$bl" 2>/dev/null
done
# Also power off the backlight device if bl_power exists
for bp in /sys/class/backlight/*/bl_power; do
	[ -e "$bp" ] && echo 4 > "$bp" 2>/dev/null   # FB_BLANK_POWERDOWN = 4
done

# Disable Pillow (UI overlay)
lipc-set-prop com.lab126.pillow disableEnablePillow disable

# Fully unload blanket modules that draw on the framebuffer:
# - screensaver: screensaver images during suspend
# - active_status_bar: clock + airplane icon + battery bar
lipc-set-prop com.lab126.blanket unload screensaver 2>/dev/null
lipc-set-prop com.lab126.blanket unload active_status_bar 2>/dev/null

# Freeze the blanket process so it can never draw anything (status bar,
# notifications, dialogs) on the framebuffer again.
killall -STOP blanket 2>/dev/null

# NOTE: Do NOT freeze powerd here. WiFi control requires powerd to be
# running. powerd will be frozen inside wifi_off() after WiFi is disabled.

# Stop unnecessary background services to reduce CPU/power usage
stop otaupd 2>/dev/null          # OTA update daemon
stop phd 2>/dev/null             # phone home daemon (metrics/telemetry)
stop tmd 2>/dev/null             # transfer manager daemon
stop webreader 2>/dev/null       # Kindle cloud reader
stop todo 2>/dev/null            # to-do list service
stop archive 2>/dev/null         # archive manager

# Disable indexing to prevent CPU wakeups
stop searchd 2>/dev/null

# Drop filesystem caches to free RAM
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null

# Freeze home screen process to prevent it from drawing over fbink
killall -STOP mesquite 2>/dev/null

(
trap 'killall -CONT blanket 2>/dev/null; killall -CONT powerd 2>/dev/null; killall -CONT mesquite 2>/dev/null; lipc-set-prop com.lab126.cmd wirelessEnable 1; lipc-set-prop com.lab126.pillow disableEnablePillow enable; rm -f "$PIDFILE"' EXIT INT TERM

LOG="/mnt/us/extensions/dashboard/dashboard.log"
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

# Track consecutive WiFi failures
WIFI_FAIL_COUNT=0

# Detect which WiFi kernel module drives wlan0.
# This lets us do clean rmmod/modprobe around suspend cycles.
detect_wifi_module() {
    # Method 1: follow the sysfs driver symlink (most reliable)
    if [ -e /sys/class/net/wlan0/device/driver/module ]; then
        _m=$(basename "$(readlink /sys/class/net/wlan0/device/driver/module)" 2>/dev/null)
        if [ -n "$_m" ]; then
            WIFI_MODULE="$_m"
            log "detect_wifi_module: found '$WIFI_MODULE' via sysfs"
            return 0
        fi
    fi
    # Method 2: check lsmod (flexible matching)
    for _mod in wlcore_sdio wl18xx ar6003 brcmfmac 8189fs mlan; do
        if lsmod 2>/dev/null | grep -q "$_mod"; then
            WIFI_MODULE="$_mod"
            log "detect_wifi_module: found '$WIFI_MODULE' via lsmod"
            return 0
        fi
    done
    # Method 3: check /proc/modules directly (some Kindles lack lsmod)
    for _mod in wlcore_sdio wl18xx ar6003 brcmfmac 8189fs mlan; do
        if grep -q "$_mod" /proc/modules 2>/dev/null; then
            WIFI_MODULE="$_mod"
            log "detect_wifi_module: found '$WIFI_MODULE' via /proc/modules"
            return 0
        fi
    done
    return 1
}

WIFI_MODULE=""
detect_wifi_module || log "detect_wifi_module: no module found at startup (will retry after first wifi_on)"

wifi_on() {
    log "wifi_on: ensuring powerd is running"
    killall -CONT powerd 2>/dev/null
    sleep 1

    # Ensure WiFi interface exists (module loaded)
    if ! ifconfig wlan0 >/dev/null 2>&1; then
        log "wifi_on: wlan0 missing, attempting to reload WiFi module"
        # Try common Kindle WiFi modules
        for mod in wlcore_sdio wl18xx ar6003 brcmfmac 8189fs mlan; do
            modprobe "$mod" 2>/dev/null && break
        done
        sleep 3
        if ! ifconfig wlan0 >/dev/null 2>&1; then
            log "wifi_on: wlan0 still missing after modprobe, cannot recover"
            return 1
        fi
        log "wifi_on: wlan0 restored after modprobe"
    fi

    # Kill stale wpa_supplicant from a previous failed cycle
    if pidof wpa_supplicant >/dev/null 2>&1; then
        log "wifi_on: killing stale wpa_supplicant"
        killall wpa_supplicant 2>/dev/null
        sleep 1
    fi

    CM_PRE=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)
    log "wifi_on: pre-enable cmState='$CM_PRE'"

    # Simple 3-attempt strategy: enable, disable+re-enable, restart wifid
    # Avoids destructive actions (rmmod, rfkill, manual bypass) that
    # destabilize the WiFi stack across suspend cycles.
    ATTEMPT=1
    MAX_ATTEMPTS=3
    while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
        log "wifi_on: attempt $ATTEMPT/$MAX_ATTEMPTS - enabling wireless"
        lipc-set-prop com.lab126.cmd wirelessEnable 1

        # Wait for connection (max 30 seconds)
        TRIES=0
        while [ $TRIES -lt 30 ]; do
            if lipc-get-prop com.lab126.wifid cmState 2>/dev/null | grep -q CONNECTED; then
                log "wifi_on: connected after ${TRIES}s (attempt $ATTEMPT)"
                sleep 1
                WIFI_FAIL_COUNT=0
                # Detect WiFi module now that wlan0 is up (if not yet known)
                if [ -z "$WIFI_MODULE" ]; then
                    detect_wifi_module || true
                fi
                return 0
            fi
            sleep 1
            TRIES=$((TRIES + 1))
        done

        log "wifi_on: attempt $ATTEMPT failed after 30s"

        if [ $ATTEMPT -eq 1 ]; then
            # Soft power-cycle via framework
            log "wifi_on: soft power-cycle (disable/enable)"
            lipc-set-prop com.lab126.cmd wirelessEnable 0
            sleep 5
        elif [ $ATTEMPT -eq 2 ]; then
            # Restart wifid to reset framework state machine
            log "wifi_on: restarting wifid"
            lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
            killall wpa_supplicant 2>/dev/null
            stop wifid 2>/dev/null
            sleep 3
            start wifid 2>/dev/null
            sleep 3
        fi

        ATTEMPT=$((ATTEMPT + 1))
    done

    WIFI_FAIL_COUNT=$((WIFI_FAIL_COUNT + 1))
    log "wifi_on: FAILED after $MAX_ATTEMPTS attempts (consecutive failures: $WIFI_FAIL_COUNT)"
    return 1
}

wifi_off() {
    log "wifi_off: disabling wireless"
    # Freeze blanket BEFORE disabling WiFi so it cannot react to the
    # WiFi state change and draw the airplane icon / status bar.
    killall -STOP blanket 2>/dev/null

    # Disable WiFi via framework (clean shutdown)
    lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
    sleep 2

    # Kill any leftover wpa_supplicant (in case framework didn't clean up)
    killall wpa_supplicant 2>/dev/null

    # Ensure wifid is still running (needed for next wifi_on)
    pidof wifid >/dev/null 2>&1 || start wifid 2>/dev/null
}

# Returns the interval in minutes based on time of day
get_interval_min() {
    HOUR=$(date +%H | sed 's/^0//')
    if [ $NIGHT_START -gt $NIGHT_END ]; then
        # Overnight range (e.g. 21-7): night if hour >= start OR hour < end
        if [ $HOUR -ge $NIGHT_START ] || [ $HOUR -lt $NIGHT_END ]; then
            echo $NIGHT_UPDATE_INTERVAL_MIN
            return
        fi
    else
        # Same-day range: night if hour >= start AND hour < end
        if [ $HOUR -ge $NIGHT_START ] && [ $HOUR -lt $NIGHT_END ]; then
            echo $NIGHT_UPDATE_INTERVAL_MIN
            return
        fi
    fi
    echo $UPDATE_INTERVAL_MIN
}

# Calculate seconds until the next cron-aligned wake time.
# E.g. with interval=10 and current time 14:03:45 -> next is 14:10:00 = 375s
# This ensures updates always land on clock boundaries (:00, :10, :20, ...)
# matching the Home Assistant cron schedule exactly.
get_seconds_to_next_slot() {
    INTERVAL_MIN=$(get_interval_min)
    INTERVAL_SEC=$((INTERVAL_MIN * 60))
    NOW=$(date +%s)
    # Seconds since midnight
    MIDNIGHT=$(date -d "$(date +%Y-%m-%d) 00:00:00" +%s 2>/dev/null)
    if [ -z "$MIDNIGHT" ] || [ "$MIDNIGHT" = "" ]; then
        # BusyBox date fallback: calculate from H/M/S
        H=$(date +%H | sed 's/^0//')
        M=$(date +%M | sed 's/^0//')
        S=$(date +%S | sed 's/^0//')
        SINCE_MIDNIGHT=$(( H * 3600 + M * 60 + S ))
    else
        SINCE_MIDNIGHT=$((NOW - MIDNIGHT))
    fi
    # How far into the current slot are we?
    SLOT_OFFSET=$((SINCE_MIDNIGHT % INTERVAL_SEC))
    SECONDS_LEFT=$((INTERVAL_SEC - SLOT_OFFSET))
    # Minimum 60s to avoid immediate re-trigger
    if [ $SECONDS_LEFT -lt 60 ]; then
        SECONDS_LEFT=$((SECONDS_LEFT + INTERVAL_SEC))
    fi
    log "get_seconds_to_next_slot: interval=${INTERVAL_MIN}m, slot_offset=${SLOT_OFFSET}s, sleeping ${SECONDS_LEFT}s"
    echo $SECONDS_LEFT
}

# Initial display: clear screen first, then fetch + draw
log "=== Dashboard starting ==="
$FBINK -c -f
if wifi_on; then
    sh /mnt/us/extensions/dashboard/update.sh
    log "Initial update done"
else
    log "Initial wifi_on FAILED – showing error on screen"
    $FBINK -q -pm "WiFi connection failed"
fi
wifi_off
log "Initial setup complete, entering suspend loop"

# Suspend the device to RAM and wake via RTC alarm after $1 seconds.
# This is drastically more power-efficient than sleep+keepalive because
# the CPU and most peripherals are fully powered off during suspend.
# The e-ink display retains the image without any power.
do_suspend() {
    SECONDS_TO_SLEEP=$1
    log "Suspending for ${SECONDS_TO_SLEEP}s"

    # Do NOT freeze powerd here. It must remain running so it can:
    # 1) Properly manage WiFi chip power state during suspend
    # 2) Process the resume event and reinitialize WiFi hardware
    # Screensaver is prevented via preventScreenSaver property.
    lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null

    # Freeze mesquite (home screen) to prevent any UI drawing
    killall -STOP mesquite 2>/dev/null

    # Prevent the system from entering hibernate (deeper than suspend-to-RAM).
    echo 0 > /sys/power/hibernate_allowed 2>/dev/null

    # Unload WiFi kernel module before suspend. Without this, the driver
    # remains loaded while the SDIO chip is powered off, leaving it in an
    # unrecoverable state on resume. A clean rmmod+modprobe cycle gives
    # the hardware a fresh initialization each time.
    killall wpa_supplicant 2>/dev/null
    stop wifid 2>/dev/null
    sleep 1
    if [ -n "$WIFI_MODULE" ]; then
        rmmod "$WIFI_MODULE" 2>/dev/null
        log "do_suspend: unloaded WiFi module $WIFI_MODULE (rc=$?)"
    else
        # Module name unknown: try to unload all known WiFi modules
        log "do_suspend: WIFI_MODULE unknown, trying all known modules"
        for _mod in wlcore_sdio wl18xx ar6003 brcmfmac 8189fs mlan; do
            rmmod "$_mod" 2>/dev/null
        done
    fi

    # Disable wakeup sources that cause spurious resume.
    # Without this, the WiFi chip (even when broken/unloaded) or USB can
    # generate interrupts that wake the device seconds after suspend.
    for ws in /sys/class/wakeup/*/device/power/wakeup; do
        [ -e "$ws" ] && echo disabled > "$ws" 2>/dev/null
    done
    # Keep only RTC as a wakeup source
    for ws in /sys/bus/sdio/devices/*/power/wakeup; do
        [ -e "$ws" ] && echo disabled > "$ws" 2>/dev/null
    done
    for ws in /sys/bus/usb/devices/*/power/wakeup; do
        [ -e "$ws" ] && echo disabled > "$ws" 2>/dev/null
    done

    # Prefer rtcwake (cleanest API)
    if command -v rtcwake >/dev/null 2>&1; then
        rtcwake -d /dev/rtc0 -m mem -s "$SECONDS_TO_SLEEP" 2>/dev/null
        RC=$?
        log "rtcwake returned $RC"
        return
    fi

    # Fallback: manual RTC alarm + suspend
    if [ -e /sys/class/rtc/rtc0/wakealarm ]; then
        WAKE_TIME=$(($(cat /sys/class/rtc/rtc0/since_epoch) + SECONDS_TO_SLEEP))
        echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null
        echo "$WAKE_TIME" > /sys/class/rtc/rtc0/wakealarm 2>/dev/null
        echo mem > /sys/power/state 2>/dev/null
        return
    fi

    # Last resort: plain sleep (no power saving, but at least keeps running)
    sleep "$SECONDS_TO_SLEEP"
}

# After resume from suspend, re-establish our display lock.
post_wake() {
    log "post_wake: re-establishing display lock"
    sleep 2

    # Reset powerd idle timer IMMEDIATELY. Without this, powerd accumulates
    # idle time across suspend cycles and eventually forces hibernate
    # (deeper than suspend-to-RAM), which kills our process.
    lipc-set-prop com.lab126.powerd wakeUp 1 2>/dev/null
    lipc-send-event com.lab126.powerd wakeUp 2>/dev/null

    # Prevent screensaver
    lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null

    # Reload WiFi kernel module (was unloaded before suspend in do_suspend).
    # This gives the driver a fresh start with properly powered hardware.
    if [ -n "$WIFI_MODULE" ]; then
        modprobe "$WIFI_MODULE" 2>/dev/null
        sleep 3
        if ifconfig wlan0 >/dev/null 2>&1; then
            log "post_wake: wlan0 restored via modprobe $WIFI_MODULE"
        else
            # Module loaded but interface missing: try rmmod+modprobe cycle
            log "post_wake: wlan0 missing after modprobe, retrying rmmod+modprobe"
            rmmod "$WIFI_MODULE" 2>/dev/null
            sleep 1
            modprobe "$WIFI_MODULE" 2>/dev/null
            sleep 3
            if ifconfig wlan0 >/dev/null 2>&1; then
                log "post_wake: wlan0 restored on retry"
            else
                log "post_wake: wlan0 still missing after retry"
            fi
        fi
    else
        # Module name unknown: try rmmod+modprobe of all known modules
        log "post_wake: WIFI_MODULE unknown, trying rmmod+modprobe of all known modules"
        for _mod in wlcore_sdio wl18xx ar6003 brcmfmac 8189fs mlan; do
            rmmod "$_mod" 2>/dev/null
        done
        sleep 1
        for _mod in wlcore_sdio wl18xx ar6003 brcmfmac 8189fs mlan; do
            modprobe "$_mod" 2>/dev/null
            sleep 2
            if ifconfig wlan0 >/dev/null 2>&1; then
                log "post_wake: wlan0 restored via modprobe $_mod"
                # Now we know the module name for next time
                WIFI_MODULE="$_mod"
                break
            fi
            rmmod "$_mod" 2>/dev/null
        done
        if ! ifconfig wlan0 >/dev/null 2>&1; then
            log "post_wake: wlan0 still missing after trying all modules"
        fi
    fi
    start wifid 2>/dev/null
    sleep 1

    # Reset framebuffer bit depth if needed
    FB_BPP=$(cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null)
    if [ "$FB_BPP" != "8" ]; then
        log "post_wake: fb bpp=$FB_BPP, resetting to 8"
        $BASEDIR/bin/fbdepth -d 8 2>/dev/null
        # Repaint last image if we had to change depth
        if [ -f "$IMG" ]; then
            $FBINK -q -f -g file="$IMG"
        fi
    fi

    # Re-disable UI overlays (blanket must be running for lipc to work)
    killall -CONT blanket 2>/dev/null
    sleep 1
    lipc-set-prop com.lab126.pillow disableEnablePillow disable 2>/dev/null
    lipc-set-prop com.lab126.blanket unload screensaver 2>/dev/null
    lipc-set-prop com.lab126.blanket unload active_status_bar 2>/dev/null

    # Re-freeze blanket and mesquite
    killall -STOP blanket 2>/dev/null
    killall -STOP mesquite 2>/dev/null

    # Kill frontlight
    lipc-set-prop com.lab126.powerd flIntensity 0 2>/dev/null
    lipc-set-prop com.lab126.powerd flEnable 0 2>/dev/null
    for bl in /sys/class/backlight/*/brightness; do
        [ -e "$bl" ] && echo 0 > "$bl" 2>/dev/null
    done

    log "post_wake: done"
}

COUNTER=1
while true
do
    SLEEP_SECONDS=$(get_seconds_to_next_slot)
    SLEEP_SECONDS=$((SLEEP_SECONDS + 5))  # Wake 5s after cron boundary so HA has rendered
    do_suspend $SLEEP_SECONDS

    # --- Device just woke up ---
    log "--- Wake cycle $COUNTER (woke at $(date '+%H:%M:%S')) ---"

    # If WiFi has failed many consecutive times, do a full stack reset
    # before trying again. This recovers from states where wifid or the
    # WiFi module are permanently stuck.
    if [ $WIFI_FAIL_COUNT -ge 3 ]; then
        log "wifi: $WIFI_FAIL_COUNT consecutive failures, full stack reset"
        killall wpa_supplicant 2>/dev/null
        stop wifid 2>/dev/null
        sleep 2
        # Force rmmod+modprobe cycle for clean hardware reset
        if [ -n "$WIFI_MODULE" ]; then
            rmmod "$WIFI_MODULE" 2>/dev/null
            sleep 1
            modprobe "$WIFI_MODULE" 2>/dev/null
        else
            for _mod in wlcore_sdio wl18xx ar6003 brcmfmac 8189fs mlan; do
                rmmod "$_mod" 2>/dev/null
            done
            sleep 1
            for _mod in wlcore_sdio wl18xx ar6003 brcmfmac 8189fs mlan; do
                modprobe "$_mod" 2>/dev/null && break
            done
        fi
        sleep 3
        start wifid 2>/dev/null
        sleep 3
        WIFI_FAIL_COUNT=0
    fi

    post_wake

    # Enable WiFi, update, disable WiFi
    if wifi_on; then
        log "Fetching dashboard image"
        sh /mnt/us/extensions/dashboard/update.sh
    else
        log "WiFi failed, skipping refresh (e-ink retains last image)"
    fi
    wifi_off
    log "Suspending immediately"

    COUNTER=$((COUNTER + 1))
done
) &

echo $! > "$PIDFILE"