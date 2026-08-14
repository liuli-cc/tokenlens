# TokenLens

TokenLens 是一个原生 macOS 菜单栏级后台助手，用来观察本机 Codex / ChatGPT 的 Token 使用情况。它不创建 Dock 图标，也不要求单独打开：打开 ChatGPT 时自动出现，退出 ChatGPT 时自动退出。

## 功能

- 顶部黑白动态岛：鼠标靠近屏幕顶部中央时由小到大展开，离开后快速收起。
- 当前模型与提供商：从 Codex 会话日志识别 `turn_context.payload.model` 和 `session_meta.payload.model_provider`。
- Token 消耗：输入、缓存输入、输出和总量。
- ChatGPT / Codex 共享额度剩余百分比。
- 上下文窗口、当前长度、缓存命中率和近 7 日趋势。
- CC Switch 外部模型：读取 `~/.cc-switch/cc-switch.db` 中的 Codex 提供商、模型目录和近 30 日代理请求用量，并在界面标注来源。
- 详细面板：点击展开的小岛查看全部模型、趋势和指标口径。

## 环境要求

- macOS 14 或更高版本（Apple Silicon 优先）。
- 已安装 `/Applications/ChatGPT.app`，且该应用使用 Codex 会话日志。
- 可选：CC Switch。未安装或数据库不存在时，CC Switch 区域会自动为空，不影响 Codex 日志统计。

## 构建与安装

```bash
chmod +x build.sh install.sh
./build.sh
./install.sh
```

`build.sh` 会运行扫描器自测、编译两个 Swift 可执行文件，并生成签名的 `dist/TokenLens.app`。

`install.sh` 会把当前构建注册为当前用户的 LaunchAgent：

```text
~/Library/LaunchAgents/cn.liuli.tokenlens.chatgpt-bridge.plist
```

安装完成后，重新打开 ChatGPT 即可看到顶部小岛。若 ChatGPT 已经打开，等待约 1 秒即可自动同步。

卸载自动联动：

```bash
launchctl bootout "gui/$(id -u)/cn.liuli.tokenlens.chatgpt-bridge" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/cn.liuli.tokenlens.chatgpt-bridge.plist"
```

## 数据与隐私

TokenLens 只在本机读取：

- `~/.codex/sessions/**/*.jsonl` 中与 Token、模型、上下文相关的事件；
- 可选的 `~/.cc-switch/cc-switch.db`（以只读 SQLite URI 查询）。

它不需要 API Key，不上传日志，也不会把用户消息或助手正文加载到仪表盘。统计结果仅保存在内存中。

## 已知限制

- 额度百分比依赖 Codex 日志中最新的 rate-limit 事件；没有该事件时显示 `--`。
- CC Switch 的统计依赖其数据库结构和代理请求日志；不同版本可能导致部分外部模型暂时不可见。
- TokenLens 目前只联动 `/Applications/ChatGPT.app`，如应用被移动，需要同步修改 `BridgeSources/TokenLensBridge.swift` 中的路径判断。

## 开源协议

本项目以 MIT License 开源，见 [LICENSE](LICENSE)。
