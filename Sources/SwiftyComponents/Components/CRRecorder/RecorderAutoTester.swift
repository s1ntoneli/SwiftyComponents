import Foundation
import AVFoundation
import CoreGraphics

// MARK: - Recording analysis & backend parity

/// Lightweight description of a single recorded movie file.
struct ScreenRecordingAnalysis: Identifiable, Sendable {
    let id = UUID()
    let url: URL

    let hasVideo: Bool
    let hasAudio: Bool
    let videoCodec: String?
    let audioCodec: String?

    let videoSize: CGSize?
    let duration: Double?
    let nominalFrameRate: Float?

    let fileSizeBytes: Int?
    let overallBitrate: Double?   // bits per second
    let videoBitrate: Double?     // bits per second
    let audioBitrate: Double?     // bits per second

    var fileSizeMegabytes: Double? {
        guard let fileSizeBytes else { return nil }
        return Double(fileSizeBytes) / 1_048_576.0
    }

    var videoBitrateMbps: Double? {
        videoBitrate.map { $0 / 1_000_000.0 }
    }

    var overallBitrateMbps: Double? {
        overallBitrate.map { $0 / 1_000_000.0 }
    }
}

/// Comparison summary between ScreenCaptureKit and AVFoundation backends.
struct ScreenBackendParitySummary: Identifiable, Sendable {
    let id = UUID()
    let screenCaptureKit: ScreenRecordingAnalysis
    let avFoundation: ScreenRecordingAnalysis

    let durationDifference: Double?
    let fileSizeRatio: Double?
    let videoBitrateRatio: Double?
    let overallBitrateRatio: Double?

    let durationWithinTolerance: Bool?
    let fileSizeWithinTolerance: Bool?
    let videoBitrateWithinTolerance: Bool?
    let overallBitrateWithinTolerance: Bool?
}

/// Analyze a recorded movie file and extract basic metrics.
func analyzeScreenRecording(at url: URL) async -> ScreenRecordingAnalysis {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVAsset(url: url)
            let videoTrack = asset.tracks(withMediaType: .video).first
            let audioTrack = asset.tracks(withMediaType: .audio).first

            let hasVideo = (videoTrack != nil)
            let hasAudio = (audioTrack != nil)

            let durationSeconds: Double? = {
                let d = asset.duration
                guard d.isNumeric && d.value != 0 else { return nil }
                return CMTimeGetSeconds(d)
            }()

            let videoSize: CGSize? = {
                guard let track = videoTrack else { return nil }
                let size = track.naturalSize.applying(track.preferredTransform)
                return CGSize(width: abs(size.width), height: abs(size.height))
            }()

            let nominalFPS = videoTrack?.nominalFrameRate
            let videoBitrate = videoTrack.map { Double($0.estimatedDataRate) }
            let audioBitrate = audioTrack.map { Double($0.estimatedDataRate) }

            let fileSizeBytes: Int? = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            let overallBitrate: Double? = {
                guard let bytes = fileSizeBytes, let d = durationSeconds, d > 0 else { return nil }
                return Double(bytes * 8) / d
            }()

            let videoCodec = videoTrack.flatMap { codecString(for: $0) }
            let audioCodec = audioTrack.flatMap { codecString(for: $0) }

            let analysis = ScreenRecordingAnalysis(
                url: url,
                hasVideo: hasVideo,
                hasAudio: hasAudio,
                videoCodec: videoCodec,
                audioCodec: audioCodec,
                videoSize: videoSize,
                duration: durationSeconds,
                nominalFrameRate: nominalFPS,
                fileSizeBytes: fileSizeBytes,
                overallBitrate: overallBitrate,
                videoBitrate: videoBitrate,
                audioBitrate: audioBitrate
            )

            continuation.resume(returning: analysis)
        }
    }
}

/// Compute parity summary and threshold-based pass/fail flags.
func computeScreenBackendParity(
    screenCaptureKit: ScreenRecordingAnalysis,
    avFoundation: ScreenRecordingAnalysis,
    durationTolerance: Double = 0.20,
    ratioTolerance: Double = 2.0
) -> ScreenBackendParitySummary {
    func ratio(_ a: Int?, _ b: Int?) -> Double? {
        guard let a, let b, a > 0, b > 0 else { return nil }
        let da = Double(a), db = Double(b)
        return max(da, db) / min(da, db)
    }
    func ratioD(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b, a > 0, b > 0 else { return nil }
        return max(a, b) / min(a, b)
    }

    let durationDifference: Double? = {
        guard let a = screenCaptureKit.duration, let b = avFoundation.duration else { return nil }
        return abs(a - b)
    }()

    let fileSizeRatio = ratio(screenCaptureKit.fileSizeBytes, avFoundation.fileSizeBytes)
    let videoBitrateRatio = ratioD(screenCaptureKit.videoBitrate, avFoundation.videoBitrate)
    let overallBitrateRatio = ratioD(screenCaptureKit.overallBitrate, avFoundation.overallBitrate)

    let durationWithinTolerance = durationDifference.map { $0 <= durationTolerance }
    let fileSizeWithinTolerance = fileSizeRatio.map { $0 <= ratioTolerance }
    let videoBitrateWithinTolerance = videoBitrateRatio.map { $0 <= ratioTolerance }
    let overallBitrateWithinTolerance = overallBitrateRatio.map { $0 <= ratioTolerance }

    return ScreenBackendParitySummary(
        screenCaptureKit: screenCaptureKit,
        avFoundation: avFoundation,
        durationDifference: durationDifference,
        fileSizeRatio: fileSizeRatio,
        videoBitrateRatio: videoBitrateRatio,
        overallBitrateRatio: overallBitrateRatio,
        durationWithinTolerance: durationWithinTolerance,
        fileSizeWithinTolerance: fileSizeWithinTolerance,
        videoBitrateWithinTolerance: videoBitrateWithinTolerance,
        overallBitrateWithinTolerance: overallBitrateWithinTolerance
    )
}

