#!/usr/bin/env bash
# nut-manager.sh - Menu-driven manager for Network UPS Tools (NUT)
# Intended for Ubuntu/Debian systems using systemd.

set -Eeuo pipefail
IFS=$'\n\t'

readonly APP_NAME="NUT Manager"
readonly APP_VERSION="1.0.0"
readonly CONF_DIR="/etc/nut"
readonly BACKUP_ROOT="/var/backups/nut-manager"
readonly NUT_PORT="3493"

TEMP_FILES=()

cleanup() {
    local item
    for item in "${TEMP_FILES[@]:-}"; do
        [[ -e "$item" ]] && rm -f -- "$item"
    done
}
trap cleanup EXIT

fatal() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            exec sudo -- "$0" "$@"
        fi
        fatal "Run this script as root."
    fi
}

require_supported_os() {
    command -v apt-get >/dev/null 2>&1 || \
        fatal "This version supports Ubuntu/Debian systems with apt."
    command -v systemctl >/dev/null 2>&1 || \
        fatal "systemd is required."
}

install_ui_dependencies() {
    if ! command -v whiptail >/dev/null 2>&1; then
        printf 'Installing whiptail...\n'
        DEBIAN_FRONTEND=noninteractive apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail
    fi
}

msg() {
    whiptail --title "$APP_NAME" --msgbox "$1" 18 78
}

error_box() {
    whiptail --title "$APP_NAME - Error" --msgbox "$1" 18 78
}

confirm() {
    whiptail --title "$APP_NAME" --yesno "$1" 14 78
}

input_box() {
    local prompt=$1
    local default=${2:-}
    whiptail --title "$APP_NAME" --inputbox "$prompt" 12 78 "$default" \
        3>&1 1>&2 2>&3
}

password_box() {
    local prompt=$1
    whiptail --title "$APP_NAME" --passwordbox "$prompt" 12 78 \
        3>&1 1>&2 2>&3
}

menu() {
    local title=$1
    local prompt=$2
    shift 2
    whiptail --title "$title" --menu "$prompt" 22 88 14 "$@" \
        3>&1 1>&2 2>&3
}

show_file() {
    local title=$1
    local file=$2
    whiptail --title "$title" --textbox "$file" 28 100
}

pause_terminal() {
    printf '\nPress Enter to return to %s...' "$APP_NAME"
    read -r _
}

new_temp_file() {
    local tmp
    tmp=$(mktemp)
    TEMP_FILES+=("$tmp")
    printf '%s\n' "$tmp"
}

run_capture() {
    local title=$1
    shift
    local output rc
    output=$(new_temp_file)
    set +e
    "$@" >"$output" 2>&1
    rc=$?
    set -e
    printf '\nExit status: %s\n' "$rc" >>"$output"
    show_file "$title" "$output"
    return 0
}

nut_group() {
    if getent group nut >/dev/null 2>&1; then
        printf 'nut\n'
    else
        printf 'root\n'
    fi
}

secure_config_permissions() {
    local group file
    group=$(nut_group)
    install -d -o root -g "$group" -m 0750 "$CONF_DIR"

    for file in nut.conf ups.conf upsd.conf upsd.users upsmon.conf upssched.conf; do
        if [[ -e "$CONF_DIR/$file" ]]; then
            chown root:"$group" "$CONF_DIR/$file"
            chmod 0640 "$CONF_DIR/$file"
        fi
    done
}

backup_configs() {
    local stamp target
    stamp=$(date '+%Y%m%d-%H%M%S')
    target="$BACKUP_ROOT/$stamp"
    install -d -m 0700 "$target"

    if [[ -d "$CONF_DIR" ]]; then
        cp -a "$CONF_DIR/." "$target/"
    fi

    printf '%s\n' "$target"
}

atomic_write() {
    local path=$1
    local mode=$2
    local content=$3
    local tmp group
    tmp=$(mktemp "${path}.tmp.XXXXXX")
    TEMP_FILES+=("$tmp")
    group=$(nut_group)

    printf '%s\n' "$content" >"$tmp"
    install -o root -g "$group" -m "$mode" "$tmp" "$path"
}

