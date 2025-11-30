# CRRecorder 录制使用说明（macOS / ScreenCaptureKit）

本文档说明库内 CRRecorder 的使用场景、生命周期、常见错误与最佳实践，帮助你在 App 中稳定集成屏幕/窗口录制与可选的麦克风、摄像头、Apple 设备采集。

## 总览
- 目标：以最少样板代码，完成“开始录制 → 停止 → 获得文件”的流程，并在异常情况下尽可能产出可读文件。
- 支持来源：
  - 屏幕或窗口（ScreenCaptureKit）
  - 摄像头（AVCapture）
  - 麦克风（AVCapture）
  - Apple 设备（AVCapture）
- 输出：`.mov`（视频）与 `.m4a`（音频，单独录制时）。
- 相关核心文件：
  - `Sources/SwiftyComponents/Foundations/CRRecorder/CRRecorder.swift`
  - `Sources/SwiftyComponents/Foundations/CRRecorder/ScreenCaptureRecorder.swift`
  - `Sources/SwiftyComponents/Foundations/CRRecorder/ScreenRecorderWriterPipeline.swift`
  - `Sources/SwiftyComponents/Foundations/CRRecorder/ScreenRecorderConfig.swift`
  - 诊断：`Sources/SwiftyComponents/Foundations/CRRecorder/Diagnostics/RecorderDiagnostics.swift`

## 架构与关键类型
- `CRRecorder`：上层协调器，组合多路录制方案（Scheme），统一启动/停止，最终返回 `Result`。
- `ScreenCaptureRecorder`：封装 ScreenCaptureKit 流 → 写入器（WriterPipeline）。
- `WriterPipeline`：`AVAssetWriter` 写入管线（视频/音频输入、会话启动、收尾）。
- `SchemeItem`：要录制的来源枚举：`.display`、`.window`、`.camera`、`.microphone`、`.appleDevice`。
- `ScreenRecorderOptions`：帧率、是否包含音频、光标、HEVC/HDR、queueDepth、目标码率等。
- `CRRecorder.Result/BundleInfo`：返回的录制结果与文件清单（可直接用于 UI 展示或自动化收集）。

## 快速开始（仅屏幕/窗口）
```swift
import SwiftyComponents

// 1) 选择输出目录与文件名
let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
let filename = "capture"

// 2) 组装方案（示例：显示器 + 区域裁剪）
let scheme: CRRecorder.SchemeItem = .display(
    displayID: CGMainDisplayID(),
    area: CGRect(x: 0, y: 0, width: 800, height: 600),
    hdr: false,
    captureSystemAudio: false,
    filename: filename,
    backend: .screenCaptureKit,
    excludedWindowTitles: []
)

// 3) 创建并配置 CRRecorder
let recorder = CRRecorder([scheme], outputDirectory: dir)
recorder.screenOptions = ScreenRecorderOptions(
    fps: 60,
    queueDepth: nil,           // 为空时按分辨率自动推荐
    targetBitRate: nil,        // 为空时按分辨率与 fps 估算
    includeAudio: false,
    showsCursor: true,
    hdr: false,
    useHEVC: false
)

// 4) 启动与停止（异步）
try await recorder.prepare([scheme])
try await recorder.startRecording()

// ... 录制中（UI 或逻辑控制） ...

let result = try await recorder.stopRecordingWithResult()
print("Saved files:", result.bundleInfo.files.map(\_.filename))
```

## SwiftUI 集成（开箱即用控件）
- 直接使用示例控件：`Sources/SwiftyComponents/Components/CRRecorder/ScreenRecorderControl.swift`
- 示例 App 页面：`Examples/SwiftyComponentsExamples/SwiftyComponentsExamples/Scenes/CRRecorderDemoView.swift`
- 控件内包含：目录选择、帧率/编码参数、开始/停止、最近文件打开、时长显示与历史记录。

## 多路采集（屏幕 + 麦克风/摄像头）
- 通过向 `CRRecorder` 传入多个 `SchemeItem` 并行录制：
```swift
let schemes: [CRRecorder.SchemeItem] = [
  .display(displayID: CGMainDisplayID(), area: nil, hdr: false, captureSystemAudio: false, filename: "screen", backend: .screenCaptureKit, excludedWindowTitles: []),
  .microphone(microphoneID: "default", filename: "mic"),
  .camera(cameraID: "default", filename: "webcam")
]
let recorder = CRRecorder(schemes, outputDirectory: dir)
try await recorder.prepare(schemes)
try await recorder.startRecording()
let result = try await recorder.stopRecordingWithResult()
```
- 返回结果 `result.bundleInfo.files` 会包含每路文件的文件名与起止时间戳等元数据。

