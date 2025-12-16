#!/bin/sh
set -eu
ORBIS_CONF="/opt/orbis/orbis.conf"
[ -f "$ORBIS_CONF" ] || { echo "Missing $ORBIS_CONF" >&2; exit 1; }
. "$ORBIS_CONF"
require_root(){ [ "$(id -u)" -eq 0 ] || { echo "This script must run as root." >&2; exit 1; }; }
die(){ echo "ERROR: $*" >&2; exit 1; }
get_phy_for_iface(){ iw dev "$1" info 2>/dev/null | awk '/wiphy/ {print "phy"$2; exit}'; }