valid_identifier() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

valid_host() {
    [[ $1 =~ ^[A-Za-z0-9._:-]+$ ]]
}

valid_ipv4() {
    local ip=$1 part
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a parts <<<"$ip"
    for part in "${parts[@]}"; do
        (( 10#$part >= 0 && 10#$part <= 255 )) || return 1
    done
}

valid_password() {
    [[ -n $1 && $1 != *[[:space:]]* && $1 != *'#'* ]]
}

escape_double_quotes() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '%s' "$value"
}

generate_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 24 | tr -d '=+/\n' | cut -c1-24
    else
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-24
        printf '\n'
    fi
}

primary_lan_ipv4() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    if [[ -z $ip ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    printf '%s\n' "${ip:-127.0.0.1}"
}

install_nut_packages() {
    local profile=${1:-server}
    local packages=(nut-client usbutils)
    local missing=() package

    if [[ $profile == server ]]; then
        packages+=(nut-server)
    fi

    for package in "${packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q '^install ok installed$'; then
            missing+=("$package")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        DEBIAN_FRONTEND=noninteractive apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    fi

    install -d -m 0750 "$CONF_DIR"
    secure_config_permissions
}

set_nut_mode() {
    local mode=$1
    local content
    content="# Managed by $APP_NAME $APP_VERSION
# Valid modes: none, standalone, netserver, netclient
MODE=$mode"
    atomic_write "$CONF_DIR/nut.conf" 0640 "$content"
}

server_quick_setup() {
    local mode ups_name driver port desc listen_ip
    local primary_user primary_password primary_generated="no"
    local client_user="" client_password="" client_generated="no"
    local backup desc_escaped upsd_listen ups_conf upsd_conf users_conf upsmon_conf

    mode=$(menu "$APP_NAME - Server Setup" \
        "Choose how this host will provide NUT service:" \
        standalone "Local UPS protects only this machine" \
        netserver "Local UPS also protects network clients") || return 0

    ups_name=$(input_box "UPS name used by NUT (letters, numbers, dot, dash, underscore):" "ups") || return 0
    valid_identifier "$ups_name" || { error_box "Invalid UPS name."; return 0; }
    [[ $ups_name != default ]] || { error_box "The name 'default' is reserved by NUT."; return 0; }

    driver=$(input_box "NUT driver name. Most USB HID UPS units use usbhid-ups:" "usbhid-ups") || return 0
    valid_identifier "$driver" || { error_box "Invalid driver name."; return 0; }

    port=$(input_box "UPS port. Most USB drivers use auto:" "auto") || return 0
    [[ -n $port && $port != *[[:space:]]* && $port != *'#'* ]] || { error_box "The port cannot contain whitespace or #."; return 0; }

    desc=$(input_box "Description for this UPS:" "UPS connected to $(hostname)") || return 0
    desc_escaped=$(escape_double_quotes "$desc")

    if [[ $mode == netserver ]]; then
        listen_ip=$(input_box \
            "LAN IPv4 address where upsd should listen. Use a static/reserved address.\n\nPort: $NUT_PORT" \
            "$(primary_lan_ipv4)") || return 0
        valid_ipv4 "$listen_ip" || { error_box "Enter a valid IPv4 address."; return 0; }
    else
        listen_ip="127.0.0.1"
    fi

    primary_user=$(input_box "Local primary monitor username:" "upsmon-primary") || return 0
    valid_identifier "$primary_user" || { error_box "Invalid primary username."; return 0; }

    primary_password=$(password_box \
        "Password for the local primary monitor. Leave blank to generate one.\n\nDo not use spaces or #.") || return 0
    if [[ -z $primary_password ]]; then
        primary_password=$(generate_password)
        primary_generated="yes"
    fi
    valid_password "$primary_password" || { error_box "The password cannot contain whitespace or #."; return 0; }

    if [[ $mode == netserver ]]; then
        client_user=$(input_box "Remote client monitor username:" "upsmon-secondary") || return 0
        valid_identifier "$client_user" || { error_box "Invalid client username."; return 0; }
        [[ $client_user != "$primary_user" ]] || { error_box "Primary and client usernames must be different."; return 0; }

        client_password=$(password_box \
            "Password for remote secondary clients. Leave blank to generate one.\n\nDo not use spaces or #.") || return 0
        if [[ -z $client_password ]]; then
            client_password=$(generate_password)
            client_generated="yes"
        fi
        valid_password "$client_password" || { error_box "The password cannot contain whitespace or #."; return 0; }
    fi

    if ! confirm \
        "This quick setup will replace the active NUT configuration files after creating a backup.\n\nMode: $mode\nUPS: $ups_name\nDriver: $driver\nPort: $port\nListen: $listen_ip:$NUT_PORT\n\nContinue?"; then
        return 0
    fi

    install_nut_packages server
    backup=$(backup_configs)

    if [[ $mode == netserver ]]; then
        upsd_listen="LISTEN 127.0.0.1 $NUT_PORT
LISTEN $listen_ip $NUT_PORT"
    else
        upsd_listen="LISTEN 127.0.0.1 $NUT_PORT"
    fi

    ups_conf="# Managed by $APP_NAME $APP_VERSION
[$ups_name]
    driver = $driver
    port = $port
    desc = \"$desc_escaped\""

    upsd_conf="# Managed by $APP_NAME $APP_VERSION
# Bind only to localhost and the selected LAN address.
MAXAGE 15
$upsd_listen"

    users_conf="# Managed by $APP_NAME $APP_VERSION
[$primary_user]
    password = $primary_password
    upsmon primary"

    if [[ $mode == netserver ]]; then
        users_conf+="

[$client_user]
    password = $client_password
    upsmon secondary"
    fi

    upsmon_conf="# Managed by $APP_NAME $APP_VERSION
MONITOR $ups_name@localhost 1 $primary_user $primary_password primary
MINSUPPLIES 1
SHUTDOWNCMD \"/sbin/shutdown -h +0\"
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
POWERDOWNFLAG /etc/killpower
RBWARNTIME 43200
NOCOMMWARNTIME 300
FINALDELAY 5"

    set_nut_mode "$mode"
    atomic_write "$CONF_DIR/ups.conf" 0640 "$ups_conf"
    atomic_write "$CONF_DIR/upsd.conf" 0640 "$upsd_conf"
    atomic_write "$CONF_DIR/upsd.users" 0640 "$users_conf"
    atomic_write "$CONF_DIR/upsmon.conf" 0640 "$upsmon_conf"
    secure_config_permissions

    apply_configuration

    local result="Server configuration was written.\n\nBackup: $backup\nUPS target: $ups_name@localhost\nListen address: $listen_ip:$NUT_PORT"
    if [[ $primary_generated == yes ]]; then
        result+="\n\nGenerated local primary credentials:\nUsername: $primary_user\nPassword: $primary_password"
    fi
    if [[ $mode == netserver ]]; then
        result+="\n\nRemote clients must use the secondary role."
        if [[ $client_generated == yes ]]; then
            result+="\nGenerated client credentials:\nUsername: $client_user\nPassword: $client_password"
        else
            result+="\nClient username: $client_user"
        fi
        result+="\n\nAllow TCP $NUT_PORT only from trusted client addresses or your trusted LAN subnet."
    fi
    result+="\n\nSave generated passwords securely."
    msg "$result"
}

client_quick_setup() {
    local server_host ups_name username password role backup upsmon_conf

    server_host=$(input_box "NUT server hostname or IPv4 address:" "") || return 0
    valid_host "$server_host" || { error_box "Invalid server hostname/address."; return 0; }

    ups_name=$(input_box "UPS name configured on the NUT server:" "ups") || return 0
    valid_identifier "$ups_name" || { error_box "Invalid UPS name."; return 0; }

    username=$(input_box "NUT monitor username created on the server:" "upsmon-secondary") || return 0
    valid_identifier "$username" || { error_box "Invalid username."; return 0; }

    password=$(password_box "NUT monitor password from the server:") || return 0
    valid_password "$password" || { error_box "A password without whitespace or # is required."; return 0; }

    role=$(menu "$APP_NAME - Client Role" \
        "Normally a network client must be secondary." \
        secondary "Recommended: shut down this client only" \
        primary "Advanced: this client may command UPS shutdown") || return 0

    if [[ $role == primary ]]; then
        confirm "Primary mode can command the UPS power-off sequence. Use it only when this host is intentionally responsible for that operation. Continue?" || return 0
    fi

    confirm \
        "This will replace this machine's upsmon.conf after creating a backup.\n\nTarget: $ups_name@$server_host\nRole: $role\n\nContinue?" || return 0

    install_nut_packages client
    backup=$(backup_configs)

    upsmon_conf="# Managed by $APP_NAME $APP_VERSION
MONITOR $ups_name@$server_host 1 $username $password $role
MINSUPPLIES 1
SHUTDOWNCMD \"/sbin/shutdown -h +0\"
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
POWERDOWNFLAG /etc/killpower
RBWARNTIME 43200
NOCOMMWARNTIME 300
FINALDELAY 5"

    set_nut_mode netclient
    atomic_write "$CONF_DIR/upsmon.conf" 0640 "$upsmon_conf"
    secure_config_permissions
    apply_configuration

    msg "Client configuration was written.\n\nBackup: $backup\nTarget: $ups_name@$server_host\nRole: $role"
}

apply_configuration() {
    systemctl daemon-reload || true

    if command -v upsdrvsvcctl >/dev/null 2>&1; then
        upsdrvsvcctl resync >/dev/null 2>&1 || true
    fi

    if systemctl list-unit-files nut-driver-enumerator.service --no-legend 2>/dev/null | grep -q nut-driver-enumerator; then
        systemctl restart nut-driver-enumerator.service >/dev/null 2>&1 || true
    fi

    local mode
    mode=$(awk -F= '/^[[:space:]]*MODE=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$CONF_DIR/nut.conf" 2>/dev/null || true)

    case "$mode" in
        standalone|netserver)
            systemctl enable nut-server.service nut-monitor.service >/dev/null 2>&1 || true
            systemctl restart nut-server.service >/dev/null 2>&1 || true
            systemctl restart nut-monitor.service >/dev/null 2>&1 || true
            ;;
        netclient)
            if command -v upsdrvsvcctl >/dev/null 2>&1; then
                upsdrvsvcctl stop >/dev/null 2>&1 || true
            fi
            systemctl stop nut-driver.target >/dev/null 2>&1 || true
            systemctl disable --now nut-server.service >/dev/null 2>&1 || true
            systemctl enable nut-monitor.service >/dev/null 2>&1 || true
            systemctl restart nut-monitor.service >/dev/null 2>&1 || true
            ;;
        none|*)
            ;;
    esac
}

