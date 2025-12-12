#!/usr/bin/env bash
# ==============================================================================
# FRESH NODE SETUP (OrbisMesh) – safer, structured, idempotent-ish
# ------------------------------------------------------------------------------

set -Eeuo pipefail


# -------- Confirmation ---------------------------------------------------------

clear

GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}┌───────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│                                                   │${NC}"
echo -e "${GREEN}│   ___       _     _       __  __           _      │${NC}"
echo -e "${GREEN}│  / _ \ _ __| |__ (_)___  |  \/  | ___  ___| |__   │${NC}"
echo -e "${GREEN}│ | | | | '__| '_ \| / __| | |\/| |/ _ \/ __| '_ \  │${NC}"
echo -e "${GREEN}│ | |_| | |  | |_) | \__ \ | |  | |  __/\__ \ | | | │${NC}"
echo -e "${GREEN}│  \___/|_|  |_.__/|_|___/ |_|  |_|\___||___/_| |_| │${NC}"
echo -e "${GREEN}│                                                   │${NC}"
echo -e "${GREEN}└───────────────────────────────────────────────────┘${NC}"
echo ""
echo ""
echo ""
echo "This script will install 'Orbis Mesh' on your system."
echo ""
read -r -p "Do you want to continue? [y/N] " ans
case "$ans" in
  [Yy]*) echo "Proceeding with setup...";;
  *) echo "Aborted."; exit 1;;
esac

# -------- Logging (warnings & errors) -----------------------------------------
mkdir -p "$HOME/orbis-mesh_log"
LOG_FILE="$HOME/orbis-mesh_log/orbis_fresh_node.log"
: > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
# -------- Settings -------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOVE_SRC="${MOVE_SRC:-${SCRIPT_DIR}}"           # source of files to be copied (default = script location)
RUN_RESET_ID=false                   # via --reset-id
DO_REBOOT=false                      # via --do-reboot
USE_PIPX=true                        # prefer pipx for Python tools
LOG_TS() { printf '[%s] ' "$(date '+%F %T')"; }

# -------- Helpers --------------------------------------------------------------
die() { LOG_TS; echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"; }
sudocheck() { [ "$(id -u)" -eq 0 ] || need sudo; }
confirm() {
  local prompt="$1"
  read -r -p "$prompt [y/N] " ans
  [[ "${ans:-N}" =~ ^[Yy]$ ]]
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--reset-id] [--no-pipx] [--do-reboot] [--dry-run]

  --reset-id    Reset machine-id/SSH keys (for cloned images).
  --no-pipx     Use pip3 system-wide (less clean).
  --do-reboot   Perform a reboot at the end.
  --dry-run     Only show what would be done.
EOF
}

DRY_RUN=false
run() { LOG_TS; echo "+ $*"; $DRY_RUN || eval "$@"; }

# -------- Argparse -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset-id)   RUN_RESET_ID=true; shift ;;
    --no-pipx)    USE_PIPX=false; shift ;;
    --do-reboot)  DO_REBOOT=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# -------- Preflight ------------------------------------------------------------
sudocheck
need bash
need tee
need awk
need sed
need grep
need rsync
command -v systemctl >/dev/null 2>&1 || true

if [ "$(id -u)" -eq 0 ]; then
    sudo=""
else
    sudo="sudo "
fi

LOG_TS; echo "Starting setup …"
LOG_TS; echo "Options: reset-id=${RUN_RESET_ID}, pipx=${USE_PIPX}, reboot=${DO_REBOOT}, dry-run=${DRY_RUN}"

n_wlan=$(iw dev | grep "^[[:space:]]*Interface" | wc -l)
if [ "$n_wlan" -lt 2 ]; then
  drv=""
  if [ "$n_wlan" -eq 1 -a -e /sys/class/net/wlan0/device ]; then
    drv=$(basename $(readlink -f "/sys/class/net/wlan0/device/driver/module"))
    read mac < /sys/class/net/wlan0/address
    echo "SUBSYSTEM==\"net\", ACTION==\"add\", ATTR{address}==\"${mac}\", NAME=\"wlan1\"" | sudo tee /etc/udev/rules.d/50-wlan1.rules > /dev/null
    run "sudo rmmod $drv"
  fi
  run "sudo modprobe dummy"
  run "sudo ip link add wlan0 type dummy"
  if [ -n "$drv" ]; then
    run "sudo modprobe $drv"
  fi
