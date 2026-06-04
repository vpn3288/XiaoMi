#!/bin/sh

BASE="${SIDEGW_BASE:-$(unset CDPATH; cd "$(dirname "$0")" && pwd)}"
REAL_CONF="$BASE/config"
CONF="${SIDEGW_CONFIG:-$REAL_CONF}"
LAST_GOOD="$BASE/config.last_good"
PENDING_GOOD="$BASE/config.pending_good"
PENDING_UNTIL="$BASE/config.pending_until"
TEST_DOMAIN="${SIDEGW_TEST_DOMAIN:-www.google.com}"
TEST_URL="${SIDEGW_TEST_URL:-http://connect.rom.miui.com/generate_204}"
TABLE="${SIDEGW_TABLE:-100}"
LAN_IF="${SIDEGW_LAN_IF:-br-lan}"
MARK_SIDE="${SIDEGW_MARK_SIDE:-0x64}"
LOCK_DIR="/tmp/xiaomi-toolbox-sidegw.lock"
LOCK_PID="$LOCK_DIR/pid"
LOCK_STALE_AFTER="${SIDEGW_LOCK_STALE_AFTER:-300}"
LOCK_HELD="${SIDEGW_LOCK_HELD:-0}"

valid_mac() {
    echo "$1" | grep -Eiq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
}

apply_candidate() {
    SIDEGW_LOCK_HELD=1 SIDEGW_CONFIG="$CONF" "$BASE/apply.sh"
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
        echo "sidegw is busy; another apply/test/rollback is running"
        exit 3
    fi
fi

[ -f "$CONF" ] || cp "$BASE/config.default" "$CONF" || {
    echo "precheck failed; cannot initialize sidegw config"
    exit 1
}
rm -f "$PENDING_GOOD" "$PENDING_UNTIL"

disable_candidate() {
    tmp="$CONF.tmp.$$"
    {
        echo "ENABLED='0'"
        grep -v "^[[:space:]]*ENABLED=" "$CONF"
    } > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$CONF" || {
        rm -f "$tmp"
        return 1
    }
}

# shellcheck source=/dev/null
. "$CONF"
ENABLED="${ENABLED:-0}"
MODE="${MODE:-list}"
SIDE_IPS="${SIDE_IPS:-}"
SIDE_MACS="${SIDE_MACS:-}"

if [ "$ENABLED" != "1" ]; then
    if ! apply_candidate; then
        echo "disabled cleanup failed"
        exit 1
    fi
    echo "disabled"
    exit 0
fi

if [ "$MODE" = "all" ]; then
    if ! disable_candidate; then
        echo "precheck rejected; cannot write disabled candidate config"
        exit 1
    fi
    if ! apply_candidate; then
        echo "precheck rejected; cleanup failed"
        exit 1
    fi
    echo "precheck rejected; all-LAN mode requires a future confirmation workflow"
    exit 2
fi

if [ -z "$SIDE_IPS" ] && [ -z "$SIDE_MACS" ]; then
    if ! disable_candidate; then
        echo "precheck rejected; cannot write disabled candidate config"
        exit 1
    fi
    if ! apply_candidate; then
        echo "precheck rejected; cleanup failed"
        exit 1
    fi
    echo "precheck rejected; at least one side IP or side MAC is required for automatic verification"
    exit 2
fi

rollback_conf="/tmp/sidegw-rollback-conf.$$"
if [ -f "$LAST_GOOD" ]; then
    cp "$LAST_GOOD" "$rollback_conf" || {
        echo "precheck failed; cannot prepare last-good rollback config"
        exit 1
    }
else
    sed "s/^[[:space:]]*ENABLED=.*/ENABLED='0'/" "$BASE/config.default" > "$rollback_conf" || {
        echo "precheck failed; cannot prepare disabled rollback config"
        exit 1
    }
fi

rollback() {
    rollback_failed=0
    cp "$rollback_conf" "$CONF" || rollback_failed=1
    if [ "$rollback_failed" = "0" ] && [ "$CONF" != "$REAL_CONF" ]; then
        cp "$rollback_conf" "$REAL_CONF" || rollback_failed=1
    fi
    if [ "$rollback_failed" = "0" ] && [ -f "$LAST_GOOD" ]; then
        SIDEGW_LOCK_HELD=1 SIDEGW_CONFIG="$LAST_GOOD" "$BASE/apply.sh" >/dev/null 2>&1 || rollback_failed=1
    elif [ "$rollback_failed" = "0" ]; then
        SIDEGW_LOCK_HELD=1 SIDEGW_CONFIG="$CONF" "$BASE/apply.sh" >/dev/null 2>&1 || rollback_failed=1
    fi
    rm -f "$rollback_conf" "$PENDING_GOOD" "$PENDING_UNTIL"
    [ "$rollback_failed" = "0" ]
}

