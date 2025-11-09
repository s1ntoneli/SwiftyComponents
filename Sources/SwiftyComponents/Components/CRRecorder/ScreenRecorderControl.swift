import SwiftUI
import Foundation
import Combine

#if os(macOS)
import AppKit
import CoreGraphics
import AVFoundation
import AVKit
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
        /// Merge system audio into the screen recording
        public var captureSystemAudio: Bool
        /// Record microphone in parallel as a separate `.m4a` file
        public var includeMicrophone: Bool

        public init(
            displayID: CGDirectDisplayID = CGMainDisplayID(),
            cropRect: CGRect = CGRect(x: 0, y: 0, width: 200, height: 200),
            captureSystemAudio: Bool = false,
            includeMicrophone: Bool = false
        ) {
            self.displayID = displayID
            self.cropRect = cropRect
            self.captureSystemAudio = captureSystemAudio
            self.includeMicrophone = includeMicrophone
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
    // Persisted audio toggles
    @AppStorage("CRDemo.IncludeSystemAudio") private var persistedSystemAudio: Bool = false
    @AppStorage("CRDemo.IncludeMicrophone") private var persistedMicrophone: Bool = false
    @AppStorage("CRDemo.SelectedMicrophoneID") private var persistedMicID: String = "default"
    @AppStorage("CRDemo.IncludeCamera") private var persistedCamera: Bool = false
    @AppStorage("CRDemo.SelectedCameraID") private var persistedCamID: String = "default"
    // Content lists
    @State private var displays: [SCDisplay] = []
    @State private var windows: [SCWindow] = []
    @State private var selectedDisplayID: Int? = nil
    @State private var selectedWindowID: Int? = nil
    // Microphones
    @State private var microphones: [AVCaptureDevice] = []
    @State private var selectedMicrophoneID: String? = nil
    // Cameras
    @State private var cameras: [AVCaptureDevice] = []
    @State private var selectedCameraID: String? = nil

    // Keep a reference while recording
    @State private var recorder: CRRecorder? = nil
    // Player sheet state
    @State private var showPlayer: Bool = false
    @State private var avPlayer: AVPlayer? = nil
    @State private var playerTitle: String = ""
    // Per-session directories (avoid bundle.json being overwritten)
    @State private var currentSessionDirectory: URL? = nil
    @State private var lastBundleDirectory: URL? = nil

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

            // Capture options (persisted)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Toggle("System Audio", isOn: $persistedSystemAudio)
                        .accessibilityIdentifier("CRRecorder.Toggle.SystemAudio")
                    Toggle("Microphone", isOn: $persistedMicrophone)
                        .accessibilityIdentifier("CRRecorder.Toggle.Microphone")
                    Toggle("Camera", isOn: $persistedCamera)
                        .accessibilityIdentifier("CRRecorder.Toggle.Camera")
                }
                if persistedMicrophone {
                    HStack(spacing: 8) {
                        Text("Mic:")
                        Picker("Microphone", selection: Binding(get: {
                            selectedMicrophoneID ?? persistedMicID
                        }, set: { newID in
                            selectedMicrophoneID = newID
                            persistedMicID = newID
                        })) {
                            Text("系统默认").tag("default")
                            ForEach(microphones, id: \.uniqueID) { d in
                                Text(d.localizedName).tag(d.uniqueID)
                            }
                        }
                        .frame(minWidth: 220)
                        .accessibilityIdentifier("CRRecorder.Picker.Microphone")
                    }
                }
                if persistedCamera {
                    HStack(spacing: 8) {
                        Text("Cam:")
                        Picker("Camera", selection: Binding(get: {
                            selectedCameraID ?? persistedCamID
                        }, set: { newID in
                            selectedCameraID = newID
                            persistedCamID = newID
                        })) {
                            Text("系统默认").tag("default")
                            ForEach(cameras, id: \.uniqueID) { d in
                                Text(d.localizedName).tag(d.uniqueID)
                            }
                        }
                        .frame(minWidth: 220)
                        .accessibilityIdentifier("CRRecorder.Picker.Camera")
                    }
                }
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

                if isBusy { ProgressView().controlSize(.small) }

                // 同时显示“点击计时”和“内容计时”两条信息
                if isRecording {
                    VStack(alignment: .leading, spacing: 2) {
                        if let clickStart = recordStartAt {
                            Text("点击时长: \(formatElapsed(since: clickStart, now: tick))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("CRRecorder.ClickElapsed")
                        } else {
                            Text("点击时长: 00:00")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("CRRecorder.ClickElapsed")
                        }
                        if let contentStart = (contentFirstFrameAt ?? recordStartAt) {
                            Text("内容时长: \(formatElapsed(since: contentStart, now: tick))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("CRRecorder.ContentElapsed")
                        } else {
                            Text("内容时长: 00:00")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("CRRecorder.ContentElapsed")
                        }
                    }
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
                                    Button("Play") { playLogItem(item) }
                                        .accessibilityIdentifier("CRRecorder.History.Play")
                                    Button("Play Session") { playSession(for: item) }
                                        .accessibilityIdentifier("CRRecorder.History.PlaySession")
                                    Button("Play Cam+Mic") { playCamMic(for: item) }
                                        .accessibilityIdentifier("CRRecorder.History.PlayCamMic")
                                    Button("Export Session") { exportSession(for: item) }
                                        .accessibilityIdentifier("CRRecorder.History.ExportSession")
                                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: item.filePath)) }
                                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.filePath)]) }
                                }
                                HStack(spacing: 12) {
                                    if let s = item.clickDurationSeconds { Text("点击时长: \(formatSeconds(s))").font(.caption) }
                                    if let v = item.videoDurationSeconds { Text("文件时长: \(formatSeconds(v))").font(.caption) }
                                    if let off = item.offsetSeconds {
                                        Text(String(format: "偏移: %.2fs", off)).font(.caption)
                                    }
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
        .sheet(isPresented: $showDiagnostics) { RecorderDiagnosticsView() }
        .sheet(isPresented: $showPlayer, onDismiss: { avPlayer?.pause() }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(playerTitle).font(.headline).lineLimit(1).truncationMode(.middle)
                if let p = avPlayer {
                    VideoPlayer(player: p)
                        .frame(minWidth: 640, minHeight: 360)
                        .onAppear { p.play() }
                } else {
                    Text("无法加载播放器").foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .onAppear {
            // Prefill a timestamped name so users don't need to type
            if fileName.isEmpty || !isRecording { fileName = Self.timestampedFilenamePrefix("capture") }
            // Seed persisted toggles from configuration on first appear only
            if configuration.captureSystemAudio && !persistedSystemAudio { persistedSystemAudio = true }
            if configuration.includeMicrophone && !persistedMicrophone { persistedMicrophone = true }
            reloadMicrophones()
            reloadCameras()
            if selectedMicrophoneID == nil { selectedMicrophoneID = persistedMicID }
            if selectedCameraID == nil { selectedCameraID = persistedCamID }
            loadLogs()
        }
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

        // Always generate a fresh timestamped base name
        fileName = Self.timestampedFilenamePrefix("capture")
        // Create a per-session subdirectory so bundle.json won't be overwritten by later sessions
        let sessionDir = outputDirectory.appendingPathComponent(fileName)
        do { try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true) } catch { }
        currentSessionDirectory = sessionDir

        // Build primary scheme
        let scheme: CRRecorder.SchemeItem
        if mode == .window {
            guard let widInt = selectedWindowID ?? Int(windowIDText) else { errorMessage = "Please select a window"; return }
            scheme = .window(displayId: 0, windowID: CGWindowID(widInt), hdr: hdr, captureSystemAudio: (persistedSystemAudio || configuration.captureSystemAudio), filename: fileName)
        } else {
            let dispID: CGDirectDisplayID = selectedDisplayID.map { CGDirectDisplayID($0) } ?? configuration.displayID
            scheme = .display(displayID: dispID, area: configuration.cropRect, hdr: hdr, captureSystemAudio: (persistedSystemAudio || configuration.captureSystemAudio), filename: fileName, excludedWindowTitles: [])
        }

        // Build full schemes list (microphone optional)
        var schemes: [CRRecorder.SchemeItem] = [scheme]
        if persistedMicrophone || configuration.includeMicrophone {
            // Use default microphone; save as separate audio file with -mic suffix
            let micName = fileName + "-mic"
            let micID = selectedMicrophoneID ?? persistedMicID
            schemes.append(.microphone(microphoneID: micID.isEmpty ? "default" : micID, filename: micName))
        }
        if persistedCamera {
            let camName = fileName + "-cam"
            let camID = selectedCameraID ?? persistedCamID
            schemes.append(.camera(cameraID: camID.isEmpty ? "default" : camID, filename: camName))
        }

        let rec = CRRecorder(schemes, outputDirectory: sessionDir)
        // Pass options
        var opts = ScreenRecorderOptions(
            fps: fps,
            queueDepth: Int(queueDepthText),
            targetBitRate: Int(targetBitrateText),
            includeAudio: (persistedSystemAudio || configuration.captureSystemAudio),
            showsCursor: showsCursor,
            hdr: hdr,
            useHEVC: useHEVC
        )
        rec.screenOptions = opts
        rec.onInterupt = { err in
            DispatchQueue.main.async { self.handleInterruption(err) }
        }

        do {
            try await rec.prepare(schemes)
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
            lastBundleDirectory = result.bundleURL
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
        let base = lastBundleDirectory ?? currentSessionDirectory ?? outputDirectory
        let url = base.appendingPathComponent(last)
        NSWorkspace.shared.open(url)
    }

    private func revealLatestFile() {
        guard let last = lastSavedFiles.last else { return }
        let base = lastBundleDirectory ?? currentSessionDirectory ?? outputDirectory
        let url = base.appendingPathComponent(last)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func playLogItem(_ item: RecordingLogItem) {
        let url = URL(fileURLWithPath: item.filePath)
        playerTitle = url.lastPathComponent
        avPlayer = AVPlayer(url: url)
        showPlayer = true
    }

    private func playSession(for item: RecordingLogItem) {
        let fileURL = URL(fileURLWithPath: item.filePath)
        let dir = fileURL.deletingLastPathComponent()
        let bundleURL = dir.appendingPathComponent("bundle.json")
        do {
            let data = try Data(contentsOf: bundleURL)
            let info = try JSONDecoder().decode(CRRecorder.BundleInfo.self, from: data)
            // 摄像头为主，屏幕作为 PiP，PiP 稍大一些
            let opts = MediaCompositionBuilder.Options(includeScreen: true, includeCamera: true, includeMicrophone: true, pipScale: 0.4, pipMargin: 16, background: .camera)
            let out = try MediaCompositionBuilder.build(from: .init(bundleInfo: info, baseDirectory: dir), options: opts)
            let pItem = AVPlayerItem(asset: out.composition)
            pItem.videoComposition = out.videoComposition
            playerTitle = "Session Composition"
            avPlayer = AVPlayer(playerItem: pItem)
            showPlayer = true
        } catch {
            // 回退：打开单文件
            playLogItem(item)
        }
    }

    private func playCamMic(for item: RecordingLogItem) {
        let fileURL = URL(fileURLWithPath: item.filePath)
        let dir = fileURL.deletingLastPathComponent()
        let bundleURL = dir.appendingPathComponent("bundle.json")
        do {
            let data = try Data(contentsOf: bundleURL)
            let info = try JSONDecoder().decode(CRRecorder.BundleInfo.self, from: data)
            let out = try MediaCompositionBuilder.build(from: .init(bundleInfo: info, baseDirectory: dir), options: .camMicOnly)
            let pItem = AVPlayerItem(asset: out.composition)
            pItem.videoComposition = out.videoComposition
            playerTitle = "Camera+Mic Composition"
            avPlayer = AVPlayer(playerItem: pItem)
            showPlayer = true
        } catch {
            playLogItem(item)
        }
    }

    private func exportSession(for item: RecordingLogItem) {
        let fileURL = URL(fileURLWithPath: item.filePath)
        let dir = fileURL.deletingLastPathComponent()
        let bundleURL = dir.appendingPathComponent("bundle.json")
        do {
            let data = try Data(contentsOf: bundleURL)
            let info = try JSONDecoder().decode(CRRecorder.BundleInfo.self, from: data)
            let opts = MediaCompositionBuilder.Options(includeScreen: true, includeCamera: true, includeMicrophone: true, pipScale: 0.4, pipMargin: 16, background: .camera)
            let out = try MediaCompositionBuilder.build(from: .init(bundleInfo: info, baseDirectory: dir), options: opts)
            guard let exporter = AVAssetExportSession(asset: out.composition, presetName: AVAssetExportPresetHighestQuality) else { return }
            exporter.videoComposition = out.videoComposition
            var target = dir.appendingPathComponent(Self.timestampedFilenamePrefix("merged")).appendingPathExtension("mov")
            // ensure unique name
            var i = 1
            while FileManager.default.fileExists(atPath: target.path) {
                let stem = target.deletingPathExtension().lastPathComponent
                let base = stem + " (\(i))"
                target.deletePathExtension()
                target.deleteLastPathComponent()
                target = dir.appendingPathComponent(base).appendingPathExtension("mov")
                i += 1
            }
            exporter.outputURL = target
            exporter.outputFileType = .mov
            exporter.exportAsynchronously {
                DispatchQueue.main.async {
                    if exporter.status == .completed {
                        NSWorkspace.shared.activateFileViewerSelecting([target])
                    } else if let err = exporter.error {
                        self.errorMessage = err.localizedDescription
                    } else {
                        self.errorMessage = "Export failed"
                    }
                }
            }
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func reloadMicrophones() {
        #if os(macOS)
        microphones = AVCaptureDevice.devices(for: .audio)
        #else
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone], mediaType: .audio, position: .unspecified).devices
        #endif
    }

    private func reloadCameras() {
        #if os(macOS)
        cameras = AVCaptureDevice.devices(for: .video)
        #else
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
        #endif
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
                self.lastBundleDirectory = result.bundleURL
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
        let base = lastBundleDirectory ?? currentSessionDirectory ?? outputDirectory
        let url = base.appendingPathComponent(name)
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
    private func loadLogs() {
        logs = currentStore().load().sorted(by: { lhs, rhs in
            let l = lhs.endedAt ?? lhs.startedAt ?? .distantPast
            let r = rhs.endedAt ?? rhs.startedAt ?? .distantPast
            return l > r
        })
    }
    private func saveLogs() { currentStore().save(logs) }
    private func appendAndPersistLog() {
        guard !lastSavedFiles.isEmpty else { return }
        // 从 bundle.json 读取每个文件的开始时间，计算相对最早开始时间的偏移
        let sessionBase = lastBundleDirectory ?? currentSessionDirectory ?? outputDirectory
        let bundleURL = sessionBase.appendingPathComponent("bundle.json")
        var fileStartMap: [String: (start: CFAbsoluteTime?, end: CFAbsoluteTime?)] = [:]
        var earliest: CFAbsoluteTime? = nil
        if let data = try? Data(contentsOf: bundleURL) {
            let dec = JSONDecoder()
            if let info = try? dec.decode(CRRecorder.BundleInfo.self, from: data) {
                for f in info.files {
                    fileStartMap[f.filename] = (f.recordingStartTimestamp, f.recordingEndTimestamp)
                    if let s = f.recordingStartTimestamp {
                        earliest = min(earliest ?? s, s)
                    }
                }
            }
        }
        let clickEnded = Date()
        let click = recordStartAt.map { clickEnded.timeIntervalSince($0) }
        // 逐个保存历史项
        for name in lastSavedFiles {
            let pathURL = sessionBase.appendingPathComponent(name)
            // 读取文件时长
            var video: TimeInterval? = nil
            let asset = AVURLAsset(url: pathURL)
            if let dur = try? awaitDuration(asset) { video = dur }

            // 偏移：文件开始时间相对最早开始时间
            var off: Double? = nil
            if let base = earliest, let rec = fileStartMap[name]?.start { off = rec - base }
            // startedAt/endedAt（使用录制时间戳转换为 Date；如缺失则使用点击时间）
            let startedAt: Date? = {
                if let s = fileStartMap[name]?.start { return Date(timeIntervalSinceReferenceDate: s) }
                return recordStartAt
            }()
            let endedAt: Date? = {
                if let e = fileStartMap[name]?.end { return Date(timeIntervalSinceReferenceDate: e) }
                return clickEnded
            }()

            let item = RecordingLogItem(
                filePath: pathURL.path,
                startedAt: startedAt,
                endedAt: endedAt,
                clickDurationSeconds: click,
                videoDurationSeconds: video,
                offsetSeconds: off,
                note: ""
            )
            logs.append(item)
        }
        // 时间倒序排序并保存
        logs.sort(by: { lhs, rhs in
            let l = lhs.endedAt ?? lhs.startedAt ?? .distantPast
            let r = rhs.endedAt ?? rhs.startedAt ?? .distantPast
            return l > r
        })
        saveLogs()
    }

    // 同步加载 AVURLAsset 时长（秒）
    private func awaitDuration(_ asset: AVURLAsset) -> TimeInterval? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: TimeInterval? = nil
        asset.loadValuesAsynchronously(forKeys: ["duration"]) {
            var error: NSError? = nil
            let status = asset.statusOfValue(forKey: "duration", error: &error)
            if status == .loaded {
                let sec = CMTimeGetSeconds(asset.duration)
                if sec.isFinite { result = sec }
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
        return result
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
