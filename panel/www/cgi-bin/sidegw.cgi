#!/bin/sh

INSTALL_DIR="${INSTALL_DIR:-$(unset CDPATH; cd "$(dirname "$0")/../../.." && pwd)}"
BASE="$INSTALL_DIR/panel/modules/sidegw"
CONF="$BASE/config"
ADMIN_TOKEN_FILE="$BASE/admin.token"
PENDING_GOOD="$BASE/config.pending_good"
PENDING_UNTIL="$BASE/config.pending_until"
LOCK_DIR="/tmp/xiaomi-toolbox-sidegw.lock"
LOCK_PID="$LOCK_DIR/pid"
LOCK_TIME="$LOCK_DIR/created"
LOCK_STALE_AFTER="${SIDEGW_LOCK_STALE_AFTER:-300}"
LOCK_ACTIVE=0

generate_admin_token() {
    token="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
    [ -n "$token" ] || return 1
    printf '%s\n' "$token"
}

admin_token() {
    if [ ! -s "$ADMIN_TOKEN_FILE" ]; then
        mkdir -p "$BASE"
        old_umask="$(umask)"
        umask 077
        if ! generate_admin_token > "$ADMIN_TOKEN_FILE"; then
            rm -f "$ADMIN_TOKEN_FILE"
            umask "$old_umask"
            return 1
        fi
        chmod 600 "$ADMIN_TOKEN_FILE" 2>/dev/null || true
        umask "$old_umask"
    fi
    cat "$ADMIN_TOKEN_FILE" 2>/dev/null
}

valid_admin_token() {
    echo "$1" | grep -Eq '^[A-Za-z0-9._-]{6,64}$'
}

write_admin_token_value() {
    value="$1"
    tmp="$ADMIN_TOKEN_FILE.tmp.$$"
    old_umask="$(umask)"
    umask 077
    if ! printf '%s\n' "$value" > "$tmp"; then
        umask "$old_umask"
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv "$tmp" "$ADMIN_TOKEN_FILE"; then
        rm -f "$tmp"
        umask "$old_umask"
        return 1
    fi
    umask "$old_umask"
    return 0
}

authorized() {
    posted="$1"
    server="$(admin_token)"
    [ -n "$server" ] || return 1
    [ -n "$posted" ] || return 1
    [ "$posted" = "$server" ]
}

release_lock() {
    [ "$LOCK_ACTIVE" = "1" ] || return
    lock_pid="$(cat "$LOCK_PID" 2>/dev/null || echo)"
    [ "$lock_pid" = "$$" ] || return
    rm -f "$LOCK_PID" "$LOCK_TIME"
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

take_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        if echo "$$" > "$LOCK_PID" 2>/dev/null; then
            date +%s > "$LOCK_TIME" 2>/dev/null || true
            LOCK_ACTIVE=1
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
                LOCK_ACTIVE=1
                trap 'release_lock' EXIT INT TERM
                return 0
            fi
            rmdir "$LOCK_DIR" 2>/dev/null || true
        fi
    fi
    return 1
}

hex_value() {
    case "$1" in
        0) echo 0 ;;
        1) echo 1 ;;
        2) echo 2 ;;
        3) echo 3 ;;
        4) echo 4 ;;
        5) echo 5 ;;
        6) echo 6 ;;
        7) echo 7 ;;
        8) echo 8 ;;
        9) echo 9 ;;
        a|A) echo 10 ;;
        b|B) echo 11 ;;
        c|C) echo 12 ;;
        d|D) echo 13 ;;
        e|E) echo 14 ;;
        f|F) echo 15 ;;
    esac
}

