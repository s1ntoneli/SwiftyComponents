import SwiftUI
import Foundation
import Combine

#if os(macOS)
import AppKit
import CoreGraphics
import AVFoundation
@preconcurrency import ScreenCaptureKit

/// A simple control to start/stop screen recording using CRRecorder.
///
/// - Records the top-left 200x200 area of the main display by default.
/// - Allows choosing the output directory and opening it in Finder.
/// - Provides a quick entry to `RecorderDiagnosticsView`.
public struct ScreenRecorderControl: View {
    @ObservedObject private var diag = RecorderDiagnostics.shared
    /// Public configuration for the control.
    public struct Configuration: Equatable, Sendable {
        public var displayID: CGDirectDisplayID
        public var cropRect: CGRect
        public var captureSystemAudio: Bool

        public init(
            displayID: CGDirectDisplayID = CGMainDisplayID(),
            cropRect: CGRect = CGRect(x: 0, y: 0, width: 200, height: 200),
            captureSystemAudio: Bool = false
        ) {
            self.displayID = displayID
            self.cropRect = cropRect
            self.captureSystemAudio = captureSystemAudio
        }
    }

    // MARK: - Public API
    public let configuration: Configuration
    public let onComplete: ((CRRecorder.Result) -> Void)?

    // MARK: - State
    @State private var outputDirectory: URL
    @State private var isRecording: Bool = false
    @State private var isBusy: Bool = false
    @State private var lastSavedFiles: [String] = []
    @State private var showDiagnostics: Bool = false
    @State private var errorMessage: String? = nil
    @State private var recordStartAt: Date? = nil
    @State private var tick: Date = Date()
    @State private var contentFirstFrameAt: Date? = nil
    @State private var latestFileDuration: TimeInterval? = nil
    @State private var logs: [RecordingLogItem] = []
    @State private var fileName: String = "capture"
    enum Mode: String, CaseIterable { case display = "Display", window = "Window" }
    @State private var mode: Mode = .display
    @State private var windowIDText: String = ""
    @State private var fps: Int = 60
    @State private var showsCursor: Bool = false
    @State private var useHEVC: Bool = false
    @State private var hdr: Bool = false
    @State private var queueDepthText: String = ""
    @State private var targetBitrateText: String = ""
    // Content lists
    @State private var displays: [SCDisplay] = []
    @State private var windows: [SCWindow] = []
    @State private var selectedDisplayID: Int? = nil
    @State private var selectedWindowID: Int? = nil

    // Keep a reference while recording
    @State private var recorder: CRRecorder? = nil