scan_usb_ups() {
    if ! command -v nut-scanner >/dev/null 2>&1; then
        if confirm "nut-scanner is not installed. Install NUT server packages now?"; then
            install_nut_packages server
        else
            return 0
        fi
    fi

    run_capture "USB UPS Scan" nut-scanner -U
}

default_ups_target() {
    local target
    target=$(awk '$1 == "MONITOR" {print $2; exit}' "$CONF_DIR/upsmon.conf" 2>/dev/null || true)
    if [[ -z $target && -f "$CONF_DIR/ups.conf" ]]; then
        target=$(awk '/^[[:space:]]*\[[^]]+\]/{gsub(/^\[|\]$/,"",$1); print $1 "@localhost"; exit}' "$CONF_DIR/ups.conf" 2>/dev/null || true)
    fi
    printf '%s\n' "${target:-ups@localhost}"
}

show_ups_status() {
    command -v upsc >/dev/null 2>&1 || { error_box "upsc is not installed. Install nut-client first."; return 0; }

    local target
    target=$(input_box "UPS target in the form upsname@hostname[:port]:" "$(default_ups_target)") || return 0
    [[ -n $target && $target != *[[:space:]]* ]] || { error_box "Invalid target."; return 0; }
    run_capture "UPS Status - $target" upsc "$target"
}

