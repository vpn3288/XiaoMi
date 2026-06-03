#!/bin/sh
set -u

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"

INSTALL_DIR="$DEFAULT_INSTALL_DIR"
KEEP_CONFIG=1
CONFIRM_DELETE=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --install-dir) shift; [ "$#" -gt 0 ] || die "--install-dir requires PATH"; INSTALL_DIR="$1" ;;
        --delete-config) KEEP_CONFIG=0 ;;
        --yes-delete) CONFIRM_DELETE=1 ;;
        --help|-h)
            echo "Usage: sh scripts/uninstall.sh [--install-dir PATH] [--delete-config --yes-delete]"
            exit 0
            ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

is_safe_install_dir "$INSTALL_DIR" || die "unsafe install dir: $INSTALL_DIR"
require_install_marker "$INSTALL_DIR"

kill_toolbox_uhttpd() {
    for pid in $(pidof uhttpd 2>/dev/null); do
        cmdline="$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
        case "$cmdline" in
            *"$INSTALL_DIR/panel/www"*)
                kill "$pid" 2>/dev/null || true
                ;;
        esac
    done
}

keep_sidegw_last_good="/tmp/xiaomi-toolbox-uninstall-last-good.$$"
keep_admin_token="/tmp/xiaomi-toolbox-uninstall-admin-token.$$"

copy_disabled_config() {
    src="$1"
    dst="$2"
    if ! {
        echo "ENABLED='0'"
        { [ -f "$src" ] && grep -v "^[[:space:]]*ENABLED=" "$src"; } || true
    } > "$dst"; then
        return 1
    fi
    return 0
}

if [ "$KEEP_CONFIG" = "1" ]; then
    [ -f "$INSTALL_DIR/panel/modules/sidegw/config.last_good" ] &&
        cp "$INSTALL_DIR/panel/modules/sidegw/config.last_good" "$keep_sidegw_last_good" 2>/dev/null || true
    [ -f "$INSTALL_DIR/panel/modules/sidegw/admin.token" ] &&
        cp "$INSTALL_DIR/panel/modules/sidegw/admin.token" "$keep_admin_token" 2>/dev/null || true
fi

if [ -x "$INSTALL_DIR/panel/modules/sidegw/rollback.sh" ]; then
    "$INSTALL_DIR/panel/modules/sidegw/rollback.sh" || die "rollback failed; abort uninstall to keep recovery tools installed"
fi

kill_toolbox_uhttpd
rm -f /var/run/xiaomi-toolbox.pid

if [ -f /etc/crontabs/root ]; then
    backup_file /etc/crontabs/root
    grep -v "$CRON_MARK" /etc/crontabs/root > /tmp/xiaomi-toolbox-cron || true
    cat /tmp/xiaomi-toolbox-cron > /etc/crontabs/root
    /etc/init.d/cron restart >/dev/null 2>&1 || true
fi

backup_file /etc/config/firewall
uci -q delete firewall.$FIREWALL_SECTION
uci commit firewall >/dev/null 2>&1 || true

if [ "$KEEP_CONFIG" = "0" ]; then
    [ "$CONFIRM_DELETE" = "1" ] || die "--delete-config requires --yes-delete"
    rm -rf "$INSTALL_DIR"
else
    mkdir -p "$INSTALL_DIR/config"
    if [ -f "$INSTALL_DIR/panel/modules/sidegw/config" ]; then
        copy_disabled_config "$INSTALL_DIR/panel/modules/sidegw/config" "$INSTALL_DIR/config/sidegw.config" ||
            die "cannot preserve disabled sidegw config"
    fi
    if [ -f "$keep_sidegw_last_good" ]; then
        cp "$keep_sidegw_last_good" "$INSTALL_DIR/config/sidegw.last_good" 2>/dev/null || true
    fi
    if [ -f "$keep_admin_token" ]; then
        cp "$keep_admin_token" "$INSTALL_DIR/config/admin.token" 2>/dev/null || true
    fi
    rm -rf "$INSTALL_DIR/panel" "$INSTALL_DIR/toolbox-bootstrap.sh"
fi

rm -f "$keep_sidegw_last_good" "$keep_admin_token"
log "Uninstalled. Config kept: $KEEP_CONFIG"
