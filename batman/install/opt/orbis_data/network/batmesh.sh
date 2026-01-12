#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- Logging: /var/log if root, otherwise $HOME
if [ "$(id -u)" -eq 0 ]; then
  LOG="/var/log/orbis_batmesh.log"
else
  LOG="$HOME/orbis_batmesh.log"
fi
umask 022
mkdir -p "$(dirname "$LOG")"
touch "$LOG"
# as of here, logging
exec >>"$LOG" 2>&1

# --- Settings ---
IF="wlan1"
MESH_SSID="orbis_mesh"
FREQ=2462           # wifi channel (standard channel is 11)
MESH_CHANNEL="${MESH_CHANNEL:-$FREQ}"
export MESH_CHANNEL
REG="US"            # wifi region
WAIT_PEER=5         # seconds, wait for mesh-peer
BRIDGE_NAME="br0"   # bridge name

ts(){ date +'%F %T'; }
log(){ echo "[$(ts)] $*"; }

log "[prep] stop wpa_supplicant (ignore if already masked or deactivated)"
systemctl stop "wpa_supplicant@${IF}.service" wpa_supplicant.service NetworkManager iwd 2>/dev/null || true
pkill -f "wpa_supplicant.*-i ${IF}" 2>/dev/null || true
rm -f "/var/run/wpa_supplicant/${IF}" 2>/dev/null || true

log "[mesh] set RegDomain=${REG}, Type=MESH, bring ${IF} up"
iw reg set "${REG}" || true
ip link set "${IF}" down 2>/dev/null || true
iw dev "${IF}" set type mesh
ip link set "${IF}" up

# --- Mesh tuning (before join!) ---
log "[mesh] tuning beacon interval and mesh parameters"
# Increase beacon interval (non-critical for mesh)
iw dev "${IF}" set beacon_int 750 || true

# Mesh-IE minimieren / Root-Funktion deaktivieren
# Optimierungen für Pi Zero 2W: CPU und RAM sparen
iw dev "${IF}" set mesh_param mesh_hwmp_rootmode=0 || true
iw dev "${IF}" set mesh_param mesh_gate_announcements=0 || true
# Reduziere OGM Frequenz (von default 1000ms auf 5000ms)
iw dev "${IF}" set mesh_param mesh_hwmp_preq_min_interval=5000 || true
iw dev "${IF}" set mesh_param mesh_element_ttl=31 || true
# Deaktiviere Mesh Power Save für stabilere Verbindungen
iw dev "${IF}" set mesh_param mesh_power_mode=0 || true || true

log "[mesh] join open 802.11s: ssid='${MESH_SSID}', freq=${FREQ}"
# Leave (idempotent), Join (open), Forwarding for batman-adv
iw dev "${IF}" mesh leave 2>/dev/null || true
iw dev "${IF}" mesh join "${MESH_SSID}" freq "${FREQ}"
iw dev "${IF}" set mesh_param mesh_fwding=0 || true

# MTU slightly larger for batman-adv + 802.11s overhead
ip link set "${IF}" mtu 1560 || true

log "[batman] load module, bat0 setup/up, ${IF} connect"
modprobe batman-adv 2>/dev/null || true
ip link add bat0 type batadv 2>/dev/null || true
ip link set bat0 up
batctl if add "${IF}" 2>/dev/null || true
# Optimierungen für Pi Zero 2W: Reduziere Broadcast-Last
batctl dat 1                    # Distributed ARP Table aktiviert (spart Broadcasts)
batctl ap_isolation 0           # AP Isolation aus (ermöglicht direkte Client-Kommunikation)
batctl loglevel 0 batman-adv    # Reduziere Debug-Logging
batctl gw_mode off 2>/dev/null || true  # Gateway Mode aus (nicht nötig für reines Mesh)

# Ensure: bat0 is attached to ${BRIDGE_NAME} (wait/retry for deterministic startup)
log "[bridge] ensure bat0 is member of ${BRIDGE_NAME}"
for i in $(seq 1 30); do
  if ip link show "${BRIDGE_NAME}" >/dev/null 2>&1; then
    ip link set "${BRIDGE_NAME}" up || true
    ip link set bat0 up || true
    # idempotent: may already be enslaved
    ip link set dev bat0 master "${BRIDGE_NAME}" 2>/dev/null || true
    # verify membership
    if bridge link 2>/dev/null | grep -qE "bat0:.*master ${BRIDGE_NAME}"; then
      log "[bridge] bat0 successfully joined ${BRIDGE_NAME}"
      break
    fi
  fi
  sleep 1
done
# Optional: wait for peer (just info)
log "[wait] wait for ${WAIT_PEER}s mesh-peer"
for i in $(seq "${WAIT_PEER}"); do
  if iw dev "${IF}" station dump | grep -q "^Station "; then
    log "[ok] minimum one mesh-peer available"
    break
  fi
  sleep 1
done

# Status (not critical)
log "[status] Interface:"
iw dev "${IF}" info | egrep -i 'type|channel|addr' || true
log "[status] Peers:"
iw dev "${IF}" station dump | sed -n '1,30p' || true
log "[status] batman-adv Nachbarn/Originators:"
batctl n || true
batctl o || true

log "[done] batmesh.sh erfolgreich abgeschlossen"
exit 0