import Foundation
import AVFoundation

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
        let note: String
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
            .init(id: .untilInterrupted, title: "直到系统打断", summary: "不设时长，等待系统/用户停止共享后收尾并统计关键数据", defaultSeconds: 0)
        ]
    }

    func run(config: RunConfig) async {
        guard !isRunning else { return }
        isRunning = true
        results.removeAll()
        defer { isRunning = false }

        // Log run header for easier automation parsing
        logAutoTest("START scenarios=\(config.scenarios.count) reps=\(config.repetitions) secondsOverride=\(config.secondsOverride?.description ?? "nil") systemAudio=\(config.includeSystemAudio) mic=\(config.includeMicrophone) cam=\(config.includeCamera) display=\(config.displayID) crop=\(config.cropRect?.debugDescription ?? "nil") base=\(config.baseOutput.path)")

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
                    let dir = config.baseOutput
                    let failed = RunResult(scenario: scenario, index: i, sessionDir: dir, files: [], passed: false, note: error.localizedDescription)
                    results.append(failed)
                    logRunResult(failed)
                }
            }
        }

        // Final summary
        logSummary()
    }

    private func runOne(scenario: Scenario, index: Int, config: RunConfig) async throws -> RunResult? {
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

        if includeScreen {
            schemes.append(.display(displayID: config.displayID, area: config.cropRect, hdr: false, captureSystemAudio: captureSystemAudio, filename: dirName, excludedWindowTitles: []))
        }
        if wantMic { schemes.append(.microphone(microphoneID: "default", filename: dirName + "-mic")) }
        if wantCam { schemes.append(.camera(cameraID: "default", filename: dirName + "-cam")) }

        let rec = CRRecorder(schemes, outputDirectory: sessionDir)
        // 捕获屏幕流错误，用于失败时标注具体原因
        var lastStreamError: NSError? = nil
        rec.onInterupt = { err in lastStreamError = err as NSError }
        var opts = ScreenRecorderOptions(
            fps: 60,
            queueDepth: nil,
            targetBitRate: nil,
            includeAudio: captureSystemAudio,
            showsCursor: true,
            hdr: false,
            useHEVC: false
        )
        switch scenario.id {
        case .highFPS120: opts.fps = 120
        case .lowFPS15: opts.fps = 15
        case .hevcHDR: opts.hdr = true; opts.useHEVC = true
        case .cursorOn: opts.showsCursor = true
        case .cursorOff: opts.showsCursor = false
        default: break
        }
        rec.screenOptions = opts
        try await rec.prepare(schemes)
        try await rec.startRecording()

        // 基线诊断快照（用于本轮统计增量）
        let diagBefore = diagSnapshot()

        let seconds = config.secondsOverride ?? scenario.defaultSeconds
        let start = CFAbsoluteTimeGetCurrent()

        // Scenario-specific action
        switch scenario.id {
        case .externalStop:
            // 尝试通过菜单栏“停止共享”结束（需要辅助功能权限）
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
            try? await Self.menuBarStopSharing()
        case .untilInterrupted:
            // 不主动停止：等待系统/用户从外部停止共享（SCStream -3821）
            // 通过 CRRecorder.onInterupt 回调触发收尾，并记录关键指标
            let startWall = CFAbsoluteTimeGetCurrent()
            let interrupted: (CRRecorder.Result?, Error) = await withCheckedContinuation { (cont: CheckedContinuation<(CRRecorder.Result?, Error), Never>) in
                rec.onInterupt = { err in
                    Task.detached(priority: .userInitiated) {
                        let result = try? await rec.stopRecordingWithResult()
                        cont.resume(returning: (result, err))
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
                return RunResult(scenario: scenario, index: index, sessionDir: sessionDir, files: checks, passed: true, note: note)
            } else {
                return RunResult(scenario: scenario, index: index, sessionDir: sessionDir, files: [], passed: true, note: note)
            }
        case .stress10, .shortQuick, .staticLong, .micOnly, .camOnly, .highFPS120, .lowFPS15, .hevcHDR, .noAudio, .cursorOn, .cursorOff, .long60s, .camMicBoth:
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
        case .beforeFirstFrame:
            // 尽快停止，触发“未收到首帧”的收尾路径
            try? await Task.sleep(nanoseconds: 10_000_000) // ~0.01s
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
        return RunResult(scenario: scenario, index: index, sessionDir: sessionDir, files: checks, passed: allPass, note: note)
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
        let header = "scenario=\(r.scenario.id.rawValue) index=\(r.index) passed=\(r.passed) note=\(r.note) dir=\(r.sessionDir.lastPathComponent)"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自动化测试").font(.headline)
            Text("选择场景与次数，自动运行并校验时长与文件").font(.caption).foregroundStyle(.secondary)

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
            baseOutput: baseDirectory.appendingPathComponent("AutoTests")
        )
        try? FileManager.default.createDirectory(at: cfg.baseOutput, withIntermediateDirectories: true)
        await tester.run(config: cfg)
    }
}