url_decode() {
    input="$1"
    while [ -n "$input" ]; do
        case "$input" in
            +*)
                printf ' '
                input="${input#?}"
                ;;
            %[0-9A-Fa-f][0-9A-Fa-f]*)
                hex="${input#%}"
                hex="${hex%"${hex#??}"}"
                high="${hex%"${hex#?}"}"
                low="${hex#?}"
                low="${low%"${low#?}"}"
                dec=$(( $(hex_value "$high") * 16 + $(hex_value "$low") ))
                oct="$(printf '%03o' "$dec")"
                printf '%b' "\\$oct"
                input="${input#???}"
                ;;
            *)
                first="${input%"${input#?}"}"
                printf '%s' "$first"
                input="${input#?}"
                ;;
        esac
    done
}

param() {
    printf '%s' "$POST_DATA" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1
}

clean_ips() {
    printf '%s\n' "$1" |
        tr ',;\r\t' ' ' |
        tr ' ' '\n' |
        sed '/^$/d' |
        grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' |
        awk -F. '$1<=255 && $2<=255 && $3<=255 && $4<=255' |
        sort -u |
        xargs
}

clean_macs() {
    printf '%s\n' "$1" |
        tr 'A-F' 'a-f' |
        tr ',;\r\t' ' ' |
        tr ' ' '\n' |
        sed '/^$/d' |
        grep -Ei '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' |
        sort -u |
        xargs
}

filter_words() {
    values="$1"
    removes="$2"
    out=""
    for item in $values; do
        skip=0
        for remove in $removes; do
            [ "$item" = "$remove" ] && skip=1
        done
        [ "$skip" = "0" ] && out="${out}${out:+ }$item"
    done
    printf '%s\n' "$out"
}

clean_cidr() {
    v="$(printf '%s' "$1" | tr -cd '0-9./')"
    echo "$v" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' || {
        echo "192.168.31.0/24"
        return
    }
    ip="${v%/*}"
    bits="${v#*/}"
    oldifs="$IFS"
    IFS=.
    # shellcheck disable=SC2086
    set -- $ip
    IFS="$oldifs"
    [ "$#" -eq 4 ] &&
        [ "$1" -le 255 ] && [ "$2" -le 255 ] && [ "$3" -le 255 ] && [ "$4" -le 255 ] &&
        [ "$bits" -ge 0 ] && [ "$bits" -le 32 ] &&
        echo "$v" || echo "192.168.31.0/24"
}

html_escape() {
    sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

write_config_file() {
    dst="$1"
    enabled="$2"
    mode="$3"
    gateway="$4"
    lan_cidr="$5"
    side_ips="$6"
    side_macs="$7"
    direct_ips="$8"
    direct_macs="$9"
    tmp="$dst.tmp.$$"
    [ "$enabled" = "0" ] || [ "$enabled" = "1" ] || return 1
    [ "$mode" = "list" ] || [ "$mode" = "all" ] || return 1
    mkdir -p "$BASE" || return 1
    {
        echo "ENABLED='$enabled'"
        echo "MODE='$mode'"
        echo "GATEWAY='$gateway'"
        echo "LAN_CIDR='$lan_cidr'"
        echo "SIDE_IPS='$side_ips'"
        echo "SIDE_MACS='$side_macs'"
        echo "DIRECT_IPS='$direct_ips'"
        echo "DIRECT_MACS='$direct_macs'"
    } > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$dst" || {
        rm -f "$tmp"
        return 1
    }
}

write_config() {
    write_config_file "$CONF" "$@"
}

remove_entries_from_config_file() {
    target="$1"
    remove_ips="$2"
    remove_macs="$3"
    [ -f "$target" ] || return 0
    ENABLED="0"
    MODE="list"
    GATEWAY=""
    LAN_CIDR="192.168.31.0/24"
    SIDE_IPS=""
    SIDE_MACS=""
    DIRECT_IPS=""
    DIRECT_MACS=""
    # shellcheck source=/dev/null
    . "$target" 2>/dev/null || return 0
    [ "$MODE" = "all" ] || MODE="list"
    SIDE_IPS="$(filter_words "${SIDE_IPS:-}" "$remove_ips")"
    DIRECT_IPS="$(filter_words "${DIRECT_IPS:-}" "$remove_ips")"
    SIDE_MACS="$(filter_words "${SIDE_MACS:-}" "$remove_macs")"
    DIRECT_MACS="$(filter_words "${DIRECT_MACS:-}" "$remove_macs")"
    write_config_file "$target" "${ENABLED:-0}" "$MODE" "${GATEWAY:-}" "${LAN_CIDR:-192.168.31.0/24}" "$SIDE_IPS" "$SIDE_MACS" "$DIRECT_IPS" "$DIRECT_MACS"
}

MSG=""
ACTION=""
POST_DATA=""
VIEW_AUTH=0
if [ ! -f "$CONF" ] && ! cp "$BASE/config.default" "$CONF"; then
    MSG="默认配置初始化失败，请检查安装目录是否可写。"
fi
QUERY_ACTION="$(printf '%s' "$QUERY_STRING" | tr '&' '\n' | sed -n 's/^action=//p' | head -n 1)"

if [ "$REQUEST_METHOD" = "POST" ]; then
    POST_LEN="${CONTENT_LENGTH:-0}"
    echo "$POST_LEN" | grep -Eq '^[0-9]{1,5}$' || POST_LEN=0
    [ "$POST_LEN" -le 32768 ] || POST_LEN=32768
    [ "$POST_LEN" -gt 0 ] && POST_DATA="$(dd bs=1 count="$POST_LEN" 2>/dev/null)"
    ACTION="$(param action)"
    if authorized "$(param admin_token)"; then
        VIEW_AUTH=1
    else
        MSG="管理口令不正确，已拒绝本次操作。"
    fi

    if [ "$VIEW_AUTH" = "1" ] && [ "$QUERY_ACTION" != "diagnose" ]; then
        ENABLED="$(param enabled)"
        [ "$ENABLED" = "1" ] || ENABLED="0"
        MODE="$(param mode)"
        [ "$MODE" = "all" ] || MODE="list"
        GATEWAY="$(url_decode "$(param gateway)" | tr -cd '0-9.')"
        LAN_CIDR="$(clean_cidr "$(url_decode "$(param lan_cidr)")")"
        SIDE_IPS="$(clean_ips "$(url_decode "$(param side_ips)")")"
        SIDE_MACS="$(clean_macs "$(url_decode "$(param side_macs)")")"
        DIRECT_IPS="$(clean_ips "$(url_decode "$(param direct_ips)")")"
        DIRECT_MACS="$(clean_macs "$(url_decode "$(param direct_macs)")")"

        case "$ACTION" in
            save|test|confirm|disable|delete_rules|remove_entries|change_token)
                if [ "$(param action_confirm)" != "$ACTION" ]; then
                    MSG="危险操作缺少二次确认，已拒绝执行。请从面板按钮重新确认。"
                    ACTION=""
                fi
                ;;
        esac

        case "$ACTION" in
            save|test|confirm|disable|delete_rules|remove_entries)
                if ! take_lock; then
                    MSG="sidegw 正忙，另一个应用、预检、确认或回滚正在运行。请稍后重试。"
                    ACTION=""
                fi
                ;;
        esac

        case "$ACTION" in
            save)
                if write_config "0" "$MODE" "$GATEWAY" "$LAN_CIDR" "$SIDE_IPS" "$SIDE_MACS" "$DIRECT_IPS" "$DIRECT_MACS"; then
                    if SAVE_CLEANUP="$(SIDEGW_LOCK_HELD=1 "$BASE/apply.sh" 2>&1)"; then
                        rm -f "$PENDING_GOOD" "$PENDING_UNTIL"
                        MSG="已保存为关闭配置并清理当前运行规则。启用必须使用“应用并预检，失败自动回滚”。"
                    else
                        MSG="已保存配置，但清理当前运行规则失败；待确认回滚标记已保留。输出：$SAVE_CLEANUP"
                    fi
                else
                    MSG="配置写入失败，未执行清理或应用。请检查安装目录是否可写。"
                fi
                ;;
            apply)
                MSG="面板不提供仅应用入口。请使用“应用并预检，失败自动回滚”。"
                ;;
            test)
                candidate_conf="$BASE/config.candidate.$$"
                if write_config_file "$candidate_conf" "$ENABLED" "$MODE" "$GATEWAY" "$LAN_CIDR" "$SIDE_IPS" "$SIDE_MACS" "$DIRECT_IPS" "$DIRECT_MACS"; then
                    MSG="$(SIDEGW_LOCK_HELD=1 SIDEGW_CONFIG="$candidate_conf" "$BASE/test.sh" 2>&1)"
                    rm -f "$candidate_conf"
                else
                    MSG="配置写入失败，未执行应用预检。请检查安装目录是否可写。"
                fi
                ;;
            confirm)
                confirm_now="$(date +%s 2>/dev/null || echo 0)"
                confirm_until="$(cat "$PENDING_UNTIL" 2>/dev/null || echo 0)"
                if echo "$confirm_until" | grep -Eq '^[0-9]+$' &&
                    [ "$confirm_now" -le "$confirm_until" ] &&
                    [ -f "$PENDING_GOOD" ] &&
                    cmp -s "$PENDING_GOOD" "$CONF"; then
                    if cp "$PENDING_GOOD" "$BASE/config.last_good"; then
                        rm -f "$PENDING_GOOD" "$PENDING_UNTIL"
                        MSG="已确认客户端联网正常，并保存为已验证配置。后续 cron/firewall 只会重应用该已验证配置。"
                    else
                        MSG="保存已验证配置失败，待确认回滚标记已保留。请检查安装目录是否可写。"
                    fi
                else
                    if [ -f "$PENDING_GOOD" ] || [ -f "$PENDING_UNTIL" ]; then
                        MSG="没有可确认的待验证配置，或当前配置已变化。待确认回滚标记已保留，请重新应用并预检，或使用一键关闭。"
                    else
                        rm -f "$PENDING_GOOD" "$PENDING_UNTIL"
                        MSG="没有可确认的待验证配置。请重新应用并预检。"
                    fi
                fi
                ;;
            disable)
                MSG="$(SIDEGW_LOCK_HELD=1 "$BASE/rollback.sh" 2>&1)"
                ;;
            remove_entries)
                REMOVE_IPS="$(clean_ips "$(url_decode "$(param remove_ips)")")"
                REMOVE_MACS="$(clean_macs "$(url_decode "$(param remove_macs)")")"
                if [ -z "$REMOVE_IPS" ] && [ -z "$REMOVE_MACS" ]; then
                    MSG="没有填写要删除的 IP 或 MAC。"
                else
                    # shellcheck source=/dev/null
                    . "$CONF"
                    ENABLED="${ENABLED:-0}"
                    MODE="${MODE:-list}"
                    [ "$MODE" = "all" ] || MODE="list"
                    GATEWAY="${GATEWAY:-}"
                    LAN_CIDR="${LAN_CIDR:-192.168.31.0/24}"
                    SIDE_IPS="$(filter_words "${SIDE_IPS:-}" "$REMOVE_IPS")"
                    DIRECT_IPS="$(filter_words "${DIRECT_IPS:-}" "$REMOVE_IPS")"
                    SIDE_MACS="$(filter_words "${SIDE_MACS:-}" "$REMOVE_MACS")"
                    DIRECT_MACS="$(filter_words "${DIRECT_MACS:-}" "$REMOVE_MACS")"
                    if write_config "0" "$MODE" "$GATEWAY" "$LAN_CIDR" "$SIDE_IPS" "$SIDE_MACS" "$DIRECT_IPS" "$DIRECT_MACS" &&
                        remove_entries_from_config_file "$BASE/config.last_good" "$REMOVE_IPS" "$REMOVE_MACS" &&
                        remove_entries_from_config_file "$BASE/config.pending_good" "$REMOVE_IPS" "$REMOVE_MACS"; then
                        if REMOVE_CLEANUP="$(SIDEGW_LOCK_HELD=1 "$BASE/apply.sh" 2>&1)"; then
                            rm -f "$PENDING_GOOD" "$PENDING_UNTIL"
                            MSG="已删除匹配的配置条目，并清理当前运行规则。"
                        else
                            MSG="已删除匹配的配置条目，但清理当前运行规则失败；待确认回滚标记已保留。输出：$REMOVE_CLEANUP"
                        fi
                    else
                        MSG="配置写入失败，未执行删除后的规则清理。请检查安装目录是否可写。"
                    fi
                fi
                ;;
            delete_rules)
                if DELETE_OUTPUT="$(SIDEGW_LOCK_HELD=1 "$BASE/rollback.sh" 2>&1)"; then
                    MSG="已删除所有 sidegw 运行规则，并已关闭当前配置。"
                    [ -n "$DELETE_OUTPUT" ] && MSG="$MSG 输出：$DELETE_OUTPUT"
                else
                    MSG="删除规则失败，输出：$DELETE_OUTPUT"
                fi
                ;;
            change_token)
                NEW_ADMIN_TOKEN="$(param new_admin_token)"
                NEW_ADMIN_TOKEN_CONFIRM="$(param new_admin_token_confirm)"
                if [ -z "$NEW_ADMIN_TOKEN" ]; then
                    MSG="新管理口令不能为空。"
                elif [ "$NEW_ADMIN_TOKEN" != "$NEW_ADMIN_TOKEN_CONFIRM" ]; then
                    MSG="两次输入的新管理口令不一致。"
                elif ! valid_admin_token "$NEW_ADMIN_TOKEN"; then
                    MSG="新管理口令格式不正确。请使用 6-64 位字母、数字、点、下划线或短横线。"
                elif write_admin_token_value "$NEW_ADMIN_TOKEN"; then
                    MSG="管理口令已更新。下一次操作请使用新口令。"
                else
                    MSG="管理口令更新失败，请检查安装目录是否可写。"
                fi
                ;;
        esac
    fi
