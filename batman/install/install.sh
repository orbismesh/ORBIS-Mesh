#!/usr/bin/env bash
# ==============================================================================
# FRESH NODE SETUP (OrbisMesh)
# ------------------------------------------------------------------------------

set -Eeuo pipefail

# -------- TTY helpers (SSH-safe even with logging via tee) --------------------
# Prompts MUST go to /dev/tty, otherwise they can disappear when stdout is piped.
if [[ ! -e /dev/tty ]]; then
  echo "ERROR: No /dev/tty available. Run with an interactive TTY (e.g., ssh -t ...)." >&2
  exit 1
fi

tty_print()   { printf "%s" "$*" > /dev/tty; }
tty_println() { printf "%s\n" "$*" > /dev/tty; }
tty_read()    { IFS= read -r "$@" < /dev/tty; }

# -------- Global variable initialization (MUST be set before use) ------------
CONFIG_ONLY=false
INSTALL_OLED=false
MODE_SELECTED=false
ABORT=false
RUN_RESET_ID=false
DO_REBOOT=false
USE_PIPX=true
DRY_RUN=false
EXIT_TO_CONSOLE=false

# Decide whether we need sudo for privileged operations (used throughout).
if [ "$(id -u)" -eq 0 ]; then
  sudo=""
else
  sudo="sudo "
fi

# Respect non-interactive mode flags if provided
for _arg in "$@"; do
  case "$_arg" in
    --config-only|--configure|--configure-only|--network-only) CONFIG_ONLY=true; MODE_SELECTED=true ;;
    --full-install) CONFIG_ONLY=false; INSTALL_OLED=false; MODE_SELECTED=true ;;
    --full-install-oled) CONFIG_ONLY=false; INSTALL_OLED=true; MODE_SELECTED=true ;;
  esac
done

select_install_mode() {
  # Sets CONFIG_ONLY true/false, and ABORT true/false
  local choice=""
  ABORT=false
  if command -v whiptail >/dev/null 2>&1; then
    choice="$(whiptail --title "OrbisMesh Installer" --clear --menu "Select operation" 15 78 4 \
      "1" "Full Installation" \
      "2" "Full Installation with OLED support" \
      "3" "Network Configuration Only" \
      "4" "Abort" \
      3>&1 1>&2 2>&3 </dev/tty)" || choice="4"
  else
    tty_println ""
    tty_println "Select operation:"
    tty_println "  1) Full Installation"
    tty_println "  2) Full Installation with OLED support"
    tty_println "  3) Network Configuration Only"
    tty_println "  4) Abort"
    tty_print "Choose [1-4] (default: 1): "
    tty_read choice
    choice="${choice:-1}"
  fi

  case "$choice" in
    2|"Full Installation with OLED support") CONFIG_ONLY=false; INSTALL_OLED=true ;;
    3|"Network Configuration Only") CONFIG_ONLY=true; INSTALL_OLED=false ;;
    4|"Abort") ABORT=true ;;
    *) CONFIG_ONLY=false; INSTALL_OLED=false ;;
  esac
}


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
echo "This script will install 'Orbis Mesh' on your system."
echo ""

# -------- Start selection (raspi-config style) --------------------------------
if ! $MODE_SELECTED; then
  select_install_mode
  MODE_SELECTED=true
fi

if $ABORT; then
  echo "Aborted."
  exit 1
fi

if $CONFIG_ONLY; then
  echo "Starting network configuration..."
else
  echo "Proceeding with full installation..."
fi


# -------- Critical paths and directories (set early) -------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOVE_SRC="${MOVE_SRC:-${SCRIPT_DIR}}"
root=""

# -------- Logging (warnings & errors) -----------------------------------------
mkdir -p "$HOME/orbis-mesh_log" 2>/dev/null || true
LOG_FILE="$HOME/orbis-mesh_log/orbis_fresh_node.log"
: > "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"
exec > >(tee -a "$LOG_FILE") 2>&1

LOG_TS() { printf '[%s] ' "$(date '+%F %T')"; }

echo "=========================================="
echo "Starting install.sh at $(date)"
echo "CONFIG_ONLY=$CONFIG_ONLY"
echo "SCRIPT_DIR=$SCRIPT_DIR"
echo "MOVE_SRC=$MOVE_SRC"
echo "Log file: $LOG_FILE"
echo "=========================================="
echo ""

