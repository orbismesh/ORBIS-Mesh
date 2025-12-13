#!/usr/bin/env bash
set -euo pipefail

PENDING_FILE="/etc/orbis_user_pending.json"

if [[ ! -f "$PENDING_FILE" ]]; then
  exit 0
fi

# Stop mesh monitor service before changing users.
systemctl stop mesh-monitor.service || true

# Parse JSON using Python (avoid jq dependency).
OLD_USER="$(python3 -c "import json; print(json.load(open('$PENDING_FILE')).get('old_username',''))")"
NEW_USER="$(python3 -c "import json; print(json.load(open('$PENDING_FILE')).get('new_username',''))")"
NEW_PASS="$(python3 -c "import json; print(json.load(open('$PENDING_FILE')).get('new_password') or '')")"

if [[ -z "$OLD_USER" ]]; then
  rm -f "$PENDING_FILE"
  exit 0
fi

if [[ -z "$NEW_USER" ]]; then
  NEW_USER="$OLD_USER"
fi

if [[ "$NEW_USER" != "$OLD_USER" ]]; then
  usermod -l "$NEW_USER" "$OLD_USER"

  # Rename group if same-named group exists
  if getent group "$OLD_USER" >/dev/null 2>&1; then
    groupmod -n "$NEW_USER" "$OLD_USER" || true
  fi

  # Move home directory and update passwd entry
  usermod -d "/home/$NEW_USER" -m "$NEW_USER"
fi

if [[ -n "$NEW_PASS" ]]; then
  echo "$NEW_USER:$NEW_PASS" | chpasswd
fi

rm -f "$PENDING_FILE"

# Start service back up (best-effort) then reboot to ensure sessions/state are clean.
systemctl start mesh-monitor.service || true
reboot