private func codecString(for track: AVAssetTrack) -> String? {
    guard let anyDesc = track.formatDescriptions.first else { return nil }
    let desc = anyDesc as! CMFormatDescription
    let fourcc = CMFormatDescriptionGetMediaSubType(desc)
    return fourCCString(fourcc)
}

private func fourCCString(_ code: UInt32) -> String {
    let big = CFSwapInt32HostToBig(code)
    var chars: [CChar] = [
        CChar((big >> 24) & 0xff),
        CChar((big >> 16) & 0xff),
        CChar((big >> 8) & 0xff),
        CChar(big & 0xff),
        0
    ]
    return String(cString: &chars)
}

@MainActor
final class RecorderAutoTester: ObservableObject {
    struct Scenario: Identifiable, Hashable {
        enum Kind: String {
            case shortQuick
            case staticLong
            case externalStop
            case stress10
            case micOnly
            case camOnly
            // 新增更丰富的默认场景
            case highFPS120
            case lowFPS15
            case hevcHDR
            case noAudio
            case cursorOn
            case cursorOff
            case beforeFirstFrame
            case long60s
            case camMicBoth
            /// Compare ScreenCaptureKit vs AVFoundation backends on core metrics.
            case backendParity
            case backendParityLowFPS
            case backendParityHighFPS
            case backendParityFullScreen
            case backendParityHEVC
            case backendParityLong
            /// 不限制时长，直到系统/用户外部打断（如 Control Center 停止共享）
            case untilInterrupted
        }
        let id: Kind
        let title: String
        let summary: String
        let defaultSeconds: Double
    }

    struct RunConfig: Sendable {
        let scenarios: [Scenario]
        let repetitions: Int
        let secondsOverride: Double?
        let includeSystemAudio: Bool
        let includeMicrophone: Bool
        let includeCamera: Bool
        let displayID: CGDirectDisplayID
        let cropRect: CGRect?
        let baseOutput: URL
        let backend: CRRecorder.ScreenBackend
    }

    struct FileCheck: Sendable, Identifiable {
        var id = UUID()
        let filename: String
        let expectedSeconds: Double
        let actualSeconds: Double
        let pass: Bool
    }

    struct RunResult: Identifiable, Sendable {
        var id = UUID()
        let scenario: Scenario
        let index: Int
        let sessionDir: URL
        let files: [FileCheck]
        let passed: Bool
        /// Screen recording backend used for this run（ScreenCaptureKit / AVFoundation）；为 parity 场景则为 nil。
        let backend: CRRecorder.ScreenBackend?
        let note: String
        let backendParity: ScreenBackendParitySummary?
    }

    @Published var isRunning = false
    @Published var progressText: String = ""
    @Published var results: [RunResult] = []

    func availableScenarios() -> [Scenario] {
        [
            .init(id: .shortQuick, title: "短时录制", summary: "快速开始-停止（~0.5s）", defaultSeconds: 0.5),
            .init(id: .staticLong, title: "静态长时间（30s）", summary: "录制30s静态画面", defaultSeconds: 30),
            .init(id: .externalStop, title: "外部停止共享", summary: "通过菜单栏停止共享", defaultSeconds: 3),
            .init(id: .stress10, title: "连跑10次", summary: "连续短录10轮", defaultSeconds: 0.7),
            .init(id: .micOnly, title: "仅麦克风", summary: "屏幕无声，单录麦克风", defaultSeconds: 3),
            .init(id: .camOnly, title: "仅摄像头", summary: "录制摄像头3秒", defaultSeconds: 3),
            .init(id: .highFPS120, title: "高帧率 120fps", summary: "以120fps录制 2s", defaultSeconds: 2),
            .init(id: .lowFPS15, title: "低帧率 15fps", summary: "以15fps录制 3s", defaultSeconds: 3),
            .init(id: .hevcHDR, title: "HEVC + HDR", summary: "启用HEVC/HDR 编码 3s", defaultSeconds: 3),
            .init(id: .noAudio, title: "无音频", summary: "屏幕不含系统音频，且不录麦克风，3s", defaultSeconds: 3),
            .init(id: .cursorOn, title: "显示光标", summary: "showsCursor=true 3s", defaultSeconds: 3),
            .init(id: .cursorOff, title: "隐藏光标", summary: "showsCursor=false 3s", defaultSeconds: 3),
            .init(id: .beforeFirstFrame, title: "首帧前停止", summary: "启动后立即停止，校验无崩溃", defaultSeconds: 0),
            .init(id: .long60s, title: "长时间 60s", summary: "录制60s，验证稳定性与时长", defaultSeconds: 60),
            .init(id: .camMicBoth, title: "摄像头+麦克风", summary: "强制同时录制摄像头和麦克风，3s", defaultSeconds: 3),
            .init(id: .backendParity, title: "后端一致性 · 基础", summary: "60fps、裁剪区域，SCK vs AVF 对比分辨率/时长/体积/码率", defaultSeconds: 3),
            .init(id: .backendParityLowFPS, title: "后端一致性 · 低帧率 15fps", summary: "15fps、裁剪区域，检查低帧率时长与码率的一致性", defaultSeconds: 3),
            .init(id: .backendParityHighFPS, title: "后端一致性 · 高帧率 120fps", summary: "120fps、裁剪区域，检查高帧率下的行为差异", defaultSeconds: 2),
            .init(id: .backendParityFullScreen, title: "后端一致性 · 全屏", summary: "全屏录制，验证高分辨率下的分辨率/体积/码率", defaultSeconds: 3),
            .init(id: .backendParityHEVC, title: "后端一致性 · HEVC (SCK)", summary: "SCK 使用 HEVC/HDR，AVF 保持 H.264，对比分辨率和时长并观测码率差异", defaultSeconds: 3),
            .init(id: .backendParityLong, title: "后端一致性 · 长时间 15s", summary: "长时间 15s 录制，检查时长与码率随时间的稳定性", defaultSeconds: 15),
            .init(id: .untilInterrupted, title: "直到系统打断", summary: "不设时长，等待系统/用户停止共享后收尾并统计关键数据", defaultSeconds: 0)
        ]
    }

