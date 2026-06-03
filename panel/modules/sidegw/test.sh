#!/bin/sh

BASE="${SIDEGW_BASE:-$(CDPATH= cd "$(dirname "$0")" && pwd)}"
CONF="$BASE/config"
LAST_GOOD="$BASE/config.last_good"
TEST_DOMAIN="${SIDEGW_TEST_DOMAIN:-www.google.com}"
TEST_URL="${SIDEGW_TEST_URL:-http://connect.rom.miui.com/generate_204}"

[ -f "$CONF" ] || cp "$BASE/config.default" "$CONF"
rollback_conf="/tmp/sidegw-rollback-conf.$$"
if [ -f "$LAST_GOOD" ]; then
    cp "$LAST_GOOD" "$rollback_conf"
else
    sed "s/^ENABLED=.*/ENABLED='0'/" "$BASE/config.default" > "$rollback_conf"
fi

rollback() {
    cp "$rollback_conf" "$CONF"
    if [ -f "$LAST_GOOD" ]; then
        SIDEGW_CONFIG="$LAST_GOOD" "$BASE/apply.sh" >/dev/null 2>&1 || true
    else
        "$BASE/apply.sh" >/dev/null 2>&1 || true
    fi
    rm -f "$rollback_conf"
}

if ! "$BASE/apply.sh"; then
    rollback
    echo "apply failed; rolled back"
    exit 1
fi

sleep 3

dns_ok=0
route_ok=0
gateway_ok=0
chains_ok=0
url_ok=0
route_note=""
router_ip="$(ip -4 addr show dev br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n 1)"
[ -n "$router_ip" ] || router_ip="192.168.31.1"
. "$CONF"

if [ "$MODE" = "all" ]; then
    rollback
    echo "precheck rejected; all-LAN mode requires a future confirmation workflow"
    exit 2
fi

if [ -z "$SIDE_IPS" ]; then
    rollback
    echo "precheck rejected; at least one side IP is required for automatic verification"
    exit 2
fi

nslookup "$TEST_DOMAIN" "$router_ip" >/tmp/sidegw-test-dns.log 2>&1 && dns_ok=1
ping -c 1 -W 2 "$GATEWAY" >/tmp/sidegw-test-gateway.log 2>&1 && gateway_ok=1

for ipaddr in $SIDE_IPS; do
    route_ok=0
    ip route get 8.8.8.8 from "$ipaddr" iif br-lan 2>/tmp/sidegw-test-route.log | grep -q "via $GATEWAY" && {
        route_ok=1
        route_note="route source check passed for $ipaddr"
        break
    }
done

iptables -vnL SIDEGW_FWD >/tmp/sidegw-test-fwd.log 2>&1 &&
    iptables -t nat -vnL SIDEGW_DNS >/tmp/sidegw-test-dns-chain.log 2>&1 &&
    iptables -t nat -vnL SIDEGW_DNS_POST >/tmp/sidegw-test-dns-post.log 2>&1 &&
    chains_ok=1

if command -v wget >/dev/null 2>&1; then
    wget -q -T 5 -O /tmp/sidegw-test-url.out "$TEST_URL" >/tmp/sidegw-test-url.log 2>&1 && url_ok=1
else
    url_ok=1
    echo "wget missing; URL test skipped" >/tmp/sidegw-test-url.log
fi

if [ "$dns_ok" != "1" ] || [ "$gateway_ok" != "1" ] || [ "$route_ok" != "1" ] || [ "$chains_ok" != "1" ] || [ "$url_ok" != "1" ]; then
    rollback
    echo "precheck failed; rolled back"
    echo "dns_ok=$dns_ok gateway_ok=$gateway_ok route_ok=$route_ok chains_ok=$chains_ok url_ok=$url_ok"
    cat /tmp/sidegw-test-dns.log 2>/dev/null || true
    cat /tmp/sidegw-test-gateway.log 2>/dev/null || true
    cat /tmp/sidegw-test-route.log 2>/dev/null || true
    cat /tmp/sidegw-test-url.log 2>/dev/null || true
    exit 2
fi

cp "$CONF" "$LAST_GOOD"
rm -f "$rollback_conf"

echo "precheck passed"
echo "dns_ok=$dns_ok gateway_ok=$gateway_ok route_ok=$route_ok chains_ok=$chains_ok url_ok=$url_ok"
[ -n "$route_note" ] && echo "$route_note"
echo "Now test from a matched client:"
echo "curl -4 http://ifconfig.me/ip"
