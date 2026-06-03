# XiaoMi Router Toolbox

小米万兆路由器本地工具箱。目标是做一个类似 1Panel 的轻量本地面板，把高风险的路由器脚本操作做成可视化、可回滚、适合新手使用的功能模块。

当前首个功能：

```text
sidegw 指定 IP / MAC 分流
```

它可以让小米主路由保持默认网关 `192.168.31.1`，同时把指定设备的外网流量转给 ER-X / OpenWrt 旁路由，例如 `192.168.31.118`。

## 安全原则

本项目默认不做危险操作：

```text
不写 mtd
不碰 uboot
不刷固件
不恢复出厂
不默认启用分流
不默认修改全 LAN 流量
```

安装完成后，`sidegw` 默认是关闭的。你需要进入面板后手动启用。

建议优先使用：

```text
应用并预检，失败自动回滚
```

面板不提供绕过预检的“仅应用”入口。

安装时会生成面板管理口令。查看当前配置 / 规则、`保存配置`、`应用并预检`、`确认持久化`、`一键关闭` 和查看诊断都必须输入该口令，避免 LAN 内其它设备或网页表单直接触发路由变更或读取网络拓扑。

## 已验证方案

这次成功验证的关键点：

```text
1. ip rule from 指定客户端 IP lookup 100
2. table 100 default via ER-X dev br-lan
3. ER-X 自身 lookup main，避免循环
4. LAN -> LAN FORWARD 放行
5. DNS DNAT 到 ER-X
6. DNS SNAT 到小米 LAN IP，避免回包绕过 conntrack
7. 定时 / firewall include 重应用
8. ENABLED='0' 时只清理规则，不启用分流
```

## 项目结构

```text
scripts/
  install.sh        安装面板，默认不启用 sidegw
  uninstall.sh      卸载面板并清理规则
  healthcheck.sh    健康检查和诊断入口
  backup.sh         备份配置
  common.sh         公共函数

panel/
  www/
    index.html
    assets/style.css
    cgi-bin/sidegw.cgi
  modules/
    sidegw/
      apply.sh
      rollback.sh
      diagnose.sh
      test.sh
      config.default
```

## 安装

把仓库复制到小米路由器后执行：

```sh
sh scripts/install.sh
```

默认安装到：

```text
/mnt/usb-d965c2b9/xiaomi_router/toolbox
```

默认面板地址：

```text
http://192.168.31.1:8888/
```

安装完成输出里会显示：

```text
Panel management token: ...
```

请保存这个口令。也可以在路由器上查看：

```sh
cat /mnt/usb-d965c2b9/xiaomi_router/toolbox/panel/modules/sidegw/admin.token
```

自定义安装目录：

```sh
sh scripts/install.sh --install-dir /mnt/usb-d965c2b9/xiaomi_router/toolbox --host 192.168.31.1 --port 8888
```

只预演，不做任何修改：

```sh
sh scripts/install.sh --dry-run
```

## 使用 sidegw

打开：

```text
http://192.168.31.1:8888/cgi-bin/sidegw.cgi
```

填写：

```text
旁路由 IP：192.168.31.118
模式：仅列表设备走旁路由
走旁路由 IP：例如 192.168.31.216
```

当前自动预检只允许“仅列表设备走旁路由”里的 IP 列表通过临时启用。MAC-only 和全 LAN 模式会先保存配置但不会自动启用。

推荐点击：

```text
应用并预检，失败自动回滚
```

预检通过后，规则只会临时生效 5 分钟，不会立刻写入 `config.last_good`；如果没有确认，会自动回到上一次已验证配置或关闭状态。电脑保持普通 DHCP 即可。真正出口 IP 请在被分流的客户端上测试：

```text
电脑默认网关：192.168.31.1
电脑 DNS：192.168.31.1
```

被分流客户端出口验证：

```sh
curl -4 ifconfig.me
```

如果客户端联网和出口都正常，回到面板点击：

```text
确认客户端正常并持久化
```

只有确认后，配置才会写入 `config.last_good`，后续 crontab / firewall include 才会持续重应用。

## 一键关闭

如果分流后网络异常，进入面板点击：

```text
一键关闭
```

也可以 SSH 到小米路由器执行：

```sh
/mnt/usb-d965c2b9/xiaomi_router/toolbox/panel/modules/sidegw/rollback.sh
```

一键关闭会清理当前运行规则并把候选配置改为关闭，但会保留 `config.last_good`，方便后续回到上一次已验证配置。

## 诊断

```sh
sh scripts/healthcheck.sh
```

或：

```sh
/mnt/usb-d965c2b9/xiaomi_router/toolbox/panel/modules/sidegw/diagnose.sh
```

面板诊断页：

```text
http://192.168.31.1:8888/cgi-bin/sidegw.cgi?action=diagnose
```

诊断页和当前配置 / 规则页都需要输入管理口令。

## 卸载

保留配置，仅卸载面板和规则：

```sh
sh scripts/uninstall.sh
```

连配置一起删除：

```sh
sh scripts/uninstall.sh --delete-config --yes-delete
```

## AI 协作文件

本仓库根目录包含：

```text
主笔AI指导文件.md
审查者AI指导文件.md
```

每一轮审查必须打开新窗口 / 新会话，只审查最新脚本，避免旧上下文污染。

## 风险提示

这个项目运行在主路由上。任何网络脚本都有断网风险。请始终先确认：

```text
能 SSH 进小米路由器
能 SSH 进 ER-X
知道如何手动关闭 sidegw
sidegw 默认关闭
应用预检失败会自动回滚
```

不要在不了解结果的情况下开启全 LAN 分流。
