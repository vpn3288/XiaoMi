#!/bin/sh
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"

INSTALL_DIR="$DEFAULT_INSTALL_DIR"
OUT="/tmp/xiaomi-toolbox-backup-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now).tgz"

[ "$#" -ge 2 ] && [ "$1" = "--install-dir" ] && INSTALL_DIR="$2"

tar czf "$OUT" \
    "$INSTALL_DIR/config" \
    "$INSTALL_DIR/panel/modules/sidegw/config" \
    /etc/crontabs/root \
    /etc/config/firewall 2>/dev/null || die "backup failed"

echo "$OUT"

