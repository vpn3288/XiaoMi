# sidegw 设计说明

sidegw 目标：在小米主路由保持默认网关的情况下，将指定 IP / MAC 的外网流量送到 ER-X 旁路由。

关键规则：

```text
ip route table 100: default via ER-X dev br-lan
ip rule: from CLIENT_IP lookup 100
ip rule: from ERX_IP lookup main
iptables FORWARD: allow br-lan -> br-lan for matched clients
iptables nat PREROUTING: DNS DNAT to ER-X
iptables nat POSTROUTING: DNS SNAT to Xiaomi LAN IP
```

为什么 DNS 需要 SNAT：

```text
客户端问 192.168.31.1:53
小米把 DNS DNAT 到 192.168.31.118
如果没有 SNAT，ER-X 会直接回客户端
回包绕过小米 conntrack，客户端看到 DNS 超时
```

所以 DNS 必须同时有：

```text
DNAT -> ER-X
SNAT -> 小米主路由 LAN IP
```

为什么需要 LAN -> LAN FORWARD：

```text
sidegw 会把客户端流量从 br-lan 再转发到 br-lan 上的 ER-X。
小米默认防火墙不一定允许这种同接口转发。
```

所以需要 `SIDEGW_FWD` 链放行命中设备。

