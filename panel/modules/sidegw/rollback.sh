#!/bin/sh

BASE="${SIDEGW_BASE:-$(unset CDPATH; cd "$(dirname "$0")" && pwd)}"
CONF="$BASE/config"
LOCK_DIR="/tmp/xiaomi-toolbox-sidegw.lock"
LOCK_PID="$LOCK_DIR/pid"
LOCK_TIME="$LOCK_DIR/created"
LOCK_STALE_AFTER="${SIDEGW_LOCK_STALE_AFTER:-300}"
LOCK_HELD="${SIDEGW_LOCK_HELD:-0}"

release_lock() {
    [ "$LOCK_HELD" = "1" ] && return
    lock_pid="$(cat "$LOCK_PID" 2>/dev/null || echo)"
    [ "$lock_pid" = "$$" ] || return
    rm -f "$LOCK_PID" "$LOCK_TIME"
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

take_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        if echo "$$" > "$LOCK_PID" 2>/dev/null; then
            date +%s > "$LOCK_TIME" 2>/dev/null || true
            trap 'release_lock' EXIT INT TERM
            return 0
        fi
        rmdir "$LOCK_DIR" 2>/dev/null || true
        return 1
    fi

    lock_pid="$(cat "$LOCK_PID" 2>/dev/null || echo)"
    reclaim_lock=0
    if echo "$lock_pid" | grep -Eq '^[0-9]+$'; then
        kill -0 "$lock_pid" 2>/dev/null || reclaim_lock=1
    else
        now="$(date +%s 2>/dev/null || echo 0)"
        lock_mtime="$(cat "$LOCK_TIME" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0)"
        if echo "$now" "$lock_mtime" "$LOCK_STALE_AFTER" | grep -Eq '^[0-9]+ [0-9]+ [0-9]+$' &&
            [ "$now" -gt 0 ] &&
            [ "$lock_mtime" -gt 0 ] &&
            [ $((now - lock_mtime)) -ge "$LOCK_STALE_AFTER" ]; then
            reclaim_lock=1
        fi
    fi

    if [ "$reclaim_lock" = "1" ]; then
        rm -f "$LOCK_PID" "$LOCK_TIME"
        rmdir "$LOCK_DIR" 2>/dev/null || true
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            if echo "$$" > "$LOCK_PID" 2>/dev/null; then
                date +%s > "$LOCK_TIME" 2>/dev/null || true
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

[ -f "$CONF" ] || cp "$BASE/config.default" "$CONF" || {
    echo "rollback failed; cannot initialize sidegw config" >&2
    exit 1
}

tmp="$CONF.tmp.$$"
{
    echo "ENABLED='0'"
    grep -v "^[[:space:]]*ENABLED=" "$CONF"
} > "$tmp" || {
    rm -f "$tmp"
    echo "rollback failed; cannot write disabled sidegw config" >&2
    exit 1
}
mv "$tmp" "$CONF" || {
    rm -f "$tmp"
    echo "rollback failed; cannot replace sidegw config" >&2
    exit 1
}

SIDEGW_LOCK_HELD=1 "$BASE/apply.sh" || {
    echo "rollback failed; sidegw rules may still be active" >&2
    exit 1
}
rm -f "$BASE/config.pending_good" "$BASE/config.pending_until" || {
    echo "rollback failed; pending confirmation markers may still exist" >&2
    exit 1
}
