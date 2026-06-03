#!/bin/sh

BASE="${SIDEGW_BASE:-$(CDPATH= cd "$(dirname "$0")" && pwd)}"
CONF="${SIDEGW_CONFIG:-$BASE/config}"
TABLE="${SIDEGW_TABLE:-100}"
LAN_IF="${SIDEGW_LAN_IF:-br-lan}"
LAN_CIDR="${SIDEGW_LAN_CIDR:-192.168.31.0/24}"
CHAIN="SIDEGW"
DNS_CHAIN="SIDEGW_DNS"
DNS_POST_CHAIN="SIDEGW_DNS_POST"
FWD_CHAIN="SIDEGW_FWD"
PREF_START=10000
PREF_END=10299
MARK_SIDE="0x64"
MARK_DIRECT="0x65"

valid_ip() {
    echo "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || return 1
    oldifs="$IFS"
    IFS=.
    set -- $1
    IFS="$oldifs"
    [ "$#" -eq 4 ] || return 1
    [ "$1" -le 255 ] && [ "$2" -le 255 ] && [ "$3" -le 255 ] && [ "$4" -le 255 ]
}

valid_cidr() {
    echo "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' || return 1
    ip="${1%/*}"
    bits="${1#*/}"
    valid_ip "$ip" && [ "$bits" -ge 0 ] && [ "$bits" -le 32 ]
}

valid_mac() {
    echo "$1" | grep -Eiq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
}

log() {
    logger -t sidegw "$1" 2>/dev/null || true
    echo "$1"
}

rule_del_pref() {
    pref="$1"
    while ip rule del pref "$pref" 2>/dev/null; do :; done
}

iptables_cleanup() {
    while iptables -t mangle -D PREROUTING -i "$LAN_IF" -j "$CHAIN" 2>/dev/null; do :; done
    iptables -t mangle -F "$CHAIN" 2>/dev/null || true
    iptables -t mangle -X "$CHAIN" 2>/dev/null || true

    while iptables -D FORWARD -i "$LAN_IF" -o "$LAN_IF" -j "$FWD_CHAIN" 2>/dev/null; do :; done
    iptables -F "$FWD_CHAIN" 2>/dev/null || true
    iptables -X "$FWD_CHAIN" 2>/dev/null || true

    while iptables -t nat -D PREROUTING -i "$LAN_IF" -j "$DNS_CHAIN" 2>/dev/null; do :; done
    iptables -t nat -F "$DNS_CHAIN" 2>/dev/null || true
    iptables -t nat -X "$DNS_CHAIN" 2>/dev/null || true

    while iptables -t nat -D POSTROUTING -o "$LAN_IF" -j "$DNS_POST_CHAIN" 2>/dev/null; do :; done
    iptables -t nat -F "$DNS_POST_CHAIN" 2>/dev/null || true
    iptables -t nat -X "$DNS_POST_CHAIN" 2>/dev/null || true
}

sysctl_tune() {
    for key in \
        /proc/sys/net/ipv4/conf/all/send_redirects \
        /proc/sys/net/ipv4/conf/default/send_redirects \
        /proc/sys/net/ipv4/conf/"$LAN_IF"/send_redirects \
        /proc/sys/net/ipv4/conf/all/rp_filter \
        /proc/sys/net/ipv4/conf/default/rp_filter \
        /proc/sys/net/ipv4/conf/"$LAN_IF"/rp_filter
    do
        [ -e "$key" ] && echo 0 > "$key" 2>/dev/null || true
    done
}

add_direct_ip_rules() {
    idx=0
    for ipaddr in $DIRECT_IPS $GATEWAY; do
        valid_ip "$ipaddr" || continue
        pref=$((10010 + idx))
        ip rule add pref "$pref" from "$ipaddr/32" lookup main 2>/dev/null || true
        idx=$((idx + 1))
        [ "$idx" -ge 80 ] && break
    done
}

add_side_ip_rules() {
    idx=0
    for ipaddr in $SIDE_IPS; do
        valid_ip "$ipaddr" || continue
        pref=$((10110 + idx))
        ip rule add pref "$pref" from "$ipaddr/32" table "$TABLE" 2>/dev/null || true
        idx=$((idx + 1))
        [ "$idx" -ge 120 ] && break
    done
    echo "$idx"
}