if $CONFIG_ONLY; then
  echo "Running in: Network Configuration Only"
fi

# -------- Helpers --------------------------------------------------------------
die() { LOG_TS; echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Command not found: $1"; }
sudocheck() { [ "$(id -u)" -eq 0 ] || need sudo; }

confirm() {
  local prompt="$1"
  local ans
  tty_print "$prompt [y/N] "
  tty_read ans
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

run() { LOG_TS; echo "+ $*"; $DRY_RUN || eval "$@"; }

# -------- Argparse -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset-id)   RUN_RESET_ID=true; shift ;;
    --no-pipx)    USE_PIPX=false; shift ;;
    --do-reboot)  DO_REBOOT=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --config-only|--configure|--configure-only|--network-only) CONFIG_ONLY=true; shift ;;
    --full-install) CONFIG_ONLY=false; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# -------- Preflight  & Configuration setup (runs for all modes) --------
# Set sudo variable (if already set above, this is redundant but safe)
if [ "$(id -u)" -eq 0 ]; then
  sudo=""
else
  sudo="sudo "
fi

# -------- File copies (required for both CONFIG_ONLY and full install) ----
LOG_TS; echo "Setting up configuration files …"
[ -d "${MOVE_SRC}" ] || die "Source not found: ${MOVE_SRC}"

dst="/opt/orbis_data"
run "sudo install -d \"$dst\""

# 1) Copy top-level files in opt/orbis_data (e.g., orbis.conf)
src_root="${MOVE_SRC}/opt/orbis_data"
if [ -d "$src_root" ]; then
  if command -v rsync >/dev/null 2>&1; then
    run "sudo rsync -a --chown=root:root --exclude='*/' \"${src_root}/\" \"${dst}/\""
  else
    run "sudo find \"$src_root\" -maxdepth 1 -type f -exec cp -a --no-preserve=ownership {} \"$dst/\" \;"
  fi
else
  LOG_TS; echo "Skipping: ${src_root} not found."
fi

# 2) Copy required subdirectories
for d in interface network ogm scripts; do
  src="${MOVE_SRC}/opt/orbis_data/${d}"
  if [ -d "$src" ]; then
    if command -v rsync >/dev/null 2>&1; then
      run "sudo rsync -a --chown=root:root \"${src}/\" \"${dst}/${d}/\""
    else
      run "sudo cp -a --no-preserve=ownership \"${src}\" \"$dst/\""
    fi
  else
    LOG_TS; echo "Skipping: ${src} not found."
  fi
done

# -------- Permissions (required for both CONFIG_ONLY and full install) ----
LOG_TS; echo "Setting permissions …"
run "sudo find /opt/orbis_data -type d -exec chmod 755 {} \;"
run "sudo chmod +x /opt/orbis_data/network/startup_sequence.sh"
run "sudo chmod +x /opt/orbis_data/network/batmesh.sh"
run "sudo chmod +x /opt/orbis_data/interface/start_monitor.sh"
run "sudo chmod +x /opt/orbis_data/scripts/manage_wlan2.sh 2>/dev/null || true"
run "sudo chmod +x /opt/orbis_data/scripts/manage_ap.sh 2>/dev/null || true"
run "sudo chmod +x /opt/orbis_data/network/generate_networkd.sh 2>/dev/null || true"
run "sudo chmod 0755 /opt/orbis_data/orbis.conf 2>/dev/null || true"

# -------- Full installation tasks (only if not CONFIG_ONLY) --------
if ! $CONFIG_ONLY; then
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

# -------- wlan dummy logic (as in your original) ------------------------------
#n_wlan=$(iw dev | grep "^[[:space:]]*Interface" | wc -l)
#if [ "$n_wlan" -lt 2 ]; then
#  drv=""
#  if [ "$n_wlan" -eq 1 -a -e /sys/class/net/wlan0/device ]; then
#    drv=$(basename "$(readlink -f "/sys/class/net/wlan0/device/driver/module")")
#    read mac < /sys/class/net/wlan0/address
#    echo "SUBSYSTEM==\"net\", ACTION==\"add\", ATTR{address}==\"${mac}\", NAME=\"wlan1\"" | sudo tee /etc/udev/rules.d/50-wlan1.rules > /dev/null
#    run "sudo rmmod $drv"
#  fi
#  run "sudo modprobe dummy"
#  run "sudo ip link add wlan0 type dummy"
#  if [ -n "$drv" ]; then
#    run "sudo modprobe $drv"
#  fi
#fi

