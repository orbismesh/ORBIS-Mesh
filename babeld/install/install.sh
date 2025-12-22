#!/usr/bin/env bash
set -euo pipefail

# Always run from the directory that contains this script, so relative paths work
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
cd "$SCRIPT_DIR"

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

# Detailed installer log
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
echo "Working dir: $(pwd)"
echo "Kernel: $(uname -a)"
echo

echo "[1/10] Installing base packages (apt)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  babeld \
  hostapd \
  dnsmasq \
  iw \
  rfkill \
  iproute2 \
  iputils-ping \
  procps \
  tcpdump \
  smcroute \
  ca-certificates \
  iperf3 \
  python3 python3-pip python3-flask \
  pipx

# Prevent a distro-provided babeld.service (if present) from racing with ORBIS.
# ORBIS runs babeld via orbis-babeld.service.
systemctl disable --now babeld.service 2>/dev/null || true
systemctl mask babeld.service 2>/dev/null || true

echo "[2/10] Installing python tooling with pipx..."
python3 -m pipx ensurepath >/dev/null 2>&1 || true
pipx install --force gunicorn==22.0.0
install -d -m 0755 /usr/local/bin
ln -sf /root/.local/bin/gunicorn /usr/local/bin/gunicorn

echo "[3/10] Create /opt/orbis..."
install -d -m 0755 /opt/orbis /opt/orbis/network /opt/orbis/interface

echo "[4/10] Copy files..."
if [ ! -d "./opt/orbis" ]; then
  echo "ERROR: missing ./opt/orbis in installer directory ($(pwd))."
  echo "Expected layout: <script_dir>/{install.sh,opt/orbis,etc/...}"
  exit 1
