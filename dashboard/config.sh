#!/bin/sh

# Dashboard server IP and port
DASHBOARD_HOST="192.168.1.23"
DASHBOARD_PORT="5000"

# Path for temporary image file
IMG="/tmp/kindle.png"

# Update interval in minutes - used during daytime
# Aligns to clock boundaries (e.g. 10 = wake at :00, :10, :20, :30, :40, :50)
UPDATE_INTERVAL_MIN=10

# Update interval in minutes during night hours
# Aligns to clock boundaries (e.g. 60 = wake at :00 each hour)
NIGHT_UPDATE_INTERVAL_MIN=60

# Night mode hours (24h format): reduced update frequency between these hours
NIGHT_START=21
NIGHT_END=7

# Full e-ink refresh every N updates (every 10th update = ~100 min)
FULL_REFRESH_EVERY=10
