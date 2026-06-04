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
至少知道一台要测试的客户端 IP，例如 192.168.31.50
```

推荐安装方式是在本地电脑 PowerShell 里执行命令：本地电脑负责访问 GitHub，小米万兆只通过 SSH 接收文件并安装。

## PowerShell 安装，推荐

这个方式适合小米万兆主路由不能访问 GitHub，但本地电脑可以访问 GitHub 的情况。命令在本地电脑 PowerShell 里执行，不是在小米路由器 SSH 里执行。

整段复制到本地电脑 PowerShell 执行：

```powershell
$router="root@192.168.31.1"
$work="$env:TEMP\XiaoMi-install"

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
git clone --depth 1 https://github.com/vpn3288/XiaoMi.git $work

ssh $router "rm -rf /tmp/XiaoMi-main"
scp -O -r $work "${router}:/tmp/XiaoMi-main"

ssh $router "cd /tmp/XiaoMi-main && sh scripts/install.sh --dry-run && sh scripts/install.sh"
```

`scp -O` 很重要。小米路由器通常没有 `/usr/libexec/sftp-server`，新版 Windows `scp` 默认走 SFTP 会失败，`-O` 会强制使用老式 SCP 协议。

如果你的路由器 SSH 地址不是 `root@192.168.31.1`，只改第一行：

```powershell
$router="root@192.168.31.1"
```

如果你的 U 盘路径不是默认的 `/mnt/usb-d965c2b9`，把最后一行换成：

```powershell
ssh $router "cd /tmp/XiaoMi-main && sh scripts/install.sh --dry-run --install-dir /mnt/sda1/xiaomi_router/toolbox && sh scripts/install.sh --install-dir /mnt/sda1/xiaomi_router/toolbox"
```

把 `/mnt/sda1` 换成你实际的 U 盘挂载路径。

`dry-run` 会检查小米路由器上是否有 `ip`、`iptables`、`uci`、`uhttpd`、`pidof`、`netstat`、`awk` 等基础命令。大多数小米 / OpenWrt 环境已经内置；如果缺少，先按固件环境补齐对应依赖后再安装。

`dry-run` 还会检查 `br-lan`、安装目录对应的 `/mnt/...` 挂载点以及面板源码文件是否存在。它不会创建目录、写配置、注册定时任务或启动面板。

安装时会自动禁用旧版 `/xiaomi_router/sidegw-panel` 启动脚本，并把旧配置改成关闭，避免旧面板每分钟重建旧的分流规则。

## 本地 HTTP 中转安装，备用

如果不想用 `scp`，也可以在本地电脑下载并开 HTTP 文件服务，让小米从局域网下载。

先在本地电脑下载：

```text
https://github.com/vpn3288/XiaoMi/archive/refs/heads/main.tar.gz
```

把下载到的文件改名为：

```text
XiaoMi-main.tar.gz
```

然后用本地电脑开一个临时 HTTP 文件服务，端口示例为 `8765`，并确保浏览器能打开：

```text
http://192.168.31.216:8765/XiaoMi-main.tar.gz
```

这里的 `192.168.31.216` 换成你的本地电脑 LAN IP。确认本地链接能打开后，SSH 登录小米万兆路由器，整段复制执行：

```sh
cd /tmp
rm -rf XiaoMi-main XiaoMi-main.tar.gz
wget -O XiaoMi-main.tar.gz http://192.168.31.216:8765/XiaoMi-main.tar.gz
tar -xzf XiaoMi-main.tar.gz
cd XiaoMi-main
sh scripts/install.sh --dry-run
sh scripts/install.sh
```

如果你的本地电脑 IP 或端口不同，只改这一行：

```sh
wget -O XiaoMi-main.tar.gz http://你的电脑IP:端口/XiaoMi-main.tar.gz
```

## GitHub 直连安装，备用

只有在小米万兆路由器自己能访问 GitHub 时，才用这一段：

```sh
cd /tmp
rm -rf XiaoMi-main XiaoMi-main.tar.gz
wget -O XiaoMi-main.tar.gz https://github.com/vpn3288/XiaoMi/archive/refs/heads/main.tar.gz ||
  wget --no-check-certificate -O XiaoMi-main.tar.gz https://github.com/vpn3288/XiaoMi/archive/refs/heads/main.tar.gz
tar -xzf XiaoMi-main.tar.gz
cd XiaoMi-main
sh scripts/install.sh --dry-run
sh scripts/install.sh
```

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

如果路由器无法从 `/dev/urandom` 生成强随机管理口令，安装会中止。此时请先检查系统随机源，或显式传入 `--admin-token`。

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

面板会显示基础入口。当前配置、运行规则和诊断输出需要提交管理口令后查看。执行保存、预检、确认持久化、删除或关闭时，在“确认客户端正常并持久化”旁边的当前管理口令框填入安装时显示的 Panel management token。

会影响运行规则的动作还会弹出二次确认；服务端也会校验本次按钮动作的确认参数。只带管理口令直接 POST 危险动作会被拒绝。

面板的危险操作需要浏览器启用 JavaScript。禁用 JavaScript 时，服务端会拒绝缺少二次确认参数的危险动作。

## 新手推荐填写

先只测试一台设备：

```text
旁路由 IP：192.168.31.118
LAN 网段：192.168.31.0/24
模式：仅列表设备走旁路由
走旁路由 IP：192.168.31.50
直连 IP：留空，或填不想走旁路由的 IP
走旁路由 MAC：先留空
直连 MAC：先留空
当前管理口令：执行操作前填安装时显示的 Panel management token
```

然后按这个顺序点：

```text
1. 保存为关闭配置并清理当前规则
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

也可以从安装脚本入口卸载：

```sh
sh scripts/install.sh --uninstall
```

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

重新下载最新版并安装即可。安装脚本会保留管理口令、已验证配置和待确认状态。为避免未验证规则在重装后自动复活，如果旧的当前配置是启用状态但没有 `config.last_good` 或待确认验证状态，安装脚本会把当前配置降级为关闭：

```sh
cd /tmp
rm -rf XiaoMi-main XiaoMi-main.tar.gz
wget -O XiaoMi-main.tar.gz https://github.com/vpn3288/XiaoMi/archive/refs/heads/main.tar.gz
tar -xzf XiaoMi-main.tar.gz
cd XiaoMi-main
sh scripts/install.sh
```

更新不会默认启用未验证的 sidegw 配置。旧版本卸载后留下的保留配置也会按关闭状态处理，避免重装后无确认自动启用。

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
tests/
  shellcheck/run.sh 静态语法检查；RUN_SHELLCHECK=1 时追加 shellcheck
```

## 本地静态检查

在源码目录执行：

```sh
sh tests/shellcheck/run.sh
```

这个检查只读取源码文件，不会应用网络规则，也不会写路由器配置。

需要更严格的 shellcheck 审查时执行：

```sh
RUN_SHELLCHECK=1 sh tests/shellcheck/run.sh
```

当前 `RUN_SHELLCHECK=1` 是严格审查入口，不是默认绿色门槛；它可能输出仓库既有 warning/info，需要按风险分批处理。

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
