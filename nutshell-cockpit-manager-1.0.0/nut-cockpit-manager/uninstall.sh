#!/usr/bin/env bash
# Remove Cockpit NUT Manager while preserving NUT configuration and backups.
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -- "$0" "$@"
    fi
    printf 'ERROR: Run this script as root.\n' >&2
    exit 1
fi

rm -rf /usr/share/cockpit/nut_manager
rm -f /usr/libexec/nut-cockpit-helper
systemctl try-restart cockpit.socket >/dev/null 2>&1 || true

printf 'Cockpit NUT Manager removed.\n'
printf 'NUT packages, /etc/nut configuration, and /var/backups/nut-manager backups were preserved.\n'
