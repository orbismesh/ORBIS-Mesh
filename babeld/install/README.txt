ORBIS v16
- Fix: wpa_supplicant ctrl_iface conflicts by using dedicated ctrl dir: /run/wpa_supplicant-orbis
  and removing stale sockets before starting.
- Fix: recreate wlan1 if missing by selecting secondary phy (common on Raspberry Pi: phy0 onboard, phy1 USB).
- Fix: avoid losing wlan1 permanently on failures; adds a retry path with optional multi-vif workaround.
