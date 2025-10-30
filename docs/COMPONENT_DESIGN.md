# 组件设计思想（从使用者出发）

目标：让使用者“拿来即用、心智零负担、扩展不设限”。所有 API 与实现都围绕这三点持续减法。

## 设计总纲
- 最小可用：一行代码可完成典型使用，无需样板或额外依赖。
- 渐进增强：默认足够好；需要时再层层暴露进阶能力（样式、环境、协议、回调）。
- 一致命名：与 SwiftUI 生态一致（View 命名为名词，样式以 `Style` 结尾，配置以 `Configuration` 命名）。
- 值语义优先：输入尽量为值类型，副作用隔离在可注入边界（如 `ObservableObject`）。
- 失败安全：容错不崩溃，必要时 `assert`/日志提示开发者，面向用户的失败默认降级显示。
- 文档先行：公开 API 均有文档注释与最小示例；示例 App 提供“可复制黏贴”的片段。

## 使用者视角的 API 形态
- 单一职责构造：
  - 默认构造函数覆盖 80% 场景；
  - 额外能力通过可选参数或修饰器（Modifier）逐步开启；
  - 谨慎增加枚举与协议泛型，保证调用点易读。
- 风格与主题：
  - 提供 `EnvironmentKey`/`ViewModifier` 驱动的主题能力；
  - 暴露 `*Style` 协议以供彻底自定义；默认实现质量高且通用。
- 交互与状态：
  - 可交互组件以 `Binding<Value>` 输入；
  - 只在必要时引入 `@StateObject` 管理内部控制器，并通过 `@MainActor` 保证线程安全。
- 逃生舱：
  - 预留 `content` 闭包、`background`/`overlay` 等挂点；
  - 保留 `View` 合成自由，不锁死布局。

## 示例优先与可测试性
- 示例优先：每个组件配 1 个极简示例 + 1 个进阶示例；示例 App 中可直接跑通。
- 测试友好：
  - 计算与映射逻辑抽成纯函数（易测、可基准），
  - 关键元素设置稳定的 `accessibilityIdentifier`；
  - UI 测试专注“可见性与交互达成”。

## 性能与可达性
- 默认廉价：避免在 `body` 中创建重型对象；对高频绘制视图使用 `Canvas`/`CGPath` 等批量绘制。
- 受控刷新：按需刷新（`TimelineView`、分段重绘、下采样）。
- 可达性：支持 Dynamic Type、颜色对比；交互元素具备合理的 `hitTest` 范围与语义标签。

## 破坏性变更与版本
- 遵循 SemVer，破坏性变更先经弃用周期，并在示例与说明中给出迁移路径。

## 评审核对清单（Checklist）
- 是否一行代码可完成典型用例？
- 默认值是否“看起来就对”？
- API 命名是否与 SwiftUI 一致且可预期？
- 复杂选项是否通过修饰器/样式渐进暴露？
- 是否提供逃生舱避免被设计锁死？
- 是否具备可测试的纯函数边界？
- 是否覆盖动态字体/深色模式/本地化？
- 是否有示例与文档注释？

---

示例（极简心智）：

```swift
// 默认即可用，支持主题与进阶样式扩展
WaveformView(audioURL: url)
    .waveformStyle(.bars)
    .tint(.blue)
```

---

## 实施规范摘要（落地参考）

### 仓库结构与放置
- 包目标 `SwiftyComponents`（iOS 15+ / macOS 12+）
  - `Sources/SwiftyComponents/Components/` 组件主体
  - `Sources/SwiftyComponents/Styles/` 样式与配置
  - `Sources/SwiftyComponents/Foundations/` 基础能力（如音频解析）
  - `Sources/SwiftyComponents/Utilities/` 纯函数/工具
  - `Sources/SwiftyComponents/Extensions/` 轻量扩展
- 示例 App
  - `Examples/SwiftyComponentsExamples/SwiftyComponentsExamples/Scenes/` 页面（目录/演示/检查器）
  - `.../Resources/Audio/` 示例音频，`.../Resources/Docs/` 示例文档
- Agent 指南位置（Codex）
  - `Packages/SwiftyComponents/AGENTS.md`（覆盖本包与其子目录，包括 Examples/Tests）
  - 若需全工程生效，可在主仓库根再放置一份“顶层 AGENTS.md”做统一说明（可引用本文件）。

### 示例 App 页面结构
- 目录页 `CatalogView`：分组/搜索/导航，支持深链 `-demo <id> -variant <id>`
- 演示页 `DemoPage`：单组件 Demo，变体切换
- 测试支架 `DemoHarness`：主题/布局方向/动效控制，提供稳定标识符
- 启动参数工具 `UITestGate`：`UI_TEST`、`-demo`、`-variant`
- 检查器（Inspector）：集中“数据/显示/样式/外观/示例与文档”，支持 Markdown 渲染与复制代码片段