chain_has_parts() {
    table="$1"
    chain="$2"
    shift 2
    if [ "$table" = "filter" ]; then
        lines="$(iptables -S "$chain" 2>/dev/null)" || return 1
    else
        lines="$(iptables -t "$table" -S "$chain" 2>/dev/null)" || return 1
    fi
    for part in "$@"; do
        lines="$(printf '%s\n' "$lines" | grep -F -- "$part")" || return 1
    done
    [ -n "$lines" ]
}

if ! apply_candidate; then
    if rollback; then
        echo "apply failed; rolled back"
    else
        echo "apply failed; rollback also failed"
    fi
    exit 1
fi

sleep 3

dns_ok=0
route_ok=1
gateway_ok=0
rules_ok=1
url_ok=0
route_note=""
mark_route_note=""
router_ip="$(ip -4 addr show dev "$LAN_IF" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n 1)"
[ -n "$router_ip" ] || router_ip="192.168.31.1"
# shellcheck source=/dev/null
. "$CONF"

nslookup "$TEST_DOMAIN" "$router_ip" >/tmp/sidegw-test-dns.log 2>&1 && dns_ok=1
ping -c 1 -W 2 "$GATEWAY" >/tmp/sidegw-test-gateway.log 2>&1 && gateway_ok=1

ip route show table "$TABLE" 2>/tmp/sidegw-test-table.log | grep -F "default via $GATEWAY dev $LAN_IF" >/dev/null || rules_ok=0
ip rule 2>/tmp/sidegw-test-rule.log | grep -F "fwmark 0x64" | grep -F "lookup $TABLE" >/dev/null || rules_ok=0
ip rule 2>/tmp/sidegw-test-direct-rule.log | grep -F "fwmark 0x65" | grep -F "lookup main" >/dev/null || rules_ok=0

for ipaddr in $SIDE_IPS; do
    ip rule 2>/tmp/sidegw-test-side-rule.log | grep -F "from $ipaddr" | grep -F "lookup $TABLE" >/dev/null || rules_ok=0
    chain_has_parts filter SIDEGW_FWD "-s $ipaddr/32" "-j ACCEPT" || rules_ok=0
    chain_has_parts nat SIDEGW_DNS "-s $ipaddr/32" "-p udp" "--dport 53" "-j DNAT" "--to-destination $GATEWAY" || rules_ok=0
    chain_has_parts nat SIDEGW_DNS "-s $ipaddr/32" "-p tcp" "--dport 53" "-j DNAT" "--to-destination $GATEWAY" || rules_ok=0
    chain_has_parts nat SIDEGW_DNS_POST "-s $ipaddr/32" "-d $GATEWAY/32" "-p udp" "--dport 53" "-j SNAT" "--to-source $router_ip" || rules_ok=0
    chain_has_parts nat SIDEGW_DNS_POST "-s $ipaddr/32" "-d $GATEWAY/32" "-p tcp" "--dport 53" "-j SNAT" "--to-source $router_ip" || rules_ok=0
    if ip route get 8.8.8.8 from "$ipaddr" iif "$LAN_IF" 2>/tmp/sidegw-test-route.log | grep -q "via $GATEWAY"; then
        route_note="route source check passed for $ipaddr"
    else
        route_ok=0
    fi
done

for mac in $SIDE_MACS; do
    mac_lc="$(echo "$mac" | tr 'A-F' 'a-f')"
    valid_mac "$mac_lc" || {
        rules_ok=0
        continue
    }
    chain_has_parts mangle SIDEGW "--mac-source $mac_lc" "-j MARK" || rules_ok=0
    chain_has_parts mangle SIDEGW "--mac-source $mac_lc" "-j RETURN" || rules_ok=0
    chain_has_parts filter SIDEGW_FWD "--mac-source $mac_lc" "-j ACCEPT" || rules_ok=0
    chain_has_parts nat SIDEGW_DNS "--mac-source $mac_lc" "-p udp" "--dport 53" "-j DNAT" "--to-destination $GATEWAY" || rules_ok=0
    chain_has_parts nat SIDEGW_DNS "--mac-source $mac_lc" "-p tcp" "--dport 53" "-j DNAT" "--to-destination $GATEWAY" || rules_ok=0
done