fi

# -------- Optional: Reset for cloned images -----------------------------------
if $RUN_RESET_ID; then
  LOG_TS; echo "Running machine reset for cloned images …"
  run "rm -rf /opt/orbis_data/linux || true"
  # Reset machine-id & SSH keys carefully
  run "sudo systemctl stop systemd-networkd || true"
  run "sudo rm -f /etc/machine-id"
  run "sudo sh -c 'echo -n > /etc/machine-id'"
  run "sudo systemd-machine-id-setup"
  run "sudo rm -f /etc/ssh/ssh_host_*"
  run "sudo dpkg-reconfigure -f noninteractive openssh-server"
  run "sudo systemctl restart systemd-networkd || true"
fi

# -------- Packages -------------------------------------------------------------
LOG_TS; echo "Installing system packages …"
export DEBIAN_FRONTEND=noninteractive
run "sudo apt-get update -y"
run "sudo DEBIAN_FRONTEND=readline apt-get install -y hostapd batctl wget curl rsync"
run "sudo DEBIAN_FRONTEND=readline apt-get install -y python3 python3-pam python3-pip pipx"
run "sudo DEBIAN_FRONTEND=readline apt-get install -y aircrack-ng iperf3 network-manager dnsmasq python3-flask"

# Load batman-adv kernel module & keep it persistent
run "sudo modprobe -v batman_adv"
run "echo 'batman_adv' | sudo tee /etc/modules-load.d/batman_adv.conf >/dev/null"

# Note: consider disabling wpa_supplicant if hostapd should run exclusively in AP mode.
# This is system-specific — intentionally NOT automated.

# -------- File copies ----------------------------------------------------------
LOG_TS; echo "Copying configuration files from ${MOVE_SRC} …"
[ -d "${MOVE_SRC}" ] || die "Source not found: ${MOVE_SRC}"

# User directories
dst="/opt/orbis_data"
run "sudo install -d \"$dst\""
for d in interface network ogm scripts; do
  src="${MOVE_SRC}/opt/orbis_data/${d}"
  if [ -d "$src" ]; then
    if command -v rsync >/dev/null 2>&1; then
      run "sudo rsync -a --chown=root:root \"${src}/\" \"${dst}/${d}/\""
    else
      run "sudo cp -a --no-preserve=ownership ${src} \"$dst/\""
    fi
  else
    LOG_TS; echo "Skipping: ${src} not found."
  fi
done

# -------- Permissions ----------------------------------------------------------
LOG_TS; echo "Setting permissions on user directories …"
run "sudo find /opt/orbis_data -type d -exec chmod 755 {} \;"
run "sudo chmod +x /opt/orbis_data/network/startup_sequence.sh"
run "sudo chmod +x /opt/orbis_data/network/batmesh.sh"
run "sudo chmod +x /opt/orbis_data/interface/start_monitor.sh"
run "sudo chmod +x /opt/orbis_data/scripts/manage_wlan2.sh"

# OLD Version
#for d in interface network ogm; do
#  dst="${HOME}/${d}"
#  if [ -d "$dst" ]; then
#    run "find \"$dst\" -type d -exec chmod 0777 {} \\;"
#  fi
#done

# System directories
run "sudo install -d /etc/dnsmasq.d /etc/hostapd /etc/modprobe.d /etc/NetworkManager /etc/sudoers.d /etc/sysctl.d /etc/udev /etc/systemd/network /etc/systemd/system /etc/wpa_supplicant /usr/lib/systemd/system"

