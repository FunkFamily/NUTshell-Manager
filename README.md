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

<img width="3117" height="1061" alt="nutshell-manager" src="https://github.com/user-attachments/assets/2fca11f0-1d58-4b93-a82f-508b928a5787" />


**nut-cockpit-extension**

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

Select directory and run:

cd nut-cockpit-manager/cockpit/

sudo ./install.sh

Open Cockpit at:

https://SERVER-IP:9090

<img width="3435" height="1264" alt="NUTshell-cockpit-extension" src="https://github.com/user-attachments/assets/aec57e22-9ac5-4cc6-911b-f5233ff38d2c" />

Then select:

Tools → NUT Manager

Configuration backups are stored in:

/var/backups/nut-manager
Security

Do not expose the NUT server or Cockpit directly to the public internet. Restrict Cockpit port 9090 and NUT port 3493 to trusted devices or networks.

Test UPS shutdown behavior while you have physical access to the server and UPS.