add_mac_rules() {
    direct_count=0
    side_count=0

    iptables -t mangle -N "$CHAIN" 2>/dev/null || true
    iptables -t mangle -C PREROUTING -i "$LAN_IF" -j "$CHAIN" 2>/dev/null ||
        iptables -t mangle -A PREROUTING -i "$LAN_IF" -j "$CHAIN"

    for mac in $DIRECT_MACS; do
        mac_lc="$(echo "$mac" | tr 'A-F' 'a-f')"
        valid_mac "$mac_lc" || continue
        iptables -t mangle -A "$CHAIN" -m mac --mac-source "$mac_lc" -j MARK --set-mark "$MARK_DIRECT"
        iptables -t mangle -A "$CHAIN" -m mac --mac-source "$mac_lc" -j RETURN
        direct_count=$((direct_count + 1))
    done

    for mac in $SIDE_MACS; do
        mac_lc="$(echo "$mac" | tr 'A-F' 'a-f')"
        valid_mac "$mac_lc" || continue
        iptables -t mangle -A "$CHAIN" -m mac --mac-source "$mac_lc" -j MARK --set-mark "$MARK_SIDE"
        iptables -t mangle -A "$CHAIN" -m mac --mac-source "$mac_lc" -j RETURN
        side_count=$((side_count + 1))
    done

    if [ "$MODE" = "all" ] && valid_cidr "$LAN_CIDR"; then
        iptables -t mangle -A "$CHAIN" -s "$LAN_CIDR" -j MARK --set-mark "$MARK_SIDE"
    fi

    echo "$direct_count $side_count"
}

add_forward_rules() {
    fwd_count=0

    iptables -N "$FWD_CHAIN" 2>/dev/null || true
    iptables -C FORWARD -i "$LAN_IF" -o "$LAN_IF" -j "$FWD_CHAIN" 2>/dev/null ||
        iptables -I FORWARD 1 -i "$LAN_IF" -o "$LAN_IF" -j "$FWD_CHAIN"

    for ipaddr in $DIRECT_IPS; do
        valid_ip "$ipaddr" || continue
        iptables -A "$FWD_CHAIN" -s "$ipaddr/32" -j RETURN
    done

    for mac in $DIRECT_MACS; do
        mac_lc="$(echo "$mac" | tr 'A-F' 'a-f')"
        valid_mac "$mac_lc" || continue
        iptables -A "$FWD_CHAIN" -m mac --mac-source "$mac_lc" -j RETURN
    done

    for ipaddr in $SIDE_IPS; do
        valid_ip "$ipaddr" || continue
        iptables -A "$FWD_CHAIN" -s "$ipaddr/32" -j ACCEPT
        iptables -A "$FWD_CHAIN" -s "$GATEWAY/32" -d "$ipaddr/32" -j ACCEPT
        fwd_count=$((fwd_count + 1))
    done

    for mac in $SIDE_MACS; do
        mac_lc="$(echo "$mac" | tr 'A-F' 'a-f')"
        valid_mac "$mac_lc" || continue
        iptables -A "$FWD_CHAIN" -m mac --mac-source "$mac_lc" -j ACCEPT
        fwd_count=$((fwd_count + 1))
    done

    if [ "$MODE" = "all" ] && valid_cidr "$LAN_CIDR"; then
        iptables -A "$FWD_CHAIN" -s "$LAN_CIDR" -j ACCEPT
        fwd_count=$((fwd_count + 1))
    fi

    echo "$fwd_count"
}

add_dns_rules() {
    dns_count=0
    router_ip="$(ip -4 addr show dev "$LAN_IF" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n 1)"
    [ -n "$router_ip" ] || router_ip="192.168.31.1"

    iptables -t nat -N "$DNS_CHAIN" 2>/dev/null || true
    iptables -t nat -C PREROUTING -i "$LAN_IF" -j "$DNS_CHAIN" 2>/dev/null ||
        iptables -t nat -A PREROUTING -i "$LAN_IF" -j "$DNS_CHAIN"
    iptables -t nat -N "$DNS_POST_CHAIN" 2>/dev/null || true
    iptables -t nat -C POSTROUTING -o "$LAN_IF" -j "$DNS_POST_CHAIN" 2>/dev/null ||
        iptables -t nat -A POSTROUTING -o "$LAN_IF" -j "$DNS_POST_CHAIN"

    for ipaddr in $DIRECT_IPS $GATEWAY; do
        valid_ip "$ipaddr" || continue
        iptables -t nat -A "$DNS_CHAIN" -s "$ipaddr/32" -j RETURN
        iptables -t nat -A "$DNS_POST_CHAIN" -s "$ipaddr/32" -j RETURN
    done

    iptables -t nat -A "$DNS_POST_CHAIN" -m mark --mark "$MARK_DIRECT" -j RETURN

    for mac in $DIRECT_MACS; do
        mac_lc="$(echo "$mac" | tr 'A-F' 'a-f')"
        valid_mac "$mac_lc" || continue
        iptables -t nat -A "$DNS_CHAIN" -m mac --mac-source "$mac_lc" -j RETURN
    done

    for ipaddr in $SIDE_IPS; do
        valid_ip "$ipaddr" || continue
        iptables -t nat -A "$DNS_CHAIN" -s "$ipaddr/32" -p udp --dport 53 -j DNAT --to-destination "$GATEWAY"
        iptables -t nat -A "$DNS_CHAIN" -s "$ipaddr/32" -p tcp --dport 53 -j DNAT --to-destination "$GATEWAY"
        iptables -t nat -A "$DNS_POST_CHAIN" -s "$ipaddr/32" -d "$GATEWAY/32" -p udp --dport 53 -j SNAT --to-source "$router_ip"
        iptables -t nat -A "$DNS_POST_CHAIN" -s "$ipaddr/32" -d "$GATEWAY/32" -p tcp --dport 53 -j SNAT --to-source "$router_ip"
        dns_count=$((dns_count + 1))
    done

    for mac in $SIDE_MACS; do
        mac_lc="$(echo "$mac" | tr 'A-F' 'a-f')"
        valid_mac "$mac_lc" || continue
        iptables -t nat -A "$DNS_CHAIN" -m mac --mac-source "$mac_lc" -p udp --dport 53 -j DNAT --to-destination "$GATEWAY"
        iptables -t nat -A "$DNS_CHAIN" -m mac --mac-source "$mac_lc" -p tcp --dport 53 -j DNAT --to-destination "$GATEWAY"
        iptables -t nat -A "$DNS_POST_CHAIN" -m mark --mark "$MARK_SIDE" -d "$GATEWAY/32" -p udp --dport 53 -j SNAT --to-source "$router_ip"
        iptables -t nat -A "$DNS_POST_CHAIN" -m mark --mark "$MARK_SIDE" -d "$GATEWAY/32" -p tcp --dport 53 -j SNAT --to-source "$router_ip"
        dns_count=$((dns_count + 1))
    done

    if [ "$MODE" = "all" ] && valid_cidr "$LAN_CIDR"; then
        iptables -t nat -A "$DNS_CHAIN" -s "$LAN_CIDR" -p udp --dport 53 -j DNAT --to-destination "$GATEWAY"
        iptables -t nat -A "$DNS_CHAIN" -s "$LAN_CIDR" -p tcp --dport 53 -j DNAT --to-destination "$GATEWAY"
        iptables -t nat -A "$DNS_POST_CHAIN" -s "$LAN_CIDR" -d "$GATEWAY/32" -p udp --dport 53 -j SNAT --to-source "$router_ip"
        iptables -t nat -A "$DNS_POST_CHAIN" -s "$LAN_CIDR" -d "$GATEWAY/32" -p tcp --dport 53 -j SNAT --to-source "$router_ip"
        dns_count=$((dns_count + 1))
    fi

    echo "$dns_count"
}