list_remote_ups() {
    command -v upsc >/dev/null 2>&1 || { error_box "upsc is not installed."; return 0; }
    local host
    host=$(input_box "NUT server hostname or address:" "localhost") || return 0
    valid_host "$host" || { error_box "Invalid server hostname/address."; return 0; }
    run_capture "UPS Devices on $host" upsc -L "$host"
}

edit_config_file() {
    local selected editor backup
    selected=$(menu "$APP_NAME - Edit Configuration" \
        "Choose a NUT file. A timestamped backup is created first." \
        nut.conf "Select operating mode" \
        ups.conf "UPS driver and device definitions" \
        upsd.conf "NUT data server listening settings" \
        upsd.users "Server users, roles, and commands" \
        upsmon.conf "Monitored UPS systems and shutdown behavior" \
        upssched.conf "Delayed event scheduling" \
        restore "Restore a previous configuration backup") || return 0

    if [[ $selected == restore ]]; then
        restore_backup
        return 0
    fi

    install -d -m 0750 "$CONF_DIR"
    touch "$CONF_DIR/$selected"
    secure_config_permissions
    backup=$(backup_configs)

    editor=${EDITOR:-}
    if [[ -z $editor ]]; then
        if command -v nano >/dev/null 2>&1; then
            editor=nano
        else
            editor=vi
        fi
    fi

    clear
    printf 'Editing %s\nBackup: %s\n\n' "$CONF_DIR/$selected" "$backup"
    "$editor" "$CONF_DIR/$selected"
    secure_config_permissions

    if confirm "Apply and restart the applicable NUT services now?"; then
        apply_configuration
    fi
}

