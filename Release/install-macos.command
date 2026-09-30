#!/bin/zsh
set -euo pipefail
package_dir="${0:A:h}"
source_app="$package_dir/TokenLens.app"
installed_app="$HOME/Applications/TokenLens.app"
service_label='cn.liuli.tokenlens.chatgpt-bridge'
agent_dir="$HOME/Library/LaunchAgents"
agent_plist="$agent_dir/$service_label.plist"
[[ -d "$source_app" ]] || { print -u2 '请保持安装脚本与 TokenLens.app 在同一目录。'; exit 1; }
/usr/bin/codesign --verify --deep --strict "$source_app"
/bin/launchctl bootout "gui/$(id -u)/$service_label" 2>/dev/null || true
# Stop only the previous TokenLens copy before replacing its installed files.
/usr/bin/pkill -x TokenLens 2>/dev/null || true
mkdir -p "$HOME/Applications" "$agent_dir"
if [[ -d "$installed_app" ]]; then
  previous_app="$HOME/Applications/TokenLens.previous.app"
  if [[ -d "$previous_app" ]]; then
    mkdir -p "$HOME/.Trash"
    mv "$previous_app" "$HOME/.Trash/TokenLens-previous-$(date +%Y%m%d%H%M%S).app"
  fi
  mv "$installed_app" "$previous_app"
fi
/usr/bin/ditto "$source_app" "$installed_app"
cp "$installed_app/Contents/Resources/bridge.plist" "$agent_plist"
/usr/libexec/PlistBuddy -c 'Delete :ProgramArguments' "$agent_plist"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$agent_plist"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $installed_app/Contents/Helpers/TokenLensBridge" "$agent_plist"
chmod 600 "$agent_plist"
/bin/launchctl bootstrap "gui/$(id -u)" "$agent_plist"
/bin/launchctl kickstart -k "gui/$(id -u)/$service_label"
print '已安装到 ~/Applications/TokenLens.app。打开 Codex / GPT、DeepSeek Harness、WorkBuddy、Claude 或 CodeBuddy 后，灵动岛自动出现。'
print '第一次启动若被系统拦截，请在「系统设置 → 隐私与安全性」允许打开。'
