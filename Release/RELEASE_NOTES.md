GPT 和 DeepSeek Harness 共用一个顶部灵动岛，跟随正在使用的助手切换。Mac 保留原生摄像头融合设计；Windows 使用贴合屏幕顶部的胶囊，并避让系统任务栏。

| 你的电脑 | 下载 |
| --- | --- |
| Mac · Apple M 系列 | **TokenLens-macOS-arm64-3.0.0.zip** |
| Mac · Intel | **TokenLens-macOS-x86_64-3.0.0.zip** |
| Windows · Intel / AMD | **TokenLens-Windows-x64-3.0.0-Setup.exe** |
| Windows · ARM / 骁龙 | **TokenLens-Windows-arm64-3.0.0-Setup.exe** |

Windows 的同名 `.zip` 是免安装版：完整解压后运行 `TokenLens.exe`。Mac 解压后运行 `安装.command`；DSH 余额与模型需要运行包内的 `连接DSH.command`。Windows 在托盘菜单中点击「连接 DeepSeek Harness 状态」。安装包自带所需运行环境，无需安装 Swift、Node.js 或 Homebrew。

本版包含：GPT 渐变紫配色、DSH 蓝紫配色、弹簧展开与回弹、明确的任务完成动效、顶部当前模型与额度、展开区对称修正、Mac 摄像头区域悬停、菜单图标避让、Windows 显示器选择、托盘设置与可选开机启动。

数据来自本机 Codex / Harness 记录与已登录账号。GPT 订阅额度随 Codex 新消息更新；普通 ChatGPT 网页或独立客户端没有对应日志时显示 `--`。没有读到数据时不会伪造额度。应用不上传聊天记录或凭据。

要求：macOS 14+；Windows 10/11。尚无 Apple 公证或 Windows 发行证书，首次运行可能出现系统提示。请确认来自本项目后使用系统的允许打开选项。`SHA256SUMS.txt` 可核对下载文件。

验证范围：Mac 原生扫描、悬停几何、弹簧与完成事件检查；四种架构自动构建。Windows x64 在 CI 中实际启动打包后的程序，检查 Win32 接口、GPT/DSH 渲染和完成提示；Windows ARM64 包完成交叉构建，尚未在 ARM 实机上验收。
