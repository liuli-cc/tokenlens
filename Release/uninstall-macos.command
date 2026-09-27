#!/bin/zsh
set -euo pipefail
service_label='cn.liuli.tokenlens.chatgpt-bridge'
/bin/launchctl bootout "gui/$(id -u)/$service_label" 2>/dev/null || true
/usr/bin/pkill -x TokenLens 2>/dev/null || true
agent_plist="$HOME/Library/LaunchAgents/$service_label.plist"
[[ ! -f "$agent_plist" ]] || mv "$agent_plist" "$agent_plist.disabled"
print '已停用联动和开机启动。可将 ~/Applications/TokenLens.app 移到废纸篓。'
print 'DSH 插件和本机数据已保留；如需停用插件，请从 Harness 配置中移除 tokenlens-dsh-status 条目。'