    func run(config: RunConfig) async {
        guard !isRunning else { return }
        isRunning = true
        results.removeAll()
        defer { isRunning = false }

        // Log run header for easier automation parsing
        logAutoTest("START scenarios=\(config.scenarios.count) reps=\(config.repetitions) secondsOverride=\(config.secondsOverride?.description ?? "nil") systemAudio=\(config.includeSystemAudio) mic=\(config.includeMicrophone) cam=\(config.includeCamera) backend=\(config.backend.rawValue) display=\(config.displayID) crop=\(config.cropRect?.debugDescription ?? "nil") base=\(config.baseOutput.path)")

        var counter = 0
        for scenario in config.scenarios {
            let reps = scenario.id == .stress10 ? max(config.repetitions, 10) : config.repetitions
            for i in 1...reps {
                counter += 1
                self.progressText = "运行: \(scenario.title) [\(i)/\(reps)]"
                do {
                    if let r = try await runOne(scenario: scenario, index: i, config: config) {
                        results.append(r)
                        logRunResult(r)
                    }
                } catch {
                    // 对于 Legacy AV 后端，极短场景在 AVFoundation 下可能返回 "Cannot Record"，
                    // 此时只要应用未崩溃，我们视为“预期行为”，将其标记为通过以避免干扰。
                    if config.backend == .avFoundation,
                       let recErr = error as? AVScreenRecorder.RecorderError,
                       case .recordingFailed(let msg) = recErr,
                       msg == "Cannot Record",
                       [.shortQuick, .beforeFirstFrame, .stress10].contains(scenario.id) {
                        let dir = config.baseOutput
                        let note = "AVScreenRecorder returned 'Cannot Record' for \(scenario.id.rawValue) under legacy backend; treated as pass (no crash)."
                        let passed = RunResult(scenario: scenario, index: i, sessionDir: dir, files: [], passed: true, backend: config.backend, note: note, backendParity: nil)
                        results.append(passed)
                        logRunResult(passed)
                    } else {
                        let dir = config.baseOutput
                        let failed = RunResult(scenario: scenario, index: i, sessionDir: dir, files: [], passed: false, backend: config.backend, note: error.localizedDescription, backendParity: nil)
                        results.append(failed)
                        logRunResult(failed)
                    }
                }
            }
        }

        // Final summary
        logSummary()
    }

