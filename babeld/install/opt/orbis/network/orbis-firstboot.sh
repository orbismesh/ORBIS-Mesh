#!/usr/bin/env bash
set -euo pipefail


ORBIS_CONF="/opt/orbis/orbis.conf"
[ -f "$ORBIS_CONF" ] && . "$ORBIS_CONF" || true

log(){ echo "[orbis-firstboot] $*"; }

[ "$(id -u)" -eq 0 ] || { echo "Must run as root" >&2; exit 1; }

log "Running first-boot network transition tasks..."

# Ensure only dnsmasq provides DHCP for ORBIS LAN
for svc in isc-dhcp-server kea-dhcp4-server udhcpd dhcpd; do
  systemctl disable --now "$svc" 2>/dev/null || true
  systemctl mask "$svc" 2>/dev/null || true
done

# Disable dhcpcd (commonly used on Raspberry Pi) to avoid bridge conflicts
systemctl disable --now dhcpcd.service 2>/dev/null || true
systemctl mask dhcpcd.service 2>/dev/null || true

# Unmask hostapd.service but keep it disabled (ORBIS uses orbis-hostapd)
systemctl unmask hostapd.service 2>/dev/null || true
systemctl disable --now hostapd.service 2>/dev/null || true
systemctl reset-failed hostapd.service 2>/dev/null || true

# Disable/Mask distro wpa_supplicant units (ORBIS starts its own mesh instance)
systemctl disable --now wpa_supplicant.service 2>/dev/null || true
systemctl mask wpa_supplicant.service 2>/dev/null || true
systemctl disable --now wpa_supplicant@wlan0.service 2>/dev/null || true
systemctl disable --now wpa_supplicant@wlan1.service 2>/dev/null || true
systemctl disable --now wpa_supplicant@mesh0.service 2>/dev/null || true

# Disable NetworkManager to avoid interference (after reboot only, per requirement)
systemctl disable --now NetworkManager.service 2>/dev/null || true
systemctl mask NetworkManager.service 2>/dev/null || true
systemctl disable --now NetworkManager-wait-online.service 2>/dev/null || true
systemctl mask NetworkManager-wait-online.service 2>/dev/null || true
systemctl reset-failed NetworkManager-wait-online.service 2>/dev/null || true

log "Enabling ORBIS services..."
systemctl daemon-reload
systemctl enable orbis-ssh-ip.service orbis-network.service orbis-hostapd.service orbis-dnsmasq.service orbis-babeld.service orbis-ui.service smcroute.service

log "Starting ORBIS services..."
systemctl restart orbis-ssh-ip.service || true
systemctl restart orbis-network.service || true
systemctl restart orbis-hostapd.service || true
systemctl restart orbis-dnsmasq.service || true
systemctl restart orbis-babeld.service || true
systemctl restart orbis-ui.service || true
systemctl restart smcroute.service || true

log "Disabling orbis-firstboot.service (one-shot)."
systemctl disable --now orbis-firstboot.service 2>/dev/null || true

log "Done. ORBIS should now be active. UI: http://${ORBIS_UI_ADDR:-${ORBIS_LAN_ADDR:-192.168.200.1}}:${ORBIS_UI_PORT:-5000}"
