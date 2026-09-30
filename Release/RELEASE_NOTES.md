GPT、DeepSeek Harness、WorkBuddy、Claude、CodeBuddy 共用一个顶部灵动岛，优先显示实际正在使用的助手。Mac 保留摄像头融合与隐藏区域悬停，Windows 贴合屏幕顶部并避让任务栏。

| 你的电脑 | 下载 |
| --- | --- |
| Mac · Apple M 系列 | **TokenLens-macOS-arm64-3.1.1.zip** |
| Mac · Intel | **TokenLens-macOS-x86_64-3.1.1.zip** |
| Windows · Intel / AMD | **TokenLens-Windows-x64-3.1.1-Setup.exe** |
| Windows · ARM / 骁龙 | **TokenLens-Windows-arm64-3.1.1-Setup.exe** |

Windows 同名 `.zip` 是免安装版，完整解压后运行 `TokenLens.exe`。Mac 解压后运行 `安装.command`；DSH 余额与模型运行 `连接DSH.command`。Windows 从托盘连接 DSH。无需安装开发工具。

本版新增：WorkBuddy 品牌青色、Claude 陶土橙、CodeBuddy 紫青色；五助手前台优先切换；延续 GPT 渐变紫、DSH 蓝紫、弹簧展开、对称布局、菜单图标避让、任务完成反馈。

用量核对修正：重复 Token 事件去重，累计计数重置处理，子任务不抢当前模型，缓存读取/写入口径区分，最近响应上下文估算明确标记，短期与长期额度同时显示，额度/余额超时不沿用旧值。详情显示来源、更新时间、统计范围与未提供指标。CodeBuddy 已消耗积分不当余额；Claude 桌面端不借用 Claude Code 数据。

各软件能提供的指标不同：当前 Claude 桌面端记录没有可用 Token 或额度数字时显示 `--`；WorkBuddy / CodeBuddy 未提供余额时显示 `--`。上下文标记 `≈` 表示根据最近响应估算，未含后续工具消息或压缩变化，并非软件报告的精确实时占用。发行包与 GitHub 不包含个人聊天、账号、课表或凭据。完整核对说明见仓库 `docs/metrics-audit.md` 和 `docs/telemetry-additional.md`。

要求 macOS 14+、Windows 10/11。当前无 Apple 公证或 Windows 发行证书。提供六个平台下载包与 `SHA256SUMS.txt`。

验证范围：本机 Mac 原生构建与记录解析检查；五助手状态切换、未知数据、去重、累计重置、缓存及额度口径回归检查；四架构自动构建。Windows x64 在 CI 中实际启动打包程序检查 Win32 接口、五助手渲染和完成提示；Windows ARM64 尚未在 ARM 实机验收。没有为了验证而发送收费模型请求。
