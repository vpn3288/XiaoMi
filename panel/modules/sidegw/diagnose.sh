#!/bin/sh

BASE="${SIDEGW_BASE:-$(unset CDPATH; cd "$(dirname "$0")" && pwd)}"
CONF="$BASE/config"
REDACT="${SIDEGW_REDACT:-1}"

redact_sensitive() {
    if [ "$REDACT" != "1" ]; then
        cat
        return
    fi
    sed \
        -e 's/\([Tt][Oo][Kk][Ee][Nn][^= :]*[=:][[:space:]]*\)[^[:space:]]*/\1REDACTED/g' \
        -e 's/\([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][^= :]*[=:][[:space:]]*\)[^[:space:]]*/\1REDACTED/g' \
        -e 's/\([Pp][Aa][Ss][Ss][Ww][Dd][^= :]*[=:][[:space:]]*\)[^[:space:]]*/\1REDACTED/g' \
        -e 's/\([Cc][Oo][Oo][Kk][Ii][Ee][^= :]*[=:][[:space:]]*\)[^[:space:]]*/\1REDACTED/g' \
        -e 's/\([Ss][Ee][Cc][Rr][Ee][Tt][^= :]*[=:][[:space:]]*\)[^[:space:]]*/\1REDACTED/g' \
        -e 's/\([Kk][Ee][Yy][^= :]*[=:][[:space:]]*\)[^[:space:]]*/\1REDACTED/g' \
        -e 's/\([Uu][Uu][Ii][Dd][^= :]*[=:][[:space:]]*\)[^[:space:]]*/\1REDACTED/g' \
        -e 's#https\{0,1\}://[^[:space:]]*#URL_REDACTED#g' \
        -e 's/\([0-9A-Fa-f][0-9A-Fa-f]:\)\{5\}[0-9A-Fa-f][0-9A-Fa-f]/MAC_REDACTED/g'
}

emit() {
    if [ "$REDACT" = "1" ]; then
        "$@" 2>&1 | redact_sensitive
    else
        "$@"
    fi
}

echo "=== sidegw config ==="
if [ -f "$CONF" ]; then
    emit cat "$CONF"
else
    echo "missing config"
fi

echo "=== lan ==="
ip -4 addr show br-lan 2>/dev/null || true
ip route 2>/dev/null || true

echo "=== sidegw rules ==="
ip rule 2>/dev/null || true
ip route show table 100 2>/dev/null || true

echo "=== iptables sidegw ==="
emit iptables -vnL SIDEGW_FWD || true
emit iptables -t mangle -vnL SIDEGW || true
emit iptables -t nat -vnL SIDEGW_DNS || true
emit iptables -t nat -vnL SIDEGW_DNS_POST || true

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
emit lsmod | grep -Ei 'qca[-_].*(nss|sfe|ppe)|shortcut|ecm|flow' || echo "kernel module hints: none detected"
emit iptables-save | grep -i FLOWOFFLOAD || echo "iptables FLOWOFFLOAD: none detected"
emit nft list ruleset | grep -Ei 'flowtable|flow offload' || echo "nft flow offload: none detected"

echo "=== sidegw log ==="
emit logread | grep -i sidegw | tail -50 || true
emit tail -50 /tmp/xiaomi-toolbox-sidegw.log || true
