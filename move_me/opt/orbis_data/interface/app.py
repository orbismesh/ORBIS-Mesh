#!/usr/bin/env python3
"""
Orbis Mesh – Flask configuration interface

This Flask application provides a simple, responsive web UI with:

- Login for user "admin"
- Initial password setup on first start (password + confirmation)
- Two example content pages behind authentication
- Responsive sidebar navigation
- Light/Dark mode toggle persisted in the browser

"""

import json
import os
import socket
import subprocess
import re
import shlex
from datetime import datetime
from pathlib import Path
from functools import wraps
from typing import Optional

PENDING_USER_FILE = Path('/etc/orbis_user_pending.json')
ISO_COUNTRY_CODES = ['AF', 'AX', 'AL', 'DZ', 'AS', 'AD', 'AO', 'AI', 'AQ', 'AG', 'AR', 'AM', 'AW', 'AU', 'AT', 'AZ', 'BS', 'BH', 'BD', 'BB', 'BY', 'BE', 'BZ', 'BJ', 'BM', 'BT', 'BO', 'BQ', 'BA', 'BW', 'BV', 'BR', 'IO', 'BN', 'BG', 'BF', 'BI', 'CV', 'KH', 'CM', 'CA', 'KY', 'CF', 'TD', 'CL', 'CN', 'CX', 'CC', 'CO', 'KM', 'CG', 'CD', 'CK', 'CR', 'CI', 'HR', 'CU', 'CW', 'CY', 'CZ', 'DK', 'DJ', 'DM', 'DO', 'EC', 'EG', 'SV', 'GQ', 'ER', 'EE', 'SZ', 'ET', 'FK', 'FO', 'FJ', 'FI', 'FR', 'GF', 'PF', 'TF', 'GA', 'GM', 'GE', 'DE', 'GH', 'GI', 'GR', 'GL', 'GD', 'GP', 'GU', 'GT', 'GG', 'GN', 'GW', 'GY', 'HT', 'HM', 'VA', 'HN', 'HK', 'HU', 'IS', 'IN', 'ID', 'IR', 'IQ', 'IE', 'IM', 'IL', 'IT', 'JM', 'JP', 'JE', 'JO', 'KZ', 'KE', 'KI', 'KP', 'KR', 'KW', 'KG', 'LA', 'LV', 'LB', 'LS', 'LR', 'LY', 'LI', 'LT', 'LU', 'MO', 'MG', 'MW', 'MY', 'MV', 'ML', 'MT', 'MH', 'MQ', 'MR', 'MU', 'YT', 'MX', 'FM', 'MD', 'MC', 'MN', 'ME', 'MS', 'MA', 'MZ', 'MM', 'NA', 'NR', 'NP', 'NL', 'NC', 'NZ', 'NI', 'NE', 'NG', 'NU', 'NF', 'MK', 'MP', 'NO', 'OM', 'PK', 'PW', 'PS', 'PA', 'PG', 'PY', 'PE', 'PH', 'PN', 'PL', 'PT', 'PR', 'QA', 'RE', 'RO', 'RU', 'RW', 'BL', 'SH', 'KN', 'LC', 'MF', 'PM', 'VC', 'WS', 'SM', 'ST', 'SA', 'SN', 'RS', 'SC', 'SL', 'SG', 'SX', 'SK', 'SI', 'SB', 'SO', 'ZA', 'GS', 'SS', 'ES', 'LK', 'SD', 'SR', 'SJ', 'SE', 'CH', 'SY', 'TW', 'TJ', 'TZ', 'TH', 'TL', 'TG', 'TK', 'TO', 'TT', 'TN', 'TR', 'TM', 'TC', 'TV', 'UG', 'UA', 'AE', 'GB', 'US', 'UM', 'UY', 'UZ', 'VU', 'VE', 'VN', 'VG', 'VI', 'WF', 'EH', 'YE', 'ZM', 'ZW']

def _max_channel_24ghz(country_code: str) -> int:
    """Conservative 2.4 GHz channel limit by country."""
    c = (country_code or "").upper()
    if c == "JP":
        return 14
    if c in ("US", "CA", "MX"):
        return 11
    return 13


