#!/bin/sh
set -u

SCRIPT_DIR="$(unset CDPATH; cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/common.sh
. "$SCRIPT_DIR/common.sh"

INSTALL_DIR="$DEFAULT_INSTALL_DIR"
TEST_ROUTE_IP="${XIAOMI_TOOLBOX_TEST_ROUTE_IP:-8.8.8.8}"
[ "$#" -ge 2 ] && [ "$1" = "--install-dir" ] && INSTALL_DIR="$2"

echo "=== system ==="
uname -a 2>/dev/null || true
date 2>/dev/null || true

echo "=== commands ==="
for cmd in ip iptables uci uhttpd pidof nslookup wget stat; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "$cmd: ok"
    else
        echo "$cmd: missing"
    fi
done

echo "=== route capability probes ==="
route_iif_log="/tmp/xiaomi-toolbox-route-iif.$$"
if ip route get "$TEST_ROUTE_IP" iif br-lan >"$route_iif_log" 2>&1; then
    echo "ip route get iif: ok ($TEST_ROUTE_IP)"
else
    echo "ip route get iif: unavailable or failed ($TEST_ROUTE_IP)"
    cat "$route_iif_log" 2>/dev/null || true
fi
rm -f "$route_iif_log"

route_mark_log="/tmp/xiaomi-toolbox-route-mark.$$"
if ip route get "$TEST_ROUTE_IP" mark 0x64 >"$route_mark_log" 2>&1; then
    echo "ip route get mark: ok ($TEST_ROUTE_IP)"
else
    echo "ip route get mark: unavailable or failed ($TEST_ROUTE_IP)"
    cat "$route_mark_log" 2>/dev/null || true
fi
rm -f "$route_mark_log"

if stat -c %Y /tmp >/dev/null 2>&1; then
    echo "stat -c %Y: ok"
else
    echo "stat -c %Y: unavailable; sidegw lock fallback will use lock timestamp file"
fi

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
