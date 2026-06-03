#!/bin/sh

BASE="${SIDEGW_BASE:-$(CDPATH= cd "$(dirname "$0")" && pwd)}"
CONF="$BASE/config"
LOCK_DIR="/tmp/xiaomi-toolbox-sidegw.lock"
LOCK_HELD="${SIDEGW_LOCK_HELD:-0}"

release_lock() {
    [ "$LOCK_HELD" = "1" ] || rmdir "$LOCK_DIR" 2>/dev/null || true
}

if [ "$LOCK_HELD" != "1" ]; then
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "sidegw is busy; another apply/test/rollback is running" >&2
        exit 3
    fi
    trap 'release_lock' EXIT INT TERM
fi

[ -f "$CONF" ] || cp "$BASE/config.default" "$CONF"

tmp="$CONF.tmp.$$"
{
    echo "ENABLED='0'"
    grep -v "^ENABLED=" "$CONF"
} > "$tmp"
mv "$tmp" "$CONF"

SIDEGW_LOCK_HELD=1 "$BASE/apply.sh" || {
    echo "rollback failed; sidegw rules may still be active" >&2
    exit 1
}
rm -f "$BASE/config.last_good" "$BASE/config.pending_good" "$BASE/config.pending_until"
