Orbis Mesh Installer:

-   Unzip file on PC, copy "install" folder to device "/tmp/"
    Optional: copy zip file to "/tmp/" and unzip there.
    File path must be "/tmp/install/"
-   Run 'sudo bash /tmp/install/install.sh'
-   Once installer is done and pre-config is set, Run
    'sudo bash /tmp/install/activator.sh' then reboot the device


NOTE:
Network confugurations made during installation are stored in "/opt/orbis_data/orbis.conf".
The files "br0.network" and "hostapd.conf" will be generated dynamically according to the "orbis.conf" values
and then symlinked to the destination folders.
The rest of the "orbis.conf" is experimental and not fully used yet.