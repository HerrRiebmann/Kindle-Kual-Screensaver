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

wifi_on() {
    log "wifi_on: ensuring powerd is running"
    # powerd should already be running (not frozen during suspend)
    # but thaw it just in case
    killall -CONT powerd 2>/dev/null
    sleep 1

    # Ensure clean state: kill any stale wpa_supplicant left from a
    # previous failed recovery cycle. A leftover daemon blocks the
    # framework from starting its own, causing all future connects to fail.
    if pidof wpa_supplicant >/dev/null 2>&1; then
        log "wifi_on: killing stale wpa_supplicant from previous cycle"
        killall wpa_supplicant 2>/dev/null
        sleep 1
    fi

    # Log current WiFi state before attempting connection
    CM_PRE=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)
    log "wifi_on: pre-enable cmState='$CM_PRE'"

    # Try up to 4 attempts with increasingly aggressive resets:
    # 1) Normal enable  2) lipc power-cycle  3) Kernel-level driver reset
    # 4) rfkill hardware power-cycle
    ATTEMPT=1
    MAX_ATTEMPTS=4
    while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
        log "wifi_on: attempt $ATTEMPT/$MAX_ATTEMPTS - enabling wireless"
        lipc-set-prop com.lab126.cmd wirelessEnable 1

        # Wait for WiFi to connect (max 20 seconds per attempt)
        TRIES=0
        while [ $TRIES -lt 20 ]; do
            if lipc-get-prop com.lab126.wifid cmState 2>/dev/null | grep -q CONNECTED; then
                log "wifi_on: connected after ${TRIES}s (attempt $ATTEMPT)"
                sleep 1
                return 0
            fi
            sleep 1
            TRIES=$((TRIES + 1))
        done

        log "wifi_on: attempt $ATTEMPT failed after 20s"

        if [ $ATTEMPT -eq 1 ]; then
            # Attempt 1 failed: soft power-cycle via framework
            log "wifi_on: soft power-cycle (lipc disable/enable)"
            lipc-set-prop com.lab126.cmd wirelessEnable 0
            sleep 3
        elif [ $ATTEMPT -eq 2 ]; then
            # Attempt 2 failed: hard reset at kernel level
            log "wifi_on: HARD RESET - reloading WiFi driver"
            lipc-set-prop com.lab126.cmd wirelessEnable 0
            sleep 1

            # Bring interface down
            ifconfig wlan0 down 2>/dev/null
            sleep 1

            # Find and reload the WiFi kernel module
            # Common Kindle WiFi modules: wlcore_sdio, wl18xx, ar6003, brcmfmac
            WIFI_MOD=$(lsmod 2>/dev/null | awk '/wl|ar6|brcm|8189|mlan/{print $1; exit}')
            if [ -n "$WIFI_MOD" ]; then
                log "wifi_on: unloading module '$WIFI_MOD'"
                rmmod "$WIFI_MOD" 2>/dev/null
                sleep 2
                modprobe "$WIFI_MOD" 2>/dev/null
                sleep 2
            else
                log "wifi_on: no WiFi module identified, using ifconfig reset"
            fi

            # Bring interface back up
            ifconfig wlan0 up 2>/dev/null
            sleep 2

            # Restart wpa_supplicant if it died
            if ! pidof wpa_supplicant >/dev/null 2>&1; then
                log "wifi_on: restarting wpa_supplicant"
                wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null \
                    || wpa_supplicant -B -i wlan0 -c /var/run/wpa_supplicant.conf 2>/dev/null
                sleep 2
            else
                # Force reassociate
                wpa_cli -i wlan0 disconnect 2>/dev/null
                wpa_cli -i wlan0 reassociate 2>/dev/null
            fi
            sleep 2
        elif [ $ATTEMPT -eq 3 ]; then
            # Attempt 3 failed: rfkill hardware power-cycle
            # This cuts power to the WiFi chip via GPIO, which can recover
            # a hung chip firmware that software resets cannot fix.
            log "wifi_on: RFKILL power-cycle - cutting chip power via GPIO"
            lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
            sleep 1
            rfkill block wifi 2>/dev/null
            sleep 3
            rfkill unblock wifi 2>/dev/null
            sleep 3
            # Bring interface back up after hardware power-cycle
            ifconfig wlan0 up 2>/dev/null
            sleep 2
            # Ensure wpa_supplicant is running
            if ! pidof wpa_supplicant >/dev/null 2>&1; then
                log "wifi_on: restarting wpa_supplicant after rfkill"
                wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null \
                    || wpa_supplicant -B -i wlan0 -c /var/run/wpa_supplicant.conf 2>/dev/null
                sleep 2
            fi
        fi

        ATTEMPT=$((ATTEMPT + 1))
    done
    log "wifi_on: FAILED to connect after $MAX_ATTEMPTS attempts (incl. rfkill)"
    return 1
}

