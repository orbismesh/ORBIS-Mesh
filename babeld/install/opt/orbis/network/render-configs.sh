#!/bin/sh
set -eu
. /opt/orbis/network/orbis-lib.sh
require_root
OUTDIR="/opt/orbis/network/generated"
mkdir -p "$OUTDIR"
chmod 700 "$OUTDIR"

# Compute a network prefix (e.g. 192.168.200.0/24) from an address + CIDR.
# babeld expects prefixes, not host addresses.
calc_prefix() {
  _addr="$1"; _cidr="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY' "$_addr" "$_cidr"
import ipaddress, sys
addr = sys.argv[1]
cidr = int(sys.argv[2])
net = ipaddress.ip_network(f"{addr}/{cidr}", strict=False)
print(str(net.network_address))
PY
    return 0
  fi

  if command -v ipcalc >/dev/null 2>&1; then
    ipcalc -n "${_addr}/${_cidr}" | awk -F= '/^NETWORK/ {print $2; exit}'
    return 0
  fi

  die "Unable to compute LAN prefix (need python3 or ipcalc)."
}

HOSTAPD_CONF="$OUTDIR/hostapd.conf"
case "${ORBIS_AP_SEC}" in
  wpa2) AP_KEY_MGMT="WPA-PSK"; SAE="0" ;;
  wpa3) AP_KEY_MGMT="SAE"; SAE="1" ;;
  mixed) AP_KEY_MGMT="WPA-PSK SAE"; SAE="1" ;;
  *) die "Unknown ORBIS_AP_SEC=${ORBIS_AP_SEC} (use wpa2|wpa3|mixed)" ;;
esac
cat >"$HOSTAPD_CONF" <<EOF
country_code=${ORBIS_COUNTRY}
interface=${ORBIS_AP_IFACE}
bridge=${ORBIS_AP_BRIDGE}
driver=nl80211
ssid=${ORBIS_AP_SSID}
hw_mode=${ORBIS_AP_HW_MODE}
channel=${ORBIS_AP_CHANNEL}
ieee80211n=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_key_mgmt=${AP_KEY_MGMT}
rsn_pairwise=CCMP
wpa_passphrase=${ORBIS_AP_PSK}
ieee80211w=1
sae_require_mfp=${SAE}
EOF
chmod 600 "$HOSTAPD_CONF"

DNSMASQ_CONF="$OUTDIR/dnsmasq.conf"

# DHCP settings: keep defaults if not provided in orbis.conf.
: "${ORBIS_LAN_DHCP_START:=${ORBIS_LAN_NET%0}50}"
: "${ORBIS_LAN_DHCP_END:=${ORBIS_LAN_NET%0}199}"
: "${ORBIS_LAN_DHCP_LEASE:=12h}"

cat >"$DNSMASQ_CONF" <<EOF
port=0
bind-interfaces
interface=${ORBIS_AP_BRIDGE}
except-interface=lo
dhcp-range=${ORBIS_LAN_DHCP_START},${ORBIS_LAN_DHCP_END},${ORBIS_LAN_DHCP_LEASE}
dhcp-option=option:router,${ORBIS_LAN_ADDR}
dhcp-option=option:dns-server,${ORBIS_LAN_ADDR}
EOF
chmod 600 "$DNSMASQ_CONF"

WPA_SUPP_CONF="$OUTDIR/wpa_supplicant-mesh.conf"
case "${ORBIS_MESH_SEC}" in
  open)
    cat >"$WPA_SUPP_CONF" <<EOF
ctrl_interface=DIR=/run/wpa_supplicant-orbis
update_config=0
country=${ORBIS_COUNTRY}
network={
    ssid="${ORBIS_MESH_SSID}"
    mode=5
    frequency=${ORBIS_MESH_FREQ_MHZ}
    key_mgmt=NONE
}
EOF
    ;;
  wpa3|sae)
    cat >"$WPA_SUPP_CONF" <<EOF
ctrl_interface=DIR=/run/wpa_supplicant-orbis
update_config=0
country=${ORBIS_COUNTRY}
network={
    ssid="${ORBIS_MESH_SSID}"
    mode=5
    frequency=${ORBIS_MESH_FREQ_MHZ}
    key_mgmt=SAE
    sae_password="${ORBIS_MESH_PSK}"
    proto=RSN
    pairwise=CCMP
    group=CCMP
    ieee80211w=2
}
EOF
    ;;
  *)
    die "Unknown ORBIS_MESH_SEC=${ORBIS_MESH_SEC} (use open|wpa3)"
    ;;
esac
chmod 600 "$WPA_SUPP_CONF"

BABELD_CONF="$OUTDIR/babeld.conf"
# babeld.conf: keep syntax compatible with babeld(8) as shipped on Debian/Raspberry Pi OS.
# babeld expects prefixes (networks), not host addresses.
LAN_NET="$(calc_prefix "${ORBIS_LAN_ADDR}" "${ORBIS_LAN_CIDR}")"

cat >"$BABELD_CONF" <<EOF
# ORBIS babeld configuration
interface ${ORBIS_MESH_IFACE}

# Advertise the local LAN prefix into the mesh
redistribute ip ${LAN_NET}/${ORBIS_LAN_CIDR}

EOF

# Optionally advertise a dedicated SSH management host route (eth0 /32), even if it is outside the LAN prefix.
if [ -n "${ORBIS_SSH_ETH0_ADDR:-}" ]; then
  echo "redistribute ip ${ORBIS_SSH_ETH0_ADDR}/${ORBIS_SSH_ETH0_CIDR:-32}" >>"$BABELD_CONF"
fi
chmod 644 "$BABELD_CONF"

echo "Rendered configs into $OUTDIR"