upsert_user_section() {
    local file=$1 username=$2 section=$3 tmp
    tmp=$(mktemp)
    TEMP_FILES+=("$tmp")

    if [[ -f $file ]]; then
        awk -v wanted="$username" '
            function section_name(line, s) {
                s=line
                sub(/^[[:space:]]*\[/, "", s)
                sub(/\][[:space:]]*$/, "", s)
                return s
            }
            /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
                current=section_name($0)
                skip=(current==wanted)
            }
            !skip { print }
        ' "$file" >"$tmp"
    fi

    {
        cat "$tmp"
        printf '\n%s\n' "$section"
    } >"${tmp}.new"
    TEMP_FILES+=("${tmp}.new")
    atomic_write "$file" 0640 "$(cat "${tmp}.new")"
}

manage_user() {
    local username password profile generated="no" role section backup

    username=$(input_box "NUT username to add or replace:" "upsmon") || return 0
    valid_identifier "$username" || { error_box "Invalid username."; return 0; }

    password=$(password_box "Password for $username. Leave blank to generate one:") || return 0
    if [[ -z $password ]]; then
        password=$(generate_password)
        generated="yes"
    fi
    valid_password "$password" || { error_box "The password cannot contain whitespace or #."; return 0; }

    profile=$(menu "$APP_NAME - User Permissions" \
        "Choose the least privilege this user requires:" \
        secondary "upsmon secondary client" \
        primary "upsmon primary controller" \
        admin "SET, FSD, and all instant commands" \
        readonly "Authentication only; no control permissions") || return 0

    case "$profile" in
        secondary|primary)
            role=$profile
            section="[$username]
    password = $password
    upsmon $role"
            ;;
        admin)
            confirm "This profile grants powerful UPS control commands, including forced shutdown. Continue?" || return 0
            section="[$username]
    password = $password
    actions = SET
    actions = FSD
    instcmds = ALL"
            ;;
        readonly)
            section="[$username]
    password = $password"
            ;;
    esac

    install_nut_packages server
    backup=$(backup_configs)
    upsert_user_section "$CONF_DIR/upsd.users" "$username" "$section"
    secure_config_permissions
    systemctl restart nut-server.service >/dev/null 2>&1 || true

    local output="User [$username] was added or replaced.\nBackup: $backup"
    if [[ $generated == yes ]]; then
        output+="\n\nGenerated password: $password\n\nSave it securely."
    fi
    msg "$output"
}

