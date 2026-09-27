#!/bin/zsh
set -euo pipefail
package_dir="${0:A:h}"
source_plugin="$package_dir/TokenLens.app/Contents/Resources/tokenlens-dsh-status.mjs"
target_plugin="$HOME/.dsh/integrations/tokenlens-dsh-status.mjs"
patch_file="$HOME/.dsh/profiles/desktop/cordis.patch.yml"
[[ -d "${patch_file:h}" ]] || { print -u2 '请先安装并启动一次 DeepSeek Harness。'; exit 1; }
if /usr/bin/pgrep -x 'DeepSeek Harness' >/dev/null; then
  print -u2 '请先完全退出 DeepSeek Harness，再运行连接脚本。'; exit 1
fi
mkdir -p "${target_plugin:h}"
[[ ! -f "$target_plugin" ]] || cp "$target_plugin" "$target_plugin.tokenlens-backup"
cp "$source_plugin" "$target_plugin"
if [[ -f "$patch_file" ]] && /usr/bin/grep -q 'id: tokenlens-dsh-status' "$patch_file"; then
  print '已更新现有状态桥。'
else
  [[ ! -f "$patch_file" ]] || cp "$patch_file" "$patch_file.tokenlens-backup"
  # YAML accepts a JSON quoted string; escape paths without invoking a shell.
  escaped_path="${target_plugin//\\/\\\\}"
  escaped_path="${escaped_path//\"/\\\"}"
  printf '%s\n' '' '- insert:' '    - id: tokenlens-dsh-status' "      name: \"$escaped_path\"" >> "$patch_file"
fi
print '状态桥已连接。重新打开 Harness 后自动同步余额，发送下一条消息后同步模型。'
