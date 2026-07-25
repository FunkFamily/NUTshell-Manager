#!/usr/bin/env bash
# Install the Cockpit NUT Manager extension on Ubuntu/Debian.
set -Eeuo pipefail
IFS=$'\n\t'

DESTDIR=${DESTDIR:-}
PACKAGE_DIR="$DESTDIR/usr/share/cockpit/nut_manager"
HELPER_PATH="$DESTDIR/usr/libexec/nut-cockpit-helper"
CONF_DIR="$DESTDIR/etc/nut"
BACKUP_DIR="$DESTDIR/var/backups/nut-manager"
SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

fatal() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || fatal "Run this installer as root."
    exec sudo -- "$0" "$@"
fi

[[ -f "$SOURCE_DIR/nut-cockpit-helper" ]] || fatal "Missing nut-cockpit-helper. Extract the complete package first."
[[ -d "$SOURCE_DIR/cockpit" ]] || fatal "Missing cockpit package directory."

if [[ -z $DESTDIR ]]; then
    command -v apt-get >/dev/null 2>&1 || fatal "This installer supports Ubuntu/Debian systems with apt."
    command -v systemctl >/dev/null 2>&1 || fatal "systemd is required."

    printf 'Installing Cockpit and NUT packages...\n'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y cockpit nut-server nut-client usbutils python3
fi

printf 'Installing privileged helper...\n'
install -D -o root -g root -m 0755 "$SOURCE_DIR/nut-cockpit-helper" "$HELPER_PATH"

printf 'Installing Cockpit extension...\n'
rm -rf -- "$PACKAGE_DIR"
install -d -o root -g root -m 0755 "$PACKAGE_DIR"
install -o root -g root -m 0644 "$SOURCE_DIR/cockpit/manifest.json" "$PACKAGE_DIR/manifest.json"
install -o root -g root -m 0644 "$SOURCE_DIR/cockpit/index.html" "$PACKAGE_DIR/index.html"
install -o root -g root -m 0644 "$SOURCE_DIR/cockpit/styles.css" "$PACKAGE_DIR/styles.css"
install -o root -g root -m 0644 "$SOURCE_DIR/cockpit/app.js" "$PACKAGE_DIR/app.js"

printf 'Preparing NUT configuration and backup directories...\n'
NUT_GROUP="root"
if [[ -z $DESTDIR ]] && getent group nut >/dev/null 2>&1; then
    NUT_GROUP="nut"
fi
install -d -o root -g "$NUT_GROUP" -m 0750 "$CONF_DIR"
install -d -o root -g root -m 0700 "$BACKUP_DIR"
for file in nut.conf ups.conf upsd.conf upsd.users upsmon.conf upssched.conf; do
    if [[ -e "$CONF_DIR/$file" ]]; then
        chown root:"$NUT_GROUP" "$CONF_DIR/$file"
        chmod 0640 "$CONF_DIR/$file"
    fi
done

if [[ -z $DESTDIR ]]; then
    systemctl enable --now cockpit.socket
    systemctl try-restart cockpit.socket >/dev/null 2>&1 || true
fi

printf '\nCockpit NUT Manager installed successfully.\n'
if [[ -z $DESTDIR ]]; then
    printf 'Open Cockpit at: https://SERVER-IP:9090\n'
    printf 'Then select: Tools -> NUT Manager\n\n'
else
    printf 'Staged installation root: %s\n' "$DESTDIR"
fi
printf 'Cockpit package: %s\n' "$PACKAGE_DIR"
printf 'Privileged helper: %s\n' "$HELPER_PATH"
printf 'Backups: %s\n' "$BACKUP_DIR"
if [[ -z $DESTDIR ]]; then
    printf '\nLog out and back into Cockpit, or refresh the browser, if the menu item does not appear immediately.\n'
fi