service_exists() {
    systemctl list-unit-files "$1" --no-legend 2>/dev/null | grep -q "^$1"
}

service_control() {
    local scope action services=() service output

    scope=$(menu "$APP_NAME - Service Control" "Choose a service group:" \
        all "NUT server, monitor, and driver services" \
        server "nut-server.service" \
        monitor "nut-monitor.service" \
        drivers "nut-driver.target and driver instances") || return 0

    action=$(menu "$APP_NAME - Service Control" "Choose an action:" \
        status "Show detailed status" \
        restart "Restart service(s)" \
        start "Start service(s)" \
        stop "Stop service(s)" \
        enable "Enable at boot" \
        disable "Disable at boot") || return 0

    case "$scope" in
        all) services=(nut-server.service nut-monitor.service nut-driver.target) ;;
        server) services=(nut-server.service) ;;
        monitor) services=(nut-monitor.service) ;;
        drivers) services=(nut-driver.target) ;;
    esac

    output=$(new_temp_file)
    for service in "${services[@]}"; do
        printf '===== %s =====\n' "$service" >>"$output"
        if ! service_exists "$service" && ! systemctl status "$service" >/dev/null 2>&1; then
            printf 'Not installed or not known to systemd.\n\n' >>"$output"
            continue
        fi

        set +e
        case "$action" in
            status) systemctl status "$service" --no-pager -l >>"$output" 2>&1 ;;
            restart) systemctl restart "$service" >>"$output" 2>&1 ;;
            start) systemctl start "$service" >>"$output" 2>&1 ;;
            stop) systemctl stop "$service" >>"$output" 2>&1 ;;
            enable) systemctl enable "$service" >>"$output" 2>&1 ;;
            disable) systemctl disable "$service" >>"$output" 2>&1 ;;
        esac
        printf 'Exit status: %s\n\n' "$?" >>"$output"
        set -e
    done

    if [[ $scope == drivers ]]; then
        printf '===== Driver instances =====\n' >>"$output"
        systemctl list-units 'nut-driver@*.service' --all --no-pager >>"$output" 2>&1 || true
    fi

    show_file "NUT Service Control" "$output"
}

driver_control() {
    local action output stop_rc start_rc
    action=$(menu "$APP_NAME - Driver Control" "Choose an action:" \
        list "List configured and active driver instances" \
        resync "Synchronize systemd driver instances with ups.conf" \
        restart "Restart all NUT driver instances" \
        status "Show driver target and instance status") || return 0

    output=$(new_temp_file)
    case "$action" in
        list)
            printf 'Configured UPS sections:\n' >"$output"
            awk '/^[[:space:]]*\[[^]]+\]/{print}' "$CONF_DIR/ups.conf" 2>/dev/null >>"$output" || true
            printf '\nSystemd driver instances:\n' >>"$output"
            systemctl list-units 'nut-driver@*.service' --all --no-pager >>"$output" 2>&1 || true
            ;;
        resync)
            if command -v upsdrvsvcctl >/dev/null 2>&1; then
                set +e
                upsdrvsvcctl resync >"$output" 2>&1
                printf '\nExit status: %s\n' "$?" >>"$output"
                set -e
            else
                printf 'upsdrvsvcctl is unavailable in this installed NUT package.\n' >"$output"
            fi
            ;;
        restart)
            if command -v upsdrvsvcctl >/dev/null 2>&1; then
                set +e
                upsdrvsvcctl stop >"$output" 2>&1
                stop_rc=$?
                upsdrvsvcctl start >>"$output" 2>&1
                start_rc=$?
                set -e
                printf '\nStop exit status: %s\nStart exit status: %s\n' "$stop_rc" "$start_rc" >>"$output"
            else
                systemctl restart nut-driver.target >"$output" 2>&1 || true
            fi
            printf '\nDriver instances:\n' >>"$output"
            systemctl list-units 'nut-driver@*.service' --all --no-pager >>"$output" 2>&1 || true
            ;;
        status)
            if command -v upsdrvsvcctl >/dev/null 2>&1; then
                upsdrvsvcctl status >"$output" 2>&1 || true
                printf '\nService mapping:\n' >>"$output"
                upsdrvsvcctl list >>"$output" 2>&1 || true
            else
                systemctl status nut-driver.target --no-pager -l >"$output" 2>&1 || true
            fi
            printf '\nDriver instances:\n' >>"$output"
            systemctl list-units 'nut-driver@*.service' --all --no-pager >>"$output" 2>&1 || true
            ;;
    esac
    show_file "NUT Driver Control" "$output"
}

