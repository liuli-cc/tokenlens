# TokenLens

TokenLens is a native macOS background companion for Codex / ChatGPT usage. It shows a minimal black-and-white Dynamic Island at the top of the screen, starts with ChatGPT, and exits when ChatGPT exits.

[中文说明 / Chinese](#中文说明)

## Features

- **Dynamic Island UI** — Move the pointer to the top-center area to reveal a slow, elastic expansion; leaving the island collapses it immediately.
- **Model and provider detection** — Reads `turn_context.payload.model` and `session_meta.payload.model_provider` from local Codex sessions.
- **Token usage** — Input, cached input, output, and total tokens.
- **Shared quota** — Remaining ChatGPT / Codex agentic quota percentage when reported by the local logs.
- **Context metrics** — Context window, current length, cache hit rate, and a seven-day usage trend.
- **CC Switch support** — Reads `~/.cc-switch/cc-switch.db` in read-only mode to show Codex providers, configured models, and the last 30 days of proxy usage. For active DeepSeek and Kimi providers, it displays the real balance returned by each provider's official API; a provider without a readable official balance endpoint is clearly labeled unavailable.
- **Detailed dashboard** — Click the expanded island to inspect all models, trends, and metric definitions.

## Requirements

- macOS 14 or later (Apple Silicon recommended).
- ChatGPT installed at `/Applications/ChatGPT.app`.
- Optional: CC Switch. If its database is not present, Codex log tracking continues normally.

## Build and install

```bash
chmod +x build.sh install.sh
./build.sh
./install.sh
```

`build.sh` runs the scanner self-test, builds the two Swift executables, packages `dist/TokenLens.app`, and signs the bundle locally.

`install.sh` registers a per-user LaunchAgent at:

```text
~/Library/LaunchAgents/cn.liuli.tokenlens.chatgpt-bridge.plist
```

After installation, reopen ChatGPT. TokenLens will appear automatically. If ChatGPT is already running, synchronization normally takes about one second.

To remove the automatic ChatGPT integration:

```bash
launchctl bootout "gui/$(id -u)/cn.liuli.tokenlens.chatgpt-bridge" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/cn.liuli.tokenlens.chatgpt-bridge.plist"
```

## Data and privacy

TokenLens reads only local files:

- `~/.codex/sessions/**/*.jsonl` for token, model, context, and rate-limit events;
- `~/.cc-switch/cc-switch.db` when CC Switch is installed, queried through a read-only SQLite URI.

It never uploads logs or loads user/assistant message bodies into the dashboard. For a supported external provider, the API key already stored by CC Switch is used only in local memory to make that provider's official balance request; it is neither displayed nor persisted by TokenLens.

## Known limitations

- Quota percentage is `--` until a rate-limit event is available in the local Codex logs.
- CC Switch coverage depends on its local schema and proxy request logs; some versions may expose fewer external-model records. Unsupported or undocumented provider balance APIs show **Unavailable** rather than a fabricated percentage.
- The ChatGPT lifecycle bridge currently matches `/Applications/ChatGPT.app`. If ChatGPT is moved, update the path check in `BridgeSources/TokenLensBridge.swift`.

## License

MIT License. See [LICENSE](LICENSE).

---

## 中文说明

TokenLens 是一个原生 macOS 后台助手，用来观察本机 Codex / ChatGPT 的 Token 使用情况。它不创建 Dock 图标，也不要求单独打开：打开 ChatGPT 时自动出现，退出 ChatGPT 时自动退出。

### 功能

- 顶部黑白动态岛：鼠标靠近屏幕顶部中央时缓慢展开，离开后立即收起。
- 自动识别当前模型与提供商，并清晰标注 Codex 或 CC Switch 外部模型来源。
- 显示 Token 消耗、共享额度百分比，或外部模型的真实余额、上下文长度、当前长度、缓存命中率和近 7 日趋势。
- 点击展开的小岛查看详细统计面板。

### 使用

```bash
chmod +x build.sh install.sh
./build.sh
./install.sh
```

安装后重新打开 `/Applications/ChatGPT.app` 即可使用。统计数据只在本机读取 `~/.codex/sessions` 和可选的 `~/.cc-switch/cc-switch.db`，不上传日志，也不解析对话正文。外部模型余额仅调用该供应商的官方余额接口，API Key 只在本机内存中使用，不会显示或写入 TokenLens。
