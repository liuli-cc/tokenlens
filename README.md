# TokenLens · 五款助手灵动岛

一个融合在屏幕顶部的助手状态岛。GPT 使用渐变紫，DeepSeek Harness 使用蓝紫，WorkBuddy 使用品牌青色，Claude 使用陶土橙，CodeBuddy 使用紫青色；胶囊显示当前模型与可读取的额度，悬停后展开详情。GPT / Harness 有明确任务完成事件时给出完成反馈。两端的动效、完成队列与外观设置见[灵动岛设计说明](docs/island-design.md)。

macOS 保留摄像头缺口融合、顶部隐藏区域悬停与菜单图标避让。Windows 采用适合其屏幕与任务栏的顶部胶囊，支持实际前台助手切换、多个显示器和托盘设置。两端完成提醒都平稳展开、轻压回弹一次，并保留软件对应的柔和光边；原生窗口和正文保持稳定。

## 直接下载

**[打开最新版本下载页](https://github.com/liuli-cc/tokenlens/releases/latest)**。普通 Windows 电脑选择 x64，Apple M 系列 Mac 选择 arm64。

| 系统 | 对应版本 | 直接下载 |
| --- | --- | --- |
| macOS · Apple M 系列 | 原生 arm64 | [Mac M 系列 ZIP](https://github.com/liuli-cc/tokenlens/releases/download/v3.2.1/TokenLens-macOS-arm64-3.2.1.zip) |
| macOS · Intel | 原生 x86_64 | [Mac Intel ZIP](https://github.com/liuli-cc/tokenlens/releases/download/v3.2.1/TokenLens-macOS-x86_64-3.2.1.zip) |
| Windows · Intel / AMD | x64 安装版 | [Windows x64 安装包](https://github.com/liuli-cc/tokenlens/releases/download/v3.2.1/TokenLens-Windows-x64-3.2.1-Setup.exe) |
| Windows · ARM / 骁龙 | ARM64 安装版 | [Windows ARM64 安装包](https://github.com/liuli-cc/tokenlens/releases/download/v3.2.1/TokenLens-Windows-arm64-3.2.1-Setup.exe) |
| Windows · Intel / AMD | x64 免安装版 | [Windows x64 ZIP](https://github.com/liuli-cc/tokenlens/releases/download/v3.2.1/TokenLens-Windows-x64-3.2.1.zip) |
| Windows · ARM / 骁龙 | ARM64 免安装版 | [Windows ARM64 ZIP](https://github.com/liuli-cc/tokenlens/releases/download/v3.2.1/TokenLens-Windows-arm64-3.2.1.zip) |

需要 macOS 14+ 或 Windows 10/11。安装包包含运行环境，使用者无需装开发工具。本项目暂未申请 Apple 公证或 Windows 签名证书，首次打开可能有系统提示。

## 安装与使用

Mac：解压 ZIP，双击 `安装.command`，安装到 `~/Applications/TokenLens.app` 并启用联动。打开 Codex / GPT、Harness、WorkBuddy、Claude 或 CodeBuddy 后自动显示灵动岛；全部关闭后自动隐藏。正在使用的助手优先显示，切到其他软件时保留最近使用的助手。悬停顶部展开，点击「返回」回到助手，点击「用量详情」看本机用量。

Windows：运行 `Setup.exe`，或完整解压免安装版后打开 `TokenLens.exe`。托盘菜单可以选择助手、跟随前台应用、选择显示器、连接 DSH 状态桥及开启开机启动。只把鼠标经过的黑色岛区域设为可交互，其余透明区域穿透点击。

DSH：先启动一次 DeepSeek Harness，再完全退出。Mac 运行 ZIP 内的 `连接DSH.command`；Windows 点击托盘的「连接 DeepSeek Harness 状态」。然后重新打开 Harness，自动同步余额，发送下一条消息后同步当前模型。插件适配 Harness 桌面 Cordis profile / v4 会话记录；上游格式更改时可能需要更新。连接前会备份已有插件和配置。

卸载：Mac 运行 `卸载.command` 停用联动，再删除个人 Applications 里的应用。Windows 使用系统「已安装的应用」卸载，免安装版退出后删除目录。DSH 插件独立保留；停用时从 `~/.dsh/profiles/desktop/cordis.patch.yml` 移除 `tokenlens-dsh-status` 插入项。

## 数据从哪里来

| 助手 | 真实来源 | 显示边界 |
| --- | --- | --- |
| GPT / Codex | `.codex/sessions` 的官方 Token 与限额事件；支持 `CODEX_HOME` | 上下文采用最近响应的上下文估算并标记 ≈；保留短期及长期额度窗口。重复事件去重，子任务不抢占当前模型。普通 ChatGPT 网页、独立聊天客户端的数据不混入。 |
| DeepSeek Harness | v4 压缩记录中的明确 usage / contextWindow；账号状态桥 | 没有 Token / 上下文记录时显示 --；余额超过 3 分钟未刷新不继续显示旧值。 |
| WorkBuddy | 自身项目日志里的 reported usage 与自身会话数据库 | 只显示软件报告的数据。未提供订阅额度、余额时显示 --。 |
| Claude 桌面端 | 桌面端自身用量记录与 plan usage history | 当前本机未提供可用 Token / 额度数字时显示 --，不借用 Claude Code 的记录。 |
| CodeBuddy | 自身扩展历史中的 request usage，按 request ID 去重 | 已消耗积分不当成余额；用户轮数不当作 API 调用次数；未提供上下文容量时显示 --。 |

- 缓存命中率采用软件报告的缓存读取量 / 完整输入量；区分缓存读取与写入。缺失与真实零值分别显示。部分客户端仅能提供当前会话记录，详情中标明统计范围。
- GPT 额度来自官方日志，15 分钟后或重置时等待新记录；显示更新时间与额度窗口，采用更紧张窗口作为顶部剩余值。近期调用按明确用量事件统计，是本机已记录数量，不是全账号调用总数。
- CC Switch 兼容的 DeepSeek / Kimi 官方余额与 GPT 订阅额度使用不同标签；不猜测无文档接口，不把已消耗金额当作余额。
- 只将明确的用户任务完成事件作为成功反馈；取消、错误、子任务和日志写入不会触发完成动画。首次启动不重播历史任务。WorkBuddy、Claude、CodeBuddy 当前缺少可靠完成事件时，不猜测完成时间或触发成功反馈。
- 不向 GitHub 或项目服务器上传聊天记录、账号凭据或本机状态。余额查询使用 Harness 已登录账号或对应官方 HTTPS 接口，凭据不写入岛的状态文件。

详细核对方法、口径及限制见 [指标核对](docs/metrics-audit.md) 与 [新增助手的数据来源](docs/telemetry-additional.md)。软件版本或私有日志格式变动时需要重新核对；没有来源的数据不会虚构填充。

## 开发与验证

```sh
# Mac: Xcode Command Line Tools / Swift 6+
./build.sh
./install.sh
# 可携带的发行包（包含静态 zstd）：
bash Release/build-macos.sh arm64
bash Release/build-macos.sh x86_64

# Windows: Node.js 22+
cd windows
npm ci
npm test
npm start
npm run build -- --x64
npm run build -- --arm64
```

提交 `v*` 标签后，GitHub Actions 自动构建四种架构、运行检查，并发布六个下载包与 SHA-256 校验文件。Windows x64 在 CI 中启动打包后的程序验证 Win32 绑定与五种岛的 UI；ARM64 当前验证到交叉构建，真实 Windows 账号和 ARM 实机交互仍需实机验收。

源码：`Sources/` 和 `BridgeSources/` 为 macOS Swift / SwiftUI；`windows/` 为 Windows Electron / Win32；`Integration/` 为助手联动与 Harness 状态桥；`Release/` 为打包和安装脚本。

MIT 许可证。随 Mac 包分发的 zstd 使用其 BSD 许可证；其他第三方许可证随 Windows 运行包保留。
