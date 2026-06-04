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
RULE_STATE="$BASE/rules.state"
APPLIED_CONFIG="$BASE/config.applied"
NEW_RULE_STATE="/tmp/sidegw-rules.$$"
LOCK_DIR="/tmp/xiaomi-toolbox-sidegw.lock"
LOCK_PID="$LOCK_DIR/pid"
LOCK_STALE_AFTER="${SIDEGW_LOCK_STALE_AFTER:-300}"
LOCK_HELD="${SIDEGW_LOCK_HELD:-0}"
APPLY_FAILED=0
SIDE_IP_COUNT=0
DIRECT_MAC_COUNT=0
SIDE_MAC_COUNT=0
FWD_RULE_COUNT=0
DNS_RULE_COUNT=0

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
    reclaim_lock=0
    if echo "$lock_pid" | grep -Eq '^[0-9]+$'; then
        kill -0 "$lock_pid" 2>/dev/null || reclaim_lock=1
    else
        now="$(date +%s 2>/dev/null || echo 0)"
        lock_mtime="$(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0)"
        if echo "$now" "$lock_mtime" "$LOCK_STALE_AFTER" | grep -Eq '^[0-9]+ [0-9]+ [0-9]+$' &&
            [ "$now" -gt 0 ] &&
            [ "$lock_mtime" -gt 0 ] &&
            [ $((now - lock_mtime)) -ge "$LOCK_STALE_AFTER" ]; then
            reclaim_lock=1
        fi
    fi

    if [ "$reclaim_lock" = "1" ]; then
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
        log "sidegw is busy; another apply/test/rollback is running"
        exit 3
    fi
fi

fail_apply() {
    logger -t sidegw "$1" 2>/dev/null || true
    printf '%s\n' "$1" >&2
    APPLY_FAILED=1
}

ip_rule_add_must() {
    if ! ip rule add "$@" 2>/tmp/sidegw-ip-rule.err; then
        fail_apply "ip rule add failed: $* $(cat /tmp/sidegw-ip-rule.err 2>/dev/null)"
    else
        printf '%s\n' "$*" >> "$NEW_RULE_STATE"
    fi
}

iptables_must() {
    if ! iptables "$@" 2>/tmp/sidegw-iptables.err; then
        fail_apply "iptables failed: iptables $* $(cat /tmp/sidegw-iptables.err 2>/dev/null)"
    fi
}

rule_del_recorded_file() {
    file="$1"
    [ -f "$file" ] || return 0
    while IFS= read -r rule_args; do
        [ -n "$rule_args" ] || continue
        set -- $rule_args
        while ip rule del "$@" 2>/dev/null; do :; done
    done < "$file"
}

rule_del_matching_sidegw() {
    while ip rule del fwmark "$MARK_DIRECT" lookup main 2>/dev/null; do :; done
    while ip rule del fwmark "$MARK_SIDE" table "$TABLE" 2>/dev/null; do :; done

    for ipaddr in $DIRECT_IPS $GATEWAY; do
        valid_ip "$ipaddr" || continue
        while ip rule del from "$ipaddr/32" lookup main 2>/dev/null; do :; done
    done

    for ipaddr in $SIDE_IPS; do
        valid_ip "$ipaddr" || continue
        while ip rule del from "$ipaddr/32" table "$TABLE" 2>/dev/null; do :; done
    done

    if [ "$MODE" = "all" ] && valid_cidr "$LAN_CIDR"; then
        while ip rule del from "$LAN_CIDR" table "$TABLE" 2>/dev/null; do :; done
    fi
}

rule_del_matching_sidegw_file() {
    file="$1"
    [ -f "$file" ] || return 0
    (
        ENABLED=0
        MODE=list
        GATEWAY=
        LAN_CIDR=192.168.31.0/24
        SIDE_IPS=
        DIRECT_IPS=
        . "$file" 2>/dev/null || exit 0
        [ "$MODE" = "all" ] || MODE="list"
        rule_del_matching_sidegw
    )
}

rule_del_sidegw_pref_range() {
    ip rule 2>/dev/null | while IFS= read -r line; do
        pref="${line%%:*}"
        echo "$pref" | grep -Eq '^[0-9]+$' || continue
        [ "$pref" -ge "$PREF_START" ] && [ "$pref" -le "$PREF_END" ] || continue
        case "$line" in
            *" lookup $TABLE"|*" table $TABLE"|*"fwmark $MARK_SIDE"*|*"fwmark $MARK_DIRECT"*|*" lookup main"*)
                while ip rule del pref "$pref" 2>/dev/null; do :; done
                ;;
        esac
    done
}

ip_rules_cleanup() {
    rule_del_recorded_file "$RULE_STATE"
    rule_del_recorded_file "$NEW_RULE_STATE"
    rule_del_matching_sidegw_file "$APPLIED_CONFIG"
    rule_del_matching_sidegw
    rule_del_sidegw_pref_range
}