fi

TOKEN_HINT_SAFE="管理口令"

if [ "$QUERY_ACTION" = "diagnose" ]; then
    if [ "$VIEW_AUTH" = "1" ]; then
        DIAG="$("$BASE/diagnose.sh" 2>&1 | html_escape)"
    else
        DIAG="请输入管理口令后查看诊断输出。"
    fi
    cat <<EOF
Content-Type: text/html; charset=utf-8

<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>诊断</title><link rel="stylesheet" href="/assets/style.css"></head><body><aside><div class="brand">小米路由工具箱</div><nav><a href="/cgi-bin/sidegw.cgi">sidegw 指定 IP 分流</a><a class="active" href="/cgi-bin/sidegw.cgi?action=diagnose">诊断</a></nav></aside><main><noscript><section class="card danger-zone"><p>诊断和危险操作需要启用 JavaScript 与管理口令。</p></section></noscript><section class="card"><h1>诊断输出</h1><form method="post" action="/cgi-bin/sidegw.cgi?action=diagnose"><label>管理口令</label><input name="admin_token" type="password" autocomplete="current-password" placeholder="$TOKEN_HINT_SAFE"><button name="action" value="view_diagnose">查看诊断</button></form><pre>$DIAG</pre></section></main></body></html>
EOF
    exit 0
