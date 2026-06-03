#!/bin/sh

APP_NAME="xiaomi-toolbox"
DEFAULT_INSTALL_DIR="/mnt/usb-d965c2b9/xiaomi_router/toolbox"
DEFAULT_HOST="192.168.31.1"
DEFAULT_PORT="8888"
CRON_MARK="# xiaomi-toolbox"
FIREWALL_SECTION="xiaomi_toolbox_bootstrap"
INSTALL_MARKER=".xiaomi-toolbox-install"

log() {
    printf '%s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

is_ipv4() {
    echo "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || return 1
    oldifs="$IFS"
    IFS=.
    set -- $1
    IFS="$oldifs"
    [ "$#" -eq 4 ] || return 1
    [ "$1" -le 255 ] && [ "$2" -le 255 ] && [ "$3" -le 255 ] && [ "$4" -le 255 ]
}

is_cidr() {
    echo "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' || return 1
    ip="${1%/*}"
    bits="${1#*/}"
    is_ipv4 "$ip" && [ "$bits" -ge 0 ] && [ "$bits" -le 32 ]
}

is_mac() {
    echo "$1" | grep -Eiq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
}

html_escape() {
    sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

detect_lan_ip() {
    ip -4 addr show dev "${LAN_IF:-br-lan}" 2>/dev/null |
        sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' |
        head -n 1
}

backup_file() {
    src="$1"
    [ -e "$src" ] || return 0
    ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
    cp "$src" "$src.bak-$ts" || die "cannot backup $src"
}

backup_path_move() {
    src="$1"
    [ -e "$src" ] || return 0
    ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
    mv "$src" "$src.bak-$ts" || die "cannot move backup $src"
}

ensure_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

is_safe_install_dir() {
    path="$1"
    case "$path" in
        ""|"/"|"/."|"/.."|"."|".."|*"/../"*|*/..|../*)
            return 1
            ;;
    esac
    case "$path" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$path" in
        /mnt/*/xiaomi_router/toolbox)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

require_install_marker() {
    dir="$1"
    [ -f "$dir/$INSTALL_MARKER" ] || die "install marker missing: $dir/$INSTALL_MARKER"
}
