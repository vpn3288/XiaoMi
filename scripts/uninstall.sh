#!/bin/sh
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"

INSTALL_DIR="$DEFAULT_INSTALL_DIR"
KEEP_CONFIG=1

while [ "$#" -gt 0 ]; do
    case "$1" in
        --install-dir) shift; INSTALL_DIR="${1:-}" ;;
        --delete-config) KEEP_CONFIG=0 ;;
        --help|-h)
            echo "Usage: sh scripts/uninstall.sh [--install-dir PATH] [--delete-config]"
            exit 0
            ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

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

uci -q delete firewall.$FIREWALL_SECTION
uci commit firewall >/dev/null 2>&1 || true

if [ "$KEEP_CONFIG" = "0" ]; then
    rm -rf "$INSTALL_DIR"
else
    rm -rf "$INSTALL_DIR/panel" "$INSTALL_DIR/toolbox-bootstrap.sh"
fi

log "Uninstalled. Config kept: $KEEP_CONFIG"

