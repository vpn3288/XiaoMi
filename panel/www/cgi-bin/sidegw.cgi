#!/bin/sh

INSTALL_DIR="${INSTALL_DIR:-$(CDPATH= cd "$(dirname "$0")/../../.." && pwd)}"
BASE="$INSTALL_DIR/panel/modules/sidegw"
CONF="$BASE/config"
ADMIN_TOKEN_FILE="$BASE/admin.token"
PENDING_GOOD="$BASE/config.pending_good"
PENDING_UNTIL="$BASE/config.pending_until"

generate_admin_token() {
    token="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
    if [ -n "$token" ]; then
        printf '%s\n' "$token"
    else
        printf '%s%s\n' "$(date +%s 2>/dev/null || echo now)" "$$"
    fi
}

admin_token() {
    if [ ! -s "$ADMIN_TOKEN_FILE" ]; then
        mkdir -p "$BASE"
        old_umask="$(umask)"
        umask 077
        generate_admin_token > "$ADMIN_TOKEN_FILE"
        chmod 600 "$ADMIN_TOKEN_FILE" 2>/dev/null || true
        umask "$old_umask"
    fi
    cat "$ADMIN_TOKEN_FILE" 2>/dev/null
}

authorized() {
    posted="$1"
    server="$(admin_token)"
    [ -n "$server" ] || return 1
    [ -n "$posted" ] || return 1
    [ "$posted" = "$server" ]
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

write_config() {
    enabled="$1"
    mode="$2"
    gateway="$3"
    lan_cidr="$4"
    side_ips="$5"
    side_macs="$6"
    direct_ips="$7"
    direct_macs="$8"
    mkdir -p "$BASE"
    {
        echo "ENABLED='$enabled'"
        echo "MODE='$mode'"
        echo "GATEWAY='$gateway'"
        echo "LAN_CIDR='$lan_cidr'"
        echo "SIDE_IPS='$side_ips'"
        echo "SIDE_MACS='$side_macs'"
        echo "DIRECT_IPS='$direct_ips'"
        echo "DIRECT_MACS='$direct_macs'"
    } > "$CONF"
}

MSG=""
ACTION=""
POST_DATA=""
VIEW_AUTH=0
[ -f "$CONF" ] || cp "$BASE/config.default" "$CONF"
QUERY_ACTION="$(printf '%s' "$QUERY_STRING" | tr '&' '\n' | sed -n 's/^action=//p' | head -n 1)"

if [ "$REQUEST_METHOD" = "POST" ]; then
    POST_LEN="${CONTENT_LENGTH:-0}"
    echo "$POST_LEN" | grep -Eq '^[0-9]{1,5}$' || POST_LEN=0
    [ "$POST_LEN" -le 32768 ] || POST_LEN=32768
    [ "$POST_LEN" -gt 0 ] && POST_DATA="$(dd bs=1 count="$POST_LEN" 2>/dev/null)"
    ACTION="$(param action)"
    if [ "$QUERY_ACTION" = "diagnose" ]; then
        :
    elif ! authorized "$(param admin_token)"; then
        MSG="管理口令不正确，已拒绝本次操作。"
    else
        VIEW_AUTH=1
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
            save)
                write_config "0" "$MODE" "$GATEWAY" "$LAN_CIDR" "$SIDE_IPS" "$SIDE_MACS" "$DIRECT_IPS" "$DIRECT_MACS"
                if SAVE_CLEANUP="$("$BASE/apply.sh" 2>&1)"; then
                    rm -f "$PENDING_GOOD" "$PENDING_UNTIL"
                    MSG="已保存配置并清理当前运行规则，但未启用。启用必须使用“应用并预检，失败自动回滚”。"
                else
                    MSG="已保存配置，但清理当前运行规则失败；待确认回滚标记已保留。输出：$SAVE_CLEANUP"
                fi
                ;;
            apply)
                MSG="面板不提供仅应用入口。请使用“应用并预检，失败自动回滚”。"
                ;;
            test)
                write_config "$ENABLED" "$MODE" "$GATEWAY" "$LAN_CIDR" "$SIDE_IPS" "$SIDE_MACS" "$DIRECT_IPS" "$DIRECT_MACS"
                MSG="$("$BASE/test.sh" 2>&1)"
                ;;
            confirm)
                confirm_now="$(date +%s 2>/dev/null || echo 0)"
                confirm_until="$(cat "$PENDING_UNTIL" 2>/dev/null || echo 0)"
                if echo "$confirm_until" | grep -Eq '^[0-9]+$' &&
                    [ "$confirm_now" -le "$confirm_until" ] &&
                    [ -f "$PENDING_GOOD" ] &&
                    cmp -s "$PENDING_GOOD" "$CONF"; then
                    cp "$PENDING_GOOD" "$BASE/config.last_good"
                    rm -f "$PENDING_GOOD" "$PENDING_UNTIL"
                    MSG="已确认客户端联网正常，并保存为已验证配置。后续 cron/firewall 只会重应用该已验证配置。"
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
                MSG="$("$BASE/rollback.sh" 2>&1)"
                ;;
        esac
    fi
