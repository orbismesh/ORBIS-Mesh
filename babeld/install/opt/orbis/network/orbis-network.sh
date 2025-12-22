#!/bin/sh
set -eu
. /opt/orbis/network/orbis-lib.sh
require_root

GEN="/opt/orbis/network/generated"
# Backwards-compat alias (older code referenced GEN_DIR)
GEN_DIR="$GEN"
CTRL_DIR="/run/wpa_supplicant-orbis"

ensure_ctrl_dir() {
  mkdir -p "$CTRL_DIR"
  chmod 755 "$CTRL_DIR" || true
}

kill_mesh_wpa() {
  # Terminate only the wpa_supplicant instance bound to the mesh interface
  pkill -f "wpa_supplicant.*-i\s*${ORBIS_MESH_IFACE}\b" 2>/dev/null || true
  # Remove stale control socket if present
  rm -f "${CTRL_DIR}/${ORBIS_MESH_IFACE}" 2>/dev/null || true
}

recreate_wlan1_if_missing() {
  # If wlan1 is missing but the USB phy exists, recreate wlan1 as managed
  if iw dev "${ORBIS_MESH_PHY_IFACE}" info >/dev/null 2>&1; then
    return 0
  fi

  # Determine phy for onboard wlan0 (so we can pick the other phy)
  PHY0="$(get_phy_for_iface "${ORBIS_AP_IFACE}" 2>/dev/null || true)"

  # Pick the first phy that is NOT PHY0 (common on Pi: phy0 onboard, phy1 USB)
  CAND="$(iw phy 2>/dev/null | awk '/^Wiphy/ {print "phy"$2}' | while read -r p; do
    [ -n "$PHY0" ] && [ "$p" = "$PHY0" ] && continue
    echo "$p"
  done | head -n1)"

  [ -n "${CAND:-}" ] || die "wlan1 missing and could not find a secondary phy to recreate it."

  iw phy "$CAND" interface add "${ORBIS_MESH_PHY_IFACE}" type managed 2>/dev/null || true

  # Verify
  iw dev "${ORBIS_MESH_PHY_IFACE}" info >/dev/null 2>&1 || die "Failed to recreate ${ORBIS_MESH_PHY_IFACE} on ${CAND}"
}

ensure_mesh_iface() {
  if iw dev "${ORBIS_MESH_IFACE}" info >/dev/null 2>&1; then
    return 0
  fi
  PHY="$(get_phy_for_iface "${ORBIS_MESH_PHY_IFACE}")"
  [ -n "$PHY" ] || die "Cannot determine PHY for ${ORBIS_MESH_PHY_IFACE}. Is adapter present?"
  iw phy "$PHY" interface add "${ORBIS_MESH_IFACE}" type mp || die "Failed to create ${ORBIS_MESH_IFACE} on $PHY"
}

start_wpa_mesh() {
  /usr/sbin/wpa_supplicant -B -i "${ORBIS_MESH_IFACE}" -c "${GEN}/wpa_supplicant-mesh.conf" -D nl80211
}

