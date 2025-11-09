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
            .init(id: .camMicBoth, title: "摄像头+麦克风", summary: "强制同时录制摄像头和麦克风，3s", defaultSeconds: 3)
        ]
    }

    func run(config: RunConfig) async {
        guard !isRunning else { return }
        isRunning = true
        results.removeAll()
        defer { isRunning = false }

        var counter = 0
        for scenario in config.scenarios {
            let reps = scenario.id == .stress10 ? max(config.repetitions, 10) : config.repetitions
            for i in 1...reps {
                counter += 1
                self.progressText = "运行: \(scenario.title) [\(i)/\(reps)]"
                do {
                    if let r = try await runOne(scenario: scenario, index: i, config: config) {
                        results.append(r)
                    }
                } catch {
                    let dir = config.baseOutput
                    results.append(RunResult(scenario: scenario, index: i, sessionDir: dir, files: [], passed: false, note: error.localizedDescription))
                }
            }
        }
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

        let seconds = config.secondsOverride ?? scenario.defaultSeconds
        let start = CFAbsoluteTimeGetCurrent()

        // Scenario-specific action
        switch scenario.id {
        case .externalStop:
            // 尝试通过菜单栏“停止共享”结束（需要辅助功能权限）
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
            try? await Self.menuBarStopSharing()
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
            // 采用更稳健的加载（避免直接读取 .duration 的过期 API 提示）
            let dur = CMTimeGetSeconds(asset.duration)
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
        let note = "耗时: \(String(format: "%.2f", end - start))s"
        return RunResult(scenario: scenario, index: index, sessionDir: sessionDir, files: checks, passed: allPass, note: note)
    }

    private static func timestamped(_ base: String) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return base + "-" + df.string(from: Date())
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
