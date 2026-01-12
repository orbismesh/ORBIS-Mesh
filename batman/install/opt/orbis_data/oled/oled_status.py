#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OLED status display for ORBIS Mesh on Raspberry Pi.
Displays:
- Node Name (from /opt/orbis_data/orbis.conf -> NODE_NAME)
- Node ID   (from /opt/orbis_data/orbis.conf -> NODE_ID)
- Peers count (from /opt/orbis_data/ogm/node_status.json)

No use of batctl for name/ID/peers to avoid overcounting or mismatches.

Hardware: SSD1306 128x64 via I2C (addr 0x3c by default)
Dependencies: luma.oled, luma.core, Pillow
"""
import json
import re
import socket
import sys
import time
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from luma.core.interface.serial import i2c
from luma.core.render import canvas
from luma.oled.device import ssd1306

NODE_STATUS_PATH = Path("/opt/orbis_data/ogm/node_status.json")
ORBIS_CONF_PATH = Path("/opt/orbis_data/orbis.conf")
I2C_ADDRESS = 0x3C
I2C_PORT = 1
REFRESH_SECONDS = 5

# Try to pick a readable font; fallback to default if not available

def load_font(size: int):
    try:
        return ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", size)
    except Exception:
        return ImageFont.load_default()


def read_orbis_conf(path: Path) -> dict:
    """Parse a simple KEY=VALUE config file (no shell sourcing).
    Returns a dict with keys like NODE_NAME, NODE_ID if present.
    """
    cfg = {}
    try:
        if not path.exists():
            return cfg
        for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            # Remove trailing inline comment if separated by space
            # (naive but effective for typical KEY=VALUE # comment lines)
            if " #" in line:
                line = line.split(" #", 1)[0].rstrip()
            if "=" not in line:
                continue
            key, val = line.split("=", 1)
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            if key:
                cfg[key] = val
    except Exception:
        pass
    return cfg


def read_node_status() -> dict:
    """Read peers info from node_status.json if available.
    Returns a dict: {"peers": int or None}
    """
    peers = None
    try:
        if NODE_STATUS_PATH.exists():
            with NODE_STATUS_PATH.open("r", encoding="utf-8") as f:
                data = json.load(f)
            # local MAC (if present) to optionally exclude self
            local_mac = None
            if isinstance(data.get("local"), dict):
                local_mac = data["local"].get("mac")

            # 1) explicit peers_count
            if "peers_count" in data and data.get("peers_count") is not None:
                peers = int(data.get("peers_count") or 0)
            else:
                # 2) neighbors
                neighbors = data.get("neighbors")
                if isinstance(neighbors, list):
                    peers = len(neighbors)
                elif isinstance(neighbors, dict):
                    peers = len(neighbors.keys())

                # 3) nodes
                if peers is None:
                    nodes = data.get("nodes")
                    if isinstance(nodes, dict):
                        count = len(nodes.keys())
                        if local_mac and local_mac in nodes:
                            count = max(0, count - 1)
                        peers = count
                    elif isinstance(nodes, list):
                        count = len(nodes)
                        if local_mac:
                            try:
                                macs = set()
                                for n in nodes:
                                    if isinstance(n, dict):
                                        m = n.get("mac") or n.get("id") or n.get("node_id")
                                        if m:
                                            macs.add(m)
                                if macs:
                                    count = len([m for m in macs if m != local_mac])
                            except Exception:
                                pass
                        peers = max(0, count)
    except Exception:
        pass
    return {"peers": peers}


MAC_RE = re.compile(r"([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}")


def shorten_id(s: str | None, width: int = 12) -> str:
    if not s:
        return "unknown"
    s = str(s)
    if len(s) <= width:
        return s
    # If it's a MAC, compact it
    if MAC_RE.fullmatch(s):
        return s.replace(":", "").lower()[:width]
    return s[: width - 1] + "…"


def get_hostname() -> str:
    try:
        return socket.gethostname()
    except Exception:
        return "unknown"


def main():
    # Initialize display
    serial = i2c(port=I2C_PORT, address=I2C_ADDRESS)
    device = ssd1306(serial, width=128, height=64)

    font_title = load_font(13)
    font_body = load_font(12)

    while True:
        cfg = read_orbis_conf(ORBIS_CONF_PATH)
        name = cfg.get("NODE_NAME") or get_hostname()
        node_id = cfg.get("NODE_ID") or "unknown"

        status = read_node_status()
        peers = status.get("peers")
        if peers is None:
            peers = 0

        # Compose display content
        name_line = f"Name: {name}"
        id_line = f"ID: {shorten_id(node_id, 12)}"
        peers_line = f"Peers: {peers}"

        with canvas(device) as draw:
            # Header
            draw.text((0, 0), "ORBIS Mesh", font=font_title, fill=255)
            draw.line([(0, 14), (127, 14)], fill=255)
            # Content
            draw.text((0, 18), name_line, font=font_body, fill=255)
            draw.text((0, 34), id_line, font=font_body, fill=255)
            draw.text((0, 50), peers_line, font=font_body, fill=255)

        time.sleep(REFRESH_SECONDS)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
