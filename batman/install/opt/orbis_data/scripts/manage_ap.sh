#!/usr/bin/env bash
set -euo pipefail

# Manage Local AP (wlan0) - bring interface UP or DOWN without removing it.
# Usage:
#   manage_ap.sh up     # bring wlan0 UP (interface stays configured)
#   manage_ap.sh down   # bring wlan0 DOWN (interface stays configured, stays in config)
#   manage_ap.sh status # show wlan0 status

IFACE="wlan0"
IFPATH="/sys/class/net/$IFACE"

cmd="${1:-status}"

# Check if interface exists
exists() { [ -d "$IFPATH" ]; }

# Get current UP/DOWN state
is_up() {
    if ! exists; then
        return 1
    fi
    ip link show "$IFACE" | grep -q "UP"
}

case "$cmd" in
  up)
    if exists; then
        echo "Bringing $IFACE UP"
        sudo ip link set "$IFACE" up
        sleep 1
        sudo systemctl restart hostapd || true
        echo "$IFACE is now UP"
    else
        echo "Error: $IFACE interface not found" 1>&2
        exit 2
    fi
    ;;
  down)
    if exists; then
        echo "Bringing $IFACE DOWN"
        sudo ip link set "$IFACE" down
        echo "$IFACE is now DOWN"
    else
        echo "Error: $IFACE interface not found" 1>&2
        exit 2
    fi
    ;;
  status)
    if exists; then
        if is_up; then
            echo "$IFACE status: UP"
        else
            echo "$IFACE status: DOWN"
        fi
        sudo ip addr show "$IFACE" 2>/dev/null || true
    else
        echo "$IFACE interface not present"
        exit 2
    fi
    ;;
  *)
    echo "Usage: $0 {up|down|status}" 1>&2
    exit 1
    ;;
esac
