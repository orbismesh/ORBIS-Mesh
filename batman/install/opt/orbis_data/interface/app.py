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

try:
    import pycountry  # type: ignore
except Exception:  # pragma: no cover
    pycountry = None


import time
import threading
# ---------------------------------------------------------------------------
# Orbis configuration helpers
# ---------------------------------------------------------------------------

ORBIS_CONF_CANDIDATES = (
    "/opt/orbis_data/orbis.conf",
    "/opt/orbis_data/network/orbis.conf",  # legacy/alternate location
)


def _get_orbis_conf_path() -> str:
    """Return the most appropriate orbis.conf path for read/write."""
    for p in ORBIS_CONF_CANDIDATES:
        if os.path.exists(p):
            return p
    # Default to the primary expected location.
    return ORBIS_CONF_CANDIDATES[0]


# ---------------------------------------------------------------------------
# RF channel database (global channel->frequency mapping)
#
# Stored as static JSON so that:
# - The UI can show channels without hardcoding MHz values.
# - Future regdom logic can filter allowed channels without changing this file.
# ---------------------------------------------------------------------------

RF_CHANNEL_DB_PATH = Path(__file__).resolve().parent / "static" / "rf" / "wifi_channels.json"

# Country names (English) mapping (ISO3166-1 alpha-2 -> name)
# Render labels like "Germany (DE)" without requiring optional dependencies.
COUNTRIES_EN_PATH = Path(__file__).resolve().parent / "static" / "rf" / "countries_en.json"


def _load_rf_channel_db() -> dict:
    """Load global Wi-Fi channel -> center frequency (MHz) mapping.

    Returns:
        {
          "2.4GHz": {1: 2412, ...},
          "5GHz": {36: 5180, ...}
        }

    Notes:
        Keys are returned as integers even though JSON stores them as strings.
    """
    try:
        with open(RF_CHANNEL_DB_PATH, "r", encoding="utf-8") as f:
            raw = json.load(f)
        out = {}
        for band, mapping in (raw or {}).items():
            out[band] = {int(k): int(v) for k, v in (mapping or {}).items()}
        return out
    except Exception:
        return {}


RF_CHANNEL_DB = _load_rf_channel_db()


def _load_countries_en() -> dict:
    """Load ISO country code -> English name mapping.

    Returns an empty dict if the file is missing/unreadable.
    """
    try:
        with open(COUNTRIES_EN_PATH, "r", encoding="utf-8") as f:
            raw = json.load(f)
        # Normalize keys/values
        out: dict[str, str] = {}
        for k, v in (raw or {}).items():
            if not k:
                continue
            out[str(k).upper()] = str(v)
        return out
    except Exception:
        return {}


COUNTRIES_EN = _load_countries_en()

def _load_orbis_conf() -> dict:
    """Load KEY=VALUE pairs from orbis.conf (shell-compatible).

    Returns an empty dict if the file is missing or unreadable.
    """
    for path in ORBIS_CONF_CANDIDATES:
        try:
            if not os.path.exists(path):
                continue
            conf = {}
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                for raw in f:
                    line = raw.strip()
                    if not line or line.startswith("#"):
                        continue
                    if "#" in line:
                        line = line.split("#", 1)[0].strip()
                    if "=" not in line:
                        continue
                    k, v = line.split("=", 1)
                    conf[k.strip()] = v.strip().strip('"').strip("'")
            return conf
        except Exception:
            continue
    return {}
PENDING_USER_FILE = Path('/etc/orbis_user_pending.json')
ISO_COUNTRY_CODES = ['AF', 'AX', 'AL', 'DZ', 'AS', 'AD', 'AO', 'AI', 'AQ', 'AG', 'AR', 'AM', 'AW', 'AU', 'AT', 'AZ', 'BS', 'BH', 'BD', 'BB', 'BY', 'BE', 'BZ', 'BJ', 'BM', 'BT', 'BO', 'BQ', 'BA', 'BW', 'BV', 'BR', 'IO', 'BN', 'BG', 'BF', 'BI', 'CV', 'KH', 'CM', 'CA', 'KY', 'CF', 'TD', 'CL', 'CN', 'CX', 'CC', 'CO', 'KM', 'CG', 'CD', 'CK', 'CR', 'CI', 'HR', 'CU', 'CW', 'CY', 'CZ', 'DK', 'DJ', 'DM', 'DO', 'EC', 'EG', 'SV', 'GQ', 'ER', 'EE', 'SZ', 'ET', 'FK', 'FO', 'FJ', 'FI', 'FR', 'GF', 'PF', 'TF', 'GA', 'GM', 'GE', 'DE', 'GH', 'GI', 'GR', 'GL', 'GD', 'GP', 'GU', 'GT', 'GG', 'GN', 'GW', 'GY', 'HT', 'HM', 'VA', 'HN', 'HK', 'HU', 'IS', 'IN', 'ID', 'IR', 'IQ', 'IE', 'IM', 'IL', 'IT', 'JM', 'JP', 'JE', 'JO', 'KZ', 'KE', 'KI', 'KP', 'KR', 'KW', 'KG', 'LA', 'LV', 'LB', 'LS', 'LR', 'LY', 'LI', 'LT', 'LU', 'MO', 'MG', 'MW', 'MY', 'MV', 'ML', 'MT', 'MH', 'MQ', 'MR', 'MU', 'YT', 'MX', 'FM', 'MD', 'MC', 'MN', 'ME', 'MS', 'MA', 'MZ', 'MM', 'NA', 'NR', 'NP', 'NL', 'NC', 'NZ', 'NI', 'NE', 'NG', 'NU', 'NF', 'MK', 'MP', 'NO', 'OM', 'PK', 'PW', 'PS', 'PA', 'PG', 'PY', 'PE', 'PH', 'PN', 'PL', 'PT', 'PR', 'QA', 'RE', 'RO', 'RU', 'RW', 'BL', 'SH', 'KN', 'LC', 'MF', 'PM', 'VC', 'WS', 'SM', 'ST', 'SA', 'SN', 'RS', 'SC', 'SL', 'SG', 'SX', 'SK', 'SI', 'SB', 'SO', 'ZA', 'GS', 'SS', 'ES', 'LK', 'SD', 'SR', 'SJ', 'SE', 'CH', 'SY', 'TW', 'TJ', 'TZ', 'TH', 'TL', 'TG', 'TK', 'TO', 'TT', 'TN', 'TR', 'TM', 'TC', 'TV', 'UG', 'UA', 'AE', 'GB', 'US', 'UM', 'UY', 'UZ', 'VU', 'VE', 'VN', 'VG', 'VI', 'WF', 'EH', 'YE', 'ZM', 'ZW']