view_logs() {
    local lines
    lines=$(input_box "Number of recent journal lines:" "200") || return 0
    [[ $lines =~ ^[0-9]+$ ]] || { error_box "Enter a positive number."; return 0; }

    local output
    output=$(new_temp_file)
    journalctl \
        -u nut-server.service \
        -u nut-monitor.service \
        -u nut-driver.target \
        -u nut-driver-enumerator.service \
        -n "$lines" --no-pager -o short-iso >"$output" 2>&1 || true
    show_file "Recent NUT Logs" "$output"
}

diagnostics() {
    local output mode target
    output=$(new_temp_file)
    mode=$(awk -F= '/^[[:space:]]*MODE=/{print $2; exit}' "$CONF_DIR/nut.conf" 2>/dev/null || printf 'not configured')
    target=$(default_ups_target)

    {
        printf '%s %s diagnostics\n' "$APP_NAME" "$APP_VERSION"
        printf 'Generated: %s\n\n' "$(date --iso-8601=seconds)"
        printf 'OS: '
        . /etc/os-release 2>/dev/null && printf '%s %s\n' "${PRETTY_NAME:-unknown}" "${VERSION_ID:-}" || printf 'unknown\n'
        printf 'Architecture: %s\n' "$(uname -m)"
        printf 'NUT mode: %s\n' "$mode"
        printf 'Default target: %s\n\n' "$target"

        printf '--- Installed commands ---\n'
        for cmd in upsc upsd upsmon upsdrvctl upsdrvsvcctl nut-scanner nutconf; do
            if command -v "$cmd" >/dev/null 2>&1; then
                printf '%-16s %s\n' "$cmd" "$(command -v "$cmd")"
            else
                printf '%-16s MISSING\n' "$cmd"
            fi
        done

        printf '\n--- NUT version ---\n'
        upsc -V 2>&1 || true

        printf '\n--- Configuration permissions ---\n'
        ls -ld "$CONF_DIR" 2>&1 || true
        ls -l "$CONF_DIR" 2>&1 || true

        printf '\n--- Service states ---\n'
        for service in nut-server.service nut-monitor.service nut-driver.target nut-driver-enumerator.service; do
            printf '%-32s active=%-10s enabled=%s\n' \
                "$service" \
                "$(systemctl is-active "$service" 2>/dev/null || true)" \
                "$(systemctl is-enabled "$service" 2>/dev/null || true)"
        done

        printf '\n--- Driver instances ---\n'
        systemctl list-units 'nut-driver@*.service' --all --no-pager 2>&1 || true

        printf '\n--- TCP port %s ---\n' "$NUT_PORT"
        ss -ltnp 2>&1 | grep -E "[:.]$NUT_PORT[[:space:]]" || printf 'No listener detected.\n'

        printf '\n--- USB devices ---\n'
        lsusb 2>&1 || true

        printf '\n--- UPS list on localhost ---\n'
        upsc -L localhost 2>&1 || true

        printf '\n--- Status for %s ---\n' "$target"
        upsc "$target" 2>&1 || true

        printf '\n--- nutconf check ---\n'
        if command -v nutconf >/dev/null 2>&1; then
            nutconf --system --is-configured 2>&1 || true
            nutconf --system --get-mode 2>&1 || true
        fi

        printf '\n--- Recent warnings/errors ---\n'
        journalctl -u nut-server.service -u nut-monitor.service -u nut-driver.target \
            -p warning -n 80 --no-pager 2>&1 || true
    } >"$output"

    show_file "NUT Diagnostics" "$output"
}