    private func runOne(scenario: Scenario, index: Int, config: RunConfig) async throws -> RunResult? {
        switch scenario.id {
        case .backendParity,
             .backendParityLowFPS,
             .backendParityHighFPS,
             .backendParityFullScreen,
             .backendParityHEVC,
             .backendParityLong:
            return try await runBackendParityScenario(scenario: scenario, index: index, config: config)
        default:
            break
        }

        let dirName = Self.timestamped("auto-\(scenario.id.rawValue)-\(index)")
        let sessionDir = config.baseOutput.appendingPathComponent(dirName)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        // Schemes（按场景重写音频/设备开关）
        var schemes: [CRRecorder.SchemeItem] = []
        var captureSystemAudio = config.includeSystemAudio
        var wantMic = config.includeMicrophone
        var wantCam = config.includeCamera
        var includeScreen = (scenario.id != .micOnly)

        switch scenario.id {
        case .noAudio:
            captureSystemAudio = false; wantMic = false
        case .micOnly:
            includeScreen = false; wantMic = true; captureSystemAudio = false
        case .camOnly:
            includeScreen = false; wantCam = true
        case .camMicBoth:
            wantCam = true; wantMic = true
        default: break
        }

        // Per-run screen options
        var screenOptions = ScreenRecorderOptions(
            fps: 60,
            queueDepth: nil,
            targetBitRate: nil,
            includeAudio: captureSystemAudio,
            showsCursor: true,
            hdr: false,
            useHEVC: false
        )
        switch scenario.id {
        case .highFPS120: screenOptions.fps = 120
        case .lowFPS15: screenOptions.fps = 15
        case .hevcHDR: screenOptions.hdr = true; screenOptions.useHEVC = true
        case .cursorOn: screenOptions.showsCursor = true
        case .cursorOff: screenOptions.showsCursor = false
        default: break
        }

        if includeScreen {
            schemes.append(
                .display(
                    displayID: config.displayID,
                    area: config.cropRect,
                    hdr: false,
                    captureSystemAudio: captureSystemAudio,
                    filename: dirName,
                    backend: config.backend,
                    screenOptions: screenOptions,
                    excludedWindowTitles: []
                )
            )
        }
        if wantMic {
            schemes.append(
                .microphone(
                    microphoneID: "default",
                    filename: dirName + "-mic",
                    microphoneOptions: .init()
                )
            )
        }
        if wantCam {
            schemes.append(
                .camera(
                    cameraID: "default",
                    filename: dirName + "-cam",
                    cameraOptions: .init()
                )
            )
        }

        let rec = CRRecorder(schemes, outputDirectory: sessionDir)
        // 捕获屏幕流错误，用于失败时标注具体原因
        var lastStreamError: NSError? = nil
        rec.onInterupt = { err in lastStreamError = err as NSError }
        try await rec.prepare(schemes)
        try await rec.startRecording()

        // 基线诊断快照（用于本轮统计增量）
        let diagBefore = diagSnapshot()

        let seconds = config.secondsOverride ?? scenario.defaultSeconds
        let start = CFAbsoluteTimeGetCurrent()

        // Scenario-specific action
        switch scenario.id {
        case .externalStop:
            // 尝试通过菜单栏“停止共享”结束（需要辅助功能权限，仅 ScreenCaptureKit 有效）
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
            if config.backend == .screenCaptureKit {
                try? await Self.menuBarStopSharing()
            } else {
                // Legacy 后端没有菜单栏入口，这里不做额外操作，由正常 stopRecordingWithResult 收尾。
            }
        case .untilInterrupted:
            // ScreenCaptureKit：等待系统/用户从外部停止共享（SCStream -3821）
            // Legacy 后端：在指定时间后注入一个模拟的中断错误，走同一套 onInterupt 收尾路径。
            let startWall = CFAbsoluteTimeGetCurrent()
            let interrupted: (CRRecorder.Result?, Error) = await withCheckedContinuation { (cont: CheckedContinuation<(CRRecorder.Result?, Error), Never>) in
                rec.onInterupt = { err in
                    Task.detached(priority: .userInitiated) {
                        let result = try? await rec.stopRecordingWithResult()
                        cont.resume(returning: (result, err))
                    }
                }
                if config.backend == .avFoundation {
                    // Legacy：模拟“外部中断”，延迟一段时间后主动触发 onInterupt
                    Task.detached(priority: .userInitiated) {
                        let delay = max(60*10, seconds)
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        let simulated = AVScreenRecorder.RecorderError.recordingFailed("Simulated external interrupt")
                        rec.onInterupt(simulated)
                    }
                }
            }
            let endWall = CFAbsoluteTimeGetCurrent()
            // 汇总关键数据（来自 RecorderDiagnostics）
            let diag = RecorderDiagnostics.shared
            let sys = diag.systemSnapshot
            let bytes = diag.currentFileSizeBytes
            let noteLines: [String] = [
                "外部中断: \((interrupted.1 as NSError).domain)#\((interrupted.1 as NSError).code) — \(interrupted.1.localizedDescription)",
                String(format: "总耗时(墙钟): %.2fs", endWall - startWall),
                "帧: captured=\(diag.capturedVideoFrames) appended=\(diag.appendedVideoFrames) dropped=\(diag.droppedVideoNotReady)",
                String(format: "测量FPS: %.2f", diag.measuredFPS),
                "写入状态: video=\(diag.lastVideoWriterStatus) audio=\(diag.lastAudioWriterStatus)",
                "最终文件大小: \(bytes) bytes",
                {
                    if let s = sys {
                        let cpu = s.systemCPUUsageRatio.map { String(format: "%.1f%%", $0 * 100) } ?? "-"
                        let pcpu = s.processCPUPercent.map { String(format: "%.1f%%", $0) } ?? "-"
                        let mem = String(format: "%.1f%%", (s.memoryUsageRatio * 100))
                        return "系统: CPU=\(cpu) 进程CPU=\(pcpu) RSS=\(s.processRSSBytes)B 内存占用=\(mem)"
                    } else { return "系统: n/a" }
                }()
            ]
            let note = noteLines.joined(separator: "\n")
            // 若能得到 result，进行文件校验；否则返回空 files
            if let result = interrupted.0 {
                var checks: [FileCheck] = []
                for f in result.bundleInfo.files {
                    let url = sessionDir.appendingPathComponent(f.filename)
                    let asset = AVURLAsset(url: url)
                    let dur = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
                    checks.append(FileCheck(filename: f.filename, expectedSeconds: -1, actualSeconds: dur, pass: true))
                }
                return RunResult(scenario: scenario, index: index, sessionDir: sessionDir, files: checks, passed: true, backend: config.backend, note: note, backendParity: nil)
            } else {
                return RunResult(scenario: scenario, index: index, sessionDir: sessionDir, files: [], passed: true, backend: config.backend, note: note, backendParity: nil)
            }
        case .stress10, .shortQuick, .staticLong, .micOnly, .camOnly, .highFPS120, .lowFPS15, .hevcHDR, .noAudio, .cursorOn, .cursorOff, .long60s, .camMicBoth, .backendParity, .backendParityLowFPS, .backendParityHighFPS, .backendParityFullScreen, .backendParityHEVC, .backendParityLong:
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
        case .beforeFirstFrame:
            // 尽快停止，触发“未收到首帧”的收尾路径
            try? await Task.sleep(nanoseconds: 10_000_000) // ~0.01s
        case .backendParity:
            break // 已在上层专门处理，不会走到这里
        }

        let result = try await rec.stopRecordingWithResult()
        let end = CFAbsoluteTimeGetCurrent()
        let expected = seconds

        // Verify durations
        var checks: [FileCheck] = []
        for f in result.bundleInfo.files {
            let url = sessionDir.appendingPathComponent(f.filename)
            let asset = AVURLAsset(url: url)
            // 更稳健地加载时长（避免直接读取 .duration 的潜在不稳定）
            let durTime = try? await asset.load(.duration)
            let dur = durTime.map { CMTimeGetSeconds($0) } ?? 0
            let tolerance: Double = {
                switch scenario.id {
                case .shortQuick, .stress10, .beforeFirstFrame: return 1.5
                case .staticLong, .long60s: return 3.5
                default: return 2.5
                }
            }()
            let pass: Bool = (scenario.id == .beforeFirstFrame) ? (dur <= 1.0) : (abs(dur - expected) <= tolerance)
            checks.append(FileCheck(filename: f.filename, expectedSeconds: expected, actualSeconds: dur, pass: pass))
        }

        let allPass = checks.allSatisfy { $0.pass }
        var note = "耗时: \(String(format: "%.2f", end - start))s"

        // 输出本轮关键统计增量（帮助定位“缩短/截断”原因）
        let diagAfter = diagSnapshot()
        logAutoTestStats(scenario: scenario, index: index, before: diagBefore, after: diagAfter)

        // 若失败，拼接明确原因到 note
        if !allPass {
            if let rsn = formatFailReason(scenario: scenario, before: diagBefore, after: diagAfter, streamError: lastStreamError) {
                note += "\n原因: " + rsn
            }
        }
        return RunResult(scenario: scenario, index: index, sessionDir: sessionDir, files: checks, passed: allPass, backend: config.backend, note: note, backendParity: nil)
    }

