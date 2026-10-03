TokenLens 3.2.1 将完成提醒升级为平稳展开、一次轻压回弹和软件对应的边缘光。macOS 与 Windows 都保留五助手、真实前台切换、用量详情、任务栏或菜单避让及透明区域点击穿透。

| 你的电脑 | 下载 |
| --- | --- |
| Mac · Apple M 系列 | **TokenLens-macOS-arm64-3.2.1.zip** |
| Mac · Intel | **TokenLens-macOS-x86_64-3.2.1.zip** |
| Windows · Intel / AMD | **TokenLens-Windows-x64-3.2.1-Setup.exe** |
| Windows · ARM / 骁龙 | **TokenLens-Windows-arm64-3.2.1-Setup.exe** |

Windows 同名 `.zip` 是免安装版，完整解压后运行 `TokenLens.exe`。Mac 解压后运行 `安装.command`；DSH 余额与模型运行 `连接DSH.command`。Windows 从托盘连接 DSH。无需安装开发工具。

完成时固定原生窗口，只让内部轮廓轻微压缩、回弹，正文保持稳定。光边随 GPT 紫色、Harness 蓝紫、WorkBuddy 青色、Claude 陶土橙、CodeBuddy 紫青切换，完成提醒停留时保留柔光。支持减少动态效果，光晕不扩大点击范围。

完成提醒按明确事件依次呈现，不要求来源助手处于前台；首次读取不重播历史事件，重复事件去重，最近 20 条完成记录只保存在本次运行内。GPT / Codex 与 DeepSeek Harness 有可靠完成事件时才触发；WorkBuddy、Claude、CodeBuddy 当前缺少可靠完成事件时不猜测成功。

数值沿用原有核对规则：未知显示 `--`，真实零值保留，估算上下文标记 `≈`，缓存读取与写入区分，余额与订阅额度区分，过期数字等待刷新。详情保留来源、更新时间、统计范围与未提供指标。Claude 桌面端不借用 Claude Code 数据；CodeBuddy 已消耗积分不是余额。发行文件不含个人聊天、账号、课表或凭据。

要求 macOS 14+、Windows 10/11。当前无 Apple 公证或 Windows 发行证书。提供六个平台下载包与 `SHA256SUMS.txt`。

验证范围：Mac 五套本机检查与 480 帧原生合成预览；Windows 运动曲线、固定画布、完成队列、几何和记录解析回归检查；四架构自动构建。Windows x64 在 CI 中启动打包程序检查 Win32 接口、五助手渲染、完成反馈与光边；Windows ARM64 为交叉构建与包架构检查，尚未在 ARM 实机验收。没有为了验证而发送收费模型请求。
