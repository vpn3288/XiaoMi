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

## 方法二：SSH 关闭

```sh
/mnt/usb-d965c2b9/xiaomi_router/toolbox/panel/modules/sidegw/rollback.sh
```

## 方法三：手动清理

```sh
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

i=10000
while [ "$i" -le 10299 ]; do
  while ip rule del pref "$i" 2>/dev/null; do :; done
  i=$((i + 1))
done

ip route flush table 100 2>/dev/null
```