## 生命周期与收尾顺序（重要）
- 屏幕/窗口（ScreenCaptureKit）：
  1) `prepareWriter`（创建 AVAssetWriter 与输入）
  2) `startCapture()` 后接收视频首帧 → `writer.startSession(at: 首帧PTS)`
  3) 录制中持续 `appendVideo/appendAudio`
  4) 停止时“先止血”再收尾：
     - 从 `SCStream` 移除输出并屏蔽回调（阻断晚到样本）
     - 调用 `stopCapture()`（若错误码为 -3821，跳过 stop，直接 finalize）
     - `markAsFinished()` → `finishWriting()`（只调一次）
- 关键实现参考：
  - `ScreenCaptureRecorder`（止血与错误分支）：`Sources/SwiftyComponents/Foundations/CRRecorder/ScreenCaptureRecorder.swift`
  - `WriterPipeline.finish()`（状态机与兜底）：`Sources/SwiftyComponents/Foundations/CRRecorder/ScreenRecorderWriterPipeline.swift`

## 错误处理与常见场景
- -3821（SCStream 被系统/用户外部停止，如菜单栏按钮）：
  - 直接跳过 `stopCapture()`，先“止血”，再 `finishWriting()` 收尾。
- 非 -3821 错误：
  - 同样先“止血”，然后尝试 `stopCapture()`，最后 `finishWriting()`。
- 并发/重入保护：
  - `ScreenCaptureRecorder` 内部用 `finalizeStarted` 确保只收尾一次。
  - `WriterPipeline.finish()` 也有 `isFinishing` 兜底；如果从未收到首帧，会 `cancelWriting()`。
- 目的：避免在 `markAsFinished()` 之后仍有 `append`，以及避免二次调用 `finishWriting()` 触发崩溃（AVAssetWriter 在 finish 过程中仍报告 `.writing` 状态，重复调用会 abort）。

## 时间基原则
- 以“首个视频样本的 PTS”作为写入会话的时间基（`writer.startSession(atSourceTime:)`）。
- 不使用墙钟扩展尾巴；若需要补尾帧，由写入器在相同时间基上进行（避免时长被意外拉长）。

## 配置要点与建议
- 帧率与分辨率：
  - 通过 `ScreenRecorderOptions.fps` 与 `ScreenRecorderConfig` 自动裁剪/降维，避免过大尺寸导致丢帧。
  - `queueDepth` 留空时按分辨率/fps 推荐；高分辨率 + 高 fps 适度增大。
- 编码：
  - H.264 + sRGB 默认；开启 HEVC/HDR 将切换 HEVC + Display P3。
  - 目标码率默认按分辨率与 fps 估算，可显式设置 `targetBitRate`。
- 音频：
  - `includeAudio=true` 时，屏幕录制会把系统音频合并到 `.mov`；麦克风单独录制输出 `.m4a`。

## 结果与清单
- `CRRecorder.Result`：
  - `bundleURL`：输出目录
  - `bundleInfo.files`：文件清单（文件名、起止时间戳、类型等）
- 旁路清单：`bundle.json` 会写入到输出目录（便于自动化收集）。

## 诊断与调试
- `RecorderDiagnostics`（可直接绑定 UI）：
  - 捕获的 fps、最近帧尺寸、写入状态、追加/丢弃计数、错误列表、文件大小时序、系统快照等。
- 可使用示例 UI：`RecorderDiagnosticsView`；或在控制台观察 `RecorderDiagnostics.shared` 的事件/错误。

## 权限与运行环境
- macOS 需要“屏幕录制”权限（System Settings → Privacy & Security → Screen Recording）。
- 录制麦克风/摄像头需要对应权限。
- Xcode 16+/Swift 6.2（参考 `Package.swift`），Apple Silicon/Intel 皆可。

## 常见坑与规避
- 不要在 finalize 期间继续 append：先移除输出/屏蔽回调，再 finish。
- 只调用一次 `finishWriting`；即使 `status == .writing`，也可能已在内部 finalize 中，重复调用会崩溃。
- 没有首帧时不要 finish，选择 `cancelWriting()`。
- 时间基保持一致，以样本 PTS 为准，避免混入墙钟。

## 参考示例
- 控件：`Sources/SwiftyComponents/Components/CRRecorder/ScreenRecorderControl.swift`
- Demo 页面：`Examples/SwiftyComponentsExamples/SwiftyComponentsExamples/Scenes/CRRecorderDemoView.swift`

以上内容覆盖了从入门到异常处理的主要用法。如需更细致的扩展（例如 UI 自动化测试策略、与主工程日志系统打通），可在此文档基础上补充你的团队约定。
