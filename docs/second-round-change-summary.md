# 第二轮主笔变更说明

## 本轮目标

按 `主笔AI指导文件.md` 继续加固安装、卸载和面板危险操作流程，让 dry-run 更可信，并补充可重复执行的静态检查入口。

## 改动文件

```text
README.md
scripts/install.sh
panel/www/cgi-bin/sidegw.cgi
panel/modules/sidegw/test.sh
panel/modules/sidegw/rollback.sh
tests/shellcheck/run.sh
docs/second-round-change-summary.md
```

## 核心改动

```text
1. install.sh 增加 --uninstall 入口，转交 scripts/uninstall.sh 执行。
2. install.sh 的 --dry-run 改为先执行 preflight，再退出且不写入文件。
3. preflight 检查 ip、iptables、uci、uhttpd、pidof、netstat、awk、br-lan、/mnt/... 挂载点和源码文件。
4. /proc/mounts 挂载点检查改为 awk 字段精确匹配，避免 grep 正则误匹配。
5. 保留配置恢复、panel/www 复制、sidegw 模块复制等关键写入增加失败中止。
6. 重装时旧 config 若启用但缺少 config.last_good 或 pending 验证态，会降级为 ENABLED='0'，避免未验证配置自动复活。
7. 面板危险动作增加浏览器二次确认，并要求服务端收到 action_confirm 才执行。
8. write_config 写入改为临时文件 + mv；写入失败时不再继续 apply/test/confirm。
9. 管理口令生成取消 date+PID 弱随机兜底；强随机失败时中止安装或拒绝自动生成。
10. 诊断页、当前配置和规则详情改为需要管理口令后查看。
11. change_token 增加服务端动作确认。
12. cron/firewall autostart 写入增加失败中止。
13. 禁用旧版 sidegw-panel 失败时中止安装，避免旧规则重建器继续运行。
14. toolbox.conf、toolbox-bootstrap.sh 写入和 chmod 增加失败检查。
15. cron 更新修正 grep -v 空输出误判，保留真实读写错误中止。
16. uhttpd 端口占用检测改为匹配监听地址端口结尾，降低端口子串误判。
17. 安装失败时尽量恢复被移走的旧 panel/www 和 sidegw 模块目录。
18. 安装完成前校验 apply.sh、test.sh、rollback.sh 可执行。
19. test.sh 写待确认/自动回滚标记失败时立即回滚并失败退出。
20. rollback.sh 写关闭配置或替换配置失败时硬失败，避免假成功。
21. 新增 tests/shellcheck/run.sh，默认统一执行 sh -n 并覆盖 scripts、panel、tests；设置 RUN_SHELLCHECK=1 时追加 shellcheck。
22. README 补充 dry-run 检查范围、服务端动作确认、JS 要求、install.sh --uninstall 和静态检查命令。
```

## 安全措施

```text
安装默认仍不启用 sidegw。
dry-run 不创建目录、不写配置、不注册 crontab/firewall include、不启动 uhttpd。
安装前强制确认安装目录对应的 /mnt/... 路径已经挂载，降低误写内部存储风险。
危险面板动作需要管理口令，且现在有浏览器二次确认和服务端动作确认。
未验证启用配置不会在重装后自动复活。
关键配置写入失败时停止后续网络规则动作，避免旧配置被误 apply。
管理口令只允许强随机生成；无法生成时要求人工传入。
诊断输出、当前配置和 iptables/ip rule 详情不再匿名展示。
本轮未改动 sidegw 已验证的 ip rule、iptables、DNS DNAT/SNAT 核心规则。
```

## 审查意见整理

```text
必须修改：
1. 服务端强制危险动作二次确认：已修改。
2. 未验证 ENABLED='1' 配置重装后可能自动应用：已修改。
3. /proc/mounts grep 正则误匹配：已修改为 awk 字段匹配。
4. 关键 cp/mv/write_config/cp last_good 未检查失败：已修改。
5. 应用并预检、确认持久化、保存并清理规则缺少明确确认或文案：已修改。
6. 弱随机管理口令兜底：已修改。
7. 匿名诊断/规则详情泄露：已修改。
8. change_token 缺少二次确认：已修改。
9. cron/firewall 写入失败未中止：已修改。
10. 旧版 sidegw-panel 禁用失败静默继续：已修改。
11. crontab grep -v 空输出误判：已修改。
12. toolbox.conf/bootstrap heredoc 写入未检查：已修改。
13. 安装失败可能移走旧恢复工具：已修改，失败时尝试恢复旧目录。
14. sidegw 核心脚本可执行性未检查：已修改。
15. test.sh 预检成功后 pending 写入未检查：已修改。
16. rollback.sh 配置写入失败可能假成功：已修改。

建议修改：
1. netstat preflight：已加入。
2. README 说明服务端确认和 RUN_SHELLCHECK=1 状态：已修改。
3. tests/shellcheck/run.sh 空白文件名支持：已修改为逐行读取。
4. dry-run 更完整的写权限/端口占用预检查：可暂缓。
5. stat -c 锁回收兼容性：可暂缓。

可暂缓：
1. shellcheck 全绿。本轮默认 sh -n 必过，RUN_SHELLCHECK=1 作为严格审查入口。
2. 特殊挂载环境 override。新手安全优先，默认继续要求 /proc/mounts 中存在挂载点。

不同审查者意见冲突处：
1. 浏览器 confirm 是否足够：最终按更保守方案处理，增加服务端 action_confirm。
2. 更新安装是否保留启用状态：最终按更保守方案处理，只保留已验证/待确认状态，未验证启用配置降级关闭。

主笔最终决策：
先合入安全阻塞项，再进入下一轮审查；不把 shellcheck 历史 warning 作为本轮阻塞项。OpenCode 连续返回 API Unauthorized，当前无法形成有效审查，需要更换或修复 key。
```