fi

if [ "$QUERY_ACTION" = "diagnose" ]; then
    TOKEN_HINT_SAFE="$(printf '%s' "$ADMIN_TOKEN_FILE" | html_escape)"
    if [ "$REQUEST_METHOD" = "POST" ] && authorized "$(param admin_token)"; then
        DIAG="$("$BASE/diagnose.sh" 2>&1 | html_escape)"
        cat <<EOF
Content-Type: text/html; charset=utf-8

<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>诊断</title><link rel="stylesheet" href="/assets/style.css"></head><body><aside><div class="brand">小米路由工具箱</div><nav><a href="/cgi-bin/sidegw.cgi">sidegw 指定 IP 分流</a><a class="active" href="/cgi-bin/sidegw.cgi?action=diagnose">诊断</a></nav></aside><main><section class="card"><h1>诊断输出</h1><pre>$DIAG</pre></section></main></body></html>
EOF
    else
        cat <<EOF
Content-Type: text/html; charset=utf-8

<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>诊断</title><link rel="stylesheet" href="/assets/style.css"></head><body><aside><div class="brand">小米路由工具箱</div><nav><a href="/cgi-bin/sidegw.cgi">sidegw 指定 IP 分流</a><a class="active" href="/cgi-bin/sidegw.cgi?action=diagnose">诊断</a></nav></aside><main><section class="card"><h1>诊断</h1><form method="post" action="/cgi-bin/sidegw.cgi?action=diagnose"><label>管理口令</label><input name="admin_token" type="password" autocomplete="current-password" placeholder="$TOKEN_HINT_SAFE"><div class="actions"><button name="action" value="diagnose">查看诊断</button></div></form></section></main></body></html>
EOF
    fi
    exit 0
fi

MSG_SAFE="$(printf '%s' "$MSG" | html_escape)"
TOKEN_HINT_SAFE="$(printf '%s' "$ADMIN_TOKEN_FILE" | html_escape)"
if [ "$VIEW_AUTH" != "1" ]; then
    cat <<EOF
Content-Type: text/html; charset=utf-8

<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>sidegw 指定 IP 分流</title><link rel="stylesheet" href="/assets/style.css"></head>
<body>
<aside><div class="brand">小米路由工具箱</div><nav><a class="active" href="/cgi-bin/sidegw.cgi">sidegw 指定 IP 分流</a><a href="/cgi-bin/sidegw.cgi?action=diagnose">诊断</a></nav></aside>
<main>
<section class="card"><h1>sidegw 指定 IP / MAC 分流</h1><form method="post" action="/cgi-bin/sidegw.cgi"><label>管理口令</label><input name="admin_token" type="password" autocomplete="current-password" placeholder="$TOKEN_HINT_SAFE"><div class="actions"><button name="action" value="view">查看当前配置</button></div></form></section>
<section class="card"><h2>执行结果</h2><pre>$MSG_SAFE</pre></section>
</main>
</body>
</html>
EOF
    exit 0
fi

