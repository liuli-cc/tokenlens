#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_dir="$project_dir/dist/TokenLens.app"
bridge_path="$app_dir/Contents/Helpers/TokenLensBridge"
source_plist="$project_dir/Integration/cn.liuli.tokenlens.chatgpt-bridge.plist"
launch_agents_dir="$HOME/Library/LaunchAgents"
target_plist="$launch_agents_dir/cn.liuli.tokenlens.chatgpt-bridge.plist"
service_label="cn.liuli.tokenlens.chatgpt-bridge"

if [[ ! -x "$bridge_path" ]]; then
  print -u2 "未找到构建产物，请先运行 ./build.sh"
  exit 1
fi

mkdir -p "$launch_agents_dir"
cp "$source_plist" "$target_plist"
/usr/bin/plutil -replace ProgramArguments -json "[\"$bridge_path\"]" "$target_plist"

launchctl bootout "gui/$(id -u)/$service_label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$target_plist"
launchctl kickstart -k "gui/$(id -u)/$service_label"

print "已安装 TokenLens ChatGPT 联动服务：$target_plist"