iptables_cleanup() {
    cleanup_failed=0
    while iptables -t mangle -D PREROUTING -i "$LAN_IF" -j "$CHAIN" 2>/dev/null; do :; done
    if iptables -t mangle -L "$CHAIN" >/dev/null 2>&1; then
        iptables -t mangle -F "$CHAIN" 2>/dev/null || cleanup_failed=1
        iptables -t mangle -X "$CHAIN" 2>/dev/null || cleanup_failed=1
    fi

    while iptables -D FORWARD -i "$LAN_IF" -o "$LAN_IF" -j "$FWD_CHAIN" 2>/dev/null; do :; done
    if iptables -L "$FWD_CHAIN" >/dev/null 2>&1; then
        iptables -F "$FWD_CHAIN" 2>/dev/null || cleanup_failed=1
        iptables -X "$FWD_CHAIN" 2>/dev/null || cleanup_failed=1
    fi

    while iptables -t nat -D PREROUTING -i "$LAN_IF" -j "$DNS_CHAIN" 2>/dev/null; do :; done
    if iptables -t nat -L "$DNS_CHAIN" >/dev/null 2>&1; then
        iptables -t nat -F "$DNS_CHAIN" 2>/dev/null || cleanup_failed=1
        iptables -t nat -X "$DNS_CHAIN" 2>/dev/null || cleanup_failed=1
    fi

    while iptables -t nat -D POSTROUTING -o "$LAN_IF" -j "$DNS_POST_CHAIN" 2>/dev/null; do :; done
    if iptables -t nat -L "$DNS_POST_CHAIN" >/dev/null 2>&1; then
        iptables -t nat -F "$DNS_POST_CHAIN" 2>/dev/null || cleanup_failed=1
        iptables -t nat -X "$DNS_POST_CHAIN" 2>/dev/null || cleanup_failed=1
    fi

    iptables -t mangle -C PREROUTING -i "$LAN_IF" -j "$CHAIN" >/dev/null 2>&1 && cleanup_failed=1
    iptables -C FORWARD -i "$LAN_IF" -o "$LAN_IF" -j "$FWD_CHAIN" >/dev/null 2>&1 && cleanup_failed=1
    iptables -t nat -C PREROUTING -i "$LAN_IF" -j "$DNS_CHAIN" >/dev/null 2>&1 && cleanup_failed=1
    iptables -t nat -C POSTROUTING -o "$LAN_IF" -j "$DNS_POST_CHAIN" >/dev/null 2>&1 && cleanup_failed=1

    [ "$cleanup_failed" = "0" ]
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
        ip_rule_add_must pref "$pref" from "$ipaddr/32" lookup main
        idx=$((idx + 1))
        [ "$idx" -ge 80 ] && break
    done
}

add_side_ip_rules() {
    idx=0
    for ipaddr in $SIDE_IPS; do
        valid_ip "$ipaddr" || continue
        pref=$((10110 + idx))
        ip_rule_add_must pref "$pref" from "$ipaddr/32" table "$TABLE"
        idx=$((idx + 1))
        [ "$idx" -ge 120 ] && break
    done
    SIDE_IP_COUNT="$idx"
}

add_mac_rules() {
    DIRECT_MAC_COUNT=0
    SIDE_MAC_COUNT=0

    iptables -t mangle -N "$CHAIN" 2>/dev/null || true
    iptables -t mangle -C PREROUTING -i "$LAN_IF" -j "$CHAIN" 2>/dev/null ||
        iptables_must -t mangle -A PREROUTING -i "$LAN_IF" -j "$CHAIN"

    for mac in $DIRECT_MACS; do
        mac_lc="$(echo "$mac" | tr 'A-F' 'a-f')"
        valid_mac "$mac_lc" || continue
        iptables_must -t mangle -A "$CHAIN" -m mac --mac-source "$mac_lc" -j MARK --set-mark "$MARK_DIRECT"
        iptables_must -t mangle -A "$CHAIN" -m mac --mac-source "$mac_lc" -j RETURN
        DIRECT_MAC_COUNT=$((DIRECT_MAC_COUNT + 1))
    done

    for mac in $SIDE_MACS; do
        mac_lc="$(echo "$mac" | tr 'A-F' 'a-f')"
        valid_mac "$mac_lc" || continue
        iptables_must -t mangle -A "$CHAIN" -m mac --mac-source "$mac_lc" -j MARK --set-mark "$MARK_SIDE"
        iptables_must -t mangle -A "$CHAIN" -m mac --mac-source "$mac_lc" -j RETURN
        SIDE_MAC_COUNT=$((SIDE_MAC_COUNT + 1))
    done

    if [ "$MODE" = "all" ] && valid_cidr "$LAN_CIDR"; then
        iptables_must -t mangle -A "$CHAIN" -s "$LAN_CIDR" -j MARK --set-mark "$MARK_SIDE"
    fi
}