. "$CONF"
ENABLED="${ENABLED:-0}"
MODE="${MODE:-list}"
GATEWAY="${GATEWAY:-}"
LAN_CIDR="${LAN_CIDR:-192.168.31.0/24}"
SIDE_IPS="${SIDE_IPS:-}"
SIDE_MACS="${SIDE_MACS:-}"
DIRECT_IPS="${DIRECT_IPS:-}"
DIRECT_MACS="${DIRECT_MACS:-}"

ROUTER_IP="$(ip -4 addr show br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n 1)"
CURRENT_IP="${REMOTE_ADDR:-unknown}"
PING_STATUS="未测试"
if echo "$GATEWAY" | grep -Eq '^[0-9.]+$'; then
    ping -c 1 -W 1 "$GATEWAY" >/dev/null 2>&1 && PING_STATUS="可达" || PING_STATUS="不可达"
fi

RULES="$(ip rule 2>/dev/null | grep -E 'lookup 100|fwmark 0x64|fwmark 0x65' | html_escape)"
ROUTES="$(ip route show table 100 2>/dev/null | html_escape)"
FWD="$(iptables -vnL SIDEGW_FWD 2>/dev/null | html_escape)"
DNS="$(iptables -t nat -vnL SIDEGW_DNS 2>/dev/null | html_escape)"
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
<section class="card"><h1>sidegw 指定 IP / MAC 分流</h1><div class="stats"><div class="stat"><div class="label">主路由 IP</div><div class="value">$ROUTER_IP_SAFE</div></div><div class="stat"><div class="label">当前访问 IP</div><div class="value">$CURRENT_IP_SAFE</div></div><div class="stat"><div class="label">旁路由</div><div class="value">$GATEWAY_SAFE</div></div><div class="stat"><div class="label">旁路由状态</div><div class="value">$PING_STATUS</div></div></div></section>
<form method="post" action="/cgi-bin/sidegw.cgi">
<section class="card"><h2>基础设置</h2><div class="row"><input id="enabled" name="enabled" value="1" type="checkbox" $checked><label for="enabled">启用 sidegw</label></div><div class="grid"><div><label>旁路由 IP</label><input name="gateway" type="text" value="$GATEWAY_SAFE" placeholder="192.168.31.118"></div><div><label>LAN 网段</label><input name="lan_cidr" type="text" value="$LAN_CIDR_SAFE"></div><div><label>模式</label><select name="mode"><option value="list" $mode_list>仅列表设备走旁路由</option><option value="all" $mode_all>全 LAN 走旁路由，直连列表除外</option></select></div><div><label>管理口令</label><input name="admin_token" type="password" autocomplete="current-password" placeholder="$TOKEN_HINT_SAFE"></div></div><p>待确认状态：$PENDING_STATUS_SAFE</p></section>
<section class="card"><h2>设备列表</h2><div class="grid"><div><label>走旁路由 IP</label><textarea name="side_ips">$side_ips_text</textarea></div><div><label>走旁路由 MAC</label><textarea name="side_macs">$side_macs_text</textarea></div><div><label>直连 IP</label><textarea name="direct_ips">$direct_ips_text</textarea></div><div><label>直连 MAC</label><textarea name="direct_macs">$direct_macs_text</textarea></div></div><p>“应用并预检”会检查规则、DNS 链和旁路由可达性；真正出口 IP 请在命中的客户端上用 <code>curl -4 http://ifconfig.me/ip</code> 验证，正常后再确认持久化。</p><div class="actions"><button name="action" value="save">保存配置</button><button name="action" value="test">应用并预检，失败自动回滚</button><button name="action" value="confirm">确认客户端正常并持久化</button><button name="action" value="disable" class="danger">一键关闭</button></div></section>
</form>
<section class="card"><h2>执行结果</h2><pre>$MSG_SAFE</pre></section>
<section class="card"><h2>当前规则</h2><label>ip rule</label><pre>$RULES</pre><label>table 100</label><pre>$ROUTES</pre><label>FORWARD</label><pre>$FWD</pre><label>DNS</label><pre>$DNS</pre></section>
</main>
</body>
</html>
EOF
