#!/usr/bin/env bash
set -euo pipefail
ORBIS_CONF="/opt/orbis/orbis.conf"
if [ -f "$ORBIS_CONF" ]; then
  # shellcheck disable=SC1090
  . "$ORBIS_CONF"
fi

LISTEN="${ORBIS_UI_LISTEN:-0.0.0.0}"
PORT="${ORBIS_UI_PORT:-5000}"

exec /usr/local/bin/gunicorn --bind "${LISTEN}:${PORT}" --workers 2 --threads 4 wsgi:app