add_forward_rules() {
    FWD_RULE_COUNT=0

    iptables -N "$FWD_CHAIN" 2>/dev/null || true
    iptables -C FORWARD -i "$LAN_IF" -o "$LAN_IF" -j "$FWD_CHAIN" 2>/dev/null ||
        iptables_must -I FORWARD 1 -i "$LAN_IF" -o "$LAN_IF" -j "$FWD_CHAIN"

    for ipaddr in $DIRECT_IPS; do
        valid_ip "$ipaddr" || continue
        iptables_must -A "$FWD_CHAIN" -s "$ipaddr/32" -j RETURN
    done

    for mac in $DIRECT_MACS; do
        mac_lc="$(echo "$mac" | tr 'A-F' 'a-f')"
        valid_mac "$mac_lc" || continue
        iptables_must -A "$FWD_CHAIN" -m mac --mac-source "$mac_lc" -j RETURN
    done

    for ipaddr in $SIDE_IPS; do
        valid_ip "$ipaddr" || continue
        iptables_must -A "$FWD_CHAIN" -s "$ipaddr/32" -j ACCEPT
        iptables_must -A "$FWD_CHAIN" -s "$GATEWAY/32" -d "$ipaddr/32" -j ACCEPT
        FWD_RULE_COUNT=$((FWD_RULE_COUNT + 1))
    done

    for mac in $SIDE_MACS; do
        mac_lc="$(echo "$mac" | tr 'A-F' 'a-f')"
        valid_mac "$mac_lc" || continue
        iptables_must -A "$FWD_CHAIN" -m mac --mac-source "$mac_lc" -j ACCEPT
        FWD_RULE_COUNT=$((FWD_RULE_COUNT + 1))
    done

    if [ "$SIDE_MAC_COUNT" -gt 0 ]; then
        iptables_must -A "$FWD_CHAIN" -s "$GATEWAY/32" -j ACCEPT
        FWD_RULE_COUNT=$((FWD_RULE_COUNT + 1))
    fi

    if [ "$MODE" = "all" ] && valid_cidr "$LAN_CIDR"; then
        iptables_must -A "$FWD_CHAIN" -s "$LAN_CIDR" -j ACCEPT
        FWD_RULE_COUNT=$((FWD_RULE_COUNT + 1))
    fi
}

