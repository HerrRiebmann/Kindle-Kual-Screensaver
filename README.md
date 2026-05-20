# Kindle-KUAL-Dashboard

A [KUAL](https://www.mobileread.com/forums/showthread.php?t=203326) extension that turns a Kindle Paperwhite into a wall-mounted [Home Assistant](https://www.home-assistant.io/) dashboard.

## Background

I wanted a Home Assistant dashboard to hang on my wall. After some research I read about jailbreaking a Kindle to achieve this. However, I bought a **Kindle Paperwhite 7th Generation** FW 5.16 which can be jailbroken but cannot use the recommended screensaver extension. So I created my own solution — not perfect, but working.

## Prerequisites

- A jailbreak-capable Kindle — check compatibility at [kindlemodding.org](https://kindlemodding.org/jailbreaking/WinterBreak/)
- Jailbreak applied to the device
- [KUAL](https://www.mobileread.com/forums/showthread.php?t=203326) (Kindle Unified Application Launcher) installed
- A Home Assistant instance (or any HTTP server) serving a PNG dashboard image [Lovelace Kindle Screensaver](https://github.com/sibbl/hass-lovelace-kindle-screensaver)
- Using the Kiosk Extension for fullscreen. [HACS Kiosk-Mode](https://github.com/NemesisRE/kiosk-mode)
- The latest [FBInk release](https://github.com/NiLuJe/FBInk/releases) — specifically the binaries `fbink`, `fbdepth`, and `doom` copied into `extensions/dashboard/bin/`

## Installation

1. Copy the `dashboard` folder onto the Kindle at `/mnt/us/extensions/dashboard`
2. Download the FBInk binaries and place them in `extensions/dashboard/bin/`
3. Edit `config.sh` to point to your dashboard server IP and port
4. Launch KUAL and select **Dashboard → Start auto refresh**

## Project Structure

| File | Purpose |
|------|---------|
| `auto.sh` | Main daemon — manages the full lifecycle (WiFi, display, suspend/wake loop) |
| `stop.sh` | Gracefully stops the running daemon and restores Kindle services |
| `update.sh` | Fetches the dashboard PNG from the server and draws it via FBInk |
| `test.sh` | Diagnostic script for testing individual components (wget, fbink) |
| `config.sh` | User configuration (server address, update intervals, night mode) |
| `config.xml` | KUAL extension metadata |
| `menu.json` | KUAL menu entries (Update now, Start/Stop auto refresh, Test) |
| `bin/fbink` | [FBInk](https://github.com/NiLuJe/FBInk) — framebuffer drawing tool for e-ink displays |
| `bin/fbdepth` | FBInk utility to reset framebuffer bit depth (fixes display artifacts after suspend) |
| `bin/doom` | FBInk doom-fire demo (bundled with FBInk release) |

## How It Works

### Update Cycle

1. The device wakes from suspend-to-RAM via an RTC alarm
2. WiFi is enabled (with up to 3 retry attempts including kernel-level driver reset)
3. `update.sh` fetches a PNG from the configured HTTP server, passing battery level and charging state as query parameters
4. The image is rendered to the e-ink framebuffer using FBInk
5. WiFi is disabled and the device suspends again

### Power Optimization

- Uses **suspend-to-RAM** (`echo mem > /sys/power/state` or `rtcwake`) instead of `sleep` — the CPU is fully powered off between updates while the e-ink display retains the image
- Frontlight is completely disabled at the hardware level (sysfs `brightness` + `bl_power`)
- Unnecessary services are stopped: `otaupd`, `phd`, `tmd`, `webreader`, `searchd`, etc.
- UI processes (`blanket`, `mesquite`, `pillow`) are frozen to prevent framebuffer overwrites
- Filesystem caches are dropped to free RAM

### Night Mode

Configurable reduced update frequency during night hours (default: every 60 min between 21:00–07:00 vs. every 10 min during the day). Updates are aligned to clock boundaries (e.g., `:00`, `:10`, `:20`).

### WiFi Resilience

The `wifi_on` function implements a 3-stage retry strategy:

1. Normal enable via `lipc-set-prop`
2. Soft power-cycle (disable/re-enable via framework)
3. Hard reset — kernel module unload/reload + `wpa_supplicant` restart

### Display Stability

After each wake from suspend, `post_wake` re-establishes control:

- Resets framebuffer to 8bpp grayscale via `fbdepth` (prevents artifacts from kernel depth switching)
- Forces a full e-ink panel refresh to wake the display controller
- Re-freezes UI processes and re-disables the frontlight

## Configuration

Edit `config.sh`:

```sh
DASHBOARD_HOST="192.168.1.23"    # Your dashboard server IP
DASHBOARD_PORT="5000"            # Server port
UPDATE_INTERVAL_MIN=10           # Daytime update interval (minutes)
NIGHT_UPDATE_INTERVAL_MIN=60     # Nighttime update interval (minutes)
NIGHT_START=21                   # Night mode start hour (24h)
NIGHT_END=7                      # Night mode end hour (24h)
FULL_REFRESH_EVERY=10            # Full e-ink refresh every N updates
```

## KUAL Menu

The extension exposes four actions through KUAL:

- **Update now** — single manual refresh
- **Start auto refresh** — launches the background daemon
- **Stop auto refresh** — kills the daemon and restores normal Kindle operation
- **Test** — runs diagnostics and writes results to `/mnt/us/dashboard_test.log`

## Server Expectations

The dashboard server should respond to `GET /?batteryLevel=<0-100>&isCharging=<Yes|No>` with a PNG image sized to match the Kindle's screen resolution (e.g., 1024×758 for PW3).

Sending the batterylevel reqires to setup an endpoint on Home Assistant [Kindle Screensaver Webhook](https://github.com/sibbl/hass-lovelace-kindle-screensaver#how-to-set-up-the-webhook)

## Problems
Ending the Dashboard mode requires using the hardware button. Then tap on the top for bringing the menu into the front.
Then the script can be stopped. This sometimes does not brings you back to the main Kindle screen. Then just restart the device 🤷🏻‍♂️
- Working on this right now.
