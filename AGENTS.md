# SwiftyComponents — AGENTS 指南

本文件为“Agent 说明书”，适用于当前目录及其子目录内的全部代码（Packages/SwiftyComponents）。请遵守以下约定来实现与调试 SwiftUI 组件，并确保组件可运行、可测试，条件允许时可实现自动化测试，以服务主项目的稳定复用。

## 目标与范围
- 目标：提供一套可复用的 SwiftUI 组件库，支持 Demo 运行、单元测试与 UI 自动化测试。
- 范围：本文件约束 `SwiftyComponents` Swift Package、其示例 App（Examples）与测试（Tests）。
- 平台/工具：Xcode 16+（Swift 6.2，对应 `// swift-tools-version: 6.2`），Apple Silicon/Intel 皆可。

## 目录结构约定
 - `Sources/SwiftyComponents/`
  - 放置库对外暴露的 SwiftUI 组件与配套类型（SPM 目标）。
  - 分层：
    - `Components/` 组件主体（每个组件优先单文件，复杂组件用子目录）。
    - `Styles/` 样式与主题相关类型（`*Style`、`Configuration`、主题环境键）。
    - `Foundations/` 基础能力（颜色/间距/形状 Token、公共协议与工具类型）。
    - `Utilities/` 与 UI 相关的通用工具与小型 Helper。
    - `Extensions/` 标准库与 SwiftUI 扩展（轻量、无副作用）。
  - 组件对外 API 使用 `public`，其余保持 `internal`（默认）。
- `Tests/SwiftyComponentsTests/`
  - 单元测试与轻量渲染测试，使用 Swift Testing（`import Testing`、`@Test`、`#expect`）。
  - 测试文件命名：`<ComponentName>Tests.swift`。
 - `Examples/SwiftyComponentsExamples/`
  - 示例 App（Xcode 工程）用于手动演示、预览与 UI 自动化测试。
  - App 目录结构（`SwiftyComponentsExamples/`）：
    - `Scenes/` 页面与导航入口（组件目录页、Demo 页）。
    - `Components/` 示例专用的可复用小视图。
    - `ViewModels/` 示例中的 `ObservableObject` 与状态管理。
    - `Models/` 示例数据模型与样本结构体。
    - `Utilities/` 示例通用工具。
    - `Resources/` 示例资源（`Audio/`, `Images/`）。
  - 新增组件时，应在示例 App 中补充一个演示页面，便于人工验证与 UI 测试编排。

## 组件开发规范
- 设计
  - 优先无副作用、可组合（Composable）、可配置（Configuration via init/parameters）。
  - 尽量解耦状态与渲染：输入（数据/样式）→ 纯渲染；复杂状态放到调用方或可注入的 `ObservableObject`。
  - 公开类型尽量实现 `Equatable`/`Sendable`（如适用），便于测试与并发安全。
- 无障碍（Accessibility）
  - 为可交互元素配置 `accessibilityLabel`/`accessibilityIdentifier`；在示例与 UI 测试中使用稳定的 identifier。
- 文档与分层
  - 对外 API 添加文档注释（`///`）。
  - 使用 `MARK:` 分组大块逻辑，保持文件可读性。

## SwiftUI 最佳实践
- 状态管理
  - View 为“数据到 UI 的纯映射”，避免在 `body` 中做副作用；副作用放入 `task`/`onAppear` 等生命周期，并可通过 `@MainActor` 限定。
  - 优先使用值类型和不可变输入，复杂状态由外部 `ObservableObject` 注入；避免视图层持久化业务状态。
  - 将动画封装在调用侧，组件只暴露 `isOn`/`progress` 等状态，允许外部决定动画时机与 Transaction。
- 布局与自适应
  - 遵循系统字号与 `Dynamic Type`；尽量使用 `LayoutPriority` 和 `fixedSize` 来控制截断/折行，而不是硬编码尺寸。
  - 优先使用 `ShapeStyle`（如 `.tint`, `.foregroundStyle`）和 `ControlSize`，支持主题与可达性设置。
  - 使用 `PreferenceKey`/`GeometryReader` 时保持边界清晰，避免递归布局或多次测量。
- 可测试性
  - 将复杂计算（布局参数、样式映射、数据规整）抽到纯函数或独立类型，便于单元测试。
  - 为关键元素添加 `accessibilityIdentifier`，配合 UI 测试稳定位。