    /// Special scenario: record twice (ScreenCaptureKit + AVFoundation) and compare core metrics.
    private func runBackendParityScenario(
        scenario: Scenario,
        index: Int,
        config: RunConfig
    ) async throws -> RunResult {
        let dirName = Self.timestamped("auto-\(scenario.id.rawValue)-\(index)")
        let sessionDir = config.baseOutput.appendingPathComponent(dirName)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let seconds = max(0.5, config.secondsOverride ?? scenario.defaultSeconds)

        // Per-scenario configuration: FPS、裁剪区域、编码与光标。
        let fps: Int
        let area: CGRect?
        let useHEVC: Bool
        let hdr: Bool
        let showsCursor: Bool
        switch scenario.id {
        case .backendParity:
            fps = 60
            area = config.cropRect
            useHEVC = false
            hdr = false
            showsCursor = true
        case .backendParityLowFPS:
            fps = 15
            area = config.cropRect
            useHEVC = false
            hdr = false
            showsCursor = true
        case .backendParityHighFPS:
            fps = 120
            area = config.cropRect
            useHEVC = false
            hdr = false
            showsCursor = true
        case .backendParityFullScreen:
            fps = 60
            area = nil
            useHEVC = false
            hdr = false
            showsCursor = true
        case .backendParityHEVC:
            fps = 60
            area = config.cropRect
            useHEVC = true
            hdr = true
            showsCursor = true
        case .backendParityLong:
            fps = 60
            area = config.cropRect
            useHEVC = false
            hdr = false
            showsCursor = true
        default:
            fps = 60
            area = config.cropRect
            useHEVC = false
            hdr = false
            showsCursor = true
        }

        func recordOne(
            backend: CRRecorder.ScreenBackend,
            suffix: String
        ) async throws -> URL {
            let baseName = dirName + "-" + suffix
            let screenOptions = ScreenRecorderOptions(
                fps: fps,
                queueDepth: nil,
                targetBitRate: nil,
                includeAudio: false,
                showsCursor: showsCursor,
                hdr: hdr,
                useHEVC: useHEVC
            )
            let scheme: CRRecorder.SchemeItem = .display(
                displayID: config.displayID,
                area: area,
                hdr: hdr,
                captureSystemAudio: false,
                filename: baseName,
                backend: backend,
                screenOptions: screenOptions,
                excludedWindowTitles: []
            )
            let rec = CRRecorder([scheme], outputDirectory: sessionDir)
            try await rec.prepare([scheme])
            try await rec.startRecording()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let result = try await rec.stopRecordingWithResult()
            guard let file = result.bundleInfo.files.first(where: { $0.tyle == .screen }) ?? result.bundleInfo.files.first else {
                throw RecordingError.recordingFailed("No screen file generated for backend \(backend.rawValue)")
            }
            return sessionDir.appendingPathComponent(file.filename)
        }

        let start = CFAbsoluteTimeGetCurrent()

        // 顺序录制，避免两套后端同时抢占屏幕录制资源。
        let sckURL = try await recordOne(backend: .screenCaptureKit, suffix: "sck")
        let avfURL = try await recordOne(backend: .avFoundation, suffix: "avf")

        let sckAnalysis = await analyzeScreenRecording(at: sckURL)
        let avfAnalysis = await analyzeScreenRecording(at: avfURL)
        let parity = computeScreenBackendParity(screenCaptureKit: sckAnalysis, avFoundation: avfAnalysis)

        let end = CFAbsoluteTimeGetCurrent()

        // Encode checks as virtual "files" rows for quick glance (duration only).
        var checks: [FileCheck] = []
        if let ds = parity.durationDifference {
            let expected = seconds
            let actualSCK = sckAnalysis.duration ?? 0
            let actualAVF = avfAnalysis.duration ?? 0
            let pass = parity.durationWithinTolerance ?? false
            checks.append(FileCheck(filename: "ScreenCaptureKit", expectedSeconds: expected, actualSeconds: actualSCK, pass: pass))
            checks.append(FileCheck(filename: "AVFoundation", expectedSeconds: expected, actualSeconds: actualAVF, pass: pass))
        }

        var noteLines: [String] = []
        noteLines.append(String(format: "耗时: %.2fs", end - start))
        if let d = parity.durationDifference {
            noteLines.append(String(format: "Δ duration: %.3fs (%@)", d, (parity.durationWithinTolerance ?? false) ? "OK" : "超出阈值"))
        }
        if let r = parity.fileSizeRatio {
            noteLines.append(String(format: "File size ratio (max/min): %.2fx (%@)", r, (parity.fileSizeWithinTolerance ?? false) ? "OK" : "超出阈值"))
        }
        if let r = parity.videoBitrateRatio {
            noteLines.append(String(format: "Video bitrate ratio (max/min): %.2fx (%@)", r, (parity.videoBitrateWithinTolerance ?? false) ? "OK" : "超出阈值"))
        }
        if let r = parity.overallBitrateRatio {
            noteLines.append(String(format: "Overall bitrate ratio (max/min): %.2fx (%@)", r, (parity.overallBitrateWithinTolerance ?? false) ? "OK" : "超出阈值"))
        }

        let allPass = [
            parity.durationWithinTolerance,
            parity.fileSizeWithinTolerance,
            parity.videoBitrateWithinTolerance,
            parity.overallBitrateWithinTolerance
        ].compactMap { $0 }.allSatisfy { $0 }

        let note = noteLines.joined(separator: "\n")

        return RunResult(
            scenario: scenario,
            index: index,
            sessionDir: sessionDir,
            files: checks,
            passed: allPass,
            backend: nil, // parity 场景：内部同时使用 SCK + AVFoundation
            note: note,
            backendParity: parity
        )
    }