fi

MSG_SAFE="$(printf '%s' "$MSG" | html_escape)"

if [ "$VIEW_AUTH" = "1" ] && [ -f "$CONF" ]; then
    # shellcheck source=/dev/null
    . "$CONF"
fi
ENABLED="${ENABLED:-0}"
MODE="${MODE:-list}"
GATEWAY="${GATEWAY:-}"
LAN_CIDR="${LAN_CIDR:-192.168.31.0/24}"
SIDE_IPS="${SIDE_IPS:-}"
SIDE_MACS="${SIDE_MACS:-}"
DIRECT_IPS="${DIRECT_IPS:-}"
DIRECT_MACS="${DIRECT_MACS:-}"

if [ "$VIEW_AUTH" = "1" ]; then
    ROUTER_IP="$(ip -4 addr show br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n 1)"
else
    ROUTER_IP="需管理口令"
fi
CURRENT_IP="${REMOTE_ADDR:-unknown}"
PING_STATUS="未测试"
if [ "$VIEW_AUTH" = "1" ] && echo "$GATEWAY" | grep -Eq '^[0-9.]+$'; then
    ping -c 1 -W 1 "$GATEWAY" >/dev/null 2>&1 && PING_STATUS="可达" || PING_STATUS="不可达"
fi

if [ "$VIEW_AUTH" = "1" ]; then
    RULES="$(ip rule 2>/dev/null | grep -E 'lookup 100|fwmark 0x64|fwmark 0x65' | html_escape)"
    ROUTES="$(ip route show table 100 2>/dev/null | html_escape)"
    FWD="$(iptables -vnL SIDEGW_FWD 2>/dev/null | html_escape)"
    DNS="$(iptables -t nat -vnL SIDEGW_DNS 2>/dev/null | html_escape)"
