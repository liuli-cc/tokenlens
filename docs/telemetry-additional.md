# WorkBuddy、Claude、CodeBuddy 用量来源

本读取器只保留白名单中的模型标识、数字用量、时间和本机请求去重标识。macOS 已有辅助功能权限时，也只读 Claude 界面的模型和用量控件，不读取文本输入框或对话内容，不点击控件，不主动申请权限。它不读取账号密钥，不调用带保存凭据的账号接口，不复制或输出聊天内容。下表描述已检查的本机记录格式，不代表服务端完整账单。

| 软件 | macOS 身份 | 数据源 | 可以测量 | 明确不推算 |
| --- | --- | --- | --- | --- |
| WorkBuddy AI | `com.workbuddy.workbuddy-ai` | `~/.workbuddy-ai/projects/**/*.jsonl`；`~/.workbuddy-ai/workbuddy.db` | 响应令牌、已报告缓存读取、按 API 响应累计的近期调用；数据库明确报告的上下文 used/size | 剩余额度、钱包余额、未经报告的模型容量 |
| Claude Desktop / Cowork | `com.anthropic.claudefordesktop` | `~/Library/Application Support/Claude/{local-agent-mode-sessions,claude-code-sessions}` 中原生 JSONL；`plan-usage-history.json` | 原生记录确实含 `message.usage` 时的令牌；额度样本确实含服务端 utilization/reset 时的额度 | 从 Claude Code 日志借用桌面聊天数字；从令牌推算订阅额度；从配置推算模型容量 |
| CodeBuddy CN | `com.tencent.codebuddycn` | `~/Library/Application Support/CodeBuddyExtension/Data/**/history/**/*.json` | 历史 `requests[].usage` 的输入、输出、缓存读取与写入 | 用户请求数当作 API 调用数；`credit` 消耗当作剩余余额；`lastTokens` 当作有验证容量的上下文百分比 |

Windows 使用用户目录中的 `.workbuddy-ai` 和 `%APPDATA%` 下对应的 `Claude`、`CodeBuddyExtension` 目录。缺少这些目录或软件采用另一种存储格式时显示不可读取，不声称已经验证本机没有发生消耗。CodeBuddy 国际版与不同发布渠道可能采用不同路径；没有符合白名单的记录时不借用其他软件的数据。

## 统计口径