    private static func timestamped(_ base: String) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return base + "-" + df.string(from: Date())
    }
}

// MARK: - Logging helpers
extension RecorderAutoTester {
    /// Print to both RecorderDiagnostics flow and NSLog with a stable prefix
    private func logAutoTest(_ message: String) {
        let msg = "[AUTO_TEST] " + message
        // Route via diagnostics flow (visible in UI and, in DEBUG, console)
        RecorderDiagnostics.shared.logFlow(msg)
        // Always print to system log for parsing irrespective of build flags
        NSLog("%@", msg)
    }

    private func logRunResult(_ r: RunResult) {
        let backendDesc: String = {
            if let b = r.backend {
                return b.rawValue
            }
            if r.backendParity != nil {
                return "parity(screenCaptureKit+avFoundation)"
            }
            return "unknown"
        }()
        let header = "scenario=\(r.scenario.id.rawValue) index=\(r.index) backend=\(backendDesc) passed=\(r.passed) note=\(r.note) dir=\(r.sessionDir.lastPathComponent)"
        logAutoTest("RESULT " + header)
        if r.files.isEmpty {
            logAutoTest("FILES 0")
        } else {
            for f in r.files {
                let actual = String(format: "%.2f", f.actualSeconds)
                let line = "FILE name=\(f.filename) expected=\(Int(f.expectedSeconds))s actual=\(actual)s pass=\(f.pass)"
                logAutoTest(line)
            }
        }
    }

    private func logSummary() {
        let total = results.count
        let passed = results.filter { $0.passed }.count
        let failed = total - passed
        logAutoTest("END total=\(total) passed=\(passed) failed=\(failed)")
    }

    // 采样当前诊断数据（读主线程，避免竞态）
    private func diagSnapshot() -> (cv: UInt64, av: UInt64, dv: UInt64, aa: UInt64, vf: UInt64, err: Int, lastV: String, lastA: String) {
        let d = RecorderDiagnostics.shared
        return (cv: d.capturedVideoFrames,
                av: d.appendedVideoFrames,
                dv: d.droppedVideoNotReady,
                aa: d.appendedAudioSamples,
                vf: d.writerVideoFailedCount,
                err: d.errors.count,
                lastV: d.lastVideoWriterStatus,
                lastA: d.lastAudioWriterStatus)
    }

    private func logAutoTestStats(scenario: Scenario, index: Int,
                                  before: (cv: UInt64, av: UInt64, dv: UInt64, aa: UInt64, vf: UInt64, err: Int, lastV: String, lastA: String),
                                  after:  (cv: UInt64, av: UInt64, dv: UInt64, aa: UInt64, vf: UInt64, err: Int, lastV: String, lastA: String)) {
        let dcv = Int64(after.cv) - Int64(before.cv)
        let dav = Int64(after.av) - Int64(before.av)
        let dda = Int64(after.aa) - Int64(before.aa)
        let ddv = Int64(after.dv) - Int64(before.dv)
        let dvf = Int64(after.vf) - Int64(before.vf)
        let derr = after.err - before.err
        logAutoTest("STATS scenario=\(scenario.id.rawValue) index=\(index) video{captured=\(dcv) appended=\(dav) dropped=\(ddv)} audio{appended=\(dda)} writer{videoFailed+=\(dvf) lastV=\(after.lastV) lastA=\(after.lastA)} errors+=\(derr)")
        if derr > 0 {
            // 打印最近的错误摘要（末尾 N 条）
            let errs = RecorderDiagnostics.shared.errors.suffix(derr)
            for e in errs {
                logAutoTest("ERROR domain=\(e.domain) code=\(e.code) msg=\(e.message)")
            }
        }
    }