    // MARK: - Init
    public init(
        configuration: Configuration = .init(),
        outputDirectory: URL? = nil,
        onComplete: ((CRRecorder.Result) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.onComplete = onComplete
        self._outputDirectory = State(initialValue: outputDirectory ?? Self.defaultOutputDirectory())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Text("Screen Recorder").font(.headline)
                statusDot(isOn: isRecording, label: isRecording ? "Recording" : "Idle")
                Spacer()
                Button("Diagnostics") { showDiagnostics = true }
                    .accessibilityIdentifier("CRRecorder.Diagnostics")
            }
            .onReceive(timer) { now in
                self.tick = now
            }

            // Output directory controls
            HStack(spacing: 8) {
                Text(outputDirectory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("CRRecorder.OutputPath")
                Spacer()
                Button("Choose Folder…", action: chooseFolder)
                    .accessibilityIdentifier("CRRecorder.ChooseFolder")
                Button("Open Folder", action: openFolder)
                    .accessibilityIdentifier("CRRecorder.OpenFolder")
            }

            // Naming + mode
            HStack(spacing: 8) {
                TextField("File name (no extension)", text: $fileName)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Button("Refresh") { Task { await reloadContent() } }
                    .buttonStyle(.bordered)
            }

            // Pickers for display/window
            if mode == .display {
                HStack(spacing: 8) {
                    Text("Display:")
                    Picker("Display", selection: Binding(get: { selectedDisplayID ?? displays.first.map { Int($0.displayID) } }, set: { selectedDisplayID = $0 })) {
                        ForEach(displays, id: \.displayID) { d in
                            Text("Display #\(d.displayID)").tag(Int(d.displayID) as Int?)
                        }
                    }
                    .frame(width: 240)
                }
            } else {
                HStack(spacing: 8) {
                    Text("Window:")
                    Picker("Window", selection: Binding(get: { selectedWindowID }, set: { selectedWindowID = $0 })) {
                        ForEach(windows, id: \.windowID) { w in
                            let title = (w.title?.isEmpty == false ? w.title! : "Untitled")
                            Text(title).tag(Int(w.windowID) as Int?)
                        }
                    }
                    .frame(width: 360)
                }
            }

            // Options
            HStack(spacing: 12) {
                Stepper("FPS: \(fps)", value: $fps, in: 1...240)
                Toggle("Cursor", isOn: $showsCursor)
                Toggle("HEVC", isOn: $useHEVC)
                Toggle("HDR", isOn: $hdr)
                TextField("QueueDepth", text: $queueDepthText)
                    .frame(width: 100)
                    .textFieldStyle(.roundedBorder)
                TextField("Bitrate(bps)", text: $targetBitrateText)
                    .frame(width: 140)
                    .textFieldStyle(.roundedBorder)
            }

            // Start / Stop controls
            HStack(spacing: 8) {
                Button {
                    Task { await start() }
                } label: {
                    Text("Start Recording")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRecording || isBusy)
                .accessibilityIdentifier("CRRecorder.Start")

                Button {
                    Task { await stop() }
                } label: {
                    Text("Stop")
                }
                .buttonStyle(.bordered)
                .disabled(!isRecording || isBusy)
                .accessibilityIdentifier("CRRecorder.Stop")

                if isBusy {
                    ProgressView().controlSize(.small)
                }
                // 测试阶段：以“按钮点击开始”的时间为基准显示内容时长
                if let start = recordStartAt, isRecording {
                    Text("内容时长: \(formatElapsed(since: start, now: tick))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CRRecorder.ContentElapsed")
                } else if isRecording {
                    Text("内容时长: 00:00")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CRRecorder.ContentElapsed")
                }
            }

            if !lastSavedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Saved")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Open Latest") { openLatestFile() }
                            .accessibilityIdentifier("CRRecorder.OpenLatest")
                        Button("Reveal Latest") { revealLatestFile() }
                            .accessibilityIdentifier("CRRecorder.RevealLatest")
                    }
                    if let sec = latestFileDuration {
                        Text("文件时长: \(formatSeconds(sec))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("CRRecorder.FileDuration")
                    }
                    ForEach(lastSavedFiles, id: \.self) { name in
                        Text(name).font(.caption).lineLimit(1).truncationMode(.middle)
                    }
                }
            }

            if let msg = errorMessage {
                Text(msg).foregroundStyle(.red).font(.caption)
            }

            if !logs.isEmpty {
                Divider()
                Text("History").font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach($logs) { $item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(URL(fileURLWithPath: item.filePath).lastPathComponent)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: item.filePath)) }
                                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.filePath)]) }
                                }
                                HStack(spacing: 12) {
                                    if let s = item.clickDurationSeconds { Text("点击时长: \(formatSeconds(s))").font(.caption) }
                                    if let v = item.videoDurationSeconds { Text("文件时长: \(formatSeconds(v))").font(.caption) }
                                }
                                HStack(spacing: 8) {
                                    Text("备注:").font(.caption)
                                    TextField("输入备注…", text: $item.note)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: item.note) { _ in saveLogs() }
                                }
                            }
                            .padding(8)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.25))
                            .cornerRadius(6)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 300)
                .accessibilityIdentifier("CRRecorder.History.List")
            }
        }
        .padding()
        .sheet(isPresented: $showDiagnostics) {
            RecorderDiagnosticsView()
        }
        .onAppear { loadLogs() }
        .task { await reloadContent() }
        .onReceive(diag.$lastFrameWallTime) { t in
            if isRecording, contentFirstFrameAt == nil, let t { contentFirstFrameAt = t }
        }
        .onChange(of: lastSavedFiles) { _ in
            Task { await updateLatestFileDuration() }
        }
        .onChange(of: outputDirectory) { _ in loadLogs() }
        .accessibilityIdentifier("ScreenRecorderControl")
    }

    // MARK: - Actions
    @MainActor private func start() async {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil

        // Build scheme
        let scheme: CRRecorder.SchemeItem
        if mode == .window {
            guard let widInt = selectedWindowID ?? Int(windowIDText) else { errorMessage = "Please select a window"; return }
            scheme = .window(displayId: 0, windowID: CGWindowID(widInt), hdr: hdr, captureSystemAudio: configuration.captureSystemAudio, filename: fileName)
        } else {
            let dispID: CGDirectDisplayID = selectedDisplayID.map { CGDirectDisplayID($0) } ?? configuration.displayID
            scheme = .display(displayID: dispID, area: configuration.cropRect, hdr: hdr, captureSystemAudio: configuration.captureSystemAudio, filename: fileName)
        }

        let rec = CRRecorder([scheme], outputDirectory: outputDirectory)
        // Pass options
        var opts = ScreenRecorderOptions(
            fps: fps,
            queueDepth: Int(queueDepthText),
            targetBitRate: Int(targetBitrateText),
            includeAudio: configuration.captureSystemAudio,
            showsCursor: showsCursor,
            hdr: hdr,
            useHEVC: useHEVC
        )
        rec.screenOptions = opts
        rec.onInterupt = { err in
            DispatchQueue.main.async { self.handleInterruption(err) }
        }

        do {
            try await rec.prepare([scheme])
            try await rec.startRecording()
            recorder = rec
            isRecording = true
            recordStartAt = Date()
            contentFirstFrameAt = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func stop() async {
        guard let rec = recorder else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await rec.stopRecordingWithResult()
            isRecording = false
            lastSavedFiles = result.bundleInfo.files.map { $0.filename }
            onComplete?(result)
            await updateLatestFileDuration()
            appendAndPersistLog()
        } catch {
            errorMessage = error.localizedDescription
        }
        recorder = nil
        recordStartAt = nil
        contentFirstFrameAt = nil
    }

    // MARK: - Helpers
    private static func defaultOutputDirectory() -> URL {
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("SwiftyRecordings")
    }

    private static func timestampedFilenamePrefix(_ base: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "\(base)-\(df.string(from: Date()))"
    }

    private func statusDot(isOn: Bool, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(isOn ? Color.green : Color.red).frame(width: 10, height: 10)
            Text(label).foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Output Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.begin { resp in
            if resp == .OK, let url = panel.url { self.outputDirectory = url }
        }
    }

    private func openFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([outputDirectory])
    }

    private func openLatestFile() {
        guard let last = lastSavedFiles.last else { return }
        let url = outputDirectory.appendingPathComponent(last)
        NSWorkspace.shared.open(url)
    }

    private func revealLatestFile() {
        guard let last = lastSavedFiles.last else { return }
        let url = outputDirectory.appendingPathComponent(last)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func handleInterruption(_ err: Error) {
        errorMessage = err.localizedDescription
        guard isRecording, let rec = recorder else { return }
        isBusy = true
        Task { @MainActor in
            defer { self.isBusy = false }
            do {
                let result = try await rec.stopRecordingWithResult()
                self.isRecording = false
                self.lastSavedFiles = result.bundleInfo.files.map { $0.filename }
                self.onComplete?(result)
                await self.updateLatestFileDuration()
                self.appendAndPersistLog()
            } catch {
                self.errorMessage = error.localizedDescription
                self.isRecording = false
                // Ensure a log entry exists even if file list is empty
                if self.lastSavedFiles.isEmpty {
                    self.lastSavedFiles = [self.fileName + ".mov"]
                    self.appendAndPersistLog()
                }
            }
            self.recorder = nil
            self.recordStartAt = nil
            self.contentFirstFrameAt = nil
        }
    }

    private var timer: Publishers.Autoconnect<Timer.TimerPublisher> { Timer.publish(every: 1.0, on: .main, in: .common).autoconnect() }

    private func formatElapsed(since start: Date, now: Date) -> String {
        let interval = Int(max(0, now.timeIntervalSince(start)))
        let h = interval / 3600
        let m = (interval % 3600) / 60
        let s = interval % 60
        if h > 0 { return String(format: "%02d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%02d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    @MainActor private func updateLatestFileDuration() async {
        guard let name = lastSavedFiles.last else { latestFileDuration = nil; return }
        let url = outputDirectory.appendingPathComponent(name)
        let asset = AVURLAsset(url: url)
        do {
            let time = try await asset.load(.duration)
            let sec = CMTimeGetSeconds(time)
            if sec.isFinite { latestFileDuration = sec } else { latestFileDuration = nil }
        } catch {
            latestFileDuration = nil
        }
    }

    // MARK: - Logs
    private func currentStore() -> RecordingLogStore { RecordingLogStore(directory: outputDirectory) }
    private func loadLogs() { logs = currentStore().load() }
    private func saveLogs() { currentStore().save(logs) }
    private func appendAndPersistLog() {
        guard let fileName = lastSavedFiles.last else { return }
        let path = outputDirectory.appendingPathComponent(fileName).path
        let started = recordStartAt
        let ended = Date()
        let click = recordStartAt.map { ended.timeIntervalSince($0) }
        let video = latestFileDuration
        let item = RecordingLogItem(filePath: path, startedAt: started, endedAt: ended, clickDurationSeconds: click, videoDurationSeconds: video, note: "")
        logs.append(item)
        saveLogs()
    }

    // MARK: - Content loading
    private func reloadContent() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
                let newDisplays = content?.displays ?? []
                let newWindows = content?.windows ?? []
                DispatchQueue.main.async {
                    if error == nil {
                        self.displays = newDisplays
                        self.windows = newWindows.filter { ($0.title ?? "").isEmpty == false }
                        if selectedDisplayID == nil { selectedDisplayID = displays.first.map { Int($0.displayID) } }
                    } else {
                        self.errorMessage = error?.localizedDescription ?? "Failed to fetch shareable content"
                    }
                    cont.resume()
                }
            }
        }
    }
}

#Preview("Control") {
    ScreenRecorderControl()
        .frame(width: 520)
}

#endif
