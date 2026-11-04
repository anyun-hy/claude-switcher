#!/bin/bash
# 重新生成仓库根 SHA256SUMS
# 维护纪律: core/、app/、daemons/、installer/ 下任何文件改动后,提交前必须运行本脚本
cd "$(dirname "$0")/.." || exit 1
shasum -a 256 \
    core/claude-switch.sh \
    app/main.swift \
    daemons/claude-bodyguard.sh \
    daemons/tz-watchdog.sh \
    daemons/local.claude-bodyguard.plist \
    daemons/local.tz-watchdog.plist \
    daemons/local.claude-update.plist \
    installer/安装.command \
    installer/卸载.command > SHA256SUMS
echo "✓ SHA256SUMS 已更新"