- 性能
  - 避免在 `body` 中创建重型对象；可使用 `@StateObject` 缓存控制器或使用懒加载。
  - 对于绘制密集型视图（如波形），建议使用 `Canvas`/`Metal`/`CoreGraphics` 并最小化重绘区域；输入数据采用简化抽样（down-sampling）。
  - 使用 `TimelineView`/`CADisplayLink` 控制刷新节奏，避免不必要的 60fps 重绘。
- 可访问性与本地化
  - 所有可见字符串支持本地化占位；必要时提供 `Text(verbatim:)` 版本避免格式化副作用。
  - 使用语义角色（`Button`, `Toggle`, `Slider`）和可达性描述，确保 VoiceOver 可用。

### 音频波形组件建议
- 架构分层：Loader（读取 URL/Data）→ Decoder（PCM/采样率）→ Analyzer（RMS/峰值/包络线）→ Renderer（SwiftUI `Canvas`）。
- 数据规整：先按时间窗口（如 512/1024 帧）计算 RMS 或峰值，再按视图宽度进行二次下采样，得到稳定的条形/折线数据。
- 绘制策略：
  - 条形图：使用 `Canvas` + `Path`，合并绘制，避免每条使用独立 `Rectangle` 造成视图树膨胀。
  - 连续波形：预生成 `CGPath` 并缓存；仅在尺寸/缩放变化时重算。
- 交互与状态：将播放进度、选区等从外部以 `Binding` 传入，组件内部不持有播放器。
- 可测试性：
  - 单元测试验证采样到可视数据的映射（输入 PCM → N 条高度/路径点）。
  - UI 测试验证播放进度指示与可见性（例如当前帧的高亮条是否移动）。

## 预览与演示
- 模块内预览
  - 如预览不依赖额外资源，可在组件同目录提供 `#Preview` 片段（可置于单独文件 `ComponentName+Preview.swift`）。
  - 预览代码不需要额外编译条件；请避免引入示例 App 依赖。
- 示例 App
  - 在 `Examples/SwiftyComponentsExamples` 内添加演示页面并接入导航入口（建议维护一个“组件目录列表”）。
  - 页面应覆盖典型态（默认/边界/交互）以便人工与自动化回归。

## 示例 App 页面设计与新增
- 页面架构
  - `CatalogView`：组件目录与搜索，按组展示（`ComponentGroup`）。
  - `DemoPage`：单个组件 Demo 页面，内置 `DemoHarness` 工具栏（主题、布局、动效、高对比）。
  - `DemoHarness`：测试支架，提供环境切换与稳定的 `accessibilityIdentifier`，用于 UI 自动化测试与对比。
  - 深链与 UI 测试：支持启动参数 `-demo <id>` 与 `-variant <id>` 直接打开 Demo 页面；`UI_TEST` 参数开启稳定环境（如减少动效）。
- 如何新增组件页面
  1) 在 `Scenes/ComponentRegistry.swift` 中添加一个 `ComponentDemo`（含唯一 `id`、`title`、`summary`）。
  2) 为该 Demo 配置一组 `DemoVariant`（每个变体使用一个闭包返回组件视图）。
  3) 如需复杂示例，可在 `Scenes/` 下新建专属文件，将复杂布局/状态封装为小型视图，然后在变体闭包中引用。
  4) 如需资源，放入 `SwiftyComponentsExamples/Resources/` 对应子目录，并确认勾选 App 目标。
  5) 确保关键元素设置稳定的 `accessibilityIdentifier`（如 `Harness.*`、`Catalog.*`、`<Component>.*`）。
- UI 测试建议
  - 通过 `xcodebuild ... -scheme SwiftyComponentsExamples -destination ... test` 运行；
  - 使用 `-demo`/`-variant` 定位到具体页面，避免跨页依赖，降低用例耦合；
  - 测试前传入 `UI_TEST` 参数，Harness 将默认降低动效，提升快照/断言稳定性。

## 资源与样本数据（Examples）
- 放置位置
  - 示例资源统一放在 `Examples/SwiftyComponentsExamples/SwiftyComponentsExamples/Resources/` 下，按类型分子目录（如 `Audio/`, `Images/`）。
  - 包（`Sources/`）层不默认内置大资源，避免污染库产物体积；若确需测试资源，优先放入 `Tests` 目标或以生成脚本产生。
