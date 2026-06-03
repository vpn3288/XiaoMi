# 第一轮主笔变更说明

## 本轮目标

按照 `主笔AI指导文件.md` 和 `审查者AI指导文件.md` 创建项目第一版脚手架和 sidegw 指定 IP / MAC 分流模块。

## 改动文件

```text
README.md
scripts/common.sh
scripts/install.sh
scripts/uninstall.sh
scripts/healthcheck.sh
scripts/backup.sh
panel/www/index.html
panel/www/assets/style.css
panel/www/cgi-bin/sidegw.cgi
panel/modules/sidegw/config.default
panel/modules/sidegw/apply.sh
panel/modules/sidegw/rollback.sh
panel/modules/sidegw/diagnose.sh
panel/modules/sidegw/test.sh
docs/safety.md
docs/sidegw-design.md
docs/recovery.md
docs/ai-review-workflow.md
ai/README.md
```

## 核心改动

```text
1. 创建轻量 Web 面板。
2. 创建 sidegw 指定 IP / MAC 分流模块。
3. 安装脚本默认只安装面板，不启用 sidegw。
4. sidegw 支持保存配置、应用、应用并预检、失败自动回滚、一键关闭。
5. sidegw 保留已验证成功的关键规则：
   - table 100
   - from CLIENT_IP lookup 100
   - ER-X 自身 lookup main
   - LAN -> LAN FORWARD 放行
   - DNS DNAT 到 ER-X
   - DNS SNAT 到小米 LAN IP
   - 清理旧规则
   - 关闭 send_redirects / rp_filter
6. 增加文档和恢复方法。
```

## 安全措施

```text
不写 mtd
不碰 uboot
不刷固件
不恢复出厂
安装默认不启用 sidegw
ENABLED='0' 时 apply.sh 只清理规则
test.sh 预检失败自动恢复旧配置并重新 apply
rollback.sh 一键关闭并清理规则
install.sh 支持 --dry-run
uninstall.sh 清理 crontab、firewall include 和 sidegw 规则
```

## 如何测试 / 预检

静态语法检查：

```sh
for f in scripts/*.sh panel/modules/sidegw/*.sh panel/www/cgi-bin/*.cgi; do
  sh -n "$f" || exit 1
done
```

路由器上 dry-run：

```sh
sh scripts/install.sh --dry-run
```

路由器上安装：

```sh
sh scripts/install.sh
```

打开面板：

```text
http://192.168.31.1:8888/
```

sidegw 预检：

```text
填写旁路由 IP
填写指定设备 IP
点击“应用并预检，失败自动回滚”
```

## 如何回滚

面板点击：

```text
一键关闭
```

SSH：

```sh
/mnt/usb-d965c2b9/xiaomi_router/toolbox/panel/modules/sidegw/rollback.sh
```

卸载：

```sh
sh scripts/uninstall.sh
```

## 需要审查者重点看的地方

```text
1. install.sh 是否有默认启用 sidegw 的风险。
2. sidegw apply.sh 是否真正幂等，重复执行不会追加重复规则。
3. DNS DNAT + SNAT 是否完整。
4. LAN -> LAN FORWARD 放行是否过宽。
5. test.sh 自动回滚是否可靠。
6. CGI 输入清洗是否足够防命令注入。
7. BusyBox ash 兼容性。
8. uninstall.sh 是否能清理干净且不误删用户文件。
9. uhttpd / CGI 的 INSTALL_DIR 推断是否适合安装后的目录。
```

## 风险等级

```text
安装：低
保存配置：低
应用 sidegw：中
应用并预检：中，但带自动回滚
全 LAN 模式：高，不建议默认使用
```

## 审查要求

请审查者 AI 打开全新窗口 / 新会话，只基于本轮最新材料审查，不要沿用旧上下文。


