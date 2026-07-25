#Cockpit NUTshell Manager
A browser-based Network UPS Tools management extension for Cockpit on Ubuntu and Debian.
It uses the existing Cockpit login and Cockpit's administrator privilege escalation. It does not run a second web server or open an additional management port.
Features
Dashboard with NUT mode, systemd service state, configured UPS names, and live `upsc` values
Standalone and network-server setup wizard
Network-client setup wizard
Configuration editor for:
`nut.conf`
`ups.conf`
`upsd.conf`
`upsd.users`
`upsmon.conf`
`upssched.conf`
NUT user creation and replacement with primary, secondary, read-only, and administrator profiles
Server, monitor, and driver service controls
Driver resynchronization and status
USB UPS scanning
Local and remote UPS queries
NUT journal logs
Diagnostic report
Timestamped configuration backups and restoration
Atomic configuration writes and `root:nut` mode `0640` permissions when the `nut` group exists
Install
```bash
cd nut-cockpit-manager
chmod +x install.sh
sudo ./install.sh
```
Open Cockpit:
```text
https://YOUR-SERVER-IP:9090
```
Then select Tools → NUT Manager.
Log out and back into Cockpit or refresh the browser if the menu entry does not appear immediately.
Administrator access
Operations that read or alter protected NUT configuration use Cockpit's administrator elevation. Your Cockpit account must be allowed to perform administrative actions.
Network-server firewall
NUT normally uses TCP port `3493`. Permit it only from trusted secondary-client IP addresses or your trusted private subnet. Do not publish it directly to the Internet.
Example with UFW for a single trusted client:
```bash
sudo ufw allow from 192.168.1.25 to any port 3493 proto tcp
```
Configuration backups
Backups are stored at:
```text
/var/backups/nut-manager/
```
A backup is created before wizard setup, editor saves, user changes, and restores.
Files installed
```text
/usr/share/cockpit/nut_manager/
/usr/libexec/nut-cockpit-helper
```
Uninstall
```bash
sudo ./uninstall.sh
```
The uninstaller preserves installed NUT packages, `/etc/nut`, and `/var/backups/nut-manager`.
Shutdown testing
Test the shutdown sequence while someone has physical access to the UPS and hosts. Confirm that each machine shuts down in the intended order and can recover after utility power returns.