# Concrete copies (only if present)
for name in etc/dnsmasq.d etc/hostapd etc/modprobe.d etc/NetworkManager etc/sudoers.d etc/sysctl.d etc/udev etc/systemd/network etc/systemd/system etc/wpa_supplicant usr/lib/systemd/system; do
  if test -d "${MOVE_SRC}/${name}"; then
    # When copying from world-writable locations (e.g. /tmp) avoid
    # preserving original file ownership (which could be a non-root user).
    # Prefer rsync so we can force owner:group at the destination; fall back
    # to cp with --no-preserve=ownership when rsync isn't available.
    if command -v rsync >/dev/null 2>&1; then
      run "sudo rsync -a --chown=root:root \"${MOVE_SRC}/${name}/\" \"/${name}/\""
    else
      run "sudo cp -a --no-preserve=ownership ${MOVE_SRC}/${name}/* /${name}/"
    fi
  else
    LOG_TS; echo "Skipping: ${MOVE_SRC}/${name} not found."
  fi
done

# -------- Services/Daemons -----------------------------------------------------
LOG_TS; echo "Enabling/configuring services …"
run "sudo systemctl enable NetworkManager.service"
run "sudo systemctl enable dnsmasq"
run "sudo systemctl enable ogm-monitor.service"
run "sudo systemctl enable ap-powersave-off.service"
run "sudo systemctl unmask hostapd || true"

# -------- Update network config values --------------------------------------------------------

run "clear"

read_with_asterisks() {
  local prompt="$1"
  local password=""
  local char
  local ord

  printf "%s" "$prompt"

  while IFS= read -r -s -n 1 char; do
    # Wenn nichts gelesen wurde (manche Terminals bei Enter mit -n 1)
    if [ -z "$char" ]; then
      break
    fi

    # ASCII-Code des Zeichens ermitteln
    ord=$(printf '%d' "'$char")

    case "$ord" in
      10|13)  # 10 = LF, 13 = CR -> Enter (normale Enter-Taste *und* NumPad-Enter)
        break
        ;;
      8|127) # 8 = Backspace (^H), 127 = DEL
        if [ -n "$password" ]; then
          password=${password%?}
          printf '\b \b'
        fi
        ;;
      *)
        password+="$char"
        printf '*'
        ;;
    esac
  done

  echo
  REPLY="$password"
}


replace() {
  old="$1"
  label="$2"
  file="$3"
  kind="${4:-}"  # optional: "ssid", "ip", "cidr", or "wpa"

  while true; do
    new=""

    if [ "$kind" = "wpa" ]; then
      # First entry (masked)
      read_with_asterisks "$label (leave empty to keep current value): "
      new="$REPLY"

      # Empty -> keep old value
      if [ -z "$new" ]; then
        return 0
      fi

      # Confirmation (also masked)
      read_with_asterisks "Repeat $label: "
      confirm_pw="$REPLY"

      if [ "$new" != "$confirm_pw" ]; then
        echo "Error: Passwords do not match. Please try again."
        echo
        continue
      fi
    else
      echo -n "$label (leave empty to keep current value): "
      read -r new

      # Nothing entered → keep old value
      if [ -z "$new" ]; then
        return 0
      fi
    fi

    new_str="$new"

    case "$kind" in
      ssid)
        # Max length 32
        if [ "${#new}" -gt 32 ]; then
          echo "Error: SSID cannot be longer than 32 characters."
          continue
        fi
        # No control characters
        if printf '%s' "$new" | grep -q '[[:cntrl:]]'; then
          echo "Error: SSID cannot contain control characters."
          continue
        fi
        # Not only spaces
        if [ -z "${new// }" ]; then
          echo "Error: SSID cannot consist only of spaces."
          continue
        fi
        # No leading/trailing spaces
        if [[ "$new" =~ ^[[:space:]] || "$new" =~ [[:space:]]$ ]]; then
          echo "Error: SSID cannot start or end with spaces."
          continue
        fi
        ;;
      ip)
        # Basic IPv4 format
        if ! printf '%s\n' "$new" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
          echo "Error: IP must be in IPv4 format a.b.c.d."
          continue
        fi

        IFS=. read -r o1 o2 o3 o4 <<< "$new"
        valid=1
        for o in "$o1" "$o2" "$o3" "$o4"; do
          if [ "$o" -lt 0 ] 2>/dev/null || [ "$o" -gt 255 ] 2>/dev/null; then
            valid=0
          fi
        done
        if [ "$valid" -ne 1 ]; then
          echo "Error: Each octet must be between 0 and 255."
          continue
        fi

        # Only allow private networks
        if ! printf '%s\n' "$new" | grep -Eq '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)'; then
          echo "Error: IP must be in a private network (10.x, 172.16–31.x, 192.168.x.x)."
          continue
        fi

        # Exclude special addresses
        if [ "$new" = "0.0.0.0" ] || printf '%s\n' "$new" | grep -Eq '^127\.'; then
          echo "Error: This IP address is not valid for this interface."
          continue
        fi
        ;;
      cidr)
        # CIDR suffix 0–32, numeric only
        if ! printf '%s\n' "$new" | grep -Eq '^[0-9]{1,2}$'; then
          echo "Error: CIDR suffix must be a number between 0 and 32."
          continue
        fi
        if [ "$new" -lt 0 ] 2>/dev/null || [ "$new" -gt 32 ] 2>/dev/null; then
          echo "Error: CIDR suffix must be between 0 and 32."
          continue
        fi
        # Replace "/old" with "/new"
        new_str="/$new"
        ;;
      wpa)
        # WPA2/3 PSK: 8–63 characters
        if [ "${#new}" -lt 8 ] || [ "${#new}" -gt 63 ]; then
          echo "Error: WPA password must be between 8 and 63 characters."
          continue
        fi
        ;;
      *)
        # No special validation
        :
        ;;
    esac

    # Input passed validation → perform replacement
    ${sudo}python3 - "$file" "$old" "$new_str" <<'PY'
