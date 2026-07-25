NUTshell Manager Tools

These tools provide command-line and browser-based management for Network UPS Tools (NUT) on Ubuntu and Debian systems.

nut-manager.sh

nut-manager.sh is a menu-driven Bash interface for configuring and managing a NUT server or client.

Features
Configure standalone, network server, or network client modes
Configure UPS devices and monitoring accounts
Edit NUT configuration files
Start, stop, restart, and check NUT services
View UPS status, logs, and diagnostics
Create and restore configuration backups
Install
chmod +x nut-manager.sh
sudo install -m 755 nut-manager.sh /usr/local/sbin/nut-manager

Run it with:

sudo nut-manager
nut-cockpit-extension

nut-cockpit-extension provides similar NUT management features inside the Cockpit web interface.

Features
UPS status dashboard
NUT server and client setup wizards
Configuration file editors
User and permission management
NUT service and driver controls
Logs, diagnostics, backups, and restoration
Uses Cockpit authentication and administrator privileges
Install

Extract the package and run:

tar -xzf nut-cockpit-manager-1.0.0.tar.gz
cd nut-cockpit-manager
sudo ./install.sh

Open Cockpit at:

https://SERVER-IP:9090

Then select:

Tools → NUT Manager
Backups

Configuration backups are stored in:

/var/backups/nut-manager
Security

Do not expose the NUT server or Cockpit directly to the public internet. Restrict Cockpit port 9090 and NUT port 3493 to trusted devices or networks.

Test UPS shutdown behavior while you have physical access to the server and UPS.
