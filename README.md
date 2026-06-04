# XiaoMi Router Toolbox

小米万兆路由器本地工具箱。它会在路由器上创建一个轻量本地面板，把高风险的网络脚本操作做成可视化、可回滚、适合新手照着操作的功能模块。

当前功能：

```text
sidegw 指定 IP / MAC 分流
```

你可以让小米主路由继续作为普通网关 `192.168.31.1`，只把指定设备的外网流量交给 ER-X / OpenWrt 旁路由，例如 `192.168.31.118`。

## 先看这几条

安装后默认不会启用分流。你需要进入面板，手动保存配置，再点“应用并预检”。

项目默认不做这些危险操作：

```text
不写 mtd
不碰 uboot
不刷固件
不恢复出厂
不默认启用分流
不默认修改全 LAN 流量
```

新手建议先只分流一台测试设备，不要一上来开启全 LAN 分流。

## 准备工作

你需要先确认：

```text
能 SSH 登录小米路由器
能 SSH 登录旁路由 / ER-X
小米路由器 LAN IP 通常是 192.168.31.1
旁路由 / ER-X IP 例如 192.168.31.118
至少知道一台要测试的客户端 IP，例如 192.168.31.216
```

下面所有命令都在“小米路由器 SSH”里执行，不是在电脑终端本地执行。

## 直接复制安装

SSH 登录小米万兆路由器后，整段复制执行即可。它会先尝试安装基础依赖，再从 GitHub 下载最新版并安装：

```sh
cd /tmp

if command -v opkg >/dev/null 2>&1; then
  opkg update
  opkg install wget ca-bundle ca-certificates tar gzip uhttpd iptables ip-full 2>/dev/null || true
fi

rm -rf XiaoMi-main XiaoMi-main.tar.gz

if command -v wget >/dev/null 2>&1; then
  wget -O XiaoMi-main.tar.gz https://github.com/vpn3288/XiaoMi/archive/refs/heads/main.tar.gz ||
    wget --no-check-certificate -O XiaoMi-main.tar.gz https://github.com/vpn3288/XiaoMi/archive/refs/heads/main.tar.gz
elif command -v curl >/dev/null 2>&1; then
  curl -L -o XiaoMi-main.tar.gz https://github.com/vpn3288/XiaoMi/archive/refs/heads/main.tar.gz
else
  echo "缺少 wget/curl，且无法自动下载 GitHub 安装包"
  exit 1
fi

tar -xzf XiaoMi-main.tar.gz
cd XiaoMi-main
sh scripts/install.sh --dry-run
sh scripts/install.sh
```

有些小米固件已经内置了这些命令，`opkg install` 显示个别包不存在不一定代表失败；最后以 `sh scripts/install.sh --dry-run` 的检查结果为准。

默认安装位置：

```text
/mnt/usb-d965c2b9/xiaomi_router/toolbox
```

默认面板地址：

```text
http://192.168.31.1:8888/cgi-bin/sidegw.cgi
```

安装成功后，SSH 输出里会看到：

```text
Panel management token: 一长串口令
```

请保存这串管理口令。忘了也可以在小米路由器 SSH 里查看：

```sh
cat /mnt/usb-d965c2b9/xiaomi_router/toolbox/panel/modules/sidegw/admin.token
```

## 如果 U 盘路径不同

如果你的 U 盘不是 `/mnt/usb-d965c2b9`，先在 SSH 里看实际路径：

```sh
ls /mnt
```

假设你看到的是 `/mnt/sda1`，就这样安装：

```sh
cd /tmp/XiaoMi-main
sh scripts/install.sh --install-dir /mnt/sda1/xiaomi_router/toolbox --host 192.168.31.1 --port 8888
```

安装目录必须是这种格式：

```text
/mnt/某个挂载名/xiaomi_router/toolbox
```

不要安装到 `/`、`/etc`、`/usr`、`/tmp` 这类系统目录。

## 打开面板

浏览器打开：

```text
http://192.168.31.1:8888/cgi-bin/sidegw.cgi
```

面板会直接显示当前配置和诊断信息。执行保存、预检、确认持久化、删除或关闭时，在“确认客户端正常并持久化”旁边的当前管理口令框填入安装时显示的 Panel management token。

## 新手推荐填写

先只测试一台设备：

```text
旁路由 IP：192.168.31.118
LAN 网段：192.168.31.0/24
模式：仅列表设备走旁路由
走旁路由 IP：192.168.31.216
直连 IP：留空，或填不想走旁路由的 IP
走旁路由 MAC：先留空
直连 MAC：先留空
当前管理口令：执行操作前填安装时显示的 Panel management token
```

然后按这个顺序点：

```text
1. 保存配置
2. 应用并预检，失败自动回滚
3. 确认客户端网络正常
4. 确认客户端正常并持久化
```

`应用并预检` 通过后，规则只会临时生效 5 分钟。5 分钟内不点确认，就会自动回到上一次已验证配置或关闭状态。

当前自动预检只支持“仅列表设备走旁路由”的 IP 列表。MAC-only 和全 LAN 模式可以保存为关闭配置，但不会通过自动预检启用。