# -------- Optional: Reset for cloned images -----------------------------------
if $RUN_RESET_ID; then
  LOG_TS; echo "Running machine reset for cloned images …"
  run "rm -rf /opt/orbis_data/linux || true"
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
echo "iperf3 iperf3/start_daemon boolean false" | sudo debconf-set-selections
export DEBIAN_FRONTEND=noninteractive
run "sudo apt-get update -y"
run "sudo apt-get install -y hostapd batctl wget curl rsync tcpdump"
run "sudo apt-get install -y python3 python3-pam python3-pip pipx"
run "sudo apt-get install -y aircrack-ng iperf3 network-manager dnsmasq python3-flask"

run "sudo modprobe -v batman_adv"
run "echo 'batman_adv' | sudo tee /etc/modules-load.d/batman_adv.conf >/dev/null"

# System directories (these are only needed for full installation)
run "sudo install -d /etc/dnsmasq.d /etc/hostapd /etc/modprobe.d /etc/NetworkManager /etc/sudoers.d /etc/sysctl.d /etc/udev /etc/systemd/network /etc/systemd/system /etc/wpa_supplicant /usr/lib/systemd/system /usr/local/sbin"

# Concrete copies (only if present)
for name in etc/dnsmasq.d etc/hostapd etc/modprobe.d etc/NetworkManager etc/sudoers.d etc/sysctl.d etc/udev etc/systemd/network etc/systemd/system etc/wpa_supplicant usr/lib/systemd/system usr/local/sbin; do
  if test -d "${MOVE_SRC}/${name}"; then
    if command -v rsync >/dev/null 2>&1; then
      run "sudo rsync -a --chown=root:root \"${MOVE_SRC}/${name}/\" \"/${name}/\""
    else
      run "sudo cp -a --no-preserve=ownership ${MOVE_SRC}/${name}/* /${name}/"
    fi
  else
    LOG_TS; echo "Skipping: ${MOVE_SRC}/${name} not found."
  fi
done

# --- nftables mesh filter (prevent DHCP leakage into mesh via bat0) -----------
# Installs /etc/nftables.d/mesh-filter.nft and ensures nftables.conf includes it.
if test -f "${MOVE_SRC}/etc/nftables.d/mesh-filter.nft"; then
  run "sudo install -d /etc/nftables.d"
  run "sudo install -m 0644 -o root -g root \"${MOVE_SRC}/etc/nftables.d/mesh-filter.nft\" /etc/nftables.d/mesh-filter.nft"

  # Ensure main config includes the mesh filter file (idempotent)
  if test -f /etc/nftables.conf; then
    run "sudo bash -c 'grep -qF \"include \\\"/etc/nftables.d/mesh-filter.nft\\\"\" /etc/nftables.conf || printf \"\n# OrbisMesh: bridge-layer DHCP leak protection\ninclude \\\"/etc/nftables.d/mesh-filter.nft\\\"\n\" >> /etc/nftables.conf'"
  fi

  # Apply rules now if nftables is available (best-effort, safe if service not present)
  if command -v nft >/dev/null 2>&1; then
    run "sudo systemctl enable --now nftables 2>/dev/null || true"
    if test -f /etc/nftables.conf; then
      run "sudo nft -f /etc/nftables.conf 2>/dev/null || true"
    else
      run "sudo nft -f /etc/nftables.d/mesh-filter.nft 2>/dev/null || true"
    fi
  fi
else
  LOG_TS; echo "Skipping: ${MOVE_SRC}/etc/nftables.d/mesh-filter.nft not found."
fi


run "sudo chmod +x /usr/local/sbin/orbis-apply-user-change.sh 2>/dev/null || true"

# -------- Services/Daemons -----------------------------------------------------
LOG_TS; echo "Enabling/configuring services …"
run "sudo systemctl enable NetworkManager.service"
run "sudo systemctl enable dnsmasq"
run "sudo systemctl enable ogm-monitor.service 2>/dev/null || true"
run "sudo systemctl enable ap-powersave-off.service 2>/dev/null || true"
run "sudo systemctl unmask hostapd || true"


