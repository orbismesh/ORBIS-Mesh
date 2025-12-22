ORBIS v30
- Add orbis-reconf tool: re-run interactive configuration (IP/SSID/etc.) without reinstalling.

ORBIS v28
- Per-node LAN addressing derived from NODE_ID: OCT3 = 200 + NODE_ID.
- Stable UI address on br-ap: .10; dedicated SSH address on eth0 (user-set host octet, outside DHCP).
- UI now binds to ORBIS_UI_LISTEN/ORBIS_UI_PORT via /opt/orbis/interface/run-ui.sh.
- Added smcroute to installer and enabled on firstboot.
ORBIS v17
- Fix: babeld unit used '-C <file>' which babeld interprets as "config from command line".
  Changed to '-c /opt/orbis/network/generated/babeld.conf'.
- Adds ExecStartPre to ensure mesh0 exists before starting babeld.
- babeld.conf permissions set to 0644 (non-sensitive).

ORBIS v18
- Installer defers eth0/bridge IP changes until after reboot via orbis-firstboot.service.

ORBIS v19
- babeld.conf generation simplified (removed directives that can fail to parse on some babeld builds).

ORBIS v20
- Fixed babeld.conf syntax: use 'protocol-port', removed unsupported 'default ...' lines.
- Added babeld.conf parse sanity-check to prevent restart loops.