## 风险点列表

```text
1. 新增挂载点检查可能让未真实挂载到 /proc/mounts 的特殊环境无法安装，需要审查者确认是否应允许人工覆盖。
2. 禁用 JS 的客户端无法通过面板按钮设置 action_confirm，因此危险动作会被服务端拒绝。
3. tests/shellcheck/run.sh 使用 find、sort、sh，适合开发环境和 OpenWrt 常见环境，但极简系统可能缺 sort。
4. RUN_SHELLCHECK=1 会暴露仓库既有 shellcheck 警告，本轮先不把它作为默认必过门槛。
```

## 如何回滚

```sh
git checkout -- README.md scripts/install.sh panel/www/cgi-bin/sidegw.cgi panel/modules/sidegw/test.sh panel/modules/sidegw/rollback.sh tests/shellcheck/run.sh docs/second-round-change-summary.md
```

路由器已安装环境的功能回滚：

```sh
/mnt/usb-d965c2b9/xiaomi_router/toolbox/panel/modules/sidegw/rollback.sh
sh scripts/install.sh --uninstall
```

## 如何测试

```sh
sh -n scripts/install.sh
sh -n panel/www/cgi-bin/sidegw.cgi
sh -n tests/shellcheck/run.sh
sh tests/shellcheck/run.sh
git diff --check
```

可选严格检查：

```sh
RUN_SHELLCHECK=1 sh tests/shellcheck/run.sh
```

## 预期输出

```text
所有 sh -n 通过。
tests/shellcheck/run.sh 输出每个脚本的 sh -n 检查；默认显示 shellcheck: skipped (set RUN_SHELLCHECK=1 to enable)。
RUN_SHELLCHECK=1 会执行 shellcheck；若存在历史警告，审查者按严重度分级处理。
git diff --check 无空白错误。
```

## 待审查文件列表

```text
scripts/install.sh
panel/www/cgi-bin/sidegw.cgi
tests/shellcheck/run.sh
README.md
docs/second-round-change-summary.md
```

## 需要审查者重点看的地方

```text
1. install.sh 的 --dry-run 是否覆盖了足够的真实安装前条件。
2. /mnt/... 挂载点必须出现在 /proc/mounts 是否过严。
3. install.sh --uninstall 的分发方式是否符合用户预期。
4. 危险按钮二次确认是否覆盖了所有需要确认的面板动作。
5. 新增静态检查入口是否保持 POSIX sh / BusyBox ash 兼容。
```

## 风险等级

```text
风险等级：低
是否默认启用：否
是否有自动回滚：本轮未触发 sidegw 应用；原有应用预检仍有自动回滚
```

## 第三轮快速加固补充

```text
1. RUN_SHELLCHECK=1 现在作为可通过的严格质量门。
2. 新增 panel/www/cgi-bin/api.cgi 作为后续统一 API 入口占位。
3. MAC-only 分流可以进入自动预检；预检会检查 mangle mark、DNS DNAT/SNAT 和 FORWARD 规则。
4. 面板预检先写 config.candidate，再由 test.sh 在 pending 状态写入成功后同步正式 config。
5. toolbox-bootstrap.sh 拒绝应用普通未验证 ENABLED=1 配置，避免 cron/firewall 误重应用候选配置。
6. ip rule 兜底清理不再删除普通 lookup main 规则，只清理 table 100 和 sidegw fwmark。
7. fresh install 失败时 autostart 恢复不再依赖旧目录备份门控。
8. uninstall.sh crontab 清理改用带 PID 的临时文件。
9. diagnose.sh 默认对 token/password/cookie/key/secret/uuid、URL 和 MAC 做基础脱敏。
10. README 和 safety 增加可信 LAN 使用、快转/硬件加速排障、MAC 预检能力说明。
11. uninstall.sh 在 rollback.sh 缺失或不可执行时会运行内置 fallback 清理，不再静默卸载。
12. MAC 预检增加可选 fwmark route 检查；系统 ip 不支持 mark route get 时会明确提示跳过。
```
