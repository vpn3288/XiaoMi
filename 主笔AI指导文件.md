# 主笔 AI 指导文件

适用项目：小米万兆路由器 Web 工具面板  
当前首个功能：`sidegw 指定 IP / MAC 分流`  
主笔 AI：负责需求拆解、架构设计、脚本编写、页面实现、测试方案和版本迭代。
让你当主笔，然后在本地WSL安装创建claude code和opencode和codex三个审查者AI。使用claudecode的claude4.6和opencode的免费deepseek flash free以及codex的gpt5.5作为审查者AI。每次你把安装脚本发给三个审查者AI，并且给与三个审查者AI关于审查的指导文件，让他们按照审查指导文件审查脚本。然后你根据三方AI审查意见和主笔AI的主笔指导文件进行脚本完善。尽量的抄1panle的页面和openwrt的IP分流功能，并且把他们优化成傻瓜式操作，适合新手操作的面板。这一步很重要，如果你忘记了claudecode，opencode，codexAPIkey,必须问我要。https://raw.githubusercontent.com/vpn3288/XiaoMi/refs/heads/main/%E4%B8%BB%E7%AC%94AI%E6%8C%87%E5%AF%BC%E6%96%87%E4%BB%B6.md这个是你的主笔AI指导文件。
https://raw.githubusercontent.com/vpn3288/XiaoMi/refs/heads/main/%E5%AE%A1%E6%9F%A5%E8%80%85AI%E6%8C%87%E5%AF%BC%E6%96%87%E4%BB%B6.md这个是你要给三个审查者AI审查脚本的指导文件。



## 1. 项目目标

创建一个可托管在 GitHub 的开源项目，用脚本在小米万兆路由器上部署一个类似 1Panel 风格的本地管理面板。

首个功能是：

```text
小米万兆路由器 sidegw 指定 IP / MAC 分流
```

目标用户是新手。用户不应该理解复杂的 `ip rule`、`iptables`、`DNS DNAT/SNAT`、`LAN -> LAN FORWARD`，只需要知道：

```text
1. 旁路由 IP 是多少
2. 哪些设备走旁路由
3. 哪些设备保持直连
4. 保存并应用
5. 一键测试
6. 出问题一键关闭 / 回滚
```

最终体验应该像：

```text
打开面板 -> 选择“小米万兆路由器 sidegw 指定 IP 分流”
-> 填旁路由 IP
-> 勾选设备或输入 IP/MAC
-> 保存并应用
-> 面板显示“已生效 / 未生效 / 问题原因”
```

## 2. 设计参考

视觉和信息架构参考 1Panel，但不要直接复制其商标、文案或源码。

应该学习：

```text
左侧导航
顶部状态栏
模块化功能入口
清晰的状态卡片
表单分组
一键启用 / 停用
日志和诊断区域
危险操作二次确认
```

功能逻辑参考 OpenWrt / ImmortalWrt 的 IP 分流、策略路由、旁路由使用习惯。

交互复杂度参考现有页面：

```text
http://192.168.31.1:8888/cgi-bin/sidegw.cgi
```

但要比它更适合新手：

```text
显示当前主路由 IP
显示旁路由连通状态
显示当前电脑 IP
显示命中设备列表
显示出口 IP 测试结果
显示 DNS 是否被正确接管
失败时给出明确原因
```

## 3. 安全第一原则

这个项目运行在小米万兆主路由上，必须默认保护设备安全。不要为了功能方便做高风险操作。

绝对禁止：

```text
禁止写入 mtd、uboot、分区表、bootloader
禁止修改 rootfs 分区
禁止自动刷固件
禁止自动恢复出厂
禁止删除系统关键配置
禁止无备份覆盖 /etc/config/network
禁止无备份覆盖 /etc/config/firewall
禁止执行 rm -rf /、格式化磁盘等破坏性命令
禁止默认开启全 LAN 旁路由且无回滚
禁止把用户网络锁死后不自动恢复
```

所有会影响联网的操作必须满足：

```text
先备份
可回滚
可禁用
有超时保护
有 dry-run 或 preview
有明确日志
```