wifi_off() {
    log "wifi_off: disabling wireless, freezing blanket"
    # Freeze blanket BEFORE disabling WiFi so it cannot react to the
    # WiFi state change and draw the airplane icon / status bar.
    killall -STOP blanket 2>/dev/null

    # Disable WiFi – powerd stays running so it can properly manage
    # the WiFi chip power state during suspend/resume.
    lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
    sleep 1

    # Clean up any leftover state from failed recovery attempts.
    # The aggressive escalation (attempts 2-4) manually starts
    # wpa_supplicant and manipulates rfkill/ifconfig. These changes
    # bypass the framework and persist across suspend/resume, causing
    # the NEXT wifi_on to fail permanently.
    killall wpa_supplicant 2>/dev/null
    rfkill unblock wifi 2>/dev/null
    ifconfig wlan0 down 2>/dev/null
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

# After resume from suspend, re-establish our display lock:
# powerd/mesquite may try to reclaim the framebuffer on wake.
post_wake() {
    log "post_wake: re-establishing display lock"
    # powerd is already running (not frozen during suspend) so it has
    # already processed the resume event and reinitialized hardware.
    # Give it a moment to finish its resume handlers.
    sleep 3

    # Prevent powerd from entering deeper sleep states (hibernate)
    lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null

    # Log WiFi chip state for diagnostics
    WLAN_STATE=$(ifconfig wlan0 2>/dev/null | head -1)
    CM_STATE=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)
    log "post_wake: wlan0='$WLAN_STATE' cmState='$CM_STATE'"

    # Reset framebuffer bit depth. After multiple suspend/resume cycles
    # the kernel may switch the framebuffer format (e.g. 8bpp -> 32bpp)
    # causing black screen + stripe artifacts. fbdepth forces it back
    # to 8bpp grayscale which fbink expects.
    FB_BPP_BEFORE=$(cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null)
    log "post_wake: resetting framebuffer depth"
    $BASEDIR/bin/fbdepth -d 8 2>/dev/null

    # Log framebuffer state for diagnostics
    FB_STATE=$(cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null)
    log "post_wake: fb0 bpp=$FB_STATE"

    # If bit depth actually changed, the framebuffer content is corrupted.
    # Repaint the last image so the display isn't garbled.
    FB_CHANGED=0
    if [ "$FB_BPP_BEFORE" != "8" ] && [ -f "$IMG" ]; then
        log "post_wake: bpp changed ($FB_BPP_BEFORE->8), repainting last image"
        $FBINK -q -f -g file="$IMG"
        FB_CHANGED=1
    fi

    # NOTE: Do NOT clear the screen here. The e-ink panel retains its
    # image across suspend-to-RAM without power. Clearing would destroy
    # the displayed dashboard and force a repaint even when WiFi fails.
    # The EPDC wakes automatically when the next fbink draw command is
    # issued (in update.sh on successful fetch).
    log "post_wake: e-ink ready (image retained)"

    # Thaw blanket briefly so it can process D-Bus unload commands.
    # If blanket is still SIGSTOP'd from the previous wifi_off(), lipc
    # commands would hang until timeout (~7s each), delaying wifi_on and
    # destabilising the WiFi stack.
    killall -CONT blanket 2>/dev/null
    sleep 1

    # Re-disable Pillow UI overlay and blanket modules
    lipc-set-prop com.lab126.pillow disableEnablePillow disable 2>/dev/null
    lipc-set-prop com.lab126.blanket unload screensaver 2>/dev/null
    lipc-set-prop com.lab126.blanket unload active_status_bar 2>/dev/null

    # Re-freeze blanket and mesquite
    killall -STOP blanket 2>/dev/null
    killall -STOP mesquite 2>/dev/null

    # Re-kill frontlight in case resume re-enabled it
    lipc-set-prop com.lab126.powerd flIntensity 0 2>/dev/null
    lipc-set-prop com.lab126.powerd flEnable 0 2>/dev/null
    for bl in /sys/class/backlight/*/brightness; do
        [ -e "$bl" ] && echo 0 > "$bl" 2>/dev/null
    done

    # NOTE: Do NOT freeze powerd here – wifi_on needs it running.
    # powerd will be frozen inside wifi_off() after WiFi is disabled.
}

COUNTER=1
while true
do
    SLEEP_SECONDS=$(get_seconds_to_next_slot)
    do_suspend $SLEEP_SECONDS

    # --- Device just woke up ---
    log "--- Wake cycle $COUNTER (woke at $(date '+%H:%M:%S')) ---"
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