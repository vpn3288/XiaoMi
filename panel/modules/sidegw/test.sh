#!/bin/sh

BASE="${SIDEGW_BASE:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
CONF="$BASE/config"
TEST_DOMAIN="${SIDEGW_TEST_DOMAIN:-www.google.com}"

[ -f "$CONF" ] || cp "$BASE/config.default" "$CONF"

old_conf="$(cat "$CONF")"

if ! "$BASE/apply.sh"; then
    printf '%s\n' "$old_conf" > "$CONF"
    "$BASE/apply.sh" >/dev/null 2>&1 || true
    echo "apply failed; rolled back"
    exit 1
fi

sleep 3

dns_ok=0
route_ok=0
gateway_ok=0
chains_ok=0
router_ip="$(ip -4 addr show dev br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n 1)"
[ -n "$router_ip" ] || router_ip="192.168.31.1"
. "$CONF"

nslookup "$TEST_DOMAIN" "$router_ip" >/tmp/sidegw-test-dns.log 2>&1 && dns_ok=1
ping -c 1 -W 2 "$GATEWAY" >/tmp/sidegw-test-gateway.log 2>&1 && gateway_ok=1

for ipaddr in $SIDE_IPS; do
    ip route get 8.8.8.8 from "$ipaddr" iif br-lan 2>/tmp/sidegw-test-route.log | grep -q "via $GATEWAY" && {
        route_ok=1
        break
    }
done

iptables -vnL SIDEGW_FWD >/tmp/sidegw-test-fwd.log 2>&1 &&
    iptables -t nat -vnL SIDEGW_DNS >/tmp/sidegw-test-dns-chain.log 2>&1 &&
    iptables -t nat -vnL SIDEGW_DNS_POST >/tmp/sidegw-test-dns-post.log 2>&1 &&
    chains_ok=1

if [ "$dns_ok" != "1" ] || [ "$gateway_ok" != "1" ] || [ "$route_ok" != "1" ] || [ "$chains_ok" != "1" ]; then
    printf '%s\n' "$old_conf" > "$CONF"
    "$BASE/apply.sh" >/dev/null 2>&1 || true
    echo "precheck failed; rolled back"
    echo "dns_ok=$dns_ok gateway_ok=$gateway_ok route_ok=$route_ok chains_ok=$chains_ok"
    cat /tmp/sidegw-test-dns.log 2>/dev/null || true
    cat /tmp/sidegw-test-gateway.log 2>/dev/null || true
    cat /tmp/sidegw-test-route.log 2>/dev/null || true
    exit 2
fi

echo "precheck passed"
echo "dns_ok=$dns_ok gateway_ok=$gateway_ok route_ok=$route_ok chains_ok=$chains_ok"
echo "Now test from a matched client:"
echo "curl -4 http://ifconfig.me/ip"