fi

# -------- Optional OLED support (runs after base install, before network config) ---
if ! $CONFIG_ONLY && $INSTALL_OLED; then
  LOG_TS; echo "OLED option selected – running install_oled.sh before network configuration …"
  OLED_SCRIPT="${SCRIPT_DIR}/installer_scripts/install_oled.sh"
  if [ -f "$OLED_SCRIPT" ]; then
    run "${sudo}bash \"$OLED_SCRIPT\""
  else
    LOG_TS; echo "WARNING: install_oled.sh not found at $OLED_SCRIPT – skipping OLED installation."
  fi
fi

# -------- Interactive network config ------------------------------------------
run "clear"

# -------- Password input (TTY-safe) -------------------------------------------
read_with_asterisks() {
  local prompt="$1"
  local password=""
  local char
  local ord

  tty_print "$prompt"

  while IFS= read -r -s -n 1 char < /dev/tty; do
    if [ -z "$char" ]; then
      break
    fi
    ord=$(printf '%d' "'$char")
    case "$ord" in
      10|13) break ;;
      8|127)
        if [ -n "$password" ]; then
          password=${password%?}
          tty_print $'\b \b'
        fi
        ;;
      *)
        password+="$char"
        tty_print "*"
        ;;
    esac
  done

  tty_println ""
  REPLY="$password"
}

# -------- raspi-config style UI (whiptail) -----------------------------------
# Uses /dev/tty explicitly so it remains usable even when stdout is piped/tee'd.
UI_TITLE="OrbisMesh Configuration"
UI_USED=false

have_whiptail() { command -v whiptail >/dev/null 2>&1; }

ui_restore_tty() {
  # Fix screen/cursor artifacts after leaving ncurses (alternate screen buffer)
  $UI_USED || return 0
  tput rmcup >/dev/tty 2>/dev/null || true
  tput cnorm >/dev/tty 2>/dev/null || true
  stty sane </dev/tty 2>/dev/null || true
  printf '\e[?1049l\e[?25h' > /dev/tty 2>/dev/null || true
  clear >/dev/tty 2>/dev/null || true
}

# Ensure we always restore terminal state if the script exits while a UI was used.
trap 'ui_restore_tty' EXIT

ui_msgbox() {
  local text="$1"
  if have_whiptail; then
    UI_USED=true
    whiptail --title "$UI_TITLE" --clear --msgbox "$text" 12 76 >/dev/tty
  else
    tty_println "$text"
  fi
}

ui_yesno() {
  local text="$1"
  if have_whiptail; then
    UI_USED=true
    whiptail --title "$UI_TITLE" --clear --yesno "$text" 12 76 >/dev/tty
    return $?
  else
    confirm "$text"
    return $?
  fi
}

ui_inputbox() {
  # echoes entered value to stdout; returns 0 if OK, 1 if Cancel
  local prompt="$1" default="${2:-}" height="${3:-10}" width="${4:-76}"
  if have_whiptail; then
    UI_USED=true
    whiptail --title "$UI_TITLE" --clear --inputbox "$prompt" "$height" "$width" "$default" \
      3>&1 1>&2 2>&3 </dev/tty
    return $?
  else
    tty_print "$prompt [$default]: "
    local v; tty_read v
    echo "${v:-$default}"
    return 0
  fi
}

ui_passwordbox() {
  # echoes entered value to stdout; returns 0 if OK, 1 if Cancel
  local prompt="$1" height="${2:-10}" width="${3:-76}"
  if have_whiptail; then
    UI_USED=true
    whiptail --title "$UI_TITLE" --clear --passwordbox "$prompt" "$height" "$width" \
      3>&1 1>&2 2>&3 </dev/tty
    return $?
  else
    read_with_asterisks "$prompt "
    echo "$REPLY"
    return 0
  fi
}