## 在客户端验证

被分流的电脑或手机保持普通 DHCP 即可：

```text
默认网关：192.168.31.1
DNS：192.168.31.1
```

在被分流客户端上测试出口 IP：

```sh
curl -4 ifconfig.me
```

如果客户端能正常上网，且出口符合预期，再回面板点：

```text
确认客户端正常并持久化
```

只有确认后，配置才会写入 `config.last_good`，后续重启、防火墙重载、定时任务才会继续重应用。

## 一键关闭

如果分流后网络异常，优先打开面板点：

```text
一键关闭
```

点击前先在主表单的当前管理口令框填入管理口令。

如果面板打不开，就 SSH 到小米路由器执行：

```sh
/mnt/usb-d965c2b9/xiaomi_router/toolbox/panel/modules/sidegw/rollback.sh
```

如果你用了自定义安装目录，把前面的路径换成你的安装目录。

一键关闭会清理当前运行规则，并把当前候选配置改为关闭。它会保留上一次已验证配置，方便以后恢复，但不会因为保留了 `config.last_good` 就自动重新启用。

## 诊断

健康检查需要用源码包里的 `scripts/healthcheck.sh`。如果 `/tmp/XiaoMi-main` 还在，可以直接执行：

```sh
cd /tmp/XiaoMi-main
sh scripts/healthcheck.sh
```

如果 `/tmp/XiaoMi-main` 已经被清理，整段复制执行：

```sh
cd /tmp
rm -rf XiaoMi-main XiaoMi-main.tar.gz
wget -O XiaoMi-main.tar.gz https://github.com/vpn3288/XiaoMi/archive/refs/heads/main.tar.gz
tar -xzf XiaoMi-main.tar.gz
cd XiaoMi-main
sh scripts/healthcheck.sh
```

如果你用了自定义安装目录，诊断时也要带同一个目录，例如：

```sh
sh scripts/healthcheck.sh --install-dir /mnt/sda1/xiaomi_router/toolbox
```

sidegw 详细诊断：

```sh
/mnt/usb-d965c2b9/xiaomi_router/toolbox/panel/modules/sidegw/diagnose.sh
```

面板诊断页：

```text
http://192.168.31.1:8888/cgi-bin/sidegw.cgi?action=diagnose
```

诊断页会直接显示诊断输出。不要把诊断输出直接发到公开地方，因为里面可能包含你的内网 IP、路由规则和防火墙规则。

## 卸载

保留配置，只卸载面板和清理规则：

```sh
cd /tmp
rm -rf XiaoMi-main XiaoMi-main.tar.gz
wget -O XiaoMi-main.tar.gz https://github.com/vpn3288/XiaoMi/archive/refs/heads/main.tar.gz
tar -xzf XiaoMi-main.tar.gz
cd XiaoMi-main
sh scripts/uninstall.sh
```

默认卸载会先关闭并清理 sidegw。保留下来的当前配置会强制写成关闭状态，重装后不会自动启用分流；上一次已验证配置仍会作为恢复材料保留。

连配置一起删除：

```sh
cd /tmp
rm -rf XiaoMi-main XiaoMi-main.tar.gz
wget -O XiaoMi-main.tar.gz https://github.com/vpn3288/XiaoMi/archive/refs/heads/main.tar.gz
tar -xzf XiaoMi-main.tar.gz
cd XiaoMi-main
sh scripts/uninstall.sh --delete-config --yes-delete
```

如果你用了自定义安装目录，卸载时也要带同一个目录，例如：

```sh
sh scripts/uninstall.sh --install-dir /mnt/sda1/xiaomi_router/toolbox
```

## 更新到最新版

重新下载最新版并安装即可。安装脚本会尽量保留现有配置、管理口令、待确认状态和已应用状态：

```sh
cd /tmp
rm -rf XiaoMi-main XiaoMi-main.tar.gz
wget -O XiaoMi-main.tar.gz https://github.com/vpn3288/XiaoMi/archive/refs/heads/main.tar.gz
tar -xzf XiaoMi-main.tar.gz
cd XiaoMi-main
sh scripts/install.sh
```

更新不会默认启用 sidegw。旧版本卸载后留下的保留配置也会按关闭状态处理，避免重装后无确认自动启用。

## 常见问题

查看管理口令：

```sh
cat /mnt/usb-d965c2b9/xiaomi_router/toolbox/panel/modules/sidegw/admin.token
```

查看工具箱是否在运行：

```sh
pidof uhttpd
```

查看 sidegw 日志：

```sh
cat /tmp/xiaomi-toolbox-sidegw.log
```

看当前规则：

```sh
ip rule
ip route show table 100
iptables -S SIDEGW_FWD 2>/dev/null
iptables -t nat -S SIDEGW_DNS 2>/dev/null
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

## 已验证的核心逻辑

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

## AI 协作文件

仓库根目录包含：

```text
主笔AI指导文件.md
审查者AI指导文件.md
```

每一轮审查必须打开新窗口 / 新会话，只审查最新脚本，避免旧上下文污染。
