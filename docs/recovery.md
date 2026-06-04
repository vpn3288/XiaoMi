# 恢复网络

如果启用 sidegw 后网络异常：

## 方法一：面板一键关闭

打开：

```text
http://192.168.31.1:8888/cgi-bin/sidegw.cgi
```

点击：

```text
一键关闭
```

先在主表单的当前管理口令框填入口令，再点击一键关闭。一键关闭会保留上一次已验证配置 `config.last_good`，但 cron / firewall include 会尊重当前关闭状态，不会自动重新启用。

## 方法二：SSH 关闭

```sh
/mnt/usb-d965c2b9/xiaomi_router/toolbox/panel/modules/sidegw/rollback.sh
```

## 方法三：手动清理

```sh
RULE_STATE=/mnt/usb-d965c2b9/xiaomi_router/toolbox/panel/modules/sidegw/rules.state

while iptables -t mangle -D PREROUTING -i br-lan -j SIDEGW 2>/dev/null; do :; done
while iptables -D FORWARD -i br-lan -o br-lan -j SIDEGW_FWD 2>/dev/null; do :; done
while iptables -t nat -D PREROUTING -i br-lan -j SIDEGW_DNS 2>/dev/null; do :; done
while iptables -t nat -D POSTROUTING -o br-lan -j SIDEGW_DNS_POST 2>/dev/null; do :; done

iptables -t mangle -F SIDEGW 2>/dev/null
iptables -t mangle -X SIDEGW 2>/dev/null
iptables -F SIDEGW_FWD 2>/dev/null
iptables -X SIDEGW_FWD 2>/dev/null
iptables -t nat -F SIDEGW_DNS 2>/dev/null
iptables -t nat -X SIDEGW_DNS 2>/dev/null
iptables -t nat -F SIDEGW_DNS_POST 2>/dev/null
iptables -t nat -X SIDEGW_DNS_POST 2>/dev/null

[ -f "$RULE_STATE" ] && while IFS= read -r rule_args; do
  [ -n "$rule_args" ] || continue
  while ip rule del $rule_args 2>/dev/null; do :; done
done < "$RULE_STATE"

while ip rule del fwmark 0x65 lookup main 2>/dev/null; do :; done
while ip rule del fwmark 0x64 table 100 2>/dev/null; do :; done
ip rule 2>/dev/null | awk -F: '$1>=10000 && $1<=10299 && ($0 ~ /lookup 100/ || $0 ~ /fwmark 0x64/ || $0 ~ /fwmark 0x65/) {print $1}' |
while read -r pref; do
  while ip rule del pref "$pref" 2>/dev/null; do :; done
done

ip route flush table 100 2>/dev/null
```