ui_menu() {
  # usage: ui_menu "Prompt" "default_tag" tag1 "item1" tag2 "item2" ...
  # echoes selected tag; returns 0 if OK, 1 if Cancel
  local prompt="$1"; shift
  local default_tag="$1"; shift
  if have_whiptail; then
    UI_USED=true
    whiptail --title "$UI_TITLE" --clear --menu "$prompt" 20 86 12 \
      --default-item "$default_tag" "$@" 3>&1 1>&2 2>&3 </dev/tty
    return $?
  else
    # minimal fallback (non-ncurses): list items and read selection
    tty_println "$prompt"
    local tags=() items=()
    while (( $# )); do tags+=("$1"); items+=("$2"); shift 2; done
    for idx in "${!tags[@]}"; do
      tty_println "  $((idx+1))) ${items[$idx]}"
    done
    tty_print "Select [1-${#tags[@]}] (default: $default_tag): "
    local sel; tty_read sel
    if [[ -z "${sel:-}" ]]; then
      echo "$default_tag"
      return 0
    fi
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel>=1 && sel<=${#tags[@]} )); then
      echo "${tags[$((sel-1))]}"
      return 0
    fi
    return 1
  fi
}

# Key-based write for orbis.conf (DO NOT use global replace for KEY=VALUE files)
conf_set() {
  # Usage: conf_set KEY VALUE FILE
  local key="$1"
  local val="$2"
  local file="$3"

  ${sudo}python3 - "$file" "$key" "$val" <<'PY'
import sys, re
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]

# Add quotes if value contains spaces and is not already quoted
if ' ' in val and not (val.startswith('"') and val.endswith('"')):
    val = f'"{val}"'

with open(path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines()

pat = re.compile(rf"^{re.escape(key)}=")
out = []
replaced = False
for line in lines:
    if pat.match(line):
        out.append(f"{key}={val}")
        replaced = True
    else:
        out.append(line)
if not replaced:
    out.append(f"{key}={val}")

with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
PY
}

get_val() {
  local key="$1"
  local file="$2"
  local line
  line="$(grep -E "^${key}=" "$file" 2>/dev/null || true)"
  echo "${line#${key}=}"
}

ui_ask_validated() {
  # usage: ui_ask_validated "Label" "Default" kind
  local label="$1" default="$2" kind="${3:-}"
  while true; do
    local v
    v="$(ui_inputbox "$label" "$default")" || return 1
    [[ -z "${v:-}" ]] && v="$default"

    case "$kind" in
      ssid)
        if [ "${#v}" -gt 32 ]; then ui_msgbox "Error: SSID cannot be longer than 32 characters."; continue; fi
        if printf '%s' "$v" | grep -q '[[:cntrl:]]'; then ui_msgbox "Error: SSID cannot contain control characters."; continue; fi
        if [ -z "${v// }" ]; then ui_msgbox "Error: SSID cannot consist only of spaces."; continue; fi
        if [[ "$v" =~ ^[[:space:]] || "$v" =~ [[:space:]]$ ]]; then ui_msgbox "Error: SSID cannot start or end with spaces."; continue; fi
        ;;
      ip)
        if ! printf '%s\n' "$v" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
          ui_msgbox "Error: Please enter a valid IPv4 address."
          continue
        fi
        IFS='.' read -r o1 o2 o3 o4 <<<"$v"
        for o in "$o1" "$o2" "$o3" "$o4"; do
          if [ "$o" -lt 0 ] 2>/dev/null || [ "$o" -gt 255 ] 2>/dev/null; then
            ui_msgbox "Error: Please enter a valid IPv4 address."
            continue 2
          fi
        done
        ;;
      cidr)
        if ! printf '%s\n' "$v" | grep -Eq '^[0-9]{1,2}$'; then
          ui_msgbox "Error: CIDR suffix must be a number between 0 and 32."
          continue
        fi
        if [ "$v" -lt 0 ] 2>/dev/null || [ "$v" -gt 32 ] 2>/dev/null; then
          ui_msgbox "Error: CIDR suffix must be between 0 and 32."
          continue
        fi
        ;;
      ch)
        if ! printf '%s\n' "$v" | grep -Eq '^[0-9]{1,3}$'; then
          ui_msgbox "Error: Channel must be a number."
          continue
        fi
        if [ "$v" -lt 1 ] 2>/dev/null || [ "$v" -gt 165 ] 2>/dev/null; then
          ui_msgbox "Error: Channel must be between 1 and 165."
          continue
        fi
        ;;
      *) : ;;
    esac

    echo "$v"
    return 0
  done
}