else
    RULES="需要管理口令查看"
    ROUTES="需要管理口令查看"
    FWD="需要管理口令查看"
    DNS="需要管理口令查看"
fi
ROUTER_IP_SAFE="$(printf '%s' "$ROUTER_IP" | html_escape)"
CURRENT_IP_SAFE="$(printf '%s' "$CURRENT_IP" | html_escape)"
GATEWAY_SAFE="$(printf '%s' "$GATEWAY" | html_escape)"
LAN_CIDR_SAFE="$(printf '%s' "$LAN_CIDR" | html_escape)"
PENDING_STATUS="无待确认配置"
now="$(date +%s 2>/dev/null || echo 0)"
pending_until="$(cat "$PENDING_UNTIL" 2>/dev/null || echo 0)"
if echo "$pending_until" | grep -Eq '^[0-9]+$' && [ -f "$PENDING_GOOD" ] && [ "$now" -le "$pending_until" ]; then
    PENDING_STATUS="待确认配置有效，请在命中客户端测试外网后确认"
fi
PENDING_STATUS_SAFE="$(printf '%s' "$PENDING_STATUS" | html_escape)"

checked=""
[ "$ENABLED" = "1" ] && checked="checked"
mode_list="selected"
mode_all=""
[ "$MODE" = "all" ] && { mode_all="selected"; mode_list=""; }