### 资源策略
- 示例资源统一放 `Examples/.../Resources/`，按类型分子目录（`Audio/`、`Docs/`）。
- 代码访问路径优先子目录，不存在时回退根目录。
- 新资源需勾选 App 目标（Target Membership）。

### 测试策略
- 单元测试（包层）：纯函数、样式映射、状态机，使用 Swift Testing。
- UI 测试（示例层）：通过 `-demo/-variant UI_TEST` 直达页面；断言稳定标识符；必要时减少动效以稳定快照。
- 快照测试（可选）：固定尺寸/主题/字体；可引入 SnapshotTesting。

### 常用命令
- 包：`swift build -v`、`swift test -v`
- 示例（含 UI 测试）：
  - `xcodebuild -project Examples/SwiftyComponentsExamples/SwiftyComponentsExamples.xcodeproj -scheme SwiftyComponentsExamples -destination 'platform=iOS Simulator,name=iPhone 16' test`

### 新增组件流程（Checklist）
1) 包层实现：在 `Components/` 新建组件；必要时在 `Styles/`/`Foundations/`/`Utilities/` 分层落地；仅暴露必要 `public`；补文档注释与最小示例。
2) 示例页：在 `Scenes/` 新建 `ComponentNameDemoView`，接入检查器分组（数据/显示/样式/外观/示例与文档）。
3) 注册：在 `ComponentRegistry.swift` 增加 `ComponentDemo` 与若干 `DemoVariant`（唯一 id）。
4) 资源：放入 `Resources/`，并勾选目标。
5) 测试：
   - 包层：针对纯函数/映射逻辑加单测。
   - 示例层：用 `-demo <id> -variant <id> UI_TEST` 直达并断言元素。

### 命名与文案（示例）
- 显示模式：双极（Bipolar）/ 单极（Unipolar）
- 平滑曲线：Catmull‑Rom 平滑
- 样式命名：名词 + `Style`；配置命名：`Configuration`

---

## Waveform 组件（参考实现要点）
- 分层：Loader/Decoder → Analyzer（RMS/Peak） → Downsampler（bins） → Renderer（Canvas）。
- 样式：Bars / Outline / Filled（支持 `smooth`）
- 显示：双极（mirror=true）/ 单极（mirror=false，底部基线）
- 外观：Tint、Filled 渐变、进度线颜色/线宽
- 主要接口：
  - `WaveformView(samples:style:mirror:progress:tint:fillGradient:progressColor:progressLineWidth:)`
  - `WaveformAnalyzer.sampleAmplitudes(fileURL|asset|track, timeRange, samples, mode: .rms|.peak, channel: .mix|.left|.right)`
  - `WaveformDownsampler.downsampleMagnitudes(_:into:mode:)`

### 录制与时间线（Streaming + LOD）
- 流式聚合（录制）
  - `WaveformStreamConfig { sampleRate, channel, mode, frameDuration, binsPerFrame, retention }`
  - `WaveformStreamAggregator`
    - `append(_ buffer: AVAudioPCMBuffer, at: CMTime)`：喂入实时 PCM（Float32）
    - `popReadyFrames() -> [FrameWaveform]`：吐出并清空已完成帧
    - `peekReadyFrames() -> [FrameWaveform]`：查看已完成帧（不清空）
    - `snapshotAll() -> [FrameWaveform]`：查看保留窗口内的帧（ready + retained）
    - `flush() -> [FrameWaveform]`：收尾吐出不足一帧样本
    - `onFrames: ([FrameWaveform]) -> Void`：新帧回调（可选）
  - `RetentionPolicy`：`.none | .windowSeconds(Double) | .windowFrames(Int) | .allInMemory`
  - 内存估算：约 `fps × binsPerFrame × 4B` 每秒；RMS+Peak 或双通道按倍数放大。建议“保留窗口 + 持久化”。
- LOD（剪辑）
  - 未来补充 `WaveformLODBuilder/Store/Archive` 接口以支持缩放与快速查询。

示例（录制侧骨架）
```swift
let cfg = WaveformStreamConfig(
  sampleRate: 48000,
  channel: .mix,
  mode: .rms,
  frameDuration: CMTime(value: 1, timescale: 60),
  binsPerFrame: 128,
  retention: .windowSeconds(15)
)
let aggr = WaveformStreamAggregator(config: cfg)
aggr.onFrames = { frames in /* persist or preview */ }
// in audio callback
aggr.append(buffer, at: bufferPTS)
let frames = aggr.popReadyFrames()
```