add_dns_rules() {
    DNS_RULE_COUNT=0
    router_ip="$(ip -4 addr show dev "$LAN_IF" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n 1)"
    [ -n "$router_ip" ] || router_ip="192.168.31.1"

    iptables -t nat -N "$DNS_CHAIN" 2>/dev/null || true
    iptables -t nat -C PREROUTING -i "$LAN_IF" -j "$DNS_CHAIN" 2>/dev/null ||
        iptables_must -t nat -A PREROUTING -i "$LAN_IF" -j "$DNS_CHAIN"
    iptables -t nat -N "$DNS_POST_CHAIN" 2>/dev/null || true
    iptables -t nat -C POSTROUTING -o "$LAN_IF" -j "$DNS_POST_CHAIN" 2>/dev/null ||
        iptables_must -t nat -A POSTROUTING -o "$LAN_IF" -j "$DNS_POST_CHAIN"

    for ipaddr in $DIRECT_IPS $GATEWAY; do
        valid_ip "$ipaddr" || continue
        iptables_must -t nat -A "$DNS_CHAIN" -s "$ipaddr/32" -j RETURN
        iptables_must -t nat -A "$DNS_POST_CHAIN" -s "$ipaddr/32" -j RETURN
    done

    iptables_must -t nat -A "$DNS_POST_CHAIN" -m mark --mark "$MARK_DIRECT" -j RETURN

    for mac in $DIRECT_MACS; do
        mac_lc="$(echo "$mac" | tr 'A-F' 'a-f')"
        valid_mac "$mac_lc" || continue
        iptables_must -t nat -A "$DNS_CHAIN" -m mac --mac-source "$mac_lc" -j RETURN
    done

    for ipaddr in $SIDE_IPS; do
        valid_ip "$ipaddr" || continue
        iptables_must -t nat -A "$DNS_CHAIN" -s "$ipaddr/32" -p udp --dport 53 -j DNAT --to-destination "$GATEWAY"
        iptables_must -t nat -A "$DNS_CHAIN" -s "$ipaddr/32" -p tcp --dport 53 -j DNAT --to-destination "$GATEWAY"
        iptables_must -t nat -A "$DNS_POST_CHAIN" -s "$ipaddr/32" -d "$GATEWAY/32" -p udp --dport 53 -j SNAT --to-source "$router_ip"
        iptables_must -t nat -A "$DNS_POST_CHAIN" -s "$ipaddr/32" -d "$GATEWAY/32" -p tcp --dport 53 -j SNAT --to-source "$router_ip"
        DNS_RULE_COUNT=$((DNS_RULE_COUNT + 1))
    done

    for mac in $SIDE_MACS; do
        mac_lc="$(echo "$mac" | tr 'A-F' 'a-f')"
        valid_mac "$mac_lc" || continue
        iptables_must -t nat -A "$DNS_CHAIN" -m mac --mac-source "$mac_lc" -p udp --dport 53 -j DNAT --to-destination "$GATEWAY"
        iptables_must -t nat -A "$DNS_CHAIN" -m mac --mac-source "$mac_lc" -p tcp --dport 53 -j DNAT --to-destination "$GATEWAY"
        iptables_must -t nat -A "$DNS_POST_CHAIN" -m mark --mark "$MARK_SIDE" -d "$GATEWAY/32" -p udp --dport 53 -j SNAT --to-source "$router_ip"
        iptables_must -t nat -A "$DNS_POST_CHAIN" -m mark --mark "$MARK_SIDE" -d "$GATEWAY/32" -p tcp --dport 53 -j SNAT --to-source "$router_ip"
        DNS_RULE_COUNT=$((DNS_RULE_COUNT + 1))
    done

    if [ "$MODE" = "all" ] && valid_cidr "$LAN_CIDR"; then
        iptables_must -t nat -A "$DNS_CHAIN" -s "$LAN_CIDR" -p udp --dport 53 -j DNAT --to-destination "$GATEWAY"
        iptables_must -t nat -A "$DNS_CHAIN" -s "$LAN_CIDR" -p tcp --dport 53 -j DNAT --to-destination "$GATEWAY"
        iptables_must -t nat -A "$DNS_POST_CHAIN" -s "$LAN_CIDR" -d "$GATEWAY/32" -p udp --dport 53 -j SNAT --to-source "$router_ip"
        iptables_must -t nat -A "$DNS_POST_CHAIN" -s "$LAN_CIDR" -d "$GATEWAY/32" -p tcp --dport 53 -j SNAT --to-source "$router_ip"
        DNS_RULE_COUNT=$((DNS_RULE_COUNT + 1))
    fi
}

command -v ip >/dev/null 2>&1 || { log "missing command: ip"; exit 1; }
command -v iptables >/dev/null 2>&1 || { log "missing command: iptables"; exit 1; }

rm -f "$NEW_RULE_STATE"
: > "$NEW_RULE_STATE"

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

ip_rules_cleanup
ip route flush table "$TABLE" 2>/dev/null || true
if ! iptables_cleanup; then
    log "failed to clean existing sidegw iptables rules"
    exit 2
fi
sysctl_tune

if [ "$ENABLED" != "1" ]; then
    cp "$CONF" "$APPLIED_CONFIG" 2>/dev/null || true
    rm -f "$RULE_STATE" "$NEW_RULE_STATE"
    ip route flush cache 2>/dev/null || true
    log "disabled"
    exit 0
fi

if ! ip route replace default via "$GATEWAY" dev "$LAN_IF" table "$TABLE" 2>/tmp/sidegw-route.err; then
    log "cannot add route via $GATEWAY: $(cat /tmp/sidegw-route.err)"
    exit 2
fi

ip_rule_add_must pref 10001 fwmark "$MARK_DIRECT" lookup main
ip_rule_add_must pref 10100 fwmark "$MARK_SIDE" table "$TABLE"
add_direct_ip_rules
add_side_ip_rules
add_mac_rules
add_forward_rules
add_dns_rules

if [ "$MODE" = "all" ]; then
    ip_rule_add_must pref 10200 from "$LAN_CIDR" table "$TABLE"
fi

if [ "$APPLY_FAILED" != "0" ]; then
    log "apply failed; cleaning partial sidegw rules"
    ip_rules_cleanup
    ip route flush table "$TABLE" 2>/dev/null || true
    iptables_cleanup || true
    ip route flush cache 2>/dev/null || true
    rm -f "$NEW_RULE_STATE"
    exit 2
fi

mv "$NEW_RULE_STATE" "$RULE_STATE"
cp "$CONF" "$APPLIED_CONFIG" 2>/dev/null || true
ip route flush cache 2>/dev/null || true
log "enabled mode=$MODE gateway=$GATEWAY side_ips=$SIDE_IP_COUNT side_macs=$SIDE_MAC_COUNT direct_macs=$DIRECT_MAC_COUNT fwd_rules=$FWD_RULE_COUNT dns_rules=$DNS_RULE_COUNT"