ui_set_local_pw() {
  # Usage: ui_set_local_pw CONF_FILE
  local file="$1"
  while true; do
    local p1 p2
    p1="$(ui_passwordbox "Local SSID Password (leave empty to keep current value)")" || return 1
    if [[ -z "${p1:-}" ]]; then
      return 0
    fi
    p2="$(ui_passwordbox "Repeat Local SSID Password")" || return 1
    if [[ "$p1" != "$p2" ]]; then
      ui_msgbox "Error: Passwords do not match."
      continue
    fi
    if [ "${#p1}" -lt 8 ] || [ "${#p1}" -gt 63 ]; then
      ui_msgbox "Error: WPA password must be between 8 and 63 characters."
      continue
    fi
    conf_set WPA_PASSPHRASE "$p1" "$file"
    return 0
  done
}

ui_set_mesh_pw() {
  # Usage: ui_set_mesh_pw CONF_FILE
  local file="$1"
  while true; do
    local p1 p2
    p1="$(ui_passwordbox "Mesh SSID Password (leave empty to keep current value)")" || return 1
    if [[ -z "${p1:-}" ]]; then
      return 0
    fi
    p2="$(ui_passwordbox "Repeat Mesh SSID Password")" || return 1
    if [[ "$p1" != "$p2" ]]; then
      ui_msgbox "Error: Passwords do not match."
      continue
    fi
    if [ "${#p1}" -lt 8 ] || [ "${#p1}" -gt 63 ]; then
      ui_msgbox "Error: WPA password must be between 8 and 63 characters."
      continue
    fi
    conf_set MESH_PASSWORD "$p1" "$file"
    return 0
  done
}

# --- orbis.conf config via raspi-config style menu ----------------------------
echo ""
echo "========== Starting Network Configuration Menu =========="
CONF="${root}/opt/orbis_data/orbis.conf"
echo "CONF file: $CONF"

# Ensure config file exists (rsync should have copied it, but keep this safe)
if [ ! -f "$CONF" ]; then
  echo "CONF file not found, creating..."
  run "sudo install -m 0755 -o root -g root -T /dev/null \"$CONF\""
  echo "CONF file created."
else
  echo "CONF file already exists: $CONF"
fi

ui_msgbox "BASIC NODE SETUP\n\nConfigure basic network settings.\n\nNavigate with arrow keys, Enter selects.\nChoose Finish to continue the installer."

EXIT_TO_CONSOLE=false
echo "Starting network configuration menu loop..."