list_backups() {
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r
}

restore_backup() {
    local options=() backup choice current_backup entry
    while IFS= read -r backup; do
        [[ -n $backup ]] || continue
        options+=("$backup" "Configuration backup")
    done < <(list_backups)

    if (( ${#options[@]} == 0 )); then
        error_box "No backups exist in $BACKUP_ROOT."
        return 0
    fi

    choice=$(menu "$APP_NAME - Restore Backup" "Choose a backup to restore:" "${options[@]}") || return 0
    confirm "Restore backup $choice? The current configuration will be backed up first." || return 0

    current_backup=$(backup_configs)
    install -d -m 0750 "$CONF_DIR"
    find "$CONF_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    cp -a "$BACKUP_ROOT/$choice/." "$CONF_DIR/"
    secure_config_permissions
    apply_configuration
    msg "Backup $choice restored.\n\nThe previous active configuration was saved to:\n$current_backup"
}

show_security_notes() {
    msg "Security notes:\n\n• NUT configuration files may contain passwords. This tool sets them to root:nut mode 0640 when the nut group exists.\n\n• For netserver mode, permit TCP $NUT_PORT only from trusted client IP addresses or your trusted LAN subnet.\n\n• Do not expose upsd directly to the public Internet.\n\n• Grant administrative actions and instant commands only to dedicated users.\n\n• Test orderly shutdown behavior while someone can physically recover the equipment."
}

about() {
    msg "$APP_NAME $APP_VERSION\n\nA menu-driven Ubuntu/Debian interface for configuring and controlling Network UPS Tools server and client components.\n\nConfiguration directory: $CONF_DIR\nBackup directory: $BACKUP_ROOT"
}

main_menu() {
    local choice
    while true; do
        choice=$(menu "$APP_NAME $APP_VERSION" \
            "Configure and control Network UPS Tools:" \
            server "Quick-configure this machine as a NUT server" \
            client "Quick-configure this machine as a NUT network client" \
            scan "Scan for a USB-connected UPS" \
            status "Display UPS status and variables" \
            list "List UPS devices offered by a NUT server" \
            users "Add or replace a NUT server user" \
            edit "Edit NUT configuration files or restore backup" \
            services "Start, stop, restart, enable, or inspect services" \
            drivers "Control and inspect NUT driver instances" \
            logs "View recent NUT journal logs" \
            diagnostics "Run a NUT diagnostic report" \
            security "Show security and shutdown-testing notes" \
            about "About this utility" \
            exit "Exit") || break

        case "$choice" in
            server) server_quick_setup ;;
            client) client_quick_setup ;;
            scan) scan_usb_ups ;;
            status) show_ups_status ;;
            list) list_remote_ups ;;
            users) manage_user ;;
            edit) edit_config_file ;;
            services) service_control ;;
            drivers) driver_control ;;
            logs) view_logs ;;
            diagnostics) diagnostics ;;
            security) show_security_notes ;;
            about) about ;;
            exit) break ;;
        esac
    done
}

print_help() {
    cat <<EOF_HELP
$APP_NAME $APP_VERSION

Usage:
  sudo $0
  $0 --help
  $0 --version

This interactive utility supports Ubuntu/Debian systems using systemd. It can
configure NUT server or client mode, edit configuration files, manage users,
scan USB UPS devices, control services and drivers, display status, view logs,
and restore timestamped backups.
EOF_HELP
}

main() {
    case "${1:-}" in
        -h|--help) print_help; exit 0 ;;
        -V|--version) printf '%s %s\n' "$APP_NAME" "$APP_VERSION"; exit 0 ;;
        "") ;;
        *) fatal "Unknown option: $1" ;;
    esac

    require_root "$@"
    require_supported_os
    install_ui_dependencies
    install -d -m 0700 "$BACKUP_ROOT"
    main_menu
}

main "$@"