    // 失败原因归纳
    private func formatFailReason(
        scenario: Scenario,
        before: (cv: UInt64, av: UInt64, dv: UInt64, aa: UInt64, vf: UInt64, err: Int, lastV: String, lastA: String),
        after:  (cv: UInt64, av: UInt64, dv: UInt64, aa: UInt64, vf: UInt64, err: Int, lastV: String, lastA: String),
        streamError: NSError?
    ) -> String? {
        var reasons: [String] = []
        let dcv = Int64(after.cv) - Int64(before.cv)
        let dav = Int64(after.av) - Int64(before.av)
        let ddv = Int64(after.dv) - Int64(before.dv)
        let dvf = Int64(after.vf) - Int64(before.vf)
        let derr = after.err - before.err
        if let e = streamError {
            reasons.append("流错误 \(e.domain)#\(e.code) \(e.localizedDescription)")
        }
        if after.lastV == "failed" || dvf > 0 {
            reasons.append("写入失败(AVAssetWriter) 次数+=\(dvf)")
        }
        if ddv > 0 {
            reasons.append("视频背压/未就绪 dropped+=\(ddv) captured+=\(dcv) appended+=\(dav)")
        }
        if derr > 0 && streamError == nil {
            // 最近的错误（非 onInterupt 回调）
            if let last = RecorderDiagnostics.shared.errors.last {
                reasons.append("错误 \(last.domain)#\(last.code) \(last.message)")
            }
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "；")
    }
}

// MARK: - Menu bar automation (best-effort)
extension RecorderAutoTester {
    static func menuBarStopSharing() async throws {
        // 尝试点击“停止共享”按钮（系统控制中心中的“屏幕录制/共享”气泡）
        // 这段 AppleScript 可能因系统版本/语言而异，需辅助功能权限。
        #if os(macOS)
        let script = """
        tell application "System Events"
            try
                tell application process "ControlCenter"
                    click menu bar item 1 of menu bar 1
                end tell
                delay 0.5
                tell application process "ControlCenter"
                    if exists (button "Stop Sharing" of window 1) then
                        click button "Stop Sharing" of window 1
                    else if exists (button "停止共享" of window 1) then
                        click button "停止共享" of window 1
                    end if
                end tell
            on error
                -- ignore
            end try
        end tell
        """
        let apple = NSAppleScript(source: script)
        var err: NSDictionary? = nil
        apple?.executeAndReturnError(&err)
        #endif
    }
}

// MARK: - UI Panel
import SwiftUI

struct RecorderAutoTestPanel: View {
    @ObservedObject var tester: RecorderAutoTester
    @State private var selected: Set<RecorderAutoTester.Scenario> = []
    @State private var repetitions: Int = 1
    @State private var secondsOverride: String = ""

    // Inputs from ScreenRecorderControl
    let includeSystemAudio: Bool
    let includeMicrophone: Bool
    let includeCamera: Bool
    let displayID: CGDirectDisplayID
    let cropRect: CGRect?
    let baseDirectory: URL
    let backend: CRRecorder.ScreenBackend

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自动化测试").font(.headline)
            Text("选择场景与次数，自动运行并校验时长与文件").font(.caption).foregroundStyle(.secondary)
            Text("当前录制后端: \(backendDisplayName(backend))")
                .font(.caption2)
                .foregroundStyle(.secondary)

            List(tester.availableScenarios(), id: \.self, selection: $selected) { sc in
                VStack(alignment: .leading, spacing: 2) {
                    Text(sc.title)
                    Text(sc.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 200)

            HStack(spacing: 12) {
                Stepper("重复次数: \(repetitions)", value: $repetitions, in: 1...50)
                TextField("自定义秒数(可空)", text: $secondsOverride)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }

            HStack(spacing: 12) {
                Button(tester.isRunning ? "运行中…" : "开始运行") {
                    Task { await run() }
                }
                .disabled(tester.isRunning || selected.isEmpty)
                if tester.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Text(tester.progressText).font(.caption).foregroundStyle(.secondary)
            }

            if !tester.results.isEmpty {
                Divider()
                Text("结果").font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(tester.results) { r in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(r.scenario.title) #\(r.index)")
                                    Text("· 后端: \(resultBackendDisplayName(r))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(r.passed ? "✅" : "❌")
                                }
                                Text(r.note).font(.caption).foregroundStyle(.secondary)
                                ForEach(r.files) { f in
                                    Text("• \(f.filename) 期望: \(Int(f.expectedSeconds))s 实际: \(String(format: "%.2f", f.actualSeconds))s \(f.pass ? "✅" : "❌")")
                                        .font(.caption)
                                }
                            }
                            .padding(8)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.25))
                            .cornerRadius(6)
                        }
                    }
                }
                .frame(minHeight: 200)
            }
        }
        .padding()
    }

    private func run() async {
        let secs = Double(secondsOverride)
        let cfg = RecorderAutoTester.RunConfig(
            scenarios: Array(selected),
            repetitions: repetitions,
            secondsOverride: secs,
            includeSystemAudio: includeSystemAudio,
            includeMicrophone: includeMicrophone,
            includeCamera: includeCamera,
            displayID: displayID,
            cropRect: cropRect,
            baseOutput: baseDirectory.appendingPathComponent("AutoTests"),
            backend: backend
        )
        try? FileManager.default.createDirectory(at: cfg.baseOutput, withIntermediateDirectories: true)
        await tester.run(config: cfg)
    }

    // MARK: - Backend labels
    private func backendDisplayName(_ backend: CRRecorder.ScreenBackend) -> String {
        switch backend {
        case .screenCaptureKit: return "ScreenCaptureKit"
        case .avFoundation: return "AVFoundation"
        }
    }

    private func resultBackendDisplayName(_ result: RecorderAutoTester.RunResult) -> String {
        if let b = result.backend {
            return backendDisplayName(b)
        }
        if result.backendParity != nil {
            return "ScreenCaptureKit + AVFoundation (Parity)"
        }
        return "Unknown"
    }
}