- WorkBuddy `providerData.usage` 的 `inputTokens`、`outputTokens`、`totalTokens` 为实际响应元数据，要求输入加输出等于总数；`providerData.messageId` 用于去重。`conversationRequestId` 代表一个用户任务，不能用它合并任务内多次模型调用。`usage-log.json` 实际是技能使用记录，不计入令牌统计。
- WorkBuddy 缓存命中读 `rawUsage.prompt_cache_hit_tokens`，兼容 `cached_tokens`、`cache_read_input_tokens`。显式 0 是已测量的零命中；字段缺失是未知。缓存写入单独保存，不计入命中。数据库 `session_usage.used/size` 是软件返回的上下文数和容量，按当前会话匹配读取；不把今日累计令牌当作当前上下文。
- CodeBuddy `requests[].usage` 是用户请求内的累计数字。多个历史副本可能保存相同请求；按 `request.id` 去重，并保留总量最大的最新副本。`inputTokens` 是完整输入，`cacheTokens` 是其已报告缓存部分，`cachedWriteTokens` 单独记录。当前格式没有每次模型 API 调用数，近期调用显示未知。
- Anthropic 的完整输入是 `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`。缓存命中只计 `cache_read_input_tokens`；写入不是命中。流式内容块可能重复相同 `message.id`，只计一次并保留最终累计值。[官方字段说明](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
- **Claude Code 的 `~/.claude/projects` 与 Claude Desktop 聊天是不同来源。** 虽然可以解析 Claude Code 的 usage 格式，它的数字不会显示到 Claude Desktop 岛。新版 Desktop Code 的 `claude-code-sessions/**/*.json` 会话元数据提供 `model` 和 `lastActivityAt`：可回退显示最近活跃且未归档的会话模型，无需借用 CLI 令牌。已有辅助功能权限时，优先读取当前窗口的模型选择和用量按钮。用户使用自定义 Gateway 时也不把官方订阅额度当作 Gateway 余额。
- 2026-10-22 兼容 Desktop 额度历史 v2：`samples[].u.fh/sd` 为服务端已使用百分比，保留显式 0，拒绝布尔值和越界值。这种格式不保存重置时间，界面明确标注“重置时间未提供”，仅接受 15 分钟内的采样，不编造重置时刻。原格式仍要求未来的真实重置时间。读取失败或样本过期时不沿用旧数值。
- 当额度样本确实提供 `five_hour`、`seven_day` 的 utilization 与 resets_at 时，显示两者中更接近耗尽的窗口；15 分钟以前的样本或已到重置时刻的样本失效，不自动恢复成 100%。
- 今日按本机日期，近期调用为最近 24 小时。读取最近 8 天更新的文件，只保留事件本身最近 8 天的记录；旧文件无日志、被软件清理的历史、另一台设备调用都不在本机统计范围。历史令牌来源时间会显示，未知与测得 0 区分。
- 模型分布与七日图使用相同的七个本机日历日；不会把第八天扫描缓冲范围的数据混入“近七日”分布。
- 本次检查版本：WorkBuddy AI 5.6.2、CodeBuddy CN 4.12.1、Claude Desktop 2.16120.0。存储格式可能随版本变化，未知字段不猜测。

## 正在运行与完成反馈

WorkBuddy 的本机 `sessions.status` 明确为 `working` 或 `planning`，且 `last_activity_at` 在最近 10 分钟内时，可以显示正在处理；后台自动化会话不触发前台用户任务状态。上下文数字同时标明其数据库记录时间。

不能把 WorkBuddy 的 `status=completed` 和 `updated_at` 当作任务刚完成。程序在启动时会把闲置加载的会话改为 completed；数据库没有独立 completed_at/finished_at。JSONL 单个消息的 completed 只是响应完成，工具返回也不是整个用户任务结束。因此本读取器不会据此发送任务完成动画。

CodeBuddy 本机请求包含 `state` 和 `startedAt`，没有 finishedAt/completedAt。明确 running 且开始时间较新时可显示正在处理，但无法证明长任务的持续活跃状态，也不能给完成状态编造结束时间。Claude Desktop/Cowork 当前没有可读取的原生生命周期记录。已有完成动画框架可以使用之后软件确实公开的任务终止事件；本版本不从文件修改时间推断任务完成。

## 校验边界

跨平台测试使用人工编写的合成记录验证缓存公式、流式重复去重、负数/布尔值拒绝、消耗不是余额、额度样本过期以及 Claude Desktop 不借用 CLI 记录。真实本机检查仅输出数字/模式和文件数，不输出用户对话或账户身份。这些检查证明本机可识别记录的计算正确，不证明服务端订阅结算、未保存调用或跨设备总账完全一致。

## Claude 本机诊断

运行 TokenLens 可执行文件并传入 `--check-claude-telemetry`，仅输出模型、剩余百分比、辅助功能权限状态和数据来源，不输出账户身份、凭据或会话内容。未授权辅助功能时仍可读取会话模型和新鲜的本地额度历史；Claude 停止更新历史且没有界面读取权限时，额度显示未知。

## 短周期与每周额度分开显示（2026-10-22）

灵动岛收起时分两行显示短周期和周额度，展开面板及用量详情分别显示两项。周期名称来自实际窗口：Claude 使用“5小时”，仅实际 1440 分钟窗口标为“每日”，不会把 5 小时伪装成每日额度。

Claude 的“每周 · 所有模型”取自用量菜单的进度控件，不读取模型专属的另一个周额度桶。每周采样有独立时间，短周期刷新不能延长周额度有效期；15 分钟后显示未知并提示展开 Claude 用量菜单刷新。菜单关闭后可复用同一可见会话的有效周采样；会话变化时不会借用上个会话的采样。缓存只包含数字、时间及会话表面的不可逆摘要，文件权限为 0600，不包含账号、网址、聊天或凭据。