def _read_kv_line(path: str, key: str, default: str = "") -> str:
    """Read first 'key=value' line from a file."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith(key + "="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return default


def _write_kv_line(path: str, key: str, value: str) -> None:
    """Replace or append a 'key=value' line, preserving other lines."""
    lines = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        lines = []

    out = []
    replaced = False
    for line in lines:
        if line.strip().startswith(key + "=") and not line.lstrip().startswith("#"):
            out.append(f"{key}={value}\n")
            replaced = True
        else:
            out.append(line)

    if not replaced:
        if out and not out[-1].endswith("\n"):
            out[-1] = out[-1] + "\n"
        out.append(f"{key}={value}\n")

    # Best-effort backup
    try:
        os.makedirs("/var/backups/orbis_mesh", exist_ok=True)
        import time
        ts = time.strftime("%Y%m%d-%H%M%S")
        backup_path = f"/var/backups/orbis_mesh/{os.path.basename(path)}.{ts}.bak"
        if lines:
            with open(backup_path, "w", encoding="utf-8") as bf:
                bf.writelines(lines)
    except Exception:
        pass

    with open(path, "w", encoding="utf-8") as f:
        f.writelines(out)


def _set_br0_address(ip_with_suffix: str) -> None:
    """Update Address= in /etc/systemd/network/br0.network."""
    network_file = "/etc/systemd/network/br0.network"
    lines = []
    try:
        with open(network_file, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        lines = []

    out = []
    replaced = False
    for line in lines:
        if line.strip().startswith("Address=") and not line.lstrip().startswith("#"):
            out.append(f"Address={ip_with_suffix}\n")
            replaced = True
        else:
            out.append(line)
    if not replaced:
        out.append(f"Address={ip_with_suffix}\n")

    # Best-effort backup
    try:
        os.makedirs("/var/backups/orbis_mesh", exist_ok=True)
        import time
        ts = time.strftime("%Y%m%d-%H%M%S")
        backup_path = f"/var/backups/orbis_mesh/br0.network.{ts}.bak"
        if lines:
            with open(backup_path, "w", encoding="utf-8") as bf:
                bf.writelines(lines)
    except Exception:
        pass

    with open(network_file, "w", encoding="utf-8") as f:
        f.writelines(out)


def _is_valid_hostname(value: str) -> bool:
    """Validate hostname with a conservative RFC 1123-compatible rule.

    - Total length: 1..253
    - Labels: 1..63
    - Allowed: a-z, A-Z, 0-9, hyphen
    - Labels must not start/end with hyphen
    """
    v = (value or "").strip()
    if not v or len(v) > 253:
        return False
    # Allow single-label hostnames (common on Raspberry Pi)
    labels = v.split(".")
    label_re = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
    for lab in labels:
        if len(lab) == 0 or len(lab) > 63:
            return False
        if not label_re.match(lab):
            return False
    return True


def _get_current_timezone() -> str:
    """Return current timezone (best-effort)."""
    # Prefer /etc/timezone on Debian/Raspberry Pi OS
    try:
        with open("/etc/timezone", "r", encoding="utf-8") as f:
            tz = f.read().strip()
            if tz:
                return tz
    except OSError:
        pass

    # Fallback to timedatectl
    try:
        r = subprocess.run(
            ["timedatectl", "show", "-p", "Timezone", "--value"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        tz = (r.stdout or "").strip()
        return tz or "–"
    except Exception:
        return "–"


def _list_timezones() -> list:
    """Return list of available timezones (best-effort)."""
    # timedatectl is the most reliable and fast for systemd-based installs
    try:
        r = subprocess.run(
            ["timedatectl", "list-timezones"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        zones = [z.strip() for z in (r.stdout or "").splitlines() if z.strip()]
        if zones:
            return zones
    except Exception:
        pass

    # Fallback: walk /usr/share/zoneinfo
    base = "/usr/share/zoneinfo"
    zones = []
    try:
        for root, dirs, files in os.walk(base):
            # skip bulky/non-timezone dirs
            rel_root = os.path.relpath(root, base)
            if rel_root.startswith("posix") or rel_root.startswith("right"):
                continue
            for fn in files:
                if fn.startswith("."):
                    continue
                p = os.path.join(root, fn)
                rel = os.path.relpath(p, base)
                # Ignore helper files
                if rel in {"zone.tab", "zone1970.tab", "leapseconds", "localtime", "posixrules"}:
                    continue
                zones.append(rel)
    except Exception:
        return []

    return sorted(set(zones))






def _pending_user_change_exists() -> bool:
    r = _run_sudo(["bash", "-c", f"test -f {shlex.quote(str(PENDING_USER_FILE))}"])
    return r.returncode == 0


def _read_pending_user_change() -> Optional[dict]:
    """Read pending user-change JSON via sudo (file is root-only)."""
    r = _run_sudo(["cat", str(PENDING_USER_FILE)])
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout or "{}")
    except Exception:
        return None


def _write_pending_user_change(payload: dict) -> None:
    """Write pending user-change JSON as root (600 perms)."""
    data = json.dumps(payload, ensure_ascii=False)
    # Use umask to ensure 600 permissions.
    r = _run_sudo(
        ["bash", "-c", f"umask 077; cat > {shlex.quote(str(PENDING_USER_FILE))}"],
        input_text=data + "\n",
    )
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout or "").strip() or "write pending file failed")


def _clear_pending_user_change() -> bool:
    """Remove pending user-change JSON file if present. Returns True if removed."""
    r = _run_sudo(["bash", "-c", f"rm -f {shlex.quote(str(PENDING_USER_FILE))}"])
    return r.returncode == 0



def _ensure_apply_user_change_service_enabled() -> None:
    """Enable the oneshot service if present (best-effort)."""
    _run_sudo(["systemctl", "daemon-reload"])
    _run_sudo(["systemctl", "enable", "orbis-apply-user-change.service"])

def _get_primary_username() -> str:
    """Return the primary non-root system username.

    On Raspberry Pi OS this is typically the first user with UID 1000.
    Falls back to the current process user if no suitable entry is found.
    """
    try:
        with open("/etc/passwd", "r", encoding="utf-8") as f:
            for line in f:
                if not line or line.startswith("#"):
                    continue
                parts = line.split(":")
                if len(parts) < 3:
                    continue
                name = parts[0].strip()
                try:
                    uid = int(parts[2])
                except Exception:
                    continue
                if uid == 1000 and name not in ("root", ""):
                    return name
        # fallback: first uid>=1000 user
        with open("/etc/passwd", "r", encoding="utf-8") as f:
            candidates = []
            for line in f:
                if not line or line.startswith("#"):
                    continue
                parts = line.split(":")
                if len(parts) < 3:
                    continue
                name = parts[0].strip()
                try:
                    uid = int(parts[2])
                except Exception:
                    continue
                if uid >= 1000 and name not in ("root", ""):
                    candidates.append((uid, name))
            if candidates:
                candidates.sort()
                return candidates[0][1]
    except Exception:
        pass

    try:
        import getpass
        return getpass.getuser()
    except Exception:
        return "pi"


_username_re = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")


def _is_valid_linux_username(name: str) -> bool:
    """Basic username validation for usermod/groupmod."""
    return bool(name and _username_re.fullmatch(name))

def _sh_quote(value: str) -> str:
    """Shell-escape a string safely."""
    return shlex.quote(value)
def _run_sudo(cmd: list, input_text: 'Optional[str]' = None) -> subprocess.CompletedProcess:
    """Run a command via sudo (non-interactive) and capture output.

    We use `sudo -n` so the Flask process never blocks on a password prompt.
    If sudo is not configured for passwordless execution, callers will get a
    non-zero return code and stderr explaining the failure.

    Args:
        cmd: Command (argv) without sudo.
        input_text: Optional stdin payload (text).
    """
    return subprocess.run(
        ["sudo", "-n", *cmd],
        input=input_text,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )


def _persist_hostname(new_hostname: str) -> subprocess.CompletedProcess:
    """Persist hostname on Debian/Raspberry Pi OS.

    `hostnamectl set-hostname` should be sufficient when it succeeds, but
    explicitly writing /etc/hostname and updating /etc/hosts makes the change
    robust against images/services that re-apply hostname at boot.
    """
    script = (
        "set -e; "
        f"echo '{new_hostname}' > /etc/hostname; "
        # Update 127.0.1.1 entry (Debian convention)
        f"if grep -qE '^[[:space:]]*127\\.0\\.1\\.1[[:space:]]' /etc/hosts; then "
        f"  sed -i -E 's/^[[:space:]]*127\\.0\\.1\\.1[[:space:]].*/127.0.1.1\t{new_hostname}/' /etc/hosts; "
        "else "
        f"  echo '127.0.1.1\t{new_hostname}' >> /etc/hosts; "
        "fi; "
        f"hostnamectl set-hostname '{new_hostname}'"
    )
    return _run_sudo(["bash", "-lc", script])


def _persist_timezone(tz: str) -> subprocess.CompletedProcess:
    """Persist timezone on Debian/Raspberry Pi OS."""
    # `timedatectl set-timezone` usually does the right thing. We also ensure
    # /etc/timezone and /etc/localtime reflect the selected zone.
    script = (
        "set -e; "
        f"timedatectl set-timezone '{tz}'; "
        f"echo '{tz}' > /etc/timezone; "
        f"ln -sf '/usr/share/zoneinfo/{tz}' /etc/localtime"
    )
    return _run_sudo(["bash", "-lc", script])


from flask import (
    Flask,
    render_template,
    request,
    redirect,
    url_for,
    session,
    flash,
    jsonify,
)

from werkzeug.security import generate_password_hash, check_password_hash


BASE_DIR = os.path.dirname(os.path.abspath(__file__))
AUTH_FILE = os.path.join(BASE_DIR, "auth.json")

# -----------------------------------------------------------------------------
# Flask application setup
# -----------------------------------------------------------------------------

app = Flask(__name__)

# IMPORTANT:
# Replace this with a persistent, secret value in production.
# Example:
#   python3 - << 'EOF'
#   import secrets; print(secrets.token_hex(32))
#   EOF
app.config["SECRET_KEY"] = "CHANGE_ME_TO_A_RANDOM_SECRET"


# -----------------------------------------------------------------------------
# Authentication helpers
# -----------------------------------------------------------------------------

def _load_auth():
    """Load authentication data from JSON file, if present."""
    if not os.path.exists(AUTH_FILE):
        return None
    try:
        with open(AUTH_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        # minimal validation
        if data.get("username") == "admin" and "password_hash" in data:
            return data
    except (OSError, json.JSONDecodeError):
        # If file is corrupt, ignore and treat as not configured
        return None
    return None


def _save_auth(password_hash):
    """Persist authentication data to JSON file."""
    data = {
        "username": "admin",
        "password_hash": password_hash,
    }
    with open(AUTH_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f)


def is_password_configured():
    """Return True if an admin password has been configured."""
    return _load_auth() is not None


def login_required(view_func):
    """Decorator to protect routes that require authentication."""

    @wraps(view_func)
    def wrapper(*args, **kwargs):
        if session.get("user") != "admin":
            return redirect(url_for("login"))
        return view_func(*args, **kwargs)

    return wrapper
def _read_mac_address(interface_name: str):
    """Return MAC address of given interface or None."""
    path = f"/sys/class/net/{interface_name}/address"
    try:
        with open(path, "r", encoding="utf-8") as f:
            mac = f.read().strip()
            return mac or None
    except OSError:
        return None


def _check_systemd_active(unit_name: str):
    """Return True if systemd unit is active, False if inactive, None on error."""
    try:
        result = subprocess.run(
            ["systemctl", "is-active", unit_name],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        status = result.stdout.strip()
        if status == "active":
            return True
        if status in {"inactive", "failed"}:
            return False
        return None
    except Exception:
        return None


def _check_interface_up(ifname: str):
    """Return True if interface operstate is 'up', False if 'down', None otherwise."""
    operstate_path = f"/sys/class/net/{ifname}/operstate"
    try:
        with open(operstate_path, "r", encoding="utf-8") as f:
            state = f.read().strip().lower()
        if state == "up":
            return True
        if state == "down":
            return False
        return None
    except OSError:
        return None



# -----------------------------------------------------------------------------
# Routes
# -----------------------------------------------------------------------------

@app.route("/")
def index():
    """Redirect to dashboard (or login if not authenticated)."""
    if session.get("user") == "admin":
        return redirect(url_for("dashboard"))
    return redirect(url_for("login"))


@app.route("/login", methods=["GET", "POST"])
def login():
    """
    Login view.

    Behaviour:
    - If no password is configured yet, the page is used to set the initial
      password for user "admin". The user must enter the password twice.
    - Once the password is configured, the same URL becomes the normal login
      screen (username + password).
    """
    auth_data = _load_auth()
    password_configured = auth_data is not None

    if request.method == "POST":
        # ---------------------------------------------------------------------
        # FIRST RUN – configure initial password
        # ---------------------------------------------------------------------
        if not password_configured:
            password = request.form.get("password", "").strip()
            password_confirm = request.form.get("password_confirm", "").strip()

            if not password or not password_confirm:
                flash("Please enter a password and confirmation.", "error")
                return render_template(
                    "login.html",
                    password_configured=False,
                    branding="Orbis Mesh",
                )

            if password != password_confirm:
                flash("The passwords do not match.", "error")
                return render_template(
                    "login.html",
                    password_configured=False,
                    branding="Orbis Mesh",
                )

            if len(password) < 6:
                flash("The password must be at least 6 characters long.", "error")
                return render_template(
                    "login.html",
                    password_configured=False,
                    branding="Orbis Mesh",
                )

            password_hash = generate_password_hash(password)
            _save_auth(password_hash)
            flash("Initial password set. Please log in now.", "success")
            return redirect(url_for("login"))

        # ---------------------------------------------------------------------
        # NORMAL LOGIN – verify credentials
        # ---------------------------------------------------------------------
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "").strip()

        if not username or not password:
            flash("Please enter username and password.", "error")
            return render_template(
                "login.html",
                password_configured=True,
                branding="Orbis Mesh",
            )

        if username != "admin":
            flash("Unbekannter Benutzer.", "error")
            return render_template(
                "login.html",
                password_configured=True,
                branding="Orbis Mesh",
            )

        if not auth_data or not check_password_hash(auth_data["password_hash"], password):
            flash("Login failed. Please check your credentials.", "error")
            return render_template(
                "login.html",
                password_configured=True,
                branding="Orbis Mesh",
            )

        # success
        session["user"] = "admin"
        flash("Erfolgreich eingeloggt.", "success")
        return redirect(url_for("dashboard"))

    # GET
    return render_template(
        "login.html",
        password_configured=password_configured,
        branding="Orbis Mesh",
    )

@app.context_processor
def inject_hostname():
    return dict(hostname=socket.gethostname())

@app.context_processor
def inject_country_codes():
    # Provide ISO country codes globally for all templates/pages.
    return {
        "ISO_COUNTRY_CODES": ISO_COUNTRY_CODES,
        "countries": ISO_COUNTRY_CODES,  # legacy name used by existing templates
    }

@app.context_processor
def inject_mesh_status():
    """Expose mesh node presence to all templates.

    mesh_has_nodes is True when at least one *external* node is present.
    External means: a node entry whose MAC differs from the local node MAC.
    """
    try:
        with open(NODE_STATUS_PATH, "r", encoding="utf-8") as f:
            raw = json.load(f)
        nodes = raw.get("nodes", {}) or {}
        local_mac = (raw.get("local") or {}).get("mac")
        external = [mac for mac in nodes.keys() if mac and mac != local_mac]
        has_nodes = len(external) > 0
    except Exception:
        has_nodes = False

    return {"mesh_has_nodes": has_nodes}




@app.route("/api/local-node")
@login_required
def api_local_node():
    """Return MAC address and status of local node services/interfaces as JSON."""
    mac_wlan1 = _read_mac_address("wlan1")

    status = {
        "mesh_monitor": _check_systemd_active("mesh-monitor.service"),
        "ogm_monitor": _check_systemd_active("ogm-monitor.service"),
        "hostapd": _check_systemd_active("hostapd.service"),
        "dnsmasq": _check_systemd_active("dnsmasq.service"),
        "br0": _check_interface_up("br0"),
        "wlan1": _check_interface_up("wlan1"),
        "eth0": _check_interface_up("eth0"),
    }

    return jsonify(
        {
            "mac_wlan1": mac_wlan1,
            "status": status,
        }
    )


# -----------------------------------------------------------------------------
# Website Routes
# -----------------------------------------------------------------------------

@app.route("/logout")
def logout():
    """Clear session and return to login screen."""
    session.clear()
    flash("Abgemeldet.", "info")
    return redirect(url_for("login"))


@app.route("/dashboard")
@login_required
def dashboard():
    """Example main page."""
    return render_template(
        "dashboard.html",
        branding="Orbis Mesh",
        page_title="Dashboard",
        active_page="dashboard",
    )


@app.route("/settings")
@login_required
def settings():
    """Example second page."""
    return render_template(
        "settings.html",
        branding="Orbis Mesh",
        page_title="Settings",
        active_page="settings",
    )


@app.route("/device-config")
@login_required
def device_config():
    """Device configuration page (hostname, timezone, user-change scheduling)."""
    pending = _read_pending_user_change()
    pending_since = None
    if pending and isinstance(pending, dict):
        pending_since = pending.get("created_at")
    return render_template(
        "device_config.html",
        branding="Orbis Mesh",
        page_title="Device Config",
        active_page="device_config",
        current_hostname=socket.gethostname(),
        current_timezone=_get_current_timezone(),
        current_username=_get_primary_username(),
        available_timezones=_list_timezones(),
        user_change_pending=bool(pending_since),
        user_change_pending_since=pending_since,
    )


@app.route("/device-info")
@login_required
def device_info():
    """Device information / overview page."""
    return render_template(
        "device_info.html",
        branding="Orbis Mesh",
        page_title="Device Info",
        active_page="device_info",
    )


@app.route("/device-config/hostname", methods=["POST"])
@login_required
def device_config_set_hostname():
    new_hostname = (request.form.get("hostname") or "").strip()

    if not _is_valid_hostname(new_hostname):
        flash("Invalid hostname. Use letters, digits, and hyphens.", "error")
        return redirect(url_for("device_config"))

    # Make the change persistent on Raspberry Pi OS by updating BOTH:
    # - /etc/hostname
    # - the 127.0.1.1 line in /etc/hosts
    #
    # IMPORTANT:
    # Many Raspberry Pi images include cloud-init. If cloud-init is configured
    # to manage the hostname, it can overwrite /etc/hostname on every boot.
    # We therefore also drop a config snippet that preserves the hostname.
    script = (
        "set -e; "
        "echo {hn} > /etc/hostname; "
        # Update or append the 127.0.1.1 entry
        "if grep -qE '^127\\.0\\.1\\.1\\s+' /etc/hosts; then "
        "  sed -i -E 's/^127\\.0\\.1\\.1\\s+.*/127.0.1.1\t{hn}/' /etc/hosts; "
        "else "
        "  printf '\n127.0.1.1\t{hn}\n' >> /etc/hosts; "
        "fi; "
        # Prevent cloud-init from resetting the hostname on reboot (if present)
        "mkdir -p /etc/cloud/cloud.cfg.d; "
        "printf 'preserve_hostname: true\n' > /etc/cloud/cloud.cfg.d/99-orbis-preserve-hostname.cfg; "
        "hostnamectl set-hostname {hn}"
    ).format(hn=new_hostname)

    try:
        r = _run_sudo(["sh", "-c", script])
        if r.returncode != 0:
            err = (r.stderr or "").strip() or "sudo/hostnamectl failed"
            flash(
                "Could not set hostname. Ensure passwordless sudo is configured for: "
                "hostnamectl, writing /etc/hostname, and editing /etc/hosts. "
                f"Details: {err}",
                "error",
            )
        else:
            flash("Hostname updated (persistent).", "success")
    except Exception as e:
        flash(f"Could not set hostname: {e}", "error")

    return redirect(url_for("device_config"))


@app.route("/device-config/timezone", methods=["POST"])
@login_required
def device_config_set_timezone():
    tz = (request.form.get("timezone") or "").strip()

    zones = _list_timezones()
    if not tz or tz not in zones:
        flash("Invalid timezone selection.", "error")
        return redirect(url_for("device_config"))

    # timedatectl should persist, but on Debian/Raspberry Pi OS we also enforce
    # /etc/timezone + /etc/localtime to avoid reverting.
    script = (
        "set -e; "
        "timedatectl set-timezone {tz} >/dev/null 2>&1 || true; "
        "echo {tz} > /etc/timezone; "
        "ln -sf /usr/share/zoneinfo/{tz} /etc/localtime"
    ).format(tz=tz)

    try:
        r = _run_sudo(["sh", "-c", script])
        if r.returncode != 0:
            err = (r.stderr or "").strip() or "sudo/timedatectl failed"
            flash(
                "Could not set timezone. Ensure passwordless sudo is configured for: "
                "timedatectl, writing /etc/timezone, and relinking /etc/localtime. "
                f"Details: {err}",
                "error",
            )
        else:
            flash("Timezone updated (persistent).", "success")
    except Exception as e:
        flash(f"Could not set timezone: {e}", "error")

    return redirect(url_for("device_config"))

@app.route("/device-config/user", methods=["POST"])
@login_required
def device_config_set_user():
    current_user = _get_primary_username()

    new_username = (request.form.get("username") or "").strip().lower()
    new_password = (request.form.get("password") or "").strip()
    new_password_confirm = (request.form.get("password_confirm") or "").strip()

    # Allow changing either field independently.
    if not new_username and not new_password:
        flash("Nothing to update.", "info")
        return redirect(url_for("device_config"))

    if new_password:
        if new_password != new_password_confirm:
            flash("Passwords do not match.", "error")
            return redirect(url_for("device_config"))

    if new_username and new_username != current_user:
        if not _is_valid_linux_username(new_username):
            flash("Invalid username. Use lowercase letters, digits, underscores, and hyphens.", "error")
            return redirect(url_for("device_config"))

    payload = {
        "old_username": current_user,
        "new_username": new_username or current_user,
        "new_password": new_password or None,
        "created_at": datetime.now().isoformat(timespec="seconds"),
    }

    try:
        _write_pending_user_change(payload)
        _ensure_apply_user_change_service_enabled()
    except Exception as e:
        flash(
            "Could not schedule user change. Ensure passwordless sudo is configured for: "
            "writing /etc/orbis_user_pending.json and enabling the apply service. "
            f"Details: {e}",
            "error",
        )
        return redirect(url_for("device_config"))

    flash("User change scheduled. It will be applied on next reboot.", "success")
    return redirect(url_for("device_config"))


@app.route("/device-config/user/apply", methods=["POST"])
@login_required
def device_config_apply_user_change():
    if not _pending_user_change_exists():
        flash("No pending user change found.", "info")
        return redirect(url_for("device_config"))

    # Reboot to apply via oneshot service early in boot.
    r = _run_sudo(["reboot"])
    if r.returncode != 0:
        err = (r.stderr or r.stdout or "").strip() or "reboot failed"
        flash(f"Could not reboot: {err}", "error")
        return redirect(url_for("device_config"))

    flash("Rebooting to apply user change...", "success")
    return redirect(url_for("device_config"))

@app.route("/device-config/user/discard", methods=["POST"])
@login_required
def device_config_discard_user_change():
    if not _pending_user_change_exists():
        flash("No pending user change found.", "info")
        return redirect(url_for("device_config"))

    ok = _clear_pending_user_change()
    # Best-effort: disable the oneshot service so it does not run needlessly.
    _run_sudo(["systemctl", "disable", "orbis-apply-user-change.service"])
    if not ok:
        flash("Could not discard pending change.", "error")
        return redirect(url_for("device_config"))

    flash("Pending user change discarded.", "success")
    return redirect(url_for("device_config"))



@app.route("/local-network")
@login_required
def local_network():
    current_ip_with_suffix = _read_kv_line("/etc/systemd/network/br0.network", "Address", default="–")
    current_ssid = _read_kv_line("/etc/hostapd/hostapd.conf", "ssid", default="–")
    current_country_code = _read_kv_line("/etc/hostapd/hostapd.conf", "country_code", default="US").upper()
    try:
        current_channel = int(_read_kv_line("/etc/hostapd/hostapd.conf", "channel", default="1"))
    except ValueError:
        current_channel = 1

    if current_country_code not in ISO_COUNTRY_CODES:
        current_country_code = "US"

    return render_template(
        "local_network.html",
        branding="Orbis Mesh",
        page_title="Local Network",
        active_page="local_network",
        current_ip_with_suffix=current_ip_with_suffix,
        current_ssid=current_ssid,
        current_country_code=current_country_code,
        current_channel=current_channel,
        countries=ISO_COUNTRY_CODES,
    )


@app.route("/local-network/ip", methods=["POST"])
@login_required
def local_network_set_ip():
    ip_address = request.form.get("ip_address", "").strip()
    ip_suffix = request.form.get("ip_suffix", "").strip()

    try:
        import ipaddress
        ipaddress.IPv4Address(ip_address)
    except Exception:
        return ("Invalid IP", 400)

    if not ip_suffix.isdigit():
        return ("Invalid suffix", 400)
    suffix_int = int(ip_suffix)
    if suffix_int < 0 or suffix_int > 32:
        return ("Invalid suffix", 400)

    ip_with_suffix = f"{ip_address}/{suffix_int}"
    _set_br0_address(ip_with_suffix)

    os.system("sudo reboot")
    return ("", 204)


@app.route("/local-network/ssid", methods=["POST"])
@login_required
def local_network_set_ssid():
    """
    Save SSID (and optionally password) independently from country/channel.
    If password is left empty, the existing password is kept.
    """
    ssid_value = request.form.get("ssid_value", "").strip()
    wifi_passphrase = request.form.get("wifi_passphrase", "").strip()

    if not ssid_value or len(ssid_value) > 32:
        return ("Invalid SSID", 400)

    hostapd_file = "/etc/hostapd/hostapd.conf"
    _write_kv_line(hostapd_file, "ssid", ssid_value)

    if wifi_passphrase:
        if len(wifi_passphrase) < 8 or len(wifi_passphrase) > 63:
            return ("Invalid password length", 400)
        _write_kv_line(hostapd_file, "wpa_passphrase", wifi_passphrase)

    os.system("sudo reboot")
    return ("", 204)



@app.route("/local-network/wifi", methods=["POST"])
@login_required
def local_network_set_wifi():
    """
    Save country code and Wi-Fi channel independently from SSID/password.
    """
    country_code = request.form.get("country_code", "US").strip().upper()
    wifi_channel = request.form.get("wifi_channel", "1").strip()

    if country_code not in ISO_COUNTRY_CODES:
        return ("Invalid country code", 400)

    if not wifi_channel.isdigit():
        return ("Invalid channel", 400)

    ch = int(wifi_channel)
    max_ch = _max_channel_24ghz(country_code)
    if ch < 1 or ch > max_ch:
        return ("Channel not allowed for country", 400)

    hostapd_file = "/etc/hostapd/hostapd.conf"
    _write_kv_line(hostapd_file, "country_code", country_code)
    _write_kv_line(hostapd_file, "channel", str(ch))

    os.system("sudo reboot")
    return ("", 204)


# ----------------------------------------------------------------------
# Mesh-Nodes API (Dashboard)
# ----------------------------------------------------------------------

NODE_STATUS_PATH = "/opt/orbis_data/ogm/node_status.json"
NODE_TIMEOUT_SECONDS = 30  # Sekunden bis ein Node als "inaktiv" gilt


@app.route("/api/mesh-nodes")
@login_required
def api_mesh_nodes():
    """Liefert Informationen zu allen bekannten Mesh-Nodes.

    Source is the JSON file written by ogm-monitor
    /opt/orbis_data/ogm/node_status.json.
    """

    try:
        with open(NODE_STATUS_PATH, "r", encoding="utf-8") as f:
            raw = json.load(f)
    except (OSError, json.JSONDecodeError):
        raw = {}

    nodes = raw.get("nodes", {}) or {}
    local = raw.get("local") or {}

    # Fallback if no MAC is present in the JSON
    if not local.get("mac"):
        local["mac"] = _read_mac_address("wlan1") or _read_mac_address("br0")

    # Health status of relevant services (same style as /api/local-node)
    def _svc_health(unit_name: str) -> str:
        state = _check_systemd_active(unit_name)
        if state is True:
            return "ok"
        if state is False:
            return "bad"
        return "unknown"

    health = {
        "ogm-monitor": _svc_health("ogm-monitor.service"),
        "mesh-monitor": _svc_health("mesh-monitor.service"),
        "systemd-networkd": _svc_health("systemd-networkd.service"),
    }

    return jsonify(
        {
            "hostname": socket.gethostname(),
            "local_mac": local.get("mac"),
            "local": local,
            "nodes": nodes,
            # for compatibility with the old interface:
            "node_status": nodes,
            "node_timeout": NODE_TIMEOUT_SECONDS,
            "health": health,
            "timestamp": raw.get("timestamp"),
        }
    )



# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------

@app.route("/reboot", methods=["POST"])
@login_required
def reboot():
    import os
    os.system("sudo reboot")
    return ("",204)

if __name__ == "__main__":
    # Run on all interfaces so it is reachable over the network
    app.run(host="0.0.0.0", port=5000, debug=True)