while true; do
  cur_local_name="$(get_val NODE_NAME "$CONF")"; : "${cur_local_name:=Node 1}"
  cur_local_id="$(get_val NODE_ID "$CONF")"; : "${cur_local_id:=1}"
  cur_local_ssid="$(get_val LOCAL_SSID "$CONF")"; : "${cur_local_ssid:=takNode1}"
  cur_local_band="$(get_val LOCAL_BAND "$CONF")"; : "${cur_local_band:=a}"
  cur_local_ch="$(get_val LOCAL_CH "$CONF")"; : "${cur_local_ch:=36}"
  cur_node_mesh_ssid="$(get_val MESH_SSID "$CONF")"; : "${cur_node_mesh_ssid:=orbis_mesh}"
  cur_node_mesh_ch_01="$(get_val MESH_CH_01 "$CONF")"; : "${cur_node_mesh_ch_01:=11}"
  cur_node_mesh_ch_02="$(get_val MESH_CH_02 "$CONF")"; : "${cur_node_mesh_ch_02:=36}"
  cur_node_ip="$(get_val NODE_IP "$CONF")"; : "${cur_node_ip:=192.168.200.10}"
  cur_node_cidr="$(get_val NODE_CIDR "$CONF")"; : "${cur_node_cidr:=24}"
  cur_dns="$(get_val DNS "$CONF")"; : "${cur_dns:=$cur_node_ip}"
  cur_ssh_ip="$(get_val SSH_IP "$CONF")"; : "${cur_ssh_ip:=192.168.0.21}"
  cur_ssh_cidr="$(get_val SSH_CIDR "$CONF")"; : "${cur_ssh_cidr:=24}"
  cur_gw="$(get_val GATEWAY "$CONF")"; : "${cur_gw:=192.168.200.10}"

  choice="$(ui_menu "Select an option" "1" \
    "1" "Local Node Name                         [ ${cur_local_name} ]" \
    "2" "Local Node ID                           [ ${cur_local_id} ]" \
    "3" "Local SSID                              [ ${cur_local_ssid} ]" \
    "4" "Local SSID Band (2.4GHz (g) | 5GHz (a)) [ ${cur_local_band} ]" \
    "5" "Local SSID Channel                      [ ${cur_local_ch} ]" \
    "6" "Local SSID Password                     [ hidden ]" \
    "7" "Mesh SSID                               [ ${cur_node_mesh_ssid} ]" \
    "8" "Mesh Channel 2.4GHz                     [ ${cur_node_mesh_ch_01} ]" \
    "9" "Mesh Channel 5GHz                       [ ${cur_node_mesh_ch_02} ]" \
    "10" "Mesh SSID Password                      [ hidden ]" \
    "11" "Node Mesh IP                            [ ${cur_node_ip} ]" \
    "12" "Node Mesh CIDR                          [ ${cur_node_cidr} ]" \
    "13" "DNS Server IP                           [ ${cur_dns} ]" \
    "14" "SSH IP                                  [ ${cur_ssh_ip} ]" \
    "15" "SSH CIDR                                [ ${cur_ssh_cidr} ]" \
    "16" "Default Gateway IP                      [ ${cur_gw} ]" \
    "F" "Finish and continue installer" \
    "E" "Exit to console" \
  )" || choice="F"

  case "$choice" in
    1)
      v="$(ui_ask_validated "Local Node Name" "$cur_local_name")" || continue
      conf_set NODE_NAME "$v" "$CONF"
      ;;
    2)
      v="$(ui_ask_validated "Local Node ID (number)" "$cur_local_id")" || continue
      if ! printf '%s\n' "$v" | grep -Eq '^[0-9]+$'; then
        ui_msgbox "Error: Node ID must be a number."
        continue
      fi
      conf_set NODE_ID "$v" "$CONF"
      ;;
    3)
      v="$(ui_ask_validated "Local SSID" "$cur_local_ssid" ssid)" || continue
      conf_set LOCAL_SSID "$v" "$CONF"
      ;;
    4)
      v="$(ui_ask_validated "Local SSID Band (2.4GHz (g) | 5GHz (a))" "$cur_local_band" )" || continue
      if [[ "$v" != "a" && "$v" != "g" ]]; then
        ui_msgbox "Error: Please enter 'a' for 5GHz or 'g' for 2.4GHz."
        continue
      fi
      conf_set LOCAL_BAND "$v" "$CONF"
      ;;
    5)
      v="$(ui_ask_validated "Local SSID Channel (2.4GHz: 1-11 | 5GHz: 36, 40, 44, 48, 52, 56, 60, 64)" "$cur_local_ch" ch)" || continue
      conf_set LOCAL_CH "$v" "$CONF"
      ;;
    6)
      ui_set_local_pw "$CONF" || continue
      ;;
    7)
      v="$(ui_ask_validated "Mesh SSID" "$cur_node_mesh_ssid" ssid)" || continue
      conf_set MESH_SSID "$v" "$CONF"
      ;;
    8)
      v="$(ui_ask_validated "Mesh Channel 2.4GHz (1-11)" "$cur_node_mesh_ch_01" ch)" || continue
      conf_set MESH_CH_01 "$v" "$CONF"
      ;;
    9)
      v="$(ui_ask_validated "Mesh Channel 5GHz (36, 40, 44, 48, 52, 56, 60, 64)" "$cur_node_mesh_ch_02" ch)" || continue
      conf_set MESH_CH_02 "$v" "$CONF"
      ;;
    10)
      ui_set_mesh_pw "$CONF" || continue
      ;;
    11)
      v="$(ui_ask_validated "Node Mesh IP" "$cur_node_ip" ip)" || continue
      conf_set NODE_IP "$v" "$CONF"
      ;;
    12)
      v="$(ui_ask_validated "Node CIDR (0-32)" "$cur_node_cidr" cidr)" || continue
      conf_set NODE_CIDR "$v" "$CONF"
      ;;
    13)
      v="$(ui_ask_validated "Node DNS server IP (usually Node IP)" "$cur_dns" ip)" || continue
      conf_set DNS "$v" "$CONF"
      ;;
    14)
      v="$(ui_ask_validated "SSH IP" "$cur_ssh_ip" ip)" || continue
      conf_set SSH_IP "$v" "$CONF"
      ;;
    15)
      v="$(ui_ask_validated "SSH CIDR (0-32)" "$cur_ssh_cidr" cidr)" || continue
      conf_set SSH_CIDR "$v" "$CONF"
      ;;
    16)
      v="$(ui_ask_validated "Default Gateway IP" "$cur_gw" ip)" || continue
      conf_set GATEWAY "$v" "$CONF"
      ;;
    F|f)
      break
      ;;
    E|e)
      EXIT_TO_CONSOLE=true
      break
      ;;
  esac
