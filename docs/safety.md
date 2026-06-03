# 安全说明

本项目只做用户态脚本和本地 Web 面板，不做刷机类操作。

禁止范围：

```text
mtd
uboot
bootloader
分区表
自动刷固件
自动恢复出厂
无备份覆盖系统关键配置
```

安装脚本默认只做：

```text
复制面板文件
创建 toolbox-bootstrap.sh
注册 crontab
注册 firewall include
启动 uhttpd
```

安装不会默认启用 sidegw 分流。

影响网络的操作必须由用户在面板里点击，并优先使用“应用并预检，失败自动回滚”。