try:
    import pycountry  # type: ignore
except Exception:  # pragma: no cover
    pycountry = None


def _get_country_options() -> list[dict]:
    """Return a list of country options with English names.

    Each item is: {"code": "DE", "name": "Germany"}
    """
    # Preferred: static JSON mapping (stable; no external deps).
    if COUNTRIES_EN:
        items = []
        for code in ISO_COUNTRY_CODES:
            name = COUNTRIES_EN.get(code, code)
            items.append({"code": code, "name": name})
        items.sort(key=lambda x: (x.get("name", ""), x.get("code", "")))
        return items

    if pycountry is None:
        # Fallback: show codes only.
        return [{"code": c, "name": c} for c in ISO_COUNTRY_CODES]

    items: list[dict] = []
    for code in ISO_COUNTRY_CODES:
        try:
            rec = pycountry.countries.get(alpha_2=code)
            name = rec.name if rec else code
        except Exception:
            name = code
        items.append({"code": code, "name": name})

    # Sort by name for usability; keep code as tie-breaker.
    items.sort(key=lambda x: (x.get("name", ""), x.get("code", "")))
    return items


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


# ---------------------------------------------------------------------------
# Wi-Fi encryption capability detection (best-effort)
#
# We expose common encryption choices in the UI, but only enable modes that
# are supported by the underlying kernel/driver for the mesh adapters.
#
# Detection strategy:
# - Determine wiphy index for each interface: `iw dev <if> info` -> "wiphy N"
# - Inspect `iw phy phyN info` for "Supported AKM suites:".
# - Map AKM suites to UI options:
#     00-0f-ac:2 -> PSK (WPA2)
#     00-0f-ac:8 -> SAE (WPA3)
#
# Notes:
# - This is intentionally conservative. If detection fails, we fall back to a
#   safe, broadly supported set.
# - OPEN is always offered.
# ---------------------------------------------------------------------------

AKM_PSK = "00-0f-ac:2"
AKM_SAE = "00-0f-ac:8"


