#!/usr/bin/env bash
set -euo pipefail

# ORBIS Mesh OLED Installer (SSD1306) with venv to avoid PEP 668 issues
# - Idempotent and avoids duplicating install.sh responsibilities
# - Uses a Python virtual environment for luma.oled/core (no system-wide pip)
#
# Usage: sudo ./install/install_oled.sh
#
# Wiring:
# - OLED VCC  -> Raspberry Pi 3V3
# - OLED GND  -> Raspberry Pi GND
# - OLED SDA  -> Raspberry Pi SDA1 (GPIO2)
# - OLED SCL  -> Raspberry Pi SCL1 (GPIO3)

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root. Use: sudo $0" >&2
  exit 1
fi

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

dpkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }
apt_install_if_missing() {
  local pkgs_to_install=()
  for pkg in "$@"; do
    if ! dpkg_installed "$pkg"; then pkgs_to_install+=("$pkg"); fi
  done
  if ((${#pkgs_to_install[@]})); then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends "${pkgs_to_install[@]}"
  fi
}

# Resolve repository root for optional source copies
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
find_src() {
  local a b
  a="$REPO_DIR/$1"; b="$REPO_DIR/install/$1"
  if [[ -f "$a" ]]; then echo "$a"; elif [[ -f "$b" ]]; then echo "$b"; else echo ""; fi
}

SRC_PY="$(find_src 'opt/orbis_data/oled/oled_status.py')"
SRC_SERVICE="$(find_src 'etc/systemd/system/oled-status.service')"

DST_DIR="/opt/orbis_data/oled"
DST_PY="$DST_DIR/oled_status.py"
DST_SERVICE="/etc/systemd/system/oled-status.service"
VENVDIR="$DST_DIR/venv"
VENVPY="$VENVDIR/bin/python"
VENVPIP="$VENVDIR/bin/pip"

# 1) Enable I2C (idempotent)
if command -v raspi-config >/dev/null 2>&1; then
  log "Enabling I2C via raspi-config (non-interactive)"
  raspi-config nonint do_i2c 0 || true
else
  # Fallback: ensure dtparam in firmware config (Bookworm: /boot/firmware/config.txt, older: /boot/config.txt)
  for CFG in /boot/firmware/config.txt /boot/config.txt; do
    if [[ -f "$CFG" ]]; then
      log "Ensuring dtparam=i2c_arm=on in $CFG"
      grep -qxF 'dtparam=i2c_arm=on' "$CFG" || echo 'dtparam=i2c_arm=on' >>"$CFG"
    fi
  done
fi

# 2) Minimal packages (install only if missing)
log "Installing minimal packages (if needed)"
apt_install_if_missing python3 python3-pip python3-venv
apt_install_if_missing python3-pil i2c-tools

# 3) Deploy OLED script (from repo if available; otherwise keep system copy)
install -d "$DST_DIR"
if [[ -n "$SRC_PY" ]]; then
  install -m 0755 "$SRC_PY" "$DST_PY"
  log "Deployed $DST_PY"
else
  if [[ ! -f "$DST_PY" ]]; then
    echo "ERROR: oled_status.py not found in repo and not present at $DST_PY" >&2
    exit 1
  fi
fi

# 4) Prepare virtual environment and install Python deps inside it
if [[ ! -x "$VENVPY" ]]; then
  log "Creating virtual environment: $VENVDIR"
  python3 -m venv "$VENVDIR"
fi

log "Upgrading venv tooling (pip/setuptools/wheel)"
"$VENVPY" -m pip install --upgrade pip setuptools wheel

log "Installing Python OLED dependencies in venv"
"$VENVPIP" install luma.oled luma.core

# 5) Deploy systemd service (use repo service if present; otherwise create minimal one)
if [[ -n "$SRC_SERVICE" ]]; then
  install -m 0644 "$SRC_SERVICE" "$DST_SERVICE"
  log "Deployed $DST_SERVICE"
else
  if [[ ! -f "$DST_SERVICE" ]]; then
    log "Creating minimal $DST_SERVICE"
    cat >"$DST_SERVICE" <<'UNIT'
[Unit]
Description=ORBIS Mesh OLED Status Display
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/orbis_data/oled/oled_status.py
Restart=always
RestartSec=2
User=root
Group=root
Environment=PYTHONUNBUFFERED=1
Environment=LC_ALL=C.UTF-8
Environment=LANG=C.UTF-8

[Install]
WantedBy=multi-user.target
UNIT
  fi
fi

# 6) Override ExecStart to use venv python
OVR_DIR="/etc/systemd/system/oled-status.service.d"
OVR_FILE="$OVR_DIR/override.conf"
install -d "$OVR_DIR"
cat >"$OVR_FILE" <<EOF
[Service]
# Clear previous ExecStart and set to venv python
ExecStart=
ExecStart=$VENVPY $DST_PY
EOF
log "Wrote systemd override: $OVR_FILE"

# 7) systemd wiring
systemctl daemon-reload
systemctl enable oled-status.service
systemctl restart oled-status.service || systemctl start oled-status.service

# 8) Probe I2C to help detect wiring/address
if command -v i2cdetect >/dev/null 2>&1; then
  log "Probing I2C bus 1 (expect address 0x3c for SSD1306)"
  i2cdetect -y 1 || true
fi

cat <<'EOF'

OLED installation complete (using Python virtual environment).
- Service enabled: oled-status.service
- Script: /opt/orbis_data/oled/oled_status.py
- venv: /opt/orbis_data/oled/venv
- ExecStart overridden to use venv python.

If the display stays blank:
  * Verify I2C wiring (SDA=SDA1/GPIO2, SCL=SCL1/GPIO3, 3V3, GND)
  * Check device address with: sudo i2cdetect -y 1 (expected: 0x3c)
  * Logs: sudo journalctl -u oled-status.service --no-pager -n 100
EOF