done

echo ""
echo "========== Exited Network Configuration Menu =========="
echo "EXIT_TO_CONSOLE=$EXIT_TO_CONSOLE"
echo ""

# If the user requested exit, stop immediately without any further actions.
if $EXIT_TO_CONSOLE; then
  echo "User requested exit to console. Stopping."
  ui_restore_tty
  exit 0
fi

# Restore terminal immediately after leaving the ncurses UI to avoid flicker/artifacts
echo ""
echo "========== Restoring terminal after UI =========="
ui_restore_tty
echo "Terminal restored."

# keep required permissions
echo "Fixing config file permissions..."
run "sudo chmod 0755 \"$CONF\""

# Generate br0.network (and hostapd.conf, if generator was extended) from template + conf
echo "Generating network configuration..."
if [ -x "${root}/opt/orbis_data/network/generate_networkd.sh" ]; then
  run "sudo /opt/orbis_data/network/generate_networkd.sh"
fi
run "sudo systemctl enable orbis-networkd-generate.service"

echo ""
tty_println ""
tty_println "=========================================="
tty_println "STARTING POST-CONFIGURATION ACTIVATION"
tty_println "=========================================="
tty_println ""

echo "========== POST-CONFIGURATION ACTIVATION =========="
LOG_TS; echo "Running post-configuration activation …"
ACTIVATOR_SCRIPT="${SCRIPT_DIR}/installer_scripts/activator.sh"
echo "ACTIVATOR_SCRIPT=$ACTIVATOR_SCRIPT"
echo "SCRIPT_DIR=$SCRIPT_DIR"
if [ -f "$ACTIVATOR_SCRIPT" ]; then
  tty_println "Found activator.sh at: $ACTIVATOR_SCRIPT"
  echo "Found activator.sh at: $ACTIVATOR_SCRIPT"
  LOG_TS; echo "Executing: $ACTIVATOR_SCRIPT"
  echo "Executing $ACTIVATOR_SCRIPT..."
  bash "$ACTIVATOR_SCRIPT"
  RESULT=$?
  echo "activator.sh exit code: $RESULT"
  if [ $RESULT -eq 0 ]; then
    tty_println "✓ Post-configuration activation completed successfully."
    LOG_TS; echo "Post-configuration activation completed."
    echo "Post-configuration activation completed successfully."
  else
    tty_println "✗ Post-configuration activation failed with exit code: $RESULT"
    LOG_TS; echo "Post-configuration activation failed with exit code: $RESULT"
    echo "ERROR: Post-configuration activation failed with exit code: $RESULT"
  fi
else
  tty_println "✗ ERROR: activator.sh not found at $ACTIVATOR_SCRIPT"
  tty_println "  Expected location: $ACTIVATOR_SCRIPT"
  tty_println "  SCRIPT_DIR: $SCRIPT_DIR"
  echo "ERROR: activator.sh not found at $ACTIVATOR_SCRIPT"
  echo "Expected location: $ACTIVATOR_SCRIPT"
  echo "SCRIPT_DIR: $SCRIPT_DIR"
  LOG_TS; echo "WARNING: activator.sh not found at $ACTIVATOR_SCRIPT – skipping activation."
fi

tty_println ""
tty_println "=========================================="
tty_println "Installation complete."
tty_println "=========================================="
echo ""
echo "=========================================="
echo "Installation complete."
echo "=========================================="
exit 0