def _iface_exists(ifname: str) -> bool:
    try:
        r = subprocess.run(["ip", "link", "show", ifname], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return r.returncode == 0
    except Exception:
        return False


def _get_wiphy_index(ifname: str) -> Optional[int]:
    try:
        r = subprocess.run(["iw", "dev", ifname, "info"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if r.returncode != 0:
            return None
        m = re.search(r"\bwiphy\s+(\d+)", r.stdout)
        if not m:
            return None
        return int(m.group(1))
    except Exception:
        return None


def _list_wifi_ifaces() -> list[str]:
    """List Wi-Fi interfaces for mesh selection.

    IMPORTANT: wlan0 is intentionally ignored (it is the end-device AP).
    """
    try:
        base = Path("/sys/class/net")
        if not base.exists():
            return []
        ifaces = []
        for p in base.iterdir():
            name = p.name
            if not name.startswith("wlan"):
                continue
            if name == "wlan0":
                continue
            if _iface_exists(name):
                ifaces.append(name)
        # Stable order: wlan1, wlan2, ...
        ifaces.sort(key=lambda s: (len(s), s))
        return ifaces
    except Exception:
        return []


def _get_iface_description(ifname: str) -> str:
    """Best-effort human-friendly adapter description."""
    # Prefer udev database names if available.
    try:
        r = subprocess.run(
            ["udevadm", "info", "--query=property", f"--path=/sys/class/net/{ifname}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if r.returncode == 0:
            props = {}
            for line in (r.stdout or "").splitlines():
                if "=" not in line:
                    continue
                k, v = line.split("=", 1)
                props[k.strip()] = v.strip()
            vendor = props.get("ID_VENDOR_FROM_DATABASE") or props.get("ID_VENDOR") or ""
            model = props.get("ID_MODEL_FROM_DATABASE") or props.get("ID_MODEL") or ""
            s = " ".join([x for x in [vendor, model] if x]).strip()
            if s:
                return s
    except Exception:
        pass

    # Fallback: driver name.
    try:
        r = subprocess.run(["ethtool", "-i", ifname], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if r.returncode == 0:
            m = re.search(r"^driver:\s*(.+)$", r.stdout or "", re.MULTILINE)
            if m:
                return m.group(1).strip()
    except Exception:
        pass

    return "Wi-Fi adapter"


def _iface_supports_mesh(ifname: str) -> bool:
    """Return True if the interface's PHY reports 'mesh point' mode."""
    try:
        wiphy = _get_wiphy_index(ifname)
        if wiphy is None:
            return False
        r = subprocess.run(["iw", "phy", f"phy{wiphy}", "info"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if r.returncode != 0:
            return False
        t = (r.stdout or "").lower()
        return "supported interface modes" in t and "mesh point" in t
    except Exception:
        return False


def _iface_supported_bands(ifname: str) -> list[str]:
    """Best-effort band detection from iw phy output."""
    bands: list[str] = []
    try:
        wiphy = _get_wiphy_index(ifname)
        if wiphy is None:
            return bands
        r = subprocess.run(["iw", "phy", f"phy{wiphy}", "info"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if r.returncode != 0:
            return bands
        out = r.stdout or ""
        freqs = _parse_phy_frequencies_mhz(out)
        if any(2400 <= f <= 2500 for f in freqs):
            bands.append("2.4GHz")
        if any(4900 <= f <= 5900 for f in freqs):
            bands.append("5GHz")
        return bands
    except Exception:
        return bands


def _parse_phy_frequencies_mhz(iw_phy_output: str) -> set[int]:
    """Parse all frequency entries (MHz) from `iw phy ... info` output.

    We intentionally DO NOT filter on '(disabled)' here. The UI's Country Code
    selection is treated as the primary regdom selector, and drivers may mark
    channels disabled until regdom is applied.
    """
    freqs: set[int] = set()
    if not iw_phy_output:
        return freqs
    for line in iw_phy_output.splitlines():
        # Typical lines: "* 2412.0 MHz [1] (20.0 dBm)" or "* 5180 MHz [36]"
        m = re.search(r"\*\s*([0-9]+(?:\.[0-9]+)?)\s*MHz\s*\[", line)
        if not m:
            continue
        try:
            mhz = int(float(m.group(1)))
            freqs.add(mhz)
        except Exception:
            continue
    return freqs


def _allowed_channels_for_country(country_code: str, bands: list[str]) -> list[dict]:
    """Return a conservative allowed channel list for a given Country Code.

    This is driven by the UI's Country Code dropdown (live). The list is
    intentionally conservative for 5 GHz to avoid offering channels that are
    commonly restricted outside their primary regions.
    """
    cc = (country_code or "").upper()
    out: list[dict] = []

    if "2.4GHz" in bands and RF_CHANNEL_DB.get("2.4GHz"):
        max_ch = _max_channel_24ghz(cc)
        for ch in range(1, max_ch + 1):
            freq = RF_CHANNEL_DB["2.4GHz"].get(ch)
            if freq:
                out.append({"band": "2.4GHz", "channel": ch, "freq_mhz": int(freq)})

    if "5GHz" in bands and RF_CHANNEL_DB.get("5GHz"):
        # Base 5 GHz channel sets.
        unii1 = [36, 40, 44, 48]
        unii2 = [52, 56, 60, 64]
        # UNII-2e (DFS) common set.
        unii2e = list(range(100, 145, 4))  # 100..144
        # UNII-3 is primarily allowed in US/CA/MX (conservative).
        unii3 = [149, 153, 157, 161, 165] if cc in ("US", "CA", "MX") else []

        # Include channels that exist in our global mapping.
        for ch in (unii1 + unii2 + unii2e + unii3):
            freq = RF_CHANNEL_DB["5GHz"].get(ch)
            if not freq:
                continue
            out.append({"band": "5GHz", "channel": ch, "freq_mhz": int(freq)})

    # Stable sort: band then channel.
    band_order = {"2.4GHz": 0, "5GHz": 1}
    out.sort(key=lambda x: (band_order.get(x.get("band", ""), 9), int(x.get("channel", 0))))
    return out


def _parse_supported_akm_suites(iw_phy_output: str) -> set[str]:
    suites: set[str] = set()
    if not iw_phy_output:
        return suites

    lines = iw_phy_output.splitlines()
    in_block = False
    for line in lines:
        if not in_block:
            if "Supported AKM suites" in line:
                in_block = True
            continue

        # End of block: next header or empty line without indentation.
        if not line.strip():
            break
        # Expect lines like: "\t* 00-0f-ac:2"
        m = re.search(r"\b([0-9a-f]{2}(?:-[0-9a-f]{2}){2}:[0-9a-f]{1,2})\b", line.strip(), re.IGNORECASE)
        if m:
            suites.add(m.group(1).lower())
        else:
            # Some iw variants print plain names; ignore.
            pass
    return suites


def _extract_supported_akm_block_lines(iw_phy_output: str) -> list[str]:
    """Return the raw lines belonging to the "Supported AKM suites" block.

    Different iw/kernel versions present the information slightly differently.
    We use this helper to enable robust name-based detection (PSK/SAE) in
    addition to suite-OUI detection.
    """
    if not iw_phy_output:
        return []

    lines = iw_phy_output.splitlines()
    in_block = False
    block: list[str] = []
    for line in lines:
        if not in_block:
            if "Supported AKM suites" in line:
                in_block = True
            continue

        # End of block on blank line (typical iw output)
        if not line.strip():
            break

        block.append(line)

    return block


def _supports_sae(iw_phy_output: str, akm_suites: set[str]) -> bool:
    """Best-effort detection of SAE (WPA3-Personal) support.

    Some platforms list SAE via suite OUI (00-0f-ac:8) and/or a named entry
    ("* SAE"). Others expose only a capability sentence such as:
      "Device supports SAE with AUTHENTICATE command"
    """
    t = (iw_phy_output or "").lower()
    if AKM_SAE in akm_suites:
        return True

    # Name-based detection inside the AKM block.
    for line in _extract_supported_akm_block_lines(iw_phy_output):
        if re.search(r"(^|\s)\*\s*sae(\s|$)", line.lower()):
            return True

    # Capability sentence variant.
    if "device supports sae" in t or "supports sae with authenticate" in t:
        return True

    return False


def _supports_psk(iw_phy_output: str, akm_suites: set[str]) -> bool:
    """Best-effort detection of PSK (WPA2-Personal) support.

    Real-world `iw phy ... info` output varies significantly by kernel/iw
    version and driver. Some stacks list PSK explicitly in the "Supported AKM
    suites" block (as OUI 00-0f-ac:2 and/or "PSK" / "PSK-SHA256"). Others do
    not list the AKM name, but do expose the relevant cipher suites (CCMP/TKIP)
    which still indicates WPA2 capability for Personal networks.

    We therefore treat PSK as supported when *any* of the following holds:
      - AKM OUI 00-0f-ac:2 is present
      - "PSK" appears in the AKM block
      - Common WPA2 pairwise ciphers appear in the phy capabilities (CCMP/TKIP)
    """
    if AKM_PSK in akm_suites:
        return True

    # Name-based: iw may print "PSK" or "PSK-SHA256".
    for line in _extract_supported_akm_block_lines(iw_phy_output):
        if re.search(r"\bpsk\b", line.lower()):
            return True

    # Cipher-based fallback: many drivers expose CCMP/TKIP but omit PSK names.
    t = (iw_phy_output or "").lower()
    if "ccmp" in t or "tkip" in t:
        return True

    return False


def _get_iface_encryption_support(ifname: str) -> set[str]:
    """Return supported encryption modes for a given interface.

    Returned values are UI/storage keys:
      - OPEN
      - WPA2 (PSK)
      - SAE (WPA3)
      - WPA2_WPA3 (transition)
    """
    supported = {"OPEN"}

    try:
        wiphy = _get_wiphy_index(ifname)
        if wiphy is None:
            return supported

        r = subprocess.run(["iw", "phy", f"phy{wiphy}", "info"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if r.returncode != 0:
            return supported

        out = r.stdout or ""
        akm = _parse_supported_akm_suites(out)

        has_psk = _supports_psk(out, akm)
        has_sae = _supports_sae(out, akm)

        if has_psk:
            supported.add("WPA2")
        if has_sae:
            supported.add("SAE")
        if has_psk and has_sae:
            supported.add("WPA2_WPA3")

        return supported
    except Exception:
        return supported


def _get_mesh_encryption_options() -> list[dict]:
    """Compute encryption options enabled by BOTH wlan1 and wlan2.

    If wlan2 does not exist, it is ignored (not an error).
    """
    # IMPORTANT: wlan0 is intentionally ignored (it is the end-device AP).
    # We only consider mesh adapters wlan1 and (optionally) wlan2.

    # Determine support set for wlan1. If wlan1 is missing, degrade gracefully.
    s1 = _get_iface_encryption_support("wlan1") if _iface_exists("wlan1") else {"OPEN", "WPA2", "SAE", "WPA2_WPA3"}
    has_wlan2 = _iface_exists("wlan2")
    s2 = _get_iface_encryption_support("wlan2") if has_wlan2 else set()

    supported = s1.intersection(s2) if has_wlan2 else s1

    # Stable ordering for UI.
    all_opts = [
        {"value": "SAE", "label": "WPA3 (SAE)"},
        {"value": "WPA2_WPA3", "label": "WPA2/WPA3 (Transition)"},
        {"value": "WPA2", "label": "WPA2 (PSK)"},
        {"value": "OPEN", "label": "OPEN"},
    ]
    for o in all_opts:
        v = o["value"]
        enabled = v in supported
        o["enabled"] = enabled
        if enabled:
            o["reason"] = ""
            continue

        missing: list[str] = []
        if v not in s1:
            missing.append("wlan1")
        if has_wlan2 and v not in s2:
            missing.append("wlan2")
        if missing:
            o["reason"] = f"Not supported by {', '.join(missing)}"
        else:
            o["reason"] = "Not supported"
    return all_opts


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


def _restart_network_stack_for_mesh() -> list[str]:
    """Apply mesh-related configuration changes without reboot.

    Returns:
        A list of human-readable warnings for units/commands that could not be
        started/restarted (best-effort execution).

    Order is important:
      1) orbis-networkd-generate.service (regenerates config files)
      2) Core networking services
      3) mesh-startup.service (rejoins mesh / restarts batman)
    """

    ordered_cmds: list[list[str]] = [
        ["systemctl", "start", "orbis-networkd-generate.service"],
        ["systemctl", "restart", "systemd-networkd"],
                ["systemctl", "restart", "dnsmasq"],
        ["systemctl", "restart", "hostapd"],
        ["systemctl", "restart", "mesh-startup.service"],
                    ]

    warnings: list[str] = []
    for cmd in ordered_cmds:
        try:
            r = _run_sudo(cmd)
            if r.returncode != 0:
                # Best-effort: some units may not exist on certain images.
                err = (r.stderr or r.stdout or "").strip()
                if err:
                    warnings.append(f"{' '.join(cmd)}: {err}")
                else:
                    warnings.append(f"{' '.join(cmd)}: failed")
        except Exception as e:
            warnings.append(f"{' '.join(cmd)}: {e}")

    return warnings


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


# ---------------------------------------------------------------------------
# Static asset cache-busting (prevents stale CSS/JS across pages)
# ---------------------------------------------------------------------------
_STATIC_ROOT = Path(__file__).resolve().parent / "static"

def _asset_mtime(rel_path: str) -> int:
    try:
        return int(os.path.getmtime(_STATIC_ROOT / rel_path))
    except Exception:
        return 0

@app.context_processor
def inject_asset_versions():
    return {
        "asset_v_css": _asset_mtime("css/main.css"),
        "asset_v_js": _asset_mtime("js/main.js"),
    }

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
            timeout=1.0,  # 1 Sekunden Timeout (Pi Zero kann sonst hängen)
            check=False,
        )
        status = result.stdout.strip()
        if status == "active":
            return True
        if status in {"inactive", "failed"}:
            return False
        return None
    except subprocess.TimeoutExpired:
        # Bei Timeout: Fallback auf Cached Status oder None
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



# ---------------------------------------------------------------------------
# Uplink reachability cache - now updated by background thread (not directly queried)
# ---------------------------------------------------------------------------
# (moved to background thread to avoid blocking requests)

# ---------------------------------------------------------------------------
# Service Status Cache (to avoid repeated systemctl queries)
# ---------------------------------------------------------------------------
_SERVICE_STATUS_CACHE_TTL = 5.0  # 5 Sekunden (Service-Status ändert sich selten)
_service_status_cache_lock = threading.Lock()
_service_status_cache_ts = 0.0
_service_status_cache_data = {}
_systemctl_update_thread = None

# Uplink cache (auch in Background-Thread aktualisiert)
_uplink_cache_lock_bg = threading.Lock()
_uplink_cache_data_bg = False

def _systemctl_update_loop():
    """Background thread: aktualisiert Service Status alle 5 Sekunden, Uplink alle 10 Sekunden (non-blocking)"""
    global _service_status_cache_ts, _service_status_cache_data, _uplink_cache_data_bg
    uplink_counter = 0
    while True:
        try:
            # Aktualisiere Service-Status in Hintergrund-Thread (blockiert nicht den Request-Handler)
            services = {
                "mesh_monitor": _check_systemd_active("mesh-monitor.service"),
                "ogm_monitor": _check_systemd_active("ogm-monitor.service"),
                "hostapd": _check_systemd_active("hostapd.service"),
                "dnsmasq": _check_systemd_active("dnsmasq.service"),
            }
            with _service_status_cache_lock:
                _service_status_cache_data = services
                _service_status_cache_ts = time.monotonic()
            
            # Aktualisiere Uplink-Status nur alle 10 Sekunden (2x pro _SERVICE_STATUS_CACHE_TTL-Zyklus)
            uplink_counter += 1
            if uplink_counter >= 2:
                uplink_ok = _check_uplink_ok(timeout_seconds=0.5)
                with _uplink_cache_lock_bg:
                    _uplink_cache_data_bg = uplink_ok
                uplink_counter = 0
            
            # Warte 5 Sekunden vor nächstem Update
            time.sleep(_SERVICE_STATUS_CACHE_TTL)
        except Exception as e:
            print(f"[systemctl-bg] error: {e}")

def _get_service_status_cached(service_name: str) -> bool | None:
    """Return cached systemd unit status (never blocks the request handler)."""
    with _service_status_cache_lock:
        return _service_status_cache_data.get(service_name)

# ---------------------------------------------------------------------------
# Wi-Fi Adapter Cache (to avoid repeated iw phy queries)
# ---------------------------------------------------------------------------
_IFACE_CACHE_TTL_SECONDS = 30.0
_iface_cache_lock = threading.Lock()
_iface_cache_last_check_ts = 0.0
_iface_cache_data = {
    "adapters": [],
    "bands": {},       # ifname -> [bands]
    "capabilities": {} # ifname -> {support: bool, bands: [...]}
}

def _invalidate_iface_cache():
    """Force refresh of interface cache on next query."""
    global _iface_cache_last_check_ts
    with _iface_cache_lock:
        _iface_cache_last_check_ts = 0.0

def _get_uplink_ok_cached() -> bool:
    """Return cached uplink status (updated by background thread every 5s, never blocks)."""
    global _uplink_cache_data_bg
    with _uplink_cache_lock_bg:
        return _uplink_cache_data_bg
def _check_uplink_ok(timeout_seconds: float = 1.5) -> bool:
    """Return True if outbound connectivity is available via any interface.

    This is intentionally interface-agnostic: if the kernel can route traffic
    (mesh, eth0, etc.) to the public internet, this returns True.
    """
    targets = [
        ("1.1.1.1", 443),  # Cloudflare
        ("8.8.8.8", 53),   # Google DNS
        ("9.9.9.9", 53),   # Quad9 DNS
    ]
    for host, port in targets:
        try:
            sock = socket.create_connection((host, port), timeout=timeout_seconds)
            sock.close()
            return True
        except OSError:
            continue
    return False


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
def inject_node_ips():
    conf = _load_orbis_conf()
    return {
        "NODE_IP": conf.get("NODE_IP", ""),
        "SSH_IP": conf.get("SSH_IP", ""),
    }

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
    """Return MAC address and status of local node services/interfaces as JSON.
    
    Optimized: Uses cached systemd checks (2s TTL) + cached interface checks
    to avoid repeated blocking subprocess calls.
    """
    mac_wlan1 = _read_mac_address("wlan1")

    # Use cached status checks instead of live queries (saves ~3s per request)
    status = {
        "mesh_monitor": _get_service_status_cached("mesh_monitor"),
        "ogm_monitor": _get_service_status_cached("ogm_monitor"),
        "hostapd": _get_service_status_cached("hostapd"),
        "dnsmasq": _get_service_status_cached("dnsmasq"),
        "br0": _check_interface_up("br0"),    # Fast: /sys filesystem read
        "wlan1": _check_interface_up("wlan1"), # Fast: /sys filesystem read
        "eth0": _check_interface_up("eth0"),   # Fast: /sys filesystem read
        "uplink": _get_uplink_ok_cached(),
    }

    return jsonify(
        {
            "mac_wlan1": mac_wlan1,
            "status": status,
        }
    )

# -----------------------------------------------------------------------------
# Mesh adapter/channel API (Mesh Config)
# -----------------------------------------------------------------------------


@app.route("/api/mesh-adapters")
@login_required
def api_mesh_adapters():
    """Return mesh-capable Wi-Fi adapters (excluding wlan0)."""
    conf = _load_orbis_conf()
    current_if = conf.get("IF", "").strip().strip('"').strip("'")

    adapters = []
    for ifname in _list_wifi_ifaces():
        adapters.append(
            {
                "ifname": ifname,
                "description": _get_iface_description(ifname),
                "mesh_supported": _iface_supports_mesh(ifname),
                "bands": _iface_supported_bands(ifname),
            }
        )

    return jsonify({"adapters": adapters, "current_if": current_if})


@app.route("/api/mesh-channels")
@login_required
def api_mesh_channels():
    """Return channel list for a given adapter and Country Code.

    Country Code is taken from the UI (live) via query parameter "country".
    """
    ifname = (request.args.get("ifname") or "").strip()
    country = (request.args.get("country") or "").strip().upper()

    if not ifname or not _iface_exists(ifname) or ifname == "wlan0":
        return jsonify({"channels": []})

    if not country or country not in ISO_COUNTRY_CODES:
        # Fall back to config COUNTRY if the UI didn't provide a valid one.
        conf = _load_orbis_conf()
        country = (conf.get("COUNTRY") or "").strip().upper()

    if not country or country not in ISO_COUNTRY_CODES:
        return jsonify({"channels": []})

    if not _iface_supports_mesh(ifname):
        return jsonify({"channels": []})

    # Determine supported frequencies from the adapter's PHY. This is used to
    # filter out channels the hardware does not provide (but we do not treat
    # '(disabled)' as disqualifying here, because the UI's country selection is
    # the primary regdom selector).
    wiphy = _get_wiphy_index(ifname)
    if wiphy is None:
        return jsonify({"channels": []})

    r = subprocess.run(["iw", "phy", f"phy{wiphy}", "info"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if r.returncode != 0:
        return jsonify({"channels": []})

    phy_freqs = _parse_phy_frequencies_mhz(r.stdout or "")
    bands = _iface_supported_bands(ifname)
    allowed = _allowed_channels_for_country(country, bands)
    channels = [c for c in allowed if int(c.get("freq_mhz", 0)) in phy_freqs]

    conf = _load_orbis_conf()
    current_frequency1 = conf.get("MESH_FREQUENCY1", "").strip().strip('"').strip("'")

    return jsonify(
        {
            "ifname": ifname,
            "country": country,
            "phy": f"phy{wiphy}",
            "bands": bands,
            "channels": channels,
            "current_frequency1": current_frequency1,
        }
    )


@app.route("/api/band-scan")
@login_required
def api_band_scan():
    """Scan all available bands on wlan1 and return channels sorted by quality.
    
    Returns channels organized by band (2.4GHz, 5GHz, 6GHz) with quality metrics.
    Channels are sorted from best (lowest interference) to worst (highest interference).
    """
    ifname = "wlan1"
    
    # Check if wlan1 exists
    if not _iface_exists(ifname):
        return jsonify({"error": "Interface wlan1 not found"}), 404
    
    # Get the PHY for wlan1
    wiphy = _get_wiphy_index(ifname)
    if wiphy is None:
        return jsonify({"error": "Could not determine PHY for wlan1"}), 500
    
    # Perform the scan
    try:
        # Check current interface mode
        iw_info = subprocess.run(
            ["iw", "dev", ifname, "info"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5
        )
        current_mode = "unknown"
        if iw_info.returncode == 0:
            for line in iw_info.stdout.splitlines():
                if "type" in line.lower():
                    current_mode = line.strip()
                    break
        
        # Try scanning with the interface in its current mode first
        scan_result = subprocess.run(
            ["iw", "dev", ifname, "scan"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=30
        )
        
        scan_stderr = scan_result.stderr
        scan_stdout = scan_result.stdout
        
        # If scan failed and interface is in mesh mode, try passive scan or use different approach
        if scan_result.returncode != 0:
            # Try with "scan passive" for mesh interfaces
            scan_result = subprocess.run(
                ["iw", "dev", ifname, "scan", "passive"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=30
            )
            scan_stderr = scan_result.stderr
            scan_stdout = scan_result.stdout
            
            if scan_result.returncode != 0:
                return jsonify({
                    "error": f"Scan failed: {scan_stderr}",
                    "interface_mode": current_mode,
                    "note": "Interface may be busy or in mesh mode. Try disabling mesh temporarily."
                }), 500
        
        # Parse scan results
        scan_output = scan_stdout
        
        # Dictionary to track channel usage and interference
        # Key: frequency in MHz, Value: list of signal strengths
        channel_usage = {}
        
        # Parse the scan output
        current_bss = {}
        for line in scan_output.splitlines():
            line = line.strip()
            
            # New BSS entry
            if line.startswith("BSS"):
                if current_bss and "freq" in current_bss and "signal" in current_bss:
                    freq = current_bss["freq"]
                    signal = current_bss["signal"]
                    if freq not in channel_usage:
                        channel_usage[freq] = []
                    channel_usage[freq].append(signal)
                current_bss = {}
            
            # Frequency
            elif line.startswith("freq:"):
                try:
                    freq_str = line.split(":", 1)[1].strip()
                    # Handle frequencies like "2462.0" - convert to int MHz
                    current_bss["freq"] = int(float(freq_str))
                except (ValueError, IndexError):
                    pass
            
            # Signal strength
            elif line.startswith("signal:"):
                try:
                    # Format: "signal: -XX.00 dBm"
                    signal_str = line.split(":", 1)[1].strip()
                    signal_dbm = float(signal_str.split()[0])
                    current_bss["signal"] = signal_dbm
                except (ValueError, IndexError):
                    pass
        
        # Don't forget the last BSS
        if current_bss and "freq" in current_bss and "signal" in current_bss:
            freq = current_bss["freq"]
            signal = current_bss["signal"]
            if freq not in channel_usage:
                channel_usage[freq] = []
            channel_usage[freq].append(signal)
        
        # Get all supported frequencies for this adapter
        phy_result = subprocess.run(
            ["iw", "phy", f"phy{wiphy}", "info"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5
        )
        
        if phy_result.returncode != 0:
            return jsonify({"error": "Could not get PHY info"}), 500
        
        supported_freqs = _parse_phy_frequencies_mhz(phy_result.stdout)
        
        # Create channel list with quality scores
        channels_by_band = {
            "2.4GHz": [],
            "5GHz": [],
            "6GHz": []
        }
        
        # Map frequency to channel number
        freq_to_channel = {}
        for band, channels_map in RF_CHANNEL_DB.items():
            for ch, freq in channels_map.items():
                freq_to_channel[int(freq)] = {"channel": ch, "band": band}
        
        # Helper function to calculate channel overlap interference
        def calculate_interference(target_freq, band_name):
            """Calculate interference for a given frequency considering channel overlap.
            
            For 2.4GHz: Channels overlap ±20-25 MHz (about 4-5 channels)
            For 5GHz: Channels are usually non-overlapping (20 MHz apart)
            """
            interfering_signals = []
            
            if band_name == "2.4GHz":
                # 2.4GHz channels overlap significantly
                # Each channel is 5 MHz apart but has 22 MHz bandwidth
                # So channels within ±25 MHz can cause interference
                overlap_range = 25
            elif band_name == "5GHz":
                # 5GHz channels are typically 20 MHz wide and non-overlapping
                # But adjacent channels can still cause some interference
                overlap_range = 20
            else:  # 6GHz
                overlap_range = 20
            
            for detected_freq, signals in channel_usage.items():
                freq_diff = abs(detected_freq - target_freq)
                
                if freq_diff <= overlap_range:
                    # Calculate interference factor based on distance
                    if freq_diff == 0:
                        # Same channel - full interference
                        interference_factor = 1.0
                    else:
                        # Adjacent/overlapping channel - reduced interference
                        # Linear falloff based on frequency distance
                        interference_factor = 1.0 - (freq_diff / overlap_range)
                    
                    # Add weighted signals
                    for signal in signals:
                        interfering_signals.append((signal, interference_factor))
            
            return interfering_signals
        
        for freq in supported_freqs:
            if freq not in freq_to_channel:
                continue
            
            channel_info = freq_to_channel[freq]
            channel = channel_info["channel"]
            band = channel_info["band"]
            
            # Calculate interference from all nearby channels
            interfering_signals = calculate_interference(freq, band)
            
            # Calculate quality score
            # Lower is better (less interference)
            if interfering_signals:
                # Calculate weighted interference
                total_interference = 0
                total_weight = 0
                network_count = 0
                
                for signal_dbm, weight in interfering_signals:
                    # Convert dBm to a linear scale for better perception
                    # Stronger signals (less negative) are worse
                    # -30 dBm is very strong (bad), -90 dBm is very weak (good)
                    interference_value = (100 + signal_dbm) * weight  # Scale to 0-100 range
                    total_interference += interference_value
                    total_weight += weight
                    network_count += weight  # Count fractional networks based on interference
                
                # Average signal strength for display
                avg_signal = sum(s for s, w in interfering_signals) / len(interfering_signals)
                
                # Quality score: weighted sum of interference
                # Network count contributes significantly
                # Signal strength contributes to overall interference
                quality_score = (network_count * 15) + total_interference
                network_count = int(round(network_count))  # Round for display
            else:
                # No networks detected - perfect!
                quality_score = 0
                avg_signal = None
                network_count = 0
            
            channel_data = {
                "channel": channel,
                "frequency": freq,
                "quality_score": round(quality_score, 2),
                "networks": network_count,
                "avg_signal": round(avg_signal, 2) if avg_signal is not None else None
            }
            
            if band in channels_by_band:
                channels_by_band[band].append(channel_data)
        
        # Sort channels by quality (best first)
        for band in channels_by_band:
            channels_by_band[band].sort(key=lambda x: x["quality_score"])
        
        # Add debug information about detected networks
        detected_networks = []
        for freq, signals in channel_usage.items():
            if freq in freq_to_channel:
                ch_info = freq_to_channel[freq]
                detected_networks.append({
                    "channel": ch_info["channel"],
                    "frequency": freq,
                    "band": ch_info["band"],
                    "count": len(signals),
                    "signals": [round(s, 1) for s in signals]
                })
        detected_networks.sort(key=lambda x: (x["band"], x["channel"]))
        
        return jsonify({
            "ifname": ifname,
            "bands": channels_by_band,
            "scan_time": datetime.now().isoformat(),
            "detected_networks": detected_networks,
            "total_networks_found": sum(len(signals) for signals in channel_usage.values()),
            "interface_mode": current_mode,
            "raw_scan_output": scan_stdout[:2000] if scan_stdout else "No output"  # First 2000 chars for debugging
        })
        
    except subprocess.TimeoutExpired:
        return jsonify({"error": "Scan timeout - operation took too long"}), 500
    except Exception as e:
        import traceback
        return jsonify({"error": f"Scan failed: {str(e)}", "traceback": traceback.format_exc()}), 500


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



@app.route("/network-config", methods=["GET", "POST"])
@login_required
def network_config():
    """Mesh configuration page."""

    conf_path = _get_orbis_conf_path()
    conf = _load_orbis_conf()

    if request.method == "POST":
        action = (request.form.get("action") or "").strip()

        if action == "save_identity":
            new_node_name = (request.form.get("new_node_name") or "").strip()
            new_node_id = (request.form.get("new_node_id") or "").strip()

            # Validate Node Name (conservative, hostname-compatible)
            if not new_node_name or len(new_node_name) > 63:
                flash("Invalid Node Name. Please use 1–63 characters.", "error")
                return redirect(url_for("network_config"))

            # Allow spaces in the UI but keep file value quoted; reject control chars
            if any(ord(c) < 32 for c in new_node_name):
                flash("Invalid Node Name.", "error")
                return redirect(url_for("network_config"))

            # Validate Node ID (positive integer)
            if not new_node_id.isdigit() or int(new_node_id) <= 0:
                flash("Invalid Node ID. Please use a positive integer.", "error")
                return redirect(url_for("network_config"))

            _write_kv_line(conf_path, "NODE_ID", str(int(new_node_id)))
            # Quote the name to remain shell-compatible and preserve spaces.
            safe_name = new_node_name.replace('"', r'\\"')
            _write_kv_line(conf_path, "NODE_NAME", f'"{safe_name}"')

            flash("Identity has been saved.", "success")
            return redirect(url_for("network_config"))

        if action == "save_mesh_params":
            new_mesh_ssid = (request.form.get("new_mesh_ssid") or "").strip()
            new_mesh_password = (request.form.get("new_mesh_password") or "").strip()
            mesh_hop_limit = (request.form.get("mesh_hop_limit") or "").strip()
            mesh_country_code = (request.form.get("mesh_country_code") or "").strip().upper()
            mesh_encryption = (request.form.get("mesh_encryption") or "").strip().upper()

            # Validate SSID (IEEE 802.11: 1..32 bytes; we enforce 1..32 chars conservatively)
            if new_mesh_ssid:
                if len(new_mesh_ssid) > 32 or any(ord(c) < 32 for c in new_mesh_ssid):
                    flash("Invalid Mesh SSID. Please use up to 32 printable characters.", "error")
                    return redirect(url_for("network_config"))
                # Preserve spaces by quoting for shell-compat.
                safe_ssid = new_mesh_ssid.replace('"', r'\\"')
                _write_kv_line(conf_path, "MESH_SSID", f'"{safe_ssid}"')

            # Hop Limit is optional; validate if provided
            if mesh_hop_limit:
                if not mesh_hop_limit.isdigit() or not (1 <= int(mesh_hop_limit) <= 255):
                    flash("Invalid Hop Limit. Please use a value between 1 and 255.", "error")
                    return redirect(url_for("network_config"))
                _write_kv_line(conf_path, "MESH_HOP_LIMIT", str(int(mesh_hop_limit)))

            # Password is optional; if provided, store as-is (shell-compatible).
            if new_mesh_password:
                # Conservative: 8..63 for WPA2/WPA3 PSK/SAE; keep permissive for now.
                if any(ord(c) < 32 for c in new_mesh_password):
                    flash("Invalid Mesh Password.", "error")
                    return redirect(url_for("network_config"))
                safe_pw = new_mesh_password.replace('"', r'\\"')
                # New key requested by the UI.
                _write_kv_line(conf_path, "MESH_PASSWORD", f'"{safe_pw}"')
                # Backwards compatibility with current config naming.
                _write_kv_line(conf_path, "SAE_PASSWORD", f'"{safe_pw}"')

            # Country code is reused from Local Network and stored in orbis.conf as COUNTRY.
            if not mesh_country_code or mesh_country_code not in ISO_COUNTRY_CODES:
                flash("Invalid Country Code.", "error")
                return redirect(url_for("network_config"))
            _write_kv_line(conf_path, "COUNTRY", mesh_country_code)

            # Encryption: only allow modes supported by the mesh adapters.
            enc_opts = _get_mesh_encryption_options()
            enabled_values = {o["value"] for o in enc_opts if o.get("enabled")}
            if mesh_encryption:
                if mesh_encryption not in enabled_values:
                    flash("Selected encryption is not supported by the mesh adapters.", "error")
                    return redirect(url_for("network_config"))
                _write_kv_line(conf_path, "MESH_ENCRYPTION", mesh_encryption)

            warnings = _restart_network_stack_for_mesh()
            if warnings:
                # Keep the user informed but do not block the workflow.
                flash("Mesh parameters saved. Some services reported warnings; check logs.", "warning")
            else:
                flash("Mesh parameters saved and applied.", "success")
            return redirect(url_for("network_config"))

        if action == "save_mesh_adapter":
            mesh_adapter_1 = (request.form.get("mesh_adapter_1") or "").strip()
            mesh_channel_1 = (request.form.get("mesh_channel_1") or "").strip()
            # Live Country Code from the dropdown (passed by JS at submit time).
            mesh_country_code_live = (request.form.get("mesh_country_code_live") or "").strip().upper()

            if not mesh_adapter_1 or not _iface_exists(mesh_adapter_1) or mesh_adapter_1 == "wlan0":
                flash("Invalid mesh adapter.", "error")
                return redirect(url_for("network_config"))

            if not _iface_supports_mesh(mesh_adapter_1):
                flash("Selected adapter does not support mesh.", "error")
                return redirect(url_for("network_config"))

            if not mesh_channel_1.isdigit():
                flash("Invalid channel selection.", "error")
                return redirect(url_for("network_config"))

            if mesh_country_code_live and mesh_country_code_live in ISO_COUNTRY_CODES:
                country = mesh_country_code_live
            else:
                country = (conf.get("COUNTRY") or "").strip().upper()

            if not country or country not in ISO_COUNTRY_CODES:
                flash("Invalid Country Code.", "error")
                return redirect(url_for("network_config"))

            # Validate the selected frequency against the allowed list for the
            # selected adapter and the *live* country selection.
            bands = _iface_supported_bands(mesh_adapter_1)
            allowed = _allowed_channels_for_country(country, bands)
            allowed_freqs = {str(int(x.get("freq_mhz"))) for x in allowed if x.get("freq_mhz")}

            # Also ensure the adapter's PHY actually lists this frequency.
            wiphy = _get_wiphy_index(mesh_adapter_1)
            if wiphy is None:
                flash("Unable to read adapter capabilities.", "error")
                return redirect(url_for("network_config"))
            r = subprocess.run(["iw", "phy", f"phy{wiphy}", "info"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            if r.returncode != 0:
                flash("Unable to read adapter capabilities.", "error")
                return redirect(url_for("network_config"))
            phy_freqs = {str(f) for f in _parse_phy_frequencies_mhz(r.stdout or "")}

            if mesh_channel_1 not in allowed_freqs or mesh_channel_1 not in phy_freqs:
                flash("Selected channel is not available for the chosen adapter/country.", "error")
                return redirect(url_for("network_config"))

            # Persist into orbis.conf.
            _write_kv_line(conf_path, "IF", f'"{mesh_adapter_1}"')
            _write_kv_line(conf_path, "MESH_FREQUENCY1", str(int(mesh_channel_1)))

            warnings = _restart_network_stack_for_mesh()
            if warnings:
                flash("Mesh adapter saved. Some services reported warnings; check logs.", "warning")
            else:
                flash("Mesh adapter saved and applied.", "success")
            return redirect(url_for("network_config"))

        if action == "save_ip":
            ip_address = request.form.get("ip_address", "").strip()
            ip_suffix = request.form.get("ip_suffix", "").strip()

            try:
                import ipaddress
                ipaddress.IPv4Address(ip_address)
            except Exception:
                flash("Invalid IP", "error")
                return redirect(url_for("network_config"))

            if not ip_suffix.isdigit():
                flash("Invalid suffix", "error")
                return redirect(url_for("network_config"))
            suffix_int = int(ip_suffix)
            if suffix_int < 0 or suffix_int > 32:
                flash("Invalid suffix", "error")
                return redirect(url_for("network_config"))

            ip_with_suffix = f"{ip_address}/{suffix_int}"
            _set_br0_address(ip_with_suffix)

            os.system("sudo reboot")
            return ("", 204)

        if action == "save_ssid":
            ssid_value = request.form.get("ssid_value", "").strip()
            wifi_passphrase = request.form.get("wifi_passphrase", "").strip()

            if not ssid_value or len(ssid_value) > 32:
                flash("Invalid SSID", "error")
                return redirect(url_for("network_config"))

            hostapd_file = "/etc/hostapd/hostapd.conf"
            _write_kv_line(hostapd_file, "ssid", ssid_value)

            if wifi_passphrase:
                if len(wifi_passphrase) < 8 or len(wifi_passphrase) > 63:
                    flash("Invalid password length", "error")
                    return redirect(url_for("network_config"))
                _write_kv_line(hostapd_file, "wpa_passphrase", wifi_passphrase)

            os.system("sudo reboot")
            return ("", 204)

        if action == "save_wifi":
            country_code = request.form.get("country_code", "US").strip().upper()
            wifi_channel = request.form.get("wifi_channel", "1").strip()

            if country_code not in ISO_COUNTRY_CODES:
                flash("Invalid country code", "error")
                return redirect(url_for("network_config"))

            if not wifi_channel.isdigit():
                flash("Invalid channel", "error")
                return redirect(url_for("network_config"))

            ch = int(wifi_channel)
            max_ch = _max_channel_24ghz(country_code)
            if ch < 1 or ch > max_ch:
                flash("Channel not allowed for country", "error")
                return redirect(url_for("network_config"))

            hostapd_file = "/etc/hostapd/hostapd.conf"
            _write_kv_line(hostapd_file, "country_code", country_code)
            _write_kv_line(hostapd_file, "channel", str(ch))

            os.system("sudo reboot")
            return ("", 204)

        # Future mesh settings will be handled here.
        flash("No changes were applied.", "info")
        return redirect(url_for("network_config"))

    return render_template(
        "network_config.html",
        branding="Orbis Mesh",
        page_title="Network Config",
        active_page="network_config",
        current_node_name=conf.get("NODE_NAME", ""),
        current_node_id=conf.get("NODE_ID", ""),
        current_mesh_ssid=conf.get("MESH_SSID", ""),
        current_mesh_password=conf.get("MESH_PASSWORD", ""),
        current_mesh_hop_limit=conf.get("MESH_HOP_LIMIT", ""),
        current_mesh_encryption=conf.get("MESH_ENCRYPTION", "SAE"),
        current_country_code=conf.get("COUNTRY", ""),
        current_mesh_if=conf.get("IF", ""),
        current_mesh_frequency1=conf.get("MESH_FREQUENCY1", ""),
        current_node_ip=conf.get("NODE_IP", ""),
        current_node_cidr=conf.get("NODE_CIDR", ""),
        current_dns=conf.get("DNS", ""),
        countries=_get_country_options(),
        mesh_encryption_options=_get_mesh_encryption_options(),
    )


@app.route("/about")
@login_required
def about():
    """About page."""
    return render_template(
        "about.html",
        branding="Orbis Mesh",
        page_title="About",
        active_page="about",
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
    import os
    
    # Starte Background-Thread für Service Status Updates
    # WICHTIG: nur im Reloader-Child-Prozess starten (nicht im Parent)
    if os.environ.get("WERKZEUG_RUN_MAIN") == "true":
        _systemctl_update_thread = threading.Thread(target=_systemctl_update_loop, daemon=True)
        _systemctl_update_thread.start()
    
    # Run on all interfaces so it is reachable over the network
    app.run(host="0.0.0.0", port=5000, debug=True)