fi
cp -a ./opt/orbis/* /opt/orbis/
cp -a ./etc/systemd/system/orbis-*.service /etc/systemd/system/
cp -a ./etc/systemd/system/orbis-firstboot.service /etc/systemd/system/

# Tools (health check etc.)
if [ -d "/opt/orbis/tools" ]; then
  chmod 755 /opt/orbis/tools/*.sh 2>/dev/null || true
  # Link every tool as /usr/local/bin/<name-without-.sh>
  install -d -m 0755 /usr/local/bin
  for sh in /opt/orbis/tools/*.sh; do
    [ -e "$sh" ] || continue
    ln -sf "$sh" "/usr/local/bin/$(basename "$sh" .sh)"
  done
fi


echo "[5/10] Configure /opt/orbis/orbis.conf (optional interactive overrides)..."
CONF_FILE="/opt/orbis/orbis.conf"
if [ -f "$CONF_FILE" ]; then
  # Read current defaults from the file (expects KEY="value" lines)
  conf_get() {
    local key="$1"
    sed -n -E "s/^${key}=\"(.*)\"\s*$/\1/p" "$CONF_FILE" | tail -n 1
  }
  escape_sed_repl() {
    # Escape replacement string for sed replacement (we use '|' as delimiter)
    printf '%s' "$1" | sed -e 's/[\\&|]/\\\\&/g'
  }
  conf_set() {
    local key="$1" val="$2"
    local esc
    esc="$(escape_sed_repl "$val")"
    if grep -q -E "^${key}=\"" "$CONF_FILE"; then
      sed -i -E "s|^${key}=\".*\"\s*$|${key}=\"${esc}\"|" "$CONF_FILE"
    else
      printf '%s="%s"\n' "$key" "$val" >>"$CONF_FILE"
    fi
  }

  # Prompt helper (empty input keeps default)
  prompt_var() {
    local key="$1" label="$2" default="$3" secret="${4:-0}"
    local input
    if [ "$secret" = "1" ]; then
      read -r -s -p "$label [$default]: " input || true
      echo
    else
      read -r -p "$label [$default]: " input || true
    fi
    if [ -n "${input:-}" ]; then
      conf_set "$key" "$input"
      if [ "$secret" = "1" ]; then
        echo "Set ${key}=********"
      else
        echo "Set ${key}=${input}"
      fi
    else
      echo "Keeping ${key}=${default}"
    fi
  }

  DEF_NODE_NAME="$(conf_get ORBIS_NODE_NAME)"; DEF_NODE_NAME="${DEF_NODE_NAME:-orbis-node}"
  DEF_NODE_ID="$(conf_get ORBIS_NODE_ID)"; DEF_NODE_ID="${DEF_NODE_ID:-01}"

  DEF_LAN_OCT1="$(conf_get ORBIS_LAN_OCT1)"; DEF_LAN_OCT1="${DEF_LAN_OCT1:-192}"
  DEF_LAN_OCT2="$(conf_get ORBIS_LAN_OCT2)"; DEF_LAN_OCT2="${DEF_LAN_OCT2:-168}"
  DEF_LAN_GW_OCT4="$(conf_get ORBIS_LAN_GW_OCT4)"; DEF_LAN_GW_OCT4="${DEF_LAN_GW_OCT4:-1}"
  DEF_SSH_IP="$(conf_get ORBIS_SSH_ETH0_ADDR)"; DEF_SSH_IP="${DEF_SSH_IP:-}"

  DEF_AP_SSID="$(conf_get ORBIS_AP_SSID)"; DEF_AP_SSID="${DEF_AP_SSID:-ORBIS-AP}"
  DEF_AP_PSK="$(conf_get ORBIS_AP_PSK)"; DEF_AP_PSK="${DEF_AP_PSK:-ChangeMeApKey!}"

  echo
  echo "You can override a few ORBIS parameters now. Press Enter to keep the current value."
  echo
  prompt_var ORBIS_NODE_NAME "ORBIS node name" "$DEF_NODE_NAME"
  prompt_var ORBIS_NODE_ID   "ORBIS node id (Leading zeros are not allowed)"   "$DEF_NODE_ID"

  prompt_var ORBIS_LAN_OCT1      "LAN octet 1 (e.g. 192)" "$DEF_LAN_OCT1"
  prompt_var ORBIS_LAN_OCT2      "LAN octet 2 (e.g. 168)" "$DEF_LAN_OCT2"
  prompt_var ORBIS_LAN_GW_OCT4   "Gateway host octet (br-ap) (e.g. 1)" "$DEF_LAN_GW_OCT4"

  # Dedicated SSH IP on eth0 (configured as /32 and advertised into the mesh as a host route).
  # You may choose any IPv4 address, including outside the ORBIS LAN.
  valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r a b c d <<<"$ip"
    for o in "$a" "$b" "$c" "$d"; do
      [[ "$o" =~ ^[0-9]+$ ]] || return 1
      [ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1
    done
    return 0
  }

  # Compute a sensible default for display if none is in the config file yet.
  if [ -z "${DEF_SSH_IP}" ]; then
    NODE_ID_T="$(conf_get ORBIS_NODE_ID)"; NODE_ID_T="${NODE_ID_T:-01}"
    NODE_ID_NUM_T=$((10#$NODE_ID_T))
    OCT1_T="$(conf_get ORBIS_LAN_OCT1)"; OCT1_T="${OCT1_T:-192}"
    OCT2_T="$(conf_get ORBIS_LAN_OCT2)"; OCT2_T="${OCT2_T:-168}"
    OCT3_T=$((200 + NODE_ID_NUM_T))
    DEF_SSH_IP="${OCT1_T}.${OCT2_T}.${OCT3_T}.2"
  fi

  while :; do
    prompt_var ORBIS_SSH_ETH0_ADDR "Dedicated SSH IP on eth0 (IPv4; any address; advertised over mesh; configured /24)" "$DEF_SSH_IP"
    SSH_IP="$(conf_get ORBIS_SSH_ETH0_ADDR)"; SSH_IP="${SSH_IP:-}"
    if ! valid_ipv4 "$SSH_IP"; then
      echo "Invalid SSH IP: must be a valid IPv4 address (e.g. 192.168.0.20)."
      continue
    fi
    break
  done

  echo
  # Show derived plan (OCT3 is computed from NODE_ID)
  NODE_ID="$(conf_get ORBIS_NODE_ID)"; NODE_ID="${NODE_ID:-01}"
  NODE_ID_NUM=$((10#$NODE_ID))
  OCT1="$(conf_get ORBIS_LAN_OCT1)"; OCT1="${OCT1:-192}"
  OCT2="$(conf_get ORBIS_LAN_OCT2)"; OCT2="${OCT2:-168}"
  OCT3=$((200 + NODE_ID_NUM))
  GW4="$(conf_get ORBIS_LAN_GW_OCT4)"; GW4="${GW4:-1}"
  UI_IP="${OCT1}.${OCT2}.${OCT3}.10"
  GW_IP="${OCT1}.${OCT2}.${OCT3}.${GW4}"
  SSH_IP="$(conf_get ORBIS_SSH_ETH0_ADDR)"; SSH_IP="${SSH_IP:-<unset>}"

  echo "Derived per-node addressing (OCT3 = 200 + NODE_ID = ${OCT3}):"
  echo " - LAN/AP net:      ${OCT1}.${OCT2}.${OCT3}.0/24"
  echo " - Gateway br-ap:   ${GW_IP}"
  echo " - Web UI:          http://${UI_IP}:5000   (stable UI address per node)"
  echo " - SSH on eth0:     ${SSH_IP}              (dedicated /24; not managed by DHCP)"
  echo

  prompt_var ORBIS_AP_SSID   "AP SSID" "$DEF_AP_SSID"
  prompt_var ORBIS_AP_PSK    "AP PSK" "$DEF_AP_PSK" 1
  echo
else
  echo "WARN: $CONF_FILE not found; skipping interactive configuration."
fi

echo "[6/10] NetworkManager unmanaged configuration..."
install -d -m 0755 /etc/NetworkManager/conf.d
cp -a ./etc/NetworkManager/conf.d/unmanaged.conf /etc/NetworkManager/conf.d/unmanaged.conf

echo "[7/10] Permissions..."
chmod 600 /opt/orbis/orbis.conf
chmod 755 /opt/orbis/network/*.sh /opt/orbis/network/orbis-lib.sh || true

echo "[8/10] systemd reload + enable firstboot task..."
systemctl daemon-reload
systemctl enable orbis-firstboot.service

echo "[9/10] Defer ORBIS networking until reboot..."
# Ensure ORBIS stack does not take over the network during the current SSH session.
systemctl disable --now \
  orbis-ssh-ip.service \
  orbis-network.service \
  orbis-hostapd.service \
  orbis-dnsmasq.service \
  orbis-babeld.service \
  orbis-ui.service 2>/dev/null || true

echo "[10/10] NOTE: Network changes deferred until reboot"
echo "This installer will NOT change eth0/br-ap configuration now."
echo "On next reboot, orbis-firstboot.service will:"
echo " - disable NetworkManager + dhcpcd"
echo " - ensure only dnsmasq provides DHCP"
echo " - start ORBIS network stack (bridge + AP + mesh + routing + UI)"
echo

# Best-effort summary based on the installed config
UI_URL="http://<unknown>:5000"
if [ -f /opt/orbis/orbis.conf ]; then
  # shellcheck disable=SC1091
  . /opt/orbis/orbis.conf
  UI_HOST="${ORBIS_UI_ADDR:-${ORBIS_LAN_ADDR:-192.168.200.1}}"
  UI_PORT="${ORBIS_UI_PORT:-5000}"
  UI_URL="http://${UI_HOST}:${UI_PORT}"
  echo "Planned br-ap gateway: ${ORBIS_LAN_ADDR:-<unknown>}/${ORBIS_LAN_CIDR:-?}"
  echo "Planned UI address:   ${ORBIS_UI_ADDR:-<unknown>} (hint: stable per node, usually .10)"
  echo "Planned SSH on eth0:  ${ORBIS_SSH_ETH0_ADDR:-<unknown>} (dedicated; keep outside DHCP)"
  echo "Planned mesh0:        ${ORBIS_MESH_ADDR:-<unknown>}/${ORBIS_MESH_CIDR:-?}"
fi
echo
echo "Installation complete. Please reboot to activate ORBIS networking:"
echo "  sudo reboot"
echo
echo "After reboot, UI: ${UI_URL}"
echo "Logfile: $LOGFILE"
echo "=== ORBIS INSTALL END $(date -Is) ==="
