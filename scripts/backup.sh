#!/bin/sh
set -u

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"

INSTALL_DIR="$DEFAULT_INSTALL_DIR"
OUT="/tmp/xiaomi-toolbox-backup-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now).tgz"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --install-dir) shift; [ "$#" -gt 0 ] || die "--install-dir requires PATH"; INSTALL_DIR="$1" ;;
        --help|-h)
            echo "Usage: sh scripts/backup.sh [--install-dir PATH]"
            exit 0
            ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

is_safe_install_dir "$INSTALL_DIR" || die "unsafe install dir: $INSTALL_DIR"

set --
for item in \
    "$INSTALL_DIR/config" \
    "$INSTALL_DIR/panel/modules/sidegw/config" \
    "$INSTALL_DIR/panel/modules/sidegw/config.last_good" \
    /etc/crontabs/root \
    /etc/config/firewall
do
    [ -e "$item" ] && set -- "$@" "$item"
done

[ "$#" -gt 0 ] || die "nothing to backup"
tar czf "$OUT" "$@" 2>/dev/null || die "backup failed"

echo "$OUT"