import sys
p, o, n = sys.argv[1], sys.argv[2], sys.argv[3]
with open(p, 'r', encoding='utf-8') as f:
    txt = f.read()
txt = txt.replace(o, n)
with open(p, 'w', encoding='utf-8') as f:
    f.write(txt)
PY
    return 0
  done
}

root=""

# SSID
line="$(grep '^ssid=' ${root}/etc/hostapd/hostapd.conf)"
ssid=${line#ssid=}
replace "$ssid" "Local SSID" "${root}/etc/hostapd/hostapd.conf" ssid

# WPA passphrase
line="$(grep '^wpa_passphrase=' ${root}/etc/hostapd/hostapd.conf)"
wpa_pass=${line#wpa_passphrase=}
replace "$wpa_pass" "Local SSID WPA password" "${root}/etc/hostapd/hostapd.conf" wpa

# IP Address + CIDR suffix for br0
line="$(grep '^Address=' ${root}/etc/systemd/network/br0.network)"
line=${line#Address=}
ip_addr=${line%/*}         # e.g. 192.168.200.10
cidr_suffix=${line#*/}     # e.g. 24
cidr_old="/$cidr_suffix"   # e.g. /24

replace "$ip_addr"  "IP Address"                 "${root}/etc/systemd/network/br0.network" ip
replace "$cidr_old" "IP suffix (CIDR, default 24)" "${root}/etc/systemd/network/br0.network" cidr

# DNS (must match IP)
line="$(grep '^DNS=' ${root}/etc/systemd/network/br0.network)"
dns=${line#DNS=}
replace "$dns" "DNS (must match IP)" "${root}/etc/systemd/network/br0.network" ip




# -------- Show Log Summary -----------------------------------------------------
echo
echo "======================================================================"
echo " LOG SUMMARY (Warnings & Errors)"
echo "======================================================================"
if [ -s "$LOG_FILE" ]; then
  cat "$LOG_FILE"
else
  echo "No warnings or errors were recorded."
fi
echo "======================================================================"
echo
# -------- Finish/Reboot --------------------------------------------------------
if $DO_REBOOT; then
  if $DRY_RUN || confirm "Reboot now?"; then
    LOG_TS; echo "Rebooting in 5s …"
    $DRY_RUN || sleep 5
    run "sudo reboot"
  else
    LOG_TS; echo "Reboot skipped."
  fi
else
  LOG_TS; echo "Setup finished – no reboot triggered but required!"
fi