start() {
  /opt/orbis/network/render-configs.sh
  ensure_ctrl_dir
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  rfkill unblock wlan >/dev/null 2>&1 || true

  # Bridge for LAN/AP segment
  if ! ip link show "${ORBIS_AP_BRIDGE}" >/dev/null 2>&1; then
    ip link add name "${ORBIS_AP_BRIDGE}" type bridge
  fi
  ip link set "${ORBIS_AP_BRIDGE}" up

  # Add eth0 to bridge
  ip link set "${ORBIS_ETH_IFACE}" down || true
  ip link set "${ORBIS_ETH_IFACE}" master "${ORBIS_AP_BRIDGE}" || true
  ip link set "${ORBIS_ETH_IFACE}" up

  # Static IP on bridge
  ip addr flush dev "${ORBIS_AP_BRIDGE}" || true
  ip addr add "${ORBIS_LAN_ADDR}/${ORBIS_LAN_CIDR}" dev "${ORBIS_AP_BRIDGE}"

  # Dedicated UI address on br-ap (stable per node: <OCT1>.<OCT2>.<200+NODE_ID>.10)
  if [ -n "${ORBIS_UI_ADDR:-}" ] && [ "${ORBIS_UI_ADDR}" != "${ORBIS_LAN_ADDR}" ]; then
    ip addr add "${ORBIS_UI_ADDR}/${ORBIS_LAN_CIDR}" dev "${ORBIS_AP_BRIDGE}" 2>/dev/null || true
  fi

  # Dedicated SSH address (not managed by DHCP).
  # IMPORTANT: eth0 is a bridge port. IPv4 addresses bound directly to a bridge *port* are often
  # not reliably reachable from the wire once the port is enslaved. To make SSH reachability
  # robust, we keep the address on eth0 very early (orbis-ssh-ip.service) but migrate it to the
  # bridge device once the bridge exists.
  if [ -n "${ORBIS_SSH_ETH0_ADDR:-}" ]; then
    if [ "${ORBIS_SSH_ETH0_ADDR}" != "${ORBIS_LAN_ADDR}" ] && [ "${ORBIS_SSH_ETH0_ADDR}" != "${ORBIS_UI_ADDR:-}" ]; then
      # Remove from eth0 if it was assigned early, then add to the bridge.
      ip addr del "${ORBIS_SSH_ETH0_ADDR}/${ORBIS_SSH_ETH0_CIDR:-32}" dev "${ORBIS_ETH_IFACE}" 2>/dev/null || true
      ip addr add "${ORBIS_SSH_ETH0_ADDR}/${ORBIS_SSH_ETH0_CIDR:-32}" dev "${ORBIS_AP_BRIDGE}" 2>/dev/null || true
    fi
  fi

  # wlan0 managed by hostapd
  ip link set "${ORBIS_AP_IFACE}" down || true

  # Make sure wlan1 exists (USB)
  recreate_wlan1_if_missing

  # Clean up any stale mesh wpa state and recreate mesh interface
  kill_mesh_wpa
  iw dev "${ORBIS_MESH_IFACE}" del 2>/dev/null || true
  sleep 1
  ensure_mesh_iface

  # Try starting wpa_supplicant once with wlan1 still present
  if ! start_wpa_mesh; then
    echo "WARN: wpa_supplicant failed on first try. Retrying with ${ORBIS_MESH_PHY_IFACE} removed (multi-vif workaround)..."
    kill_mesh_wpa
    iw dev "${ORBIS_MESH_IFACE}" del 2>/dev/null || true
    iw dev "${ORBIS_MESH_PHY_IFACE}" del 2>/dev/null || true
    sleep 1

    # Recreate mesh0 on the same phy (now without wlan1 present)
    # Find phy by picking any phy that's not wlan0's phy.
    recreate_wlan1_if_missing || true  # best effort, may remain absent
    ensure_mesh_iface
    start_wpa_mesh || die "wpa_supplicant failed to start for mesh even after retry."
  fi

  sleep 2
  ip addr flush dev "${ORBIS_MESH_IFACE}" || true
  ip addr add "${ORBIS_MESH_ADDR}/${ORBIS_MESH_CIDR}" dev "${ORBIS_MESH_IFACE}"

  # Ensure IPv6 is enabled on mesh interface (required for babeld)
  sysctl -w net.ipv6.conf.mesh0.disable_ipv6=0 >/dev/null
  sysctl -w net.ipv6.conf.mesh0.accept_dad=0 >/dev/null

  # Some drivers (notably rt2800usb) do not auto-create an IPv6 link-local on mesh interfaces.
  # Generate a deterministic fe80::/64 address from the adapter MAC (wlan1) and assign it to mesh0.
  if ! ip -6 addr show dev mesh0 scope link | grep -q fe80; then
    MAC_SRC_IF="${ORBIS_MESH_PHY_IFACE:-wlan1}"
    MAC="$(cat "/sys/class/net/${MAC_SRC_IF}/address" 2>/dev/null || true)"
    if [ -z "${MAC}" ]; then
      # Fallback: use mesh0's MAC if wlan1 is absent (e.g. multi-vif workaround removed it)
      MAC="$(cat "/sys/class/net/mesh0/address" 2>/dev/null || true)"
      echo "WARN: could not read MAC from ${MAC_SRC_IF}; falling back to mesh0 MAC (${MAC})" >&2
    fi

    # Convert MAC to EUI-64 and form a link-local address: fe80::<eui64>
    # Example: 00:11:22:33:44:55 -> fe80::0211:22ff:fe33:4455
    O1="$(printf '%s' "${MAC}" | cut -d: -f1)"
    O2="$(printf '%s' "${MAC}" | cut -d: -f2)"
    O3="$(printf '%s' "${MAC}" | cut -d: -f3)"
    O4="$(printf '%s' "${MAC}" | cut -d: -f4)"
    O5="$(printf '%s' "${MAC}" | cut -d: -f5)"
    O6="$(printf '%s' "${MAC}" | cut -d: -f6)"

    # Flip the U/L bit of the first octet (XOR with 0x02)
    O1_FLIP="$(printf '%02x' "$(( 0x${O1} ^ 0x02 ))")"

    IID="${O1_FLIP}${O2}:${O3}ff:fe${O4}:${O5}${O6}"
    LL="fe80::${IID}"

    # Assign only if still missing (idempotent)
    ip -6 addr show dev mesh0 scope link | grep -q "${LL}" || ip -6 addr add "${LL}/64" dev mesh0 scope link 2>/dev/null || true
  fi

  # Wait until IPv6 link-local appears (max ~2s)
  for i in $(seq 1 10); do
      if ip -6 addr show dev mesh0 scope link | grep -q fe80; then
          break
      fi
      sleep 0.2
  done
}

stop() {
  ensure_ctrl_dir
  kill_mesh_wpa
  ip addr flush dev "${ORBIS_MESH_IFACE}" 2>/dev/null || true
  ip link set "${ORBIS_MESH_IFACE}" down 2>/dev/null || true
  iw dev "${ORBIS_MESH_IFACE}" del 2>/dev/null || true

  ip addr flush dev "${ORBIS_AP_BRIDGE}" 2>/dev/null || true
  ip addr flush dev "${ORBIS_ETH_IFACE}" 2>/dev/null || true
  ip link set "${ORBIS_ETH_IFACE}" nomaster 2>/dev/null || true
  ip link set "${ORBIS_ETH_IFACE}" up || true
  ip link set "${ORBIS_AP_BRIDGE}" down 2>/dev/null || true
  ip link del "${ORBIS_AP_BRIDGE}" 2>/dev/null || true
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  *) echo "Usage: $0 {start|stop|restart}" >&2; exit 2 ;;
esac

# Note: babeld is started by orbis-babeld.service.
# Here we only do a lightweight presence check to fail fast on missing config.
if command -v babeld >/dev/null 2>&1; then
  if [ ! -s "$GEN_DIR/babeld.conf" ]; then
    log "ERROR: Missing or empty babeld.conf at $GEN_DIR/babeld.conf"
    exit 1
  fi
fi