side_ips_text="$(printf '%s' "$SIDE_IPS" | tr ' ' '\n' | html_escape)"
side_macs_text="$(printf '%s' "$SIDE_MACS" | tr ' ' '\n' | html_escape)"
direct_ips_text="$(printf '%s' "$DIRECT_IPS" | tr ' ' '\n' | html_escape)"
direct_macs_text="$(printf '%s' "$DIRECT_MACS" | tr ' ' '\n' | html_escape)"

cat <<EOF
Content-Type: text/html; charset=utf-8

<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>sidegw 指定 IP 分流</title><link rel="stylesheet" href="/assets/style.css"></head>
<body>
<aside><div class="brand">小米路由工具箱</div><nav><a class="active" href="/cgi-bin/sidegw.cgi">sidegw 指定 IP 分流</a><a href="/cgi-bin/sidegw.cgi?action=diagnose">诊断</a></nav></aside>
<main>
<noscript><section class="card danger-zone"><p>本面板查看诊断和执行危险操作需要启用 JavaScript 与管理口令。</p></section></noscript>
<section class="card"><h1>sidegw 指定 IP / MAC 分流</h1><div class="stats"><div class="stat"><div class="label">主路由 IP</div><div class="value">$ROUTER_IP_SAFE</div></div><div class="stat"><div class="label">当前访问 IP</div><div class="value">$CURRENT_IP_SAFE</div></div><div class="stat"><div class="label">旁路由</div><div class="value">$GATEWAY_SAFE</div></div><div class="stat"><div class="label">旁路由状态</div><div class="value">$PING_STATUS</div></div></div></section>
<form method="post" action="/cgi-bin/sidegw.cgi">
<input type="hidden" name="action_confirm" value="">
<section class="card"><h2>基础设置</h2><div class="row"><input id="enabled" name="enabled" value="1" type="checkbox" $checked><label for="enabled">启用 sidegw</label></div><div class="grid"><div><label>旁路由 IP</label><input name="gateway" type="text" value="$GATEWAY_SAFE" placeholder="192.168.31.118"></div><div><label>LAN 网段</label><input name="lan_cidr" type="text" value="$LAN_CIDR_SAFE"></div><div><label>模式</label><select name="mode"><option value="list" $mode_list>仅列表设备走旁路由</option><option value="all" $mode_all>全 LAN 走旁路由，直连列表除外</option></select></div></div><p>待确认状态：$PENDING_STATUS_SAFE</p></section>
<section class="card"><h2>设备列表</h2><div class="grid"><div><label>走旁路由 IP</label><textarea name="side_ips">$side_ips_text</textarea></div><div><label>走旁路由 MAC</label><textarea name="side_macs">$side_macs_text</textarea></div><div><label>直连 IP</label><textarea name="direct_ips">$direct_ips_text</textarea></div><div><label>直连 MAC</label><textarea name="direct_macs">$direct_macs_text</textarea></div></div><p>“当前访问 IP”只用于提示，不会自动加入分流列表。“应用并预检”会检查规则、DNS 链和旁路由可达性；真正出口 IP 请在命中的客户端上用 <code>curl -4 http://ifconfig.me/ip</code> 验证，正常后再确认持久化。</p><div class="actions"><button name="action" value="save" onclick="this.form.elements.action_confirm.value='save'; return confirm('确认保存为关闭配置并清理当前 sidegw 运行规则？')">保存为关闭配置并清理当前规则</button><button name="action" value="test" onclick="this.form.elements.action_confirm.value='test'; return confirm('确认临时修改路由和 DNS 规则并开始 5 分钟预检？失败会自动回滚。')">应用并预检，失败自动回滚</button><label class="token-field"><span>当前管理口令</span><input name="admin_token" type="password" autocomplete="current-password" placeholder="$TOKEN_HINT_SAFE"></label><button name="action" value="view">查看当前配置</button><button name="action" value="confirm" onclick="this.form.elements.action_confirm.value='confirm'; return confirm('确认已在命中客户端验证外网正常，并保存为后续可重应用配置？')">确认客户端正常并持久化</button><button name="action" value="disable" class="danger" onclick="this.form.elements.action_confirm.value='disable'; return confirm('确认关闭 sidegw 并清理当前运行规则？')">一键关闭</button></div></section>
<section class="card"><h2>删除配置条目</h2><div class="grid"><div><label>删除 IP</label><textarea name="remove_ips"></textarea></div><div><label>删除 MAC</label><textarea name="remove_macs"></textarea></div></div><div class="actions"><button name="action" value="remove_entries" onclick="this.form.elements.action_confirm.value='remove_entries'; return confirm('确认删除这些 IP 或 MAC 配置条目？')">删除配置条目</button></div></section>
<section class="card"><h2>删除所有规则</h2><div class="actions"><button name="action" value="delete_rules" class="danger" onclick="this.form.elements.action_confirm.value='delete_rules'; return confirm('确认删除所有 sidegw 运行规则并关闭当前配置？')">删除所有规则</button></div></section>
</form>
<form method="post" action="/cgi-bin/sidegw.cgi">
<input type="hidden" name="action_confirm" value="">
<section class="card"><h2>修改管理口令</h2><div class="grid"><div><label>当前管理口令</label><input name="admin_token" type="password" autocomplete="current-password" placeholder="$TOKEN_HINT_SAFE"></div><div><label>新管理口令</label><input name="new_admin_token" type="password" autocomplete="new-password" placeholder="6-64 位"></div><div><label>再次输入新口令</label><input name="new_admin_token_confirm" type="password" autocomplete="new-password" placeholder="再次输入"></div></div><div class="actions"><button name="action" value="change_token" onclick="this.form.elements.action_confirm.value='change_token'; return confirm('确认更新管理口令？下一次操作必须使用新口令。')">更新管理口令</button></div></section>
</form>
<section class="card"><h2>执行结果</h2><pre>$MSG_SAFE</pre></section>
<section class="card"><h2>当前规则</h2><label>ip rule</label><pre>$RULES</pre><label>table 100</label><pre>$ROUTES</pre><label>FORWARD</label><pre>$FWD</pre><label>DNS</label><pre>$DNS</pre></section>
</main>
</body>
</html>
EOF
