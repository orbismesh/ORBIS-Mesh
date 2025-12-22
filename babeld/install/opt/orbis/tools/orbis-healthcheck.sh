#!/bin/sh
set -eu

# ORBIS Health Check
# Runs a lightweight, read-only diagnostic of mesh/AP/babel state.
# Intended to be executed as root (or via sudo) for best results.

ok()   { printf 'OK   %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAILED=1; }

FAILED=0
NOW="$(date -Is 2>/dev/null || date)"

printf 'ORBIS health check @ %s\n\n' "$NOW"

# ---- Services ------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
  echo "[services]"
  for u in orbis-network.service orbis-babeld.service orbis-hostapd.service orbis-dnsmasq.service orbis-ui.service; do
    if systemctl list-unit-files "$u" >/dev/null 2>&1; then
      st="$(systemctl is-active "$u" 2>/dev/null || true)"
      case "$st" in
        active|exited) ok "$u is $st" ;;
        inactive) warn "$u is inactive" ;;
        failed) fail "$u is failed" ;;
        *) warn "$u is $st" ;;
      esac
    fi
  done
  echo
fi

# ---- Interfaces & addresses ---------------------------------------------
echo "[interfaces]"

# br-ap should carry the LAN IPv4
if ip link show br-ap >/dev/null 2>&1; then
  if ip -4 addr show dev br-ap | grep -q 'inet '; then
    ok "br-ap has IPv4: $(ip -4 -o addr show dev br-ap | awk '{print $4}' | head -n1)"
  else
    fail "br-ap has no IPv4 address"
  fi
else
  fail "br-ap missing"
fi

# wlan0 is bridged: it normally has no IPv4 (bridge owns it)
if ip link show wlan0 >/dev/null 2>&1; then
  if ip -4 addr show dev wlan0 | grep -q 'inet '; then
    warn "wlan0 has IPv4 (unexpected when bridged): $(ip -4 -o addr show dev wlan0 | awk '{print $4}' | head -n1)"
  else
    ok "wlan0 has no IPv4 (expected: enslaved into br-ap)"
  fi
else
  warn "wlan0 missing"
fi

# mesh0 should be UP, have IPv4 + IPv6 LL
if ip link show mesh0 >/dev/null 2>&1; then
  mesh_state="$(ip -o link show mesh0 | sed -n 's/.*state \([^ ]*\).*/\1/p')"
  case "$mesh_state" in
    UP) ok "mesh0 link state: UP" ;;
    *) warn "mesh0 link state: $mesh_state" ;;
  esac

  if ip -4 addr show dev mesh0 | grep -q 'inet '; then
    ok "mesh0 has IPv4: $(ip -4 -o addr show dev mesh0 | awk '{print $4}' | head -n1)"
  else
    fail "mesh0 has no IPv4 address"
  fi

  if ip -6 addr show dev mesh0 scope link | grep -q 'fe80::'; then
    ok "mesh0 has IPv6 link-local: $(ip -6 -o addr show dev mesh0 scope link | awk '{print $4}' | head -n1)"
  else
    fail "mesh0 has no IPv6 link-local (babeld will fail)"
  fi
else
  fail "mesh0 missing"
fi

echo

# ---- Mesh peer visibility ------------------------------------------------
echo "[mesh peers]"
if command -v iw >/dev/null 2>&1 && iw dev mesh0 info >/dev/null 2>&1; then
  peers="$(iw dev mesh0 station dump 2>/dev/null | grep -c '^Station ' || true)"
  if [ "${peers}" -gt 0 ]; then
    ok "mesh0 peers: ${peers} (station dump)"
  else
    warn "mesh0 peers: 0 (station dump empty)"
  fi
else
  warn "iw not available or mesh0 not managed by nl80211"
fi

echo

# ---- babeld checks -------------------------------------------------------
echo "[babeld]"
CONF="/opt/orbis/network/generated/babeld.conf"

if [ -f "$CONF" ]; then
  ok "babeld.conf present: $CONF"
  if command -v babeld >/dev/null 2>&1; then
    # babeld has no "parse-only" mode. Running it naively will often fail
    # with false-positives (pidfile exists, port already in use) when the real
    # daemon is already running. Instead, we run a short-lived instance on a
    # different port + pidfile and only treat explicit parse errors as failure.
    HC_PID="/run/babeld.healthcheck.pid"
    HC_PORT="6697"
    OUT=""
    if command -v timeout >/dev/null 2>&1; then
      OUT="$(timeout 1 babeld -d 0 -I "$HC_PID" -p "$HC_PORT" -c "$CONF" 2>&1 || true)"
    else
      babeld -d 0 -I "$HC_PID" -p "$HC_PORT" -c "$CONF" >/tmp/babeld.healthcheck.out 2>&1 &
      BGPID="$!"
      sleep 1
      kill "$BGPID" 2>/dev/null || true
      OUT="$(cat /tmp/babeld.healthcheck.out 2>/dev/null || true)"
      rm -f /tmp/babeld.healthcheck.out 2>/dev/null || true
    fi
    rm -f "$HC_PID" 2>/dev/null || true

    if echo "$OUT" | grep -qi "Couldn't parse configuration"; then
      fail "babeld.conf does NOT parse (babeld reported a parse error)"
    else
      ok "babeld.conf parse check: no syntax error detected"
    fi
  else
    warn "babeld binary not found"
  fi
else
  fail "babeld.conf missing: $CONF"
fi

# Exactly one UDP listener on 6696 is expected
if command -v ss >/dev/null 2>&1; then
  cnt="$(ss -ulpn 2>/dev/null | grep -c ':6696' || true)"
  if [ "$cnt" -eq 1 ]; then
    ok "UDP :6696 listener count: 1"
  elif [ "$cnt" -gt 1 ]; then
    fail "UDP :6696 listener count: $cnt (multiple babeld instances?)"
  else
    fail "No UDP :6696 listener (babeld not listening)"
  fi
fi

# Show a quick route summary
if ip route show proto babel >/dev/null 2>&1; then
  routes="$(ip route show proto babel | wc -l | tr -d ' ')"
  if [ "$routes" -gt 0 ]; then
    ok "babel routes installed: $routes"
    ip route show proto babel | sed 's/^/  /'
  else
    warn "no routes with proto babel installed yet"
  fi
fi

echo

# Optional: quick packet probe (requires root + tcpdump)
echo "[packet probe]"
if command -v tcpdump >/dev/null 2>&1; then
  if [ "$(id -u)" -ne 0 ]; then
    warn "tcpdump installed but not running as root; skipping capture"
  else
    echo "Capturing up to 3 babeld packets on mesh0 (udp/6696) for up to 5s..."
    # busybox timeout may not exist; prefer coreutils timeout when present
    if command -v timeout >/dev/null 2>&1; then
      timeout 5 tcpdump -i mesh0 -nn -c 3 udp port 6696 2>/dev/null | sed 's/^/  /' || true
    else
      tcpdump -i mesh0 -nn -c 3 udp port 6696 2>/dev/null | sed 's/^/  /' || true
    fi
  fi
else
  warn "tcpdump not installed"
fi

echo

if [ "$FAILED" -eq 0 ]; then
  echo "Overall: HEALTHY"
  exit 0
else
  echo "Overall: ISSUES DETECTED"
  exit 1
fi