if [ -n "$SIDE_MACS" ]; then
    chain_has_parts filter SIDEGW_FWD "-s $GATEWAY/32" "-j ACCEPT" || rules_ok=0
    chain_has_parts nat SIDEGW_DNS_POST "-m mark --mark 0x64" "-d $GATEWAY/32" "-p udp" "--dport 53" "-j SNAT" "--to-source $router_ip" || rules_ok=0
    chain_has_parts nat SIDEGW_DNS_POST "-m mark --mark 0x64" "-d $GATEWAY/32" "-p tcp" "--dport 53" "-j SNAT" "--to-source $router_ip" || rules_ok=0
    if ip route get 8.8.8.8 mark "$MARK_SIDE" >/tmp/sidegw-test-mark-route.log 2>&1; then
        if grep -q "via $GATEWAY" /tmp/sidegw-test-mark-route.log; then
            mark_route_note="fwmark route check passed for $MARK_SIDE"
        else
            route_ok=0
        fi
    else
        mark_route_note="fwmark route check skipped; current ip command may not support route get mark"
    fi
fi

if command -v wget >/dev/null 2>&1; then
    wget -q -T 5 -O /tmp/sidegw-test-url.out "$TEST_URL" >/tmp/sidegw-test-url.log 2>&1 && url_ok=1
else
    url_ok=1
    echo "wget missing; router URL test skipped" >/tmp/sidegw-test-url.log
fi

if [ "$dns_ok" != "1" ] || [ "$gateway_ok" != "1" ] || [ "$route_ok" != "1" ] || [ "$rules_ok" != "1" ]; then
    if rollback; then
        echo "precheck failed; rolled back"
    else
        echo "precheck failed; rollback also failed"
    fi
    echo "dns_ok=$dns_ok gateway_ok=$gateway_ok route_ok=$route_ok rules_ok=$rules_ok url_ok=$url_ok"
    cat /tmp/sidegw-test-dns.log 2>/dev/null || true
    cat /tmp/sidegw-test-gateway.log 2>/dev/null || true
    cat /tmp/sidegw-test-table.log 2>/dev/null || true
    cat /tmp/sidegw-test-rule.log 2>/dev/null || true
    cat /tmp/sidegw-test-side-rule.log 2>/dev/null || true
    cat /tmp/sidegw-test-route.log 2>/dev/null || true
    cat /tmp/sidegw-test-mark-route.log 2>/dev/null || true
    cat /tmp/sidegw-test-url.log 2>/dev/null || true
    exit 2
fi

now="$(date +%s 2>/dev/null || echo 0)"
if ! cp "$CONF" "$PENDING_GOOD" ||
    ! echo $((now + 300)) > "$PENDING_UNTIL" ||
    ! cp "$CONF" "$REAL_CONF"; then
    if rollback; then
        echo "precheck state write failed; rolled back"
    else
        echo "precheck state write failed; rollback also failed"
    fi
    exit 1
fi
rm -f "$rollback_conf"

(
    SIDEGW_LOCK_HELD=0
    sleep 300
    pending_until="$(cat "$PENDING_UNTIL" 2>/dev/null || echo 0)"
    now="$(date +%s 2>/dev/null || echo 0)"
    if echo "$pending_until" | grep -Eq '^[0-9]+$' && [ -f "$PENDING_GOOD" ] && [ "$now" -ge "$pending_until" ]; then
        rollback_ok=0
        if [ -f "$LAST_GOOD" ]; then
            cp "$LAST_GOOD" "$REAL_CONF"
            SIDEGW_CONFIG="$LAST_GOOD" "$BASE/apply.sh" >/dev/null 2>&1 && rollback_ok=1
        else
            "$BASE/rollback.sh" >/dev/null 2>&1 && rollback_ok=1
        fi
        if [ "$rollback_ok" = "1" ]; then
            rm -f "$PENDING_GOOD" "$PENDING_UNTIL"
        else
            logger -t sidegw "pending confirmation expired but automatic rollback failed" 2>/dev/null || true
        fi
    fi
) >/dev/null 2>&1 &

echo "precheck passed; rules are temporarily active for client confirmation"
echo "dns_ok=$dns_ok gateway_ok=$gateway_ok route_ok=$route_ok rules_ok=$rules_ok url_ok=$url_ok"
[ "$url_ok" = "1" ] || echo "router URL test failed but was ignored; verify from a matched client instead"
[ -n "$route_note" ] && echo "$route_note"
[ -n "$mark_route_note" ] && echo "$mark_route_note"
echo "Now test from a matched client, then click the panel confirmation button within 5 minutes:"
echo "curl -4 http://ifconfig.me/ip"
