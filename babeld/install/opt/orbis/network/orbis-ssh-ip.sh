#!/bin/sh
# Assign a dedicated management/SSH IP to the wired interface early and robustly.
# This script MUST NOT 'source' /opt/orbis/orbis.conf, because a syntax error in that file
# must not prevent SSH reachability.
set -eu

CONF="/opt/orbis/orbis.conf"

# Defaults (safe fallbacks)
ETH_IFACE="eth0"
SSH_ADDR="192.168.0.20"
SSH_CIDR="24"

# Minimal, non-executing parser for KEY="value" or KEY=value lines.
# We intentionally ignore anything that is not a simple assignment.
if [ -f "$CONF" ]; then
  # shellcheck disable=SC2013
  for key in ORBIS_ETH_IFACE ORBIS_SSH_ETH0_ADDR ORBIS_SSH_ETH0_CIDR; do
    line="$(grep -E "^[[:space:]]*$key[[:space:]]*=" "$CONF" 2>/dev/null | tail -n 1 || true)"
    [ -n "$line" ] || continue
    val="$(printf "%s" "$line" | sed -E "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//")"
    # strip inline comments
    val="$(printf "%s" "$val" | sed -E 's/[[:space:]]+#.*$//')"
    # strip surrounding quotes
    val="$(printf "%s" "$val" | sed -E 's/^"(.*)"$/\1/; s/^\x27(.*)\x27$/\1/')"
    case "$key" in
      ORBIS_ETH_IFACE) [ -n "$val" ] && ETH_IFACE="$val" ;;
      ORBIS_SSH_ETH0_ADDR) SSH_ADDR="$val" ;;
      ORBIS_SSH_ETH0_CIDR) [ -n "$val" ] && SSH_CIDR="$val" ;;
    esac
  done
fi

# Nothing to do if SSH addr not configured
[ -n "${SSH_ADDR}" ] || exit 0

# Basic sanity: crude IPv4 check (avoid obvious junk)
echo "$SSH_ADDR" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || exit 0

# Bring interface up and assign the address idempotently.
ip link set "$ETH_IFACE" up 2>/dev/null || true

# Avoid duplicates; replace if present with a different prefix length.
if ip -4 addr show dev "$ETH_IFACE" | grep -Fq " $SSH_ADDR/"; then
  exit 0
fi

# Add; ignore failures (e.g., iface missing yet) to not block boot.
ip addr add "$SSH_ADDR/$SSH_CIDR" dev "$ETH_IFACE" 2>/dev/null || true

exit 0
