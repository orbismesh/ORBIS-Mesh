#!/usr/bin/env bash
set -euo pipefail

ORBIS_CONF="/opt/orbis/orbis.conf"
RENDERER="/opt/orbis/network/render-configs.sh"

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root (use: sudo orbis-reconf)." >&2
    exit 1
  fi
}

conf_get() {
  local key="$1"
  sed -n -E "s/^${key}=\"(.*)\"\s*$/\1/p" "$ORBIS_CONF" | tail -n 1
}

escape_sed_repl() {
  # Escape replacement string for sed replacement (we use '|' as delimiter)
  printf '%s' "$1" | sed -e 's/[\\&|]/\\\\&/g'
}

conf_set() {
  local key="$1" val="$2"
  local esc
  esc="$(escape_sed_repl "$val")"
  if grep -q -E "^${key}=\"" "$ORBIS_CONF"; then
    sed -i -E "s|^${key}=\".*\"\s*$|${key}=\"${esc}\"|" "$ORBIS_CONF"
  else
    printf '%s="%s"\n' "$key" "$val" >>"$ORBIS_CONF"
  fi
}

prompt_var() {
  local key="$1" label="$2" default="$3" secret="${4:-0}"
  local input
  if [ "$secret" = "1" ]; then
    read -r -s -p "${label} [${default}]: " input || true
    echo
  else
    read -r -p "${label} [${default}]: " input || true
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

best_effort_restart() {
  local svc
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl daemon-reload >/dev/null 2>&1 || true
  for svc in orbis-ssh-ip.service orbis-network.service orbis-hostapd.service orbis-dnsmasq.service orbis-babeld.service orbis-ui.service; do
    systemctl restart "$svc" >/dev/null 2>&1 || true
  done
}

main() {
  require_root

  if [ ! -f "$ORBIS_CONF" ]; then
    echo "ERROR: Missing $ORBIS_CONF. Run the installer first." >&2
    exit 1
  fi

  echo "ORBIS reconfiguration"
  echo "This will update $ORBIS_CONF, regenerate configs, and restart ORBIS services."
  echo

  local def_node_name def_node_id def_oct1 def_oct2 def_gw4 def_ssh_ip def_ap_ssid def_ap_psk def_mesh_ssid def_mesh_sec def_mesh_psk

  def_node_name="$(conf_get ORBIS_NODE_NAME)"; def_node_name="${def_node_name:-orbis-node}"
  def_node_id="$(conf_get ORBIS_NODE_ID)"; def_node_id="${def_node_id:-1}"

  def_oct1="$(conf_get ORBIS_LAN_OCT1)"; def_oct1="${def_oct1:-192}"
  def_oct2="$(conf_get ORBIS_LAN_OCT2)"; def_oct2="${def_oct2:-168}"
  def_gw4="$(conf_get ORBIS_LAN_GW_OCT4)"; def_gw4="${def_gw4:-1}"

  def_ssh_ip="$(conf_get ORBIS_SSH_ETH0_ADDR)"; def_ssh_ip="${def_ssh_ip:-}"

  def_ap_ssid="$(conf_get ORBIS_AP_SSID)"; def_ap_ssid="${def_ap_ssid:-ORBIS-AP}"
  def_ap_psk="$(conf_get ORBIS_AP_PSK)"; def_ap_psk="${def_ap_psk:-ChangeMeApKey!}"

  def_mesh_ssid="$(conf_get ORBIS_MESH_SSID)"; def_mesh_ssid="${def_mesh_ssid:-ORBIS-MESH}"
  def_mesh_sec="$(conf_get ORBIS_MESH_SEC)"; def_mesh_sec="${def_mesh_sec:-wpa3}"
  def_mesh_psk="$(conf_get ORBIS_MESH_PSK)"; def_mesh_psk="${def_mesh_psk:-ChangeMeMeshKey!}"

  echo "Press Enter to keep the current value."
  echo

  prompt_var ORBIS_NODE_NAME "ORBIS node name" "$def_node_name"
  prompt_var ORBIS_NODE_ID   "ORBIS node id" "$def_node_id"

  prompt_var ORBIS_LAN_OCT1    "LAN octet 1" "$def_oct1"
  prompt_var ORBIS_LAN_OCT2    "LAN octet 2" "$def_oct2"
  prompt_var ORBIS_LAN_GW_OCT4 "Gateway host octet (br-ap)" "$def_gw4"

  # If SSH IP not set, suggest <LAN>.2 based on (possibly updated) values.
  if [ -z "$def_ssh_ip" ]; then
    node_id_t="$(conf_get ORBIS_NODE_ID)"; node_id_t="${node_id_t:-1}"
    # Strip leading zeros; empty becomes 0.
    node_id_num="$(printf "%s" "$node_id_t" | sed 's/^0*//; s/^$/0/')"
    oct1_t="$(conf_get ORBIS_LAN_OCT1)"; oct1_t="${oct1_t:-192}"
    oct2_t="$(conf_get ORBIS_LAN_OCT2)"; oct2_t="${oct2_t:-168}"
    oct3_t=$((200 + node_id_num))
    def_ssh_ip="${oct1_t}.${oct2_t}.${oct3_t}.2"
  fi

  while :; do
    prompt_var ORBIS_SSH_ETH0_ADDR "Dedicated SSH IP on eth0 (IPv4)" "$def_ssh_ip"
    ssh_ip_now="$(conf_get ORBIS_SSH_ETH0_ADDR)"; ssh_ip_now="${ssh_ip_now:-}"
    if valid_ipv4 "$ssh_ip_now"; then
      break
    fi
    echo "Invalid IPv4 address."
  done

  prompt_var ORBIS_AP_SSID "AP SSID" "$def_ap_ssid"
  prompt_var ORBIS_AP_PSK  "AP PSK" "$def_ap_psk" 1

  prompt_var ORBIS_MESH_SSID "Mesh SSID" "$def_mesh_ssid"
  prompt_var ORBIS_MESH_SEC  "Mesh security (open|wpa3)" "$def_mesh_sec"
  if [ "$(conf_get ORBIS_MESH_SEC)" != "open" ]; then
    prompt_var ORBIS_MESH_PSK "Mesh PSK" "$def_mesh_psk" 1
  else
    conf_set ORBIS_MESH_PSK ""
  fi

  echo
  echo "Regenerating configs..."
  if [ -x "$RENDERER" ]; then
    "$RENDERER"
  else
    echo "WARN: $RENDERER not executable or missing; skipping render." >&2
  fi

  echo "Restarting ORBIS services (best-effort)..."
  best_effort_restart

  echo
  echo "Done. Current planned UI: http://$(conf_get ORBIS_UI_ADDR):$(conf_get ORBIS_UI_PORT)"
}

main "$@"