- 目标成员与打包
  - 打开示例 Xcode 工程后，确认新资源勾选 App 目标（Target Membership）以便随 App 打包。
  - 访问路径建议使用 `Bundle.main.url(forResource:withExtension:subdirectory:)`，将 `Audio` 作为子目录：
    ```swift
    let url = Bundle.main.url(forResource: "wave-440hz-1s", withExtension: "wav", subdirectory: "Audio")
    ```
- 音频样本（已内置）
  - `Resources/Audio/wave-440hz-1s.wav` 与 `Resources/Audio/wave-880hz-1s.wav`，适合作为“音频波形图”组件的入门数据源与 UI 测试素材。
  - 若需要更多体积更大的样本，请将文件放入 `Audio/` 并在 PR 说明中备注来源与许可。

## 组件设计思想文档
- 详见：`docs/COMPONENT_DESIGN.md`。
- 核心：从使用者出发，默认即用、渐进增强、一致命名、值语义优先、失败安全、示例与测试并重。

## 测试策略
- 单元测试（Package 层）
  - 使用 Swift Testing（已在模板启用）：
    ```swift
    import Testing
    @testable import SwiftyComponents

    @Test func PrimaryButton_defaultLayout() throws {
        // 构造：纯参数渲染，校验可计算属性/布局参数/样式映射等
        #expect(true)
    }
    ```
  - 侧重：纯函数/样式映射/状态机/可序列化配置等。
- UI 测试（示例 App 层）
  - 放置于 `Examples/SwiftyComponentsExamplesUITests`。
  - 以稳定的 `accessibilityIdentifier` 定位元素，覆盖关键交互流与可见性断言。
- 快照测试（可选）
  - 允许引入 `pointfreeco/swift-snapshot-testing` 做组件快照回归；若引入，应固定渲染尺寸、颜色模式与动态字体设置。

## 自动化与命令
- 本地构建
  - 包构建：`swift build -v`
  - 包测试：`swift test -v`
- Xcode 测试（示例 App + UI 测试）
  - 构建并测试：
    - `xcodebuild -project Examples/SwiftyComponentsExamples/SwiftyComponentsExamples.xcodeproj -scheme SwiftyComponentsExamples -destination 'platform=iOS Simulator,name=iPhone 16' test`
  - 仅构建供测试：
    - `xcodebuild -project Examples/SwiftyComponentsExamples/SwiftyComponentsExamples.xcodeproj -scheme SwiftyComponentsExamples -destination 'generic/platform=iOS Simulator' build-for-testing`
- CI 建议（可选）
  - 在 CI 执行 `swift test`；若启用 UI 测试，增加 `xcodebuild test` 步骤并收集结果包（`.xcresult`）。

## 新增组件脚手架（建议）
1) 在 `Sources/SwiftyComponents/` 新建：
   - `ComponentName.swift`（主视图）
   - 可选：`ComponentNameStyle.swift`（样式/配置）
   - 可选：`ComponentName+Preview.swift`（内置预览）
2) 在 `Examples/SwiftyComponentsExamples/` 新增 SwiftUI 页面并接入主导航。
3) 在 `Tests/SwiftyComponentsTests/` 添加 `ComponentNameTests.swift` 覆盖逻辑/样式映射。
4) 在 `Examples/SwiftyComponentsExamplesUITests/` 添加 UI 测试覆盖核心交互。

示例（片段）：
```swift
// Sources/SwiftyComponents/PrimaryButton.swift
import SwiftUI

public struct PrimaryButton: View {
    public let title: String
    public let action: () -> Void

    public init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("PrimaryButton")
    }
}

#Preview("Default") {
    PrimaryButton(title: "Continue", action: {})
        .padding()
}
```

## 代码风格与边界
- 保持零或低依赖；新增三方库需权衡体积与可替代性。
- 仅对必要 API 标记 `public`；避免泄露内部实现。
- Swift Concurrency：UI 面向类型标注 `@MainActor`（如需），异步代码避免在视图层做繁重计算。
- 不在源码中加入版权/许可证头（除非明确要求）。

## Agent 执行注意
- 修改前理解上下文：遵循本 AGENTS.md，保持改动小而专注，不重命名无关文件。
- 若新增测试，仅覆盖改动点；不修复无关缺陷（可在提交信息中备注）。
- 提交前优先跑包级测试（`swift test`）；涉及 UI 交互时再补充示例 App 的 UI 测试。

—— 以上约定帮助组件在本包内“可运行、可测试、可自动化测试”，并为主项目提供稳定、清晰的复用基础。
