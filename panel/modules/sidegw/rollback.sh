#!/bin/sh

BASE="${SIDEGW_BASE:-$(CDPATH= cd "$(dirname "$0")" && pwd)}"
CONF="$BASE/config"
LOCK_DIR="/tmp/xiaomi-toolbox-sidegw.lock"
LOCK_PID="$LOCK_DIR/pid"
LOCK_HELD="${SIDEGW_LOCK_HELD:-0}"

release_lock() {
    [ "$LOCK_HELD" = "1" ] && return
    lock_pid="$(cat "$LOCK_PID" 2>/dev/null || echo)"
    [ "$lock_pid" = "$$" ] || return
    rm -f "$LOCK_PID"
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

take_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        if echo "$$" > "$LOCK_PID" 2>/dev/null; then
            trap 'release_lock' EXIT INT TERM
            return 0
        fi
        rmdir "$LOCK_DIR" 2>/dev/null || true
        return 1
    fi

    lock_pid="$(cat "$LOCK_PID" 2>/dev/null || echo)"
    if [ -z "$lock_pid" ] || ! echo "$lock_pid" | grep -Eq '^[0-9]+$' || ! kill -0 "$lock_pid" 2>/dev/null; then
        rm -f "$LOCK_PID"
        rmdir "$LOCK_DIR" 2>/dev/null || true
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            if echo "$$" > "$LOCK_PID" 2>/dev/null; then
                trap 'release_lock' EXIT INT TERM
                return 0
            fi
            rmdir "$LOCK_DIR" 2>/dev/null || true
        fi
    fi
    return 1
}

if [ "$LOCK_HELD" != "1" ]; then
    if ! take_lock; then
        echo "sidegw is busy; another apply/test/rollback is running" >&2
        exit 3
    fi
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
rm -f "$BASE/config.pending_good" "$BASE/config.pending_until"