危险操作必须二次确认。

## 4. 当前成功方案必须保留

这次已经验证成功的 sidegw 方案包含以下关键点，主笔 AI 不得遗漏：

```text
1. 小设备/客户端命中规则：ip rule from CLIENT_IP lookup 100
2. table 100 默认路由：default via ERX_IP dev br-lan
3. ER-X 自己必须 lookup main，避免路由循环
4. LAN -> LAN FORWARD 必须放行
5. DNS 请求必须 DNAT 到 ER-X
6. DNS 回包必须通过 SNAT 回小米主路由，避免回包绕过 conntrack
7. send_redirects 必须关闭
8. rp_filter 必须关闭
9. 规则可能被小米防火墙刷新清掉，必须有定时 / firewall include 重应用机制
```

核心链名建议：

```text
SIDEGW
SIDEGW_FWD
SIDEGW_DNS
SIDEGW_DNS_POST
```

策略表建议：

```text
table 100
fwmark 0x64：走旁路由
fwmark 0x65：直连
```

## 5. 项目结构建议

GitHub 项目建议结构：

```text
xiaomi-be10000-toolbox/
  README.md
  LICENSE
  docs/
    safety.md
    sidegw-design.md
    recovery.md
    ai-review-workflow.md
  scripts/
    install.sh
    uninstall.sh
    healthcheck.sh
    backup.sh
  panel/
    www/
      index.html
      assets/
      cgi-bin/
        api.cgi
        sidegw.cgi
    modules/
      sidegw/
        apply.sh
        config.default
        diagnose.sh
        rollback.sh
  ai/
    主笔AI指导文件.md
    审查者AI指导文件.md
  tests/
    shellcheck/
    fixtures/
```

要求：

```text
scripts/install.sh 只负责安装框架和注册启动项
modules/sidegw/apply.sh 只负责 sidegw 功能
modules/sidegw/diagnose.sh 只负责诊断
modules/sidegw/rollback.sh 只负责回滚
panel/www/cgi-bin/api.cgi 提供统一 API 入口
以后新增功能时放入 panel/modules/新功能名/
```

不要把所有逻辑塞进一个超大脚本。

## 6. 面板设计要求

页面第一屏应该是工具面板，不是说明书。

推荐布局：

```text
左侧导航：
  概览
  网络工具
    sidegw 指定 IP 分流
  日志
  备份与恢复
  设置

顶部：
  主路由 IP
  ER-X / 旁路由状态
  当前运行状态
  一键关闭所有自定义规则

sidegw 页面：
  状态卡片
  旁路由设置
  设备分流列表
  DNS 接管设置
  应用 / 测试 / 回滚
  诊断日志
```

新手友好要求：

```text
默认展示“推荐模式”
高级选项折叠
每个输入框有示例值
自动识别当前电脑 IP
自动列出 DHCP 设备
支持勾选设备进入分流列表
保存前预览将执行的规则
保存后显示真实 ip rule / iptables 命中状态
```

不要让用户直接编辑复杂命令作为主要交互。

## 7. 安装脚本要求

`install.sh` 必须：

```text
检测当前设备和系统信息
检测是否为小米万兆路由器或兼容环境
检测 br-lan 是否存在
检测 iptables、ip rule、uhttpd 是否可用
检测 USB 挂载路径
创建安装目录
备份已有同名文件
安装面板文件
注册 crontab
注册 firewall include
启动 uhttpd 面板
执行健康检查
输出访问地址
```

必须支持：

```text
--dry-run
--install-dir PATH
--port 8888
--host 192.168.31.1
--no-autostart
--uninstall
```

安装脚本不得强制启用 sidegw 分流。安装完成后应默认：

```text
sidegw 功能已安装
sidegw 默认关闭
用户进入面板后手动启用
```

## 8. 回滚和保命机制

必须提供“一键关闭 sidegw”：

```text
ENABLED='0'
清理 ip rule
清理 table 100
清理 SIDEGW / SIDEGW_FWD / SIDEGW_DNS / SIDEGW_DNS_POST
恢复默认连通
```

必须提供超时保护：

