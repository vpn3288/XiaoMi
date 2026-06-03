#!/bin/sh

BASE="${SIDEGW_BASE:-$(CDPATH= cd "$(dirname "$0")" && pwd)}"
CONF="$BASE/config"

echo "=== sidegw config ==="
cat "$CONF" 2>/dev/null || echo "missing config"

echo "=== lan ==="
ip -4 addr show br-lan 2>/dev/null || true
ip route 2>/dev/null || true

echo "=== sidegw rules ==="
ip rule 2>/dev/null || true
ip route show table 100 2>/dev/null || true

echo "=== iptables sidegw ==="
iptables -vnL SIDEGW_FWD 2>/dev/null || true
iptables -t mangle -vnL SIDEGW 2>/dev/null || true
iptables -t nat -vnL SIDEGW_DNS 2>/dev/null || true
iptables -t nat -vnL SIDEGW_DNS_POST 2>/dev/null || true

echo "=== sysctl ==="
for key in \
    net.ipv4.ip_forward \
    net.ipv4.conf.all.send_redirects \
    net.ipv4.conf.br-lan.send_redirects \
    net.ipv4.conf.all.rp_filter \
    net.ipv4.conf.br-lan.rp_filter
do
    sysctl "$key" 2>/dev/null || true
done

echo "=== flow offload / acceleration hints ==="
lsmod 2>/dev/null | grep -Ei 'qca[-_].*(nss|sfe|ppe)|shortcut|ecm|flow' || echo "kernel module hints: none detected"
iptables-save 2>/dev/null | grep -i FLOWOFFLOAD || echo "iptables FLOWOFFLOAD: none detected"
nft list ruleset 2>/dev/null | grep -Ei 'flowtable|flow offload' || echo "nft flow offload: none detected"

echo "=== sidegw log ==="
logread 2>/dev/null | grep -i sidegw | tail -50 || true
tail -50 /tmp/xiaomi-toolbox-sidegw.log 2>/dev/null || true
