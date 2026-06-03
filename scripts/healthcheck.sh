#!/bin/sh
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIR/common.sh"

INSTALL_DIR="$DEFAULT_INSTALL_DIR"
[ "$#" -ge 2 ] && [ "$1" = "--install-dir" ] && INSTALL_DIR="$2"

echo "=== system ==="
uname -a 2>/dev/null || true
date 2>/dev/null || true

echo "=== commands ==="
for cmd in ip iptables uci uhttpd netstat; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "$cmd: ok"
    else
        echo "$cmd: missing"
    fi
done

echo "=== lan ==="
ip -4 addr show br-lan 2>/dev/null || true
ip route 2>/dev/null || true

echo "=== install ==="
ls -ld "$INSTALL_DIR" 2>/dev/null || true
cat "$INSTALL_DIR/config/toolbox.conf" 2>/dev/null || true

echo "=== sidegw ==="
if [ -x "$INSTALL_DIR/panel/modules/sidegw/diagnose.sh" ]; then
    "$INSTALL_DIR/panel/modules/sidegw/diagnose.sh"
else
    echo "sidegw diagnose missing"
fi