[ -f "$CONF" ] || cp "$BASE/config.default" "$CONF"
. "$CONF"

ENABLED="${ENABLED:-0}"
MODE="${MODE:-list}"
GATEWAY="${GATEWAY:-}"
LAN_CIDR="${LAN_CIDR:-192.168.31.0/24}"
SIDE_IPS="${SIDE_IPS:-}"
SIDE_MACS="${SIDE_MACS:-}"
DIRECT_IPS="${DIRECT_IPS:-}"
DIRECT_MACS="${DIRECT_MACS:-}"

[ "$MODE" = "all" ] || MODE="list"

if [ "$ENABLED" = "1" ]; then
    valid_ip "$GATEWAY" || { log "invalid gateway: $GATEWAY"; exit 1; }
    valid_cidr "$LAN_CIDR" || { log "invalid lan cidr: $LAN_CIDR"; exit 1; }
    [ -d "/sys/class/net/$LAN_IF" ] || { log "lan interface missing: $LAN_IF"; exit 1; }
    ip route get "$GATEWAY" >/tmp/sidegw-gateway-route.log 2>&1 || {
        log "gateway is not reachable by current routing table: $GATEWAY"
        exit 1
    }
fi

i="$PREF_START"
while [ "$i" -le "$PREF_END" ]; do
    rule_del_pref "$i"
    i=$((i + 1))
done

ip route flush table "$TABLE" 2>/dev/null || true
iptables_cleanup
sysctl_tune

if [ "$ENABLED" != "1" ]; then
    ip route flush cache 2>/dev/null || true
    log "disabled"
    exit 0
fi

if ! ip route replace default via "$GATEWAY" dev "$LAN_IF" table "$TABLE" 2>/tmp/sidegw-route.err; then
    log "cannot add route via $GATEWAY: $(cat /tmp/sidegw-route.err)"
    exit 2
fi

ip rule add pref 10001 fwmark "$MARK_DIRECT" lookup main 2>/dev/null || true
ip rule add pref 10100 fwmark "$MARK_SIDE" table "$TABLE" 2>/dev/null || true
add_direct_ip_rules
side_ip_count="$(add_side_ip_rules)"
set -- $(add_mac_rules)
direct_mac_count="${1:-0}"
side_mac_count="${2:-0}"
fwd_rule_count="$(add_forward_rules)"
dns_rule_count="$(add_dns_rules)"

if [ "$MODE" = "all" ]; then
    ip rule add pref 10200 from "$LAN_CIDR" table "$TABLE" 2>/dev/null || true
fi

ip route flush cache 2>/dev/null || true
log "enabled mode=$MODE gateway=$GATEWAY side_ips=$side_ip_count side_macs=$side_mac_count direct_macs=$direct_mac_count fwd_rules=$fwd_rule_count dns_rules=$dns_rule_count"