```text
用户点击“应用并测试”
系统启用 sidegw
等待 3-10 秒
测试 DNS、出口 IP、Google generate_204 或用户自定义 URL
如果失败，自动回滚
```

不要让用户手动断网后再找回系统。

## 9. 诊断能力

必须提供 `diagnose.sh`，输出：

```text
系统信息
br-lan IP
ER-X IP 是否可达
当前 sidegw 配置
ip rule
ip route show table 100
iptables SIDEGW 链
iptables SIDEGW_FWD 链
iptables SIDEGW_DNS 链
iptables SIDEGW_DNS_POST 链
DNS 测试
出口 IP 测试
最近 sidegw 日志
```

输出要隐藏敏感信息。

## 10. 代码风格

Shell 脚本要求：

```text
尽量 POSIX sh 兼容
兼容 BusyBox ash
避免 Bash-only 语法
少用数组
少用 process substitution
不要依赖 Python / Node
所有变量加引号
所有外部命令失败要处理
日志清晰
函数短小
```

Web 页面要求：

```text
纯 HTML/CSS/少量 JS 即可
不要依赖外网 CDN
不要依赖 npm 构建
不要用大型前端框架
适配手机和桌面
按钮状态清晰
危险按钮使用二次确认
```

## 11. AI 协作流程

每次主笔 AI 修改脚本后，必须生成以下交付物：

```text
1. 修改说明
2. 风险点列表
3. 回滚方式
4. 本次测试命令
5. 预期输出
6. 待审查文件列表
```

然后把这些交给三个审查者 AI：

```text
Claude Code
OpenCode + DeepSeek Flash Free
Codex + GPT-5.5
```

每一轮审查都必须是“全新审查”：

```text
主笔 AI 完善脚本后，必须为每个审查者 AI 打开新的窗口 / 新的会话
不要在旧审查窗口里继续追问
不要让审查者 AI 依赖上一轮记忆
审查输入材料只包含本轮最新脚本、最新文档、最新变更说明、最新审查指导文件
如果需要引用上一轮问题，必须由主笔 AI 明确写进本轮变更说明
```

目的：

```text
避免审查者 AI 被旧脚本、旧错误、旧结论、旧缓存混淆
确保每次审查只针对当前最新版本
```

主笔 AI 必须等待三方审查意见，整理成：

```text
必须修改
建议修改
可暂缓
不同审查者意见冲突处
主笔最终决策
```

凡涉及网络中断、持久启动、iptables/ip rule、防火墙 include、crontab 的意见，优先按更保守方案处理。

## 12. 主笔 AI 输出格式

每轮完成后，主笔 AI 必须输出：

```text
本轮目标：
改动文件：
核心改动：
安全措施：
如何测试：
如何回滚：
需要审查者重点看的地方：
```

如果脚本可能导致用户断网，必须明确标注：

```text
风险等级：高
是否默认启用：否
是否有自动回滚：是
```

## 13. 长期扩展接口

项目必须预留其他功能入口，例如：

```text
SSH 保活
路由器备份
DNS 劫持检测
旁路由健康检查
Docker / USB 状态
防火墙规则管理
设备列表管理
一键导出诊断包
```

新增功能必须遵守模块化结构：

```text
panel/modules/功能名/
  apply.sh
  config.default
  diagnose.sh
  rollback.sh
  README.md
```

每个模块必须可单独启用、禁用、诊断、回滚。

## 14. 最终成功标准

首个版本成功标准：

```text
1. 安装后能打开本地面板
2. 面板中能看到 sidegw 功能
3. 能设置旁路由 IP
4. 能设置指定 IP 走旁路由
5. 能自动处理 DNS
6. 能自动处理 LAN -> LAN FORWARD
7. 能一键测试是否成功
8. 失败能自动回滚
9. 重启或防火墙刷新后能自动重应用
10. 默认不会让小米路由器变砖
```

最重要的判断：

```text
用户愿意让这个脚本跑在自己的主路由上。
```

如果主笔 AI 对某个操作是否安全不确定，必须选择不自动执行，只生成说明和人工确认步骤。
