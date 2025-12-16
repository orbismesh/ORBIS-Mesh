#!/usr/bin/env bash
set -euo pipefail

# Always run from the directory that contains this script, so relative paths work
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
cd "$SCRIPT_DIR"

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

# Create a detailed installer log
install -d -m 0755 /var/log/orbis
LOGFILE="/var/log/orbis/install-$(date +%Y%m%d-%H%M%S).log"

# Mirror installer output to SSH + logfile, and to tty1 if available
if [ -c /dev/tty1 ]; then
    exec > >(tee -a "$LOGFILE" | tee /dev/tty1) 2>&1
else
    exec > >(tee -a "$LOGFILE") 2>&1
fi

echo "=== ORBIS INSTALL START $(date -Is) ==="
echo "Logfile: $LOGFILE"
echo "Script path: $SCRIPT_PATH"
echo "Script dir:  $SCRIPT_DIR"
echo "Working dir: $(pwd)"
echo "Contents:    $(ls -1 | tr '\n' ' ')"
echo "Kernel:      $(uname -a)"
echo

echo "[1/13] Installing base packages (apt)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends       babeld hostapd dnsmasq wpasupplicant iw rfkill iproute2       ca-certificates       python3 python3-pip python3-flask pipx

echo "[2/13] Installing python tooling with pipx..."
python3 -m pipx ensurepath >/dev/null 2>&1 || true
pipx install --force gunicorn==22.0.0
install -d -m 0755 /usr/local/bin
ln -sf /root/.local/bin/gunicorn /usr/local/bin/gunicorn

echo "[3/13] Unmask hostapd.service (keep disabled; ORBIS uses orbis-hostapd)..."
systemctl unmask hostapd.service 2>/dev/null || true
systemctl disable --now hostapd.service 2>/dev/null || true
systemctl reset-failed hostapd.service 2>/dev/null || true

echo "[4/13] Ensure no other DHCP servers..."
for svc in isc-dhcp-server kea-dhcp4-server udhcpd dhcpd; do
  systemctl disable --now "$svc" 2>/dev/null || true
  systemctl mask "$svc" 2>/dev/null || true
done

echo "[5/13] Disable dhcpcd to avoid bridge conflicts..."
systemctl disable --now dhcpcd.service 2>/dev/null || true
systemctl mask dhcpcd.service 2>/dev/null || true

echo "[6/13] Create /opt/orbis..."
install -d -m 0755 /opt/orbis /opt/orbis/network /opt/orbis/interface

echo "[7/13] Copy files..."
if [ ! -d "./opt/orbis" ]; then
  echo "ERROR: missing ./opt/orbis in installer directory ($(pwd))."
  echo "Expected layout: <script_dir>/{install.sh,opt/orbis,etc/...}"
  exit 1
fi
cp -a ./opt/orbis/* /opt/orbis/
cp -a ./etc/systemd/system/orbis-*.service /etc/systemd/system/

echo "[8/13] Permissions..."
chmod 600 /opt/orbis/orbis.conf
chmod 755 /opt/orbis/network/*.sh /opt/orbis/network/orbis-lib.sh

echo "[9/13] Enable ORBIS services..."
systemctl daemon-reload
systemctl enable orbis-network.service orbis-hostapd.service orbis-dnsmasq.service orbis-babeld.service orbis-ui.service

echo "[10/13] Start ORBIS services (sets static LAN IP on br-ap)..."
set +e
systemctl restart orbis-network.service
ORBIS_NET_RC=$?
set -e
if [ "$ORBIS_NET_RC" -ne 0 ]; then
  echo "WARNING: orbis-network failed to start (rc=$ORBIS_NET_RC). Continuing installer."
  echo "         See: journalctl -u orbis-network -b --no-pager"
fi

set +e
systemctl restart orbis-hostapd.service
systemctl restart orbis-dnsmasq.service
systemctl restart orbis-babeld.service
systemctl restart orbis-ui.service
set -e

echo "[11/13] Install NetworkManager unmanaged configuration..."
install -d -m 0755 /etc/NetworkManager/conf.d
cp -a ./etc/NetworkManager/conf.d/unmanaged.conf /etc/NetworkManager/conf.d/unmanaged.conf

echo "[12/13] Disable/Mask distro wpa_supplicant units (no --now to avoid dropping current SSH)..."
systemctl disable wpa_supplicant.service 2>/dev/null || true
systemctl mask wpa_supplicant.service 2>/dev/null || true
systemctl disable wpa_supplicant@wlan0.service 2>/dev/null || true
systemctl disable wpa_supplicant@wlan1.service 2>/dev/null || true
systemctl disable wpa_supplicant@mesh0.service 2>/dev/null || true

echo "[13/13] Disable NetworkManager (avoid interference) + clear failed state..."
systemctl disable --now NetworkManager.service 2>/dev/null || true
systemctl mask NetworkManager.service 2>/dev/null || true
systemctl disable --now NetworkManager-wait-online.service 2>/dev/null || true
systemctl mask NetworkManager-wait-online.service 2>/dev/null || true
systemctl reset-failed NetworkManager-wait-online.service 2>/dev/null || true

echo
echo "=== ORBIS INSTALL END $(date -Is) ==="
echo "Logfile: $LOGFILE"
echo "UI: http://192.168.200.1:5000"
