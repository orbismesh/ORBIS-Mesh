#!/bin/sh
set -eu
. /opt/orbis/network/orbis-lib.sh
require_root

GEN="/opt/orbis/network/generated"
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
}

stop() {
  ensure_ctrl_dir
  kill_mesh_wpa
  ip addr flush dev "${ORBIS_MESH_IFACE}" 2>/dev/null || true
  ip link set "${ORBIS_MESH_IFACE}" down 2>/dev/null || true
  iw dev "${ORBIS_MESH_IFACE}" del 2>/dev/null || true

  ip addr flush dev "${ORBIS_AP_BRIDGE}" 2>/dev/null || true
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