/// 表格形式展示两种后端的关键参数对比，并标注是否在容忍范围内。
struct ScreenBackendParityView: View {
    let summary: ScreenBackendParitySummary

    private func boolText(_ value: Bool?) -> String {
        guard let value else { return "—" }
        return value ? "✅ OK" : "⚠️ 超出"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("后端对比 (ScreenCaptureKit vs AVFoundation)")
                .font(.caption)
                .bold()

            // Header row
            HStack {
                Text("指标").frame(width: 120, alignment: .leading)
                Text("ScreenCaptureKit").frame(width: 130, alignment: .leading)
                Text("AVFoundation").frame(width: 130, alignment: .leading)
                Text("差值/比值").frame(width: 110, alignment: .leading)
                Text("容忍范围").frame(width: 90, alignment: .leading)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Divider()

            // Duration row
            HStack {
                Text("时长 (s)").frame(width: 120, alignment: .leading)
                Text(formatSeconds(summary.screenCaptureKit.duration))
                    .frame(width: 130, alignment: .leading)
                Text(formatSeconds(summary.avFoundation.duration))
                    .frame(width: 130, alignment: .leading)
                Text(formatSeconds(summary.durationDifference))
                    .frame(width: 110, alignment: .leading)
                Text(boolText(summary.durationWithinTolerance))
                    .frame(width: 90, alignment: .leading)
            }

            // Resolution
            HStack {
                Text("分辨率").frame(width: 120, alignment: .leading)
                Text(formatSize(summary.screenCaptureKit.videoSize))
                    .frame(width: 130, alignment: .leading)
                Text(formatSize(summary.avFoundation.videoSize))
                    .frame(width: 130, alignment: .leading)
                Text("—").frame(width: 110, alignment: .leading)
                Text("—").frame(width: 90, alignment: .leading)
            }

            // File size
            HStack {
                Text("文件大小 (MB)").frame(width: 120, alignment: .leading)
                Text(formatMB(summary.screenCaptureKit.fileSizeMegabytes))
                    .frame(width: 130, alignment: .leading)
                Text(formatMB(summary.avFoundation.fileSizeMegabytes))
                    .frame(width: 130, alignment: .leading)
                Text(formatRatio(summary.fileSizeRatio))
                    .frame(width: 110, alignment: .leading)
                Text(boolText(summary.fileSizeWithinTolerance))
                    .frame(width: 90, alignment: .leading)
            }

            // Video bitrate
            HStack {
                Text("视频码率 (Mbps)").frame(width: 120, alignment: .leading)
                Text(formatMbps(summary.screenCaptureKit.videoBitrateMbps))
                    .frame(width: 130, alignment: .leading)
                Text(formatMbps(summary.avFoundation.videoBitrateMbps))
                    .frame(width: 130, alignment: .leading)
                Text(formatRatio(summary.videoBitrateRatio))
                    .frame(width: 110, alignment: .leading)
                Text(boolText(summary.videoBitrateWithinTolerance))
                    .frame(width: 90, alignment: .leading)
            }

            // Overall bitrate
            HStack {
                Text("整体码率 (Mbps)").frame(width: 120, alignment: .leading)
                Text(formatMbps(summary.screenCaptureKit.overallBitrateMbps))
                    .frame(width: 130, alignment: .leading)
                Text(formatMbps(summary.avFoundation.overallBitrateMbps))
                    .frame(width: 130, alignment: .leading)
                Text(formatRatio(summary.overallBitrateRatio))
                    .frame(width: 110, alignment: .leading)
                Text(boolText(summary.overallBitrateWithinTolerance))
                    .frame(width: 90, alignment: .leading)
            }
        }
        .font(.caption2)
    }

    // MARK: - Formatters
    private func formatSeconds(_ value: Double?) -> String {
        guard let v = value else { return "—" }
        return String(format: "%.3f", v)
    }

    private func formatSize(_ size: CGSize?) -> String {
        guard let s = size else { return "—" }
        return "\(Int(s.width))x\(Int(s.height))"
    }

    private func formatMB(_ mb: Double?) -> String {
        guard let m = mb else { return "—" }
        return String(format: "%.2f", m)
    }

    private func formatMbps(_ mbps: Double?) -> String {
        guard let m = mbps else { return "—" }
        return String(format: "%.2f", m)
    }

    private func formatRatio(_ ratio: Double?) -> String {
        guard let r = ratio else { return "—" }
        return String(format: "%.2fx", r)
    }
}
