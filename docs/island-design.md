# TokenLens 灵动岛设计说明

这次优化围绕任务完成提醒展开：保留五款助手的模型、用量与额度信息，让黑色胶囊从摄像头缺口下方平稳展开，再用一次轻微压缩、回弹和软件边缘光表达完成。3.2.1 修正了上一版叠加弹簧带来的晃动和边缘光不明显的问题，轮廓与文字保持稳定，更多信息放在展开后的「概览」「最近」「外观」中。

## 参考与实现边界

以下资料于 2026-10-03 核对，作为设计和动画原理参考。

| 参考 | 借鉴的原则 | 源码与许可 |
| --- | --- | --- |
| [Boring Notch](https://github.com/TheBoredTeam/boring.notch) | 黑色轮廓与缺口融合；展开有弹性，收起更平稳；顶部锚点保持稳定。 | [ContentView.swift](https://github.com/TheBoredTeam/boring.notch/blob/main/boringNotch/ContentView.swift)；[GPL-3.0](https://github.com/TheBoredTeam/boring.notch/blob/main/LICENSE)。 |
| [NotchKit](https://github.com/duongductrong/NotchKit) | 同一表面连续变形；先打开轮廓，再揭示内容；悬停有短暂延迟，减少误展开。 | [NotchContainer.swift](https://github.com/duongductrong/NotchKit/blob/master/Sources/NotchKit/NotchContainer.swift)、[运动设计说明](https://github.com/duongductrong/NotchKit/blob/master/docs/motion.md)；[MIT](https://github.com/duongductrong/NotchKit/blob/master/LICENSE)。 |
| [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) | 将出现、消失和紧凑状态转换分别处理，避免不必要的中途隐藏。 | [转场配置](https://github.com/MrKai77/DynamicNotchKit/blob/main/Sources/DynamicNotchKit/DynamicNotch/DynamicNotchTransitionConfiguration.swift)；[MIT](https://github.com/MrKai77/DynamicNotchKit/blob/main/LICENSE)。 |

Apple 的[阶段与关键帧动画示例](https://developer.apple.com/documentation/swiftui/controlling-the-timing-and-movements-of-your-animations)说明了如何分别编排位置、缩放与纵向拉伸；[弹簧动画文档](https://developer.apple.com/documentation/swiftui/animation/spring(duration:bounce:blendduration:))说明了弹性与速度衔接。

TokenLens 的轮廓、弹簧计算和完成动效在现有 AppKit / SwiftUI 架构内独立实现，没有复制这些项目的 Swift 源码，也没有引入它们的依赖。尤其没有复制 Boring Notch 的 GPL 源码。这里的「程序坞风格」指自定义的拉出、弹跳与回弹体验，不声称调用 Apple 的 Dock 神奇效果或私有接口。

## 动效与视觉

完成提醒使用一条确定的时间曲线：前 0.42 秒单调展开，0.44–0.54 秒显现正文，0.55–1.16 秒完成一次轻微压缩和较小的回弹，随后轮廓完全静止。果冻档的压缩最多降低 3.5 点高度、增加 4 点宽度；图标在同一节奏中轻微抬升和变形。文字不随独立弹簧晃动，完成徽标只淡入。悬停展开与收起采用临界阻尼，不额外叠加回弹。

原生展开窗口在整个可见期间保持同一画布，动画只改变内部表面的宽高，避免逐帧移动或缩放窗口。菜单图标避让导致顶部两翼改变时，正文中心保持稳定，通过颈部偏移连接当前顶部位置。实际显示器几何发生变化时重新定位。轮廓命中检测持续跟随内部表面，透明画布与光晕仍可点击穿透。

发光由明确的细彩色轮廓和外侧柔和阴影组成，放在正文裁切范围之外；明亮峰值随动作出现，在 1.90 秒内结束。完成提醒继续停留时，光强目标维持在 0.38，提供平稳可见的边缘光，关闭提醒后柔和淡出。轮廓使用固定阴影半径，避免大面积背景光团。几何和光强都稳定后停止对应动画计时器。

颜色跟随提醒来源：GPT 紫色、DeepSeek Harness 蓝紫、WorkBuddy 青色、Claude 陶土橙、CodeBuddy 紫青。完成提醒期间显示完成任务的软件；提醒关闭后的光效淡出仍保留该软件颜色。正常状态跟随实际前台助手，切到其他软件时保留最近使用的助手。

保留摄像头缺口融合、菜单图标避让、多显示器定位与透明区域点击穿透。光晕不扩大实际点击范围。默认跟随系统减少动态效果；偏好面板可单独关闭这一跟随，让灵动岛使用完整动效，而不修改系统设置。跟随开启且系统减少动态效果时，停用弹跳和额外变形，完成提醒仍保留静态边缘光；「软件微光」关闭时不显示完成光效。

## 本轮交互

3.2.2 新增顶部返回入口：Mac 通过原生鼠标事件识别摄像头遮挡矩形内的左键点击，沿用面板「返回」的目标选择。可见两翼与透明光晕的命中范围不变；本地事件处理后停止继续分发，避免边界点击同时触发两次。Windows 顶部中央使用现有操作分发，内部额度按钮保持详情优先级。完成提醒显示时，两端都先保存提醒来源，再关闭提醒并打开对应软件。

- **完成提醒队列**：明确的新完成事件依次呈现，不要求对应助手处于前台。重复事件去重，首次读取建立基线，不重播启动前的历史任务；等待队列有数量和时效上限。
- **最近完成**：在内存中保留最近 20 条完成记录，显示来源和时间，并可返回对应助手。退出应用后清空，不保存聊天正文。
- **固定展开**：可固定详情面板，阅读时无需持续悬停。
- **外观设置**：轻柔、自然、果冻三档；可选择跟随系统减少动态效果；软件微光可关闭；提醒停留时间可选 6、10、14 秒，默认 6 秒。macOS 另提供默认关闭的完成提示音。macOS 鼠标停留时短暂延后收起，方便点击。
- **动效预览**：可预览外观动作，不伪造真实任务完成记录或用量数字。

## Windows 实现

Windows 使用适合任务栏与可用屏幕区域的顶部胶囊。完成动作沿用同一时间曲线，但原生 BrowserWindow 始终使用固定透明画布，只更新内部 SVG 轮廓。正文宽度和位置固定，彩色细光边与柔和阴影位于内容裁切范围之外，提醒停留时保持 0.38 光强。绘制和点击判断使用同一条轮廓，透明边角与光晕点击穿透；显示器或任务栏布局变化时才重新定位原生窗口。

后台 GPT / Harness 的新完成事件按时间进入队列，来源助手决定提醒颜色和返回目标。队列最多等待 128 条，已接收记录最多保留 10 分钟，最近完成保留 20 条；第一次读取建立启动基线，重复事件不重播。动效预览排在当前提醒后面，不覆盖真实任务，也不写入最近完成。提醒中途关闭时，残余形变平稳退回；光效淡出期间保持原软件颜色。

Windows 的用量详情包含动效与提醒设置、最近完成列表。三档强度、软件微光、停留时长、系统减少动态效果跟随和固定展开存到本机偏好文件；最近完成记录只保存在内存。原有托盘菜单、开机启动、显示器选择、前台跟随、Harness 状态桥与用量信息保留。Windows ARM64 支持交叉构建和包架构检查，尚未完成 ARM 实机交互验收。

Windows 36 项检查通过，打包后的 x64 程序已在 Windows CI 启动并验证 Win32 接口、五助手渲染、九个完成曲线阶段、固定原生画布、稳定正文宽度、持续光边、减少动态效果和来源保色。查看[Windows 合成停留预览](../Preview/TokenLens-3.2.1-Windows-held.jpg)与[Windows 打包程序验证记录](../Preview/TokenLens-3.2.1-Windows-verification.json)。

## 数据口径

完成动作只接受读取器提供的明确任务完成事件。GPT / Codex 与 DeepSeek Harness 有对应来源时才能触发；WorkBuddy、Claude、CodeBuddy 当前缺少可靠完成事件，继续展示可读取状态与用量，不凭软件切换、Token 增长或日志静默推断成功。取消、错误和子任务不作为成功提醒。

数值含义沿用现有规则：未知显示 `--`，真实零值保持为零；估算上下文保留 `≈`；缓存读取与写入分开；账户余额与订阅额度区分；过期数字等待新来源；统计范围仍以本机可读取记录为准。详细依据见[指标核对](metrics-audit.md)和[新增助手的数据来源](telemetry-additional.md)。

3.2.1 动效验证时，本机签名校验通过，主程序和联动服务运行正常，安装文件与最终构建一致。五套检查通过，480 帧原生合成预览确认每次呈现只调整一次窗口，画布与摄像头下沿对齐，停留尺寸稳定、边缘光保持、透明光晕不接受点击。视频完整解码通过（480 帧、16 秒），GIF 为 240 帧、16 秒。本轮未重复实际鼠标点击验收。

查看[最终动效预览](../Preview/TokenLens-3.2.1-jelly.mp4)与[最终验证记录](../Preview/TokenLens-3.2.1-verification.json)。原生合成预览使用明确标记的本地样例，不代表五款软件都已提供自动完成事件。本地只保留最终版本的源码、测试、预览和发行文件；旧版源文件可从 Git 历史查阅。

[3.2.1 正式发行版](https://github.com/liuli-cc/tokenlens/releases/tag/v3.2.1)已提供 Mac arm64 / x86_64、Windows x64 / arm64 的六个下载包及校验文件。[四架构发布检查](https://github.com/liuli-cc/tokenlens/actions/runs/37124807573)全部通过。

3.2.2 本机已安装，签名及联动服务检查通过。五套本机检查与 23 条原生合成点击路由检查通过；Windows 36 项回归检查通过。摄像头真实鼠标点击因本机锁屏未完成验收，合成事件没有注入系统，也不代表硬件点击已验证。详见[3.2.2 点击验证记录](../Preview/TokenLens-3.2.2-click-verification.json)。
