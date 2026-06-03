#!/bin/sh

INSTALL_DIR="${INSTALL_DIR:-$(CDPATH= cd "$(dirname "$0")/../../.." && pwd)}"
BASE="$INSTALL_DIR/panel/modules/sidegw"
CONF="$BASE/config"

url_decode() {
    data="$(printf '%s' "$1" | sed 's/+/ /g; s/%/\\x/g')"
    printf '%b' "$data"
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
[ -f "$CONF" ] || cp "$BASE/config.default" "$CONF"

if [ "$REQUEST_METHOD" = "POST" ]; then
    POST_LEN="${CONTENT_LENGTH:-0}"
    echo "$POST_LEN" | grep -Eq '^[0-9]{1,5}$' || POST_LEN=0
    [ "$POST_LEN" -le 32768 ] || POST_LEN=32768
    POST_DATA=""
    [ "$POST_LEN" -gt 0 ] && POST_DATA="$(dd bs=1 count="$POST_LEN" 2>/dev/null)"
    ACTION="$(param action)"
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
            MSG="已保存配置，但未启用。启用必须使用“应用并预检，失败自动回滚”。"
            ;;
        apply)
            MSG="面板不提供仅应用入口。请使用“应用并预检，失败自动回滚”。"
            ;;
        test)
            write_config "$ENABLED" "$MODE" "$GATEWAY" "$LAN_CIDR" "$SIDE_IPS" "$SIDE_MACS" "$DIRECT_IPS" "$DIRECT_MACS"
            MSG="$("$BASE/test.sh" 2>&1)"
            ;;
        disable)
            MSG="$("$BASE/rollback.sh" 2>&1)"
            ;;
    esac
fi

QUERY_ACTION="$(printf '%s' "$QUERY_STRING" | tr '&' '\n' | sed -n 's/^action=//p' | head -n 1)"
if [ "$QUERY_ACTION" = "diagnose" ]; then
    DIAG="$("$BASE/diagnose.sh" 2>&1 | html_escape)"
    cat <<EOF
Content-Type: text/html; charset=utf-8

<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>诊断</title><link rel="stylesheet" href="/assets/style.css"></head><body><aside><div class="brand">小米路由工具箱</div><nav><a href="/cgi-bin/sidegw.cgi">sidegw 指定 IP 分流</a><a class="active" href="/cgi-bin/sidegw.cgi?action=diagnose">诊断</a></nav></aside><main><section class="card"><h1>诊断输出</h1><pre>$DIAG</pre></section></main></body></html>
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
MSG_SAFE="$(printf '%s' "$MSG" | html_escape)"
ROUTER_IP_SAFE="$(printf '%s' "$ROUTER_IP" | html_escape)"
CURRENT_IP_SAFE="$(printf '%s' "$CURRENT_IP" | html_escape)"
GATEWAY_SAFE="$(printf '%s' "$GATEWAY" | html_escape)"
LAN_CIDR_SAFE="$(printf '%s' "$LAN_CIDR" | html_escape)"

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
<section class="card"><h2>基础设置</h2><div class="row"><input id="enabled" name="enabled" value="1" type="checkbox" $checked><label for="enabled">启用 sidegw</label></div><div class="grid"><div><label>旁路由 IP</label><input name="gateway" type="text" value="$GATEWAY_SAFE" placeholder="192.168.31.118"></div><div><label>LAN 网段</label><input name="lan_cidr" type="text" value="$LAN_CIDR_SAFE"></div><div><label>模式</label><select name="mode"><option value="list" $mode_list>仅列表设备走旁路由</option><option value="all" $mode_all>全 LAN 走旁路由，直连列表除外</option></select></div></div></section>
<section class="card"><h2>设备列表</h2><div class="grid"><div><label>走旁路由 IP</label><textarea name="side_ips">$side_ips_text</textarea></div><div><label>走旁路由 MAC</label><textarea name="side_macs">$side_macs_text</textarea></div><div><label>直连 IP</label><textarea name="direct_ips">$direct_ips_text</textarea></div><div><label>直连 MAC</label><textarea name="direct_macs">$direct_macs_text</textarea></div></div><p>“应用并预检”会检查规则、DNS 链和旁路由可达性；真正出口 IP 请在命中的客户端上用 <code>curl -4 http://ifconfig.me/ip</code> 验证。</p><div class="actions"><button name="action" value="save">保存配置</button><button name="action" value="test">应用并预检，失败自动回滚</button><button name="action" value="disable" class="danger">一键关闭</button></div></section>
</form>
<section class="card"><h2>执行结果</h2><pre>$MSG_SAFE</pre></section>
<section class="card"><h2>当前规则</h2><label>ip rule</label><pre>$RULES</pre><label>table 100</label><pre>$ROUTES</pre><label>FORWARD</label><pre>$FWD</pre><label>DNS</label><pre>$DNS</pre></section>
</main>
</body>
</html>
EOF
