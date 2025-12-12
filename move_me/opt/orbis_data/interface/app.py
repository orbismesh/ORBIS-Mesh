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
from functools import wraps

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
                flash("Bitte Passwort und Bestätigung eingeben.", "error")
                return render_template(
                    "login.html",
                    password_configured=False,
                    branding="Orbis Mesh",
                )

            if password != password_confirm:
                flash("Die Passwörter stimmen nicht überein.", "error")
                return render_template(
                    "login.html",
                    password_configured=False,
                    branding="Orbis Mesh",
                )

            if len(password) < 6:
                flash("Das Passwort muss mindestens 6 Zeichen lang sein.", "error")
                return render_template(
                    "login.html",
                    password_configured=False,
                    branding="Orbis Mesh",
                )

            password_hash = generate_password_hash(password)
            _save_auth(password_hash)
            flash("Initiales Passwort gesetzt. Bitte jetzt einloggen.", "success")
            return redirect(url_for("login"))

        # ---------------------------------------------------------------------
        # NORMAL LOGIN – verify credentials
        # ---------------------------------------------------------------------
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "").strip()

        if not username or not password:
            flash("Bitte Benutzername und Passwort eingeben.", "error")
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
            flash("Login fehlgeschlagen. Bitte Zugangsdaten prüfen.", "error")
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


# ----------------------------------------------------------------------
# Mesh-Nodes API (Dashboard)
# ----------------------------------------------------------------------

NODE_STATUS_PATH = "/opt/orbis_data/ogm/node_status.json"
NODE_TIMEOUT_SECONDS = 30  # Sekunden bis ein Node als "inaktiv" gilt


@app.route("/api/mesh-nodes")
@login_required
def api_mesh_nodes():
    """Liefert Informationen zu allen bekannten Mesh-Nodes.

    Quelle ist die von ogm-monitor geschriebene JSON-Datei
    /opt/orbis_data/ogm/node_status.json.
    """

    try:
        with open(NODE_STATUS_PATH, "r", encoding="utf-8") as f:
            raw = json.load(f)
    except (OSError, json.JSONDecodeError):
        raw = {}

    nodes = raw.get("nodes", {}) or {}
    local = raw.get("local") or {}

    # Fallback, falls im JSON keine MAC enthalten ist
    if not local.get("mac"):
        local["mac"] = _read_mac_address("wlan1") or _read_mac_address("br0")

    # Health-Status der relevanten Dienste (im gleichen Stil wie /api/local-node)
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
            # für Kompatibilität zum alten Interface:
            "node_status": nodes,
            "node_timeout": NODE_TIMEOUT_SECONDS,
            "health": health,
            "timestamp": raw.get("timestamp"),
        }
    )



# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------

if __name__ == "__main__":
    # Run on all interfaces so it is reachable over the network
    app.run(host="0.0.0.0", port=5000, debug=True)

@app.route("/reboot", methods=["POST"])
@login_required
def reboot():
    import os
    os.system("sudo reboot")
    return ("",204)
