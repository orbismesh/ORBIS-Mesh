#!/usr/bin/env bash
set -euo pipefail

CONF="/opt/orbis_data/orbis.conf"
TPL_DIR="/opt/orbis_data/network/templates"
GEN_DIR="/opt/orbis_data/network/generated"

# File paths br0.network
TPL_BR0="$TPL_DIR/br0.network.in"
OUT_BR0="$GEN_DIR/br0.network"
LINK_BR0="/etc/systemd/network/br0.network"

# File paths hostapd.conf
TPL_HOSTAPD="$TPL_DIR/hostapd.conf.in"
OUT_HOSTAPD="$GEN_DIR/hostapd.conf"
LINK_HOSTAPD="/etc/hostapd/hostapd.conf"

HASH_FILE="$GEN_DIR/.orbis.conf.sha256"

mkdir -p "$GEN_DIR"

if [[ ! -f "$CONF" ]]; then
  echo "Missing config: $CONF" >&2
  exit 1
fi
if [[ ! -f "$TPL_BR0" ]]; then
  echo "Missing template: $TPL_BR0" >&2
  exit 1
fi
if [[ ! -f "$TPL_HOSTAPD" ]]; then
  echo "Missing template: $TPL_HOSTAPD" >&2
  exit 1
fi

new_hash="$(sha256sum "$CONF" | awk '{print $1}')"
old_hash=""
if [[ -f "$HASH_FILE" ]]; then
  old_hash="$(cat "$HASH_FILE" || true)"
fi

if [[ "$new_hash" == "$old_hash" ]] \
  && [[ -f "$OUT_BR0" ]] && [[ -L "$LINK_BR0" ]] \
  && [[ -f "$OUT_HOSTAPD" ]] && [[ -L "$LINK_HOSTAPD" ]]; then
  exit 0
fi

rm -f "$OUT_BR0" "$OUT_HOSTAPD"

if [[ -L "$LINK_BR0" ]]; then
  target="$(readlink -f "$LINK_BR0" || true)"
  if [[ -z "$target" || "$target" == "$GEN_DIR/"* ]]; then
    rm -f "$LINK_BR0"
  fi
fi
if [[ -L "$LINK_HOSTAPD" ]]; then
  target="$(readlink -f "$LINK_HOSTAPD" || true)"
  if [[ -z "$target" || "$target" == "$GEN_DIR/"* ]]; then
    rm -f "$LINK_HOSTAPD"
  fi
fi

# shellcheck disable=SC1090
source "$CONF"

: "${NODE_IP:?missing NODE_IP}"
: "${NODE_CIDR:?missing NODE_CIDR}"
: "${SSH_IP:?missing SSH_IP}"
: "${SSH_CIDR:?missing SSH_CIDR}"
: "${GATEWAY:?missing GATEWAY}"
: "${DNS:?missing DNS}"

: "${COUNTRY:?missing COUNTRY}"
: "${LOCAL_SSID:?missing LOCAL_SSID}"
: "${LOCAL_CH:?missing LOCAL_CH}"
: "${WPA_PASSPHRASE:?missing WPA_PASSPHRASE}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# br0.network
sed \
  -e "s|@NODE_IP@|$NODE_IP|g" \
  -e "s|@NODE_CIDR@|$NODE_CIDR|g" \
  -e "s|@SSH_IP@|$SSH_IP|g" \
  -e "s|@SSH_CIDR@|$SSH_CIDR|g" \
  -e "s|@GATEWAY@|$GATEWAY|g" \
  -e "s|@DNS@|$DNS|g" \
  "$TPL_BR0" > "$tmp"

install -o root -g root -m 0644 "$tmp" "$OUT_BR0"
ln -sfn "$OUT_BR0" "$LINK_BR0"

# hostapd.conf
sed \
  -e "s|@LOCAL_SSID@|$LOCAL_SSID|g" \
  -e "s|@COUNTRY@|$COUNTRY|g" \
  -e "s|@LOCAL_CH@|$LOCAL_CH|g" \
  -e "s|@WPA_PASSPHRASE@|$WPA_PASSPHRASE|g" \
  "$TPL_HOSTAPD" > "$tmp"

install -o root -g root -m 0644 "$tmp" "$OUT_HOSTAPD"
mkdir -p "$(dirname "$LINK_HOSTAPD")"
ln -sfn "$OUT_HOSTAPD" "$LINK_HOSTAPD"

echo "$new_hash" > "$HASH_FILE"
chmod 0644 "$HASH_FILE"
