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

if [ -x "$INSTALL_DIR/panel/modules/sidegw/rollback.sh" ]; then
    "$INSTALL_DIR/panel/modules/sidegw/rollback.sh" || true
fi

kill "$(cat /var/run/xiaomi-toolbox.pid 2>/dev/null)" 2>/dev/null || true
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
    rm -rf "$INSTALL_DIR/panel" "$INSTALL_DIR/toolbox-bootstrap.sh"
    rm -f "$INSTALL_DIR/$INSTALL_MARKER"
fi

log "Uninstalled. Config kept: $KEEP_CONFIG"
