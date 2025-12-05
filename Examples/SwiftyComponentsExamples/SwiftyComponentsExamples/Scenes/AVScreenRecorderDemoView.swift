import SwiftUI
import SwiftyComponents

#if os(macOS)
import AppKit
import CoreGraphics
import AVFoundation

struct AVScreenRecorderDemoView: View {
    private enum Mode: String, CaseIterable {
        case display = "Display"
        case window = "Window"
    }

    private struct DisplayItem: Identifiable {
        let id: CGDirectDisplayID
        let name: String
    }

    private struct WindowItem: Identifiable {
        let id: CGWindowID
        let title: String
        let bounds: CGRect
    }

    @State private var recorder: AVScreenRecorder?
    @State private var isRecording: Bool = false
    @State private var isBusy: Bool = false
    @State private var outputDirectory: URL = Self.defaultOutputDirectory()
    @State private var fileName: String = "av-capture"
    @State private var lastResult: AVScreenRecorder.Result?
    @State private var errorMessage: String?

    // Capture mode & targets
    @State private var mode: Mode = .display
    @State private var displays: [DisplayItem] = []
    @State private var selectedDisplayID: CGDirectDisplayID? = nil
    @State private var windows: [WindowItem] = []
    @State private var selectedWindowID: CGWindowID? = nil

    // Crop rect (manual area)
    @State private var useCropRect: Bool = false
    @State private var cropXText: String = ""
    @State private var cropYText: String = ""
    @State private var cropWidthText: String = ""
    @State private var cropHeightText: String = ""

    // Audio capture is not supported in this AVScreenRecorder demo.
    // Use CRRecorder / ScreenRecorderControl for system audio + microphone.

    // Parity test (ScreenCaptureKit vs AVFoundation)
    @State private var parityDurationText: String = "600" // seconds (default 10 minutes)
    @State private var isRunningParityTest: Bool = false
    @State private var parityResult: ParityResult?
    @State private var parityErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            outputControls
            modeControls
            targetSelection
            cropControls
            parityTestSection
            recordingControls
            resultSection
            Spacer()
        }
        .padding()
        .accessibilityIdentifier("AVScreenRecorderDemo.View")
        .onAppear {
            reloadDisplays()
            reloadWindows()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("AV Screen Recorder (AVCaptureScreenInput)")
                .font(.headline)
            statusDot(isOn: isRecording, label: isRecording ? "Recording" : "Idle")
            Spacer()
        }
    }

    private var outputControls: some View {
        HStack(spacing: 8) {
            Text(outputDirectory.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("AVScreenRecorderDemo.OutputPath")
            Spacer()
            Button("Choose Folder…", action: chooseFolder)
                .accessibilityIdentifier("AVScreenRecorderDemo.ChooseFolder")
            Button("Open Folder", action: openFolder)
                .accessibilityIdentifier("AVScreenRecorderDemo.OpenFolder")
        }
    }

    private var modeControls: some View {
        HStack(spacing: 8) {
            Text("Mode:")
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Spacer()
            Button("Refresh") {
                reloadDisplays()
                reloadWindows()
            }
            .buttonStyle(.bordered)
        }
    }

    private var targetSelection: some View {
        Group {
            if mode == .display {
                HStack(spacing: 8) {
                    Text("Display:")
                    Picker("Display", selection: Binding(
                        get: {
                            selectedDisplayID ?? displays.first?.id ?? CGMainDisplayID()
                        },
                        set: { newValue in
                            selectedDisplayID = newValue
                            updateCropDefaultsForCurrentDisplay()
                        }
                    )) {
                        ForEach(displays) { item in
                            Text(item.name).tag(item.id)
                        }
                    }
                    .frame(minWidth: 260)
                }
            } else {
                HStack(spacing: 8) {
                    Text("Window:")
                    Picker("Window", selection: Binding(
                        get: {
                            selectedWindowID ?? windows.first?.id
                        },
                        set: { newValue in
                            selectedWindowID = newValue
                        }
                    )) {
                        ForEach(windows) { item in
                            Text(item.title).tag(item.id as CGWindowID?)
                        }
                    }
                    .frame(minWidth: 320)
                }
            }
        }
    }

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Use crop rect (x, y, width, height)", isOn: $useCropRect)
            HStack(spacing: 6) {
                TextField("x", text: $cropXText)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                TextField("y", text: $cropYText)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                TextField("width", text: $cropWidthText)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                TextField("height", text: $cropHeightText)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Coordinates are in screen points; origin is bottom-left of the selected display.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("File name (no extension)", text: $fileName)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                Spacer()
                Button(action: startRecording) {
                    Text("Start")
                }
                .disabled(isRecording || isBusy)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("AVScreenRecorderDemo.Start")

                Button(action: stopRecording) {
                    Text("Stop")
                }
                .disabled(!isRecording || isBusy)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("AVScreenRecorderDemo.Stop")
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(Color.red)
                    .font(.caption)
            }
        }
    }

    private var resultSection: some View {
        Group {
            if let result = lastResult {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last Recording")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(result.fileURL.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let dims = result.videoDimensions {
                        Text("Size: \(Int(dims.width))x\(Int(dims.height))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    let duration = result.endTimestamp - result.startTimestamp
                    Text(String(format: "Duration: %.2fs", duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([result.fileURL])
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("AVScreenRecorderDemo.Reveal")
                }
                .textSelection(.enabled)
                .accessibilityIdentifier("AVScreenRecorderDemo.Result")
            }
        }
    }

    private var parityTestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("ScreenCaptureKit vs AVFoundation Parity")
                .font(.subheadline)
            HStack(spacing: 8) {
                Text("Duration (s):")
                TextField("Seconds", text: $parityDurationText)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                Spacer()
                Button {
                    runParityTest()
                } label: {
                    if isRunningParityTest {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        Text("Run Parity Test")
                    }
                }
                .disabled(isRunningParityTest || isRecording || isBusy)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("AVScreenRecorderDemo.Parity.Run")
            }
            if let parityErrorMessage {
                Text(parityErrorMessage)
                    .foregroundStyle(Color.red)
                    .font(.caption)
            }
            if let result = parityResult {
                ParityResultView(result: result)
                    .accessibilityIdentifier("AVScreenRecorderDemo.Parity.Result")
            }
        }
    }

    // MARK: - Actions

    private func startRecording() {
        guard !isRecording, !isBusy else { return }
        isBusy = true
        errorMessage = nil

        Task {
            let displayID = resolveDisplayIDForCurrentSelection()
            let cropRect = resolveCropRectForCurrentSelection(displayID: displayID)

            let config = AVScreenRecorder.Configuration(
                displayID: displayID,
                cropRect: cropRect,
                showsCursor: true,
                capturesMouseClicks: false,
                fps: 30
            )
            let recorder = AVScreenRecorder(configuration: config)
            self.recorder = recorder
            let url = outputDirectory.appendingPathComponent(fileName).appendingPathExtension("mov")
            do {
                try await recorder.startRecording(to: url)
                isRecording = true
                isBusy = false
            } catch {
                isRecording = false
                isBusy = false
                self.recorder = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func runParityTest() {
        guard !isRunningParityTest, !isRecording, !isBusy else { return }
        parityErrorMessage = nil
        parityResult = nil
        let durationSeconds: TimeInterval = {
            if let value = Double(parityDurationText), value > 0 {
                // 允许最长 10 分钟的长时间录制，最短 0.5 秒。
                return max(0.5, min(value, 600))
            }
            return 600
        }()
        parityDurationText = String(format: "%.1f", durationSeconds)

        let displayID = resolveDisplayIDForCurrentSelection()
        let cropRect = resolveCropRectForCurrentSelection(displayID: displayID)
        let fps = 30
        let baseDirectory = outputDirectory

        isRunningParityTest = true

        Task {
            do {
                // Ensure directory exists
                if !FileManager.default.fileExists(atPath: baseDirectory.path) {
                    try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
                }

                let timestamp = Int(Date().timeIntervalSince1970)
                async let sckURL = runScreenCaptureKitParity(
                    displayID: displayID,
                    cropRect: cropRect,
                    fps: fps,
                    duration: durationSeconds,
                    baseFilename: "parity-sck-\(timestamp)",
                    outputDirectory: baseDirectory
                )
                async let avfURL = runAVFoundationParity(
                    displayID: displayID,
                    cropRect: cropRect,
                    fps: fps,
                    duration: durationSeconds,
                    baseFilename: "parity-avf-\(timestamp)",
                    outputDirectory: baseDirectory
                )

                let (sckFile, avfFile) = try await (sckURL, avfURL)
                let sckAnalysis = await analyzeRecording(at: sckFile)
                let avfAnalysis = await analyzeRecording(at: avfFile)

                await MainActor.run {
                    self.parityResult = ParityResult(screenCaptureKit: sckAnalysis, avFoundation: avfAnalysis)
                    self.isRunningParityTest = false
                }
            } catch {
                await MainActor.run {
                    self.parityErrorMessage = error.localizedDescription
                    self.isRunningParityTest = false
                }
            }
        }
    }

    private func stopRecording() {
        guard let recorder, isRecording, !isBusy else { return }
        isBusy = true
        errorMessage = nil

        Task {
            do {
                let result = try await recorder.stopRecording()
                lastResult = result
                isRecording = false
                isBusy = false
                self.recorder = nil
            } catch {
                isRecording = false
                isBusy = false
                self.recorder = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.title = "Choose Output Folder"
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
        }
    }

    private func openFolder() {
        NSWorkspace.shared.open(outputDirectory)
    }

    private static func defaultOutputDirectory() -> URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    // MARK: - Helpers (targets & crop)

    private func reloadDisplays() {
        var count: UInt32 = 0
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        let err = CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &count)
        if err != .success || count == 0 {
            let mainID = CGMainDisplayID()
            let bounds = CGDisplayBounds(mainID)
            displays = [
                DisplayItem(
                    id: mainID,
                    name: "Display #\(mainID) (\(Int(bounds.width))x\(Int(bounds.height)))"
                )
            ]
            selectedDisplayID = mainID
            updateCropDefaultsForCurrentDisplay()
            return
        }

        let ids = displayIDs.prefix(Int(count))
        displays = ids.map { id in
            let bounds = CGDisplayBounds(id)
            return DisplayItem(
                id: id,
                name: "Display #\(id) (\(Int(bounds.width))x\(Int(bounds.height)))"
            )
        }
        if selectedDisplayID == nil {
            selectedDisplayID = ids.first
        }
        updateCropDefaultsForCurrentDisplay()
    }

    private func reloadWindows() {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else {
            windows = []
            selectedWindowID = nil
            return
        }

        var items: [WindowItem] = []
        for info in infoList {
            // Only normal windows
            if let layer = info[kCGWindowLayer as String] as? Int, layer != 0 {
                continue
            }
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            let windowID = CGWindowID(number.uint32Value)
            let ownerName = info[kCGWindowOwnerName as String] as? String ?? "App"
            let windowName = info[kCGWindowName as String] as? String
            let title: String
            if let windowName, !windowName.isEmpty {
                title = "\(ownerName) – \(windowName)"
            } else {
                title = ownerName
            }
            guard
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else {
                continue
            }
            items.append(WindowItem(id: windowID, title: title, bounds: bounds))
        }
        windows = items
        if selectedWindowID == nil {
            selectedWindowID = items.first?.id
        }
    }

    private func updateCropDefaultsForCurrentDisplay() {
        guard let displayID = selectedDisplayID ?? displays.first?.id else { return }
        let bounds = CGDisplayBounds(displayID)
        cropXText = String(Int(bounds.origin.x))
        cropYText = String(Int(bounds.origin.y))
        cropWidthText = String(Int(bounds.width))
        cropHeightText = String(Int(bounds.height))
    }

    private func resolveDisplayIDForCurrentSelection() -> CGDirectDisplayID {
        switch mode {
        case .display:
            return selectedDisplayID ?? displays.first?.id ?? CGMainDisplayID()
        case .window:
            guard let windowItem = windows.first(where: { $0.id == selectedWindowID }) ?? windows.first else {
                return CGMainDisplayID()
            }
            let rect = windowItem.bounds
            var displayIDs = [CGDirectDisplayID](repeating: 0, count: 8)
            var count: UInt32 = 0
            let err = CGGetDisplaysWithRect(rect, UInt32(displayIDs.count), &displayIDs, &count)
            if err == .success, count > 0 {
                return displayIDs[0]
            } else {
                return CGMainDisplayID()
            }
        }
    }

    private func resolveCropRectForCurrentSelection(displayID: CGDirectDisplayID) -> CGRect? {
        switch mode {
        case .display:
            guard useCropRect else { return nil }
            guard
                let x = Double(cropXText),
                let y = Double(cropYText),
                let w = Double(cropWidthText),
                let h = Double(cropHeightText),
                w > 0, h > 0
            else {
                return nil
            }
            return CGRect(x: x, y: y, width: w, height: h)
        case .window:
            guard let windowItem = windows.first(where: { $0.id == selectedWindowID }) ?? windows.first else {
                return nil
            }
            // For window mode, crop to the window's bounds on the corresponding display.
            return windowItem.bounds
        }
    }

    private func statusDot(isOn: Bool, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isOn ? Color.red : Color.gray)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("AVScreenRecorderDemo.Status")
    }
}

// MARK: - Parity helpers

private struct ParityResult: Identifiable {
    let id = UUID()
    let screenCaptureKit: RecordingAnalysis
    let avFoundation: RecordingAnalysis

    var durationDifference: Double? {
        guard let a = screenCaptureKit.duration, let b = avFoundation.duration else { return nil }
        return abs(a - b)
    }

    var fileSizeRatio: Double? {
        ratio(screenCaptureKit.fileSizeBytes, avFoundation.fileSizeBytes)
    }

    var videoBitrateRatio: Double? {
        ratio(screenCaptureKit.videoBitrate, avFoundation.videoBitrate)
    }

    var overallBitrateRatio: Double? {
        ratio(screenCaptureKit.overallBitrate, avFoundation.overallBitrate)
    }

    /// Difference between nominal frame rates, if both are available.
    var fpsDifference: Double? {
        guard
            let a = screenCaptureKit.nominalFrameRate,
            let b = avFoundation.nominalFrameRate
        else { return nil }
        return abs(Double(a) - Double(b))
    }

    private func ratio(_ a: Int?, _ b: Int?) -> Double? {
        guard let a, let b, a > 0, b > 0 else { return nil }
        let da = Double(a), db = Double(b)
        return max(da, db) / min(da, db)
    }

    private func ratio(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b, a > 0, b > 0 else { return nil }
        return max(a, b) / min(a, b)
    }
}

private struct RecordingAnalysis: Identifiable {
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

private func runScreenCaptureKitParity(
    displayID: CGDirectDisplayID,
    cropRect: CGRect?,
    fps: Int,
    duration: TimeInterval,
    baseFilename: String,
    outputDirectory: URL
) async throws -> URL {
    let scheme = CRRecorder.SchemeItem.display(
        displayID: displayID,
        area: cropRect,
        fps: fps,
        showsCursor: false,
        hdr: false,
        useHEVC: false,
        captureSystemAudio: false,
        queueDepth: nil,
        targetBitRate: nil,
        filename: baseFilename,
        backend: .screenCaptureKit,
        excludedWindowTitles: []
    )
    let recorder = CRRecorder([scheme], outputDirectory: outputDirectory)

    try await recorder.prepare([scheme])
    try await recorder.startRecording()

    try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

    let result = try await recorder.stopRecordingWithResult()
    guard let asset = result.bundleInfo.files.first else {
        throw NSError(domain: "AVScreenRecorderDemo", code: -1, userInfo: [NSLocalizedDescriptionKey: "No ScreenCaptureKit output file."])
    }
    return result.bundleURL.appendingPathComponent(asset.filename)
}

private func runAVFoundationParity(
    displayID: CGDirectDisplayID,
    cropRect: CGRect?,
    fps: Int,
    duration: TimeInterval,
    baseFilename: String,
    outputDirectory: URL
) async throws -> URL {
    let config = AVScreenRecorder.Configuration(
        displayID: displayID,
        cropRect: cropRect,
        showsCursor: false,
        capturesMouseClicks: false,
        fps: fps,
        includeAudio: false
    )
    let recorder = AVScreenRecorder(configuration: config)
    var url = outputDirectory.appendingPathComponent(baseFilename)
    if url.pathExtension.isEmpty {
        url.appendPathExtension("mov")
    }
    try await recorder.startRecording(to: url)
    try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    let result = try await recorder.stopRecording()
    return result.fileURL
}

private func analyzeRecording(at url: URL) async -> RecordingAnalysis {
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

            let analysis = RecordingAnalysis(
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

private struct ParityResultView: View {
    let result: ParityResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ScreenCaptureKit")
                    .font(.caption)
                    .bold()
                Spacer()
                Text(result.screenCaptureKit.url.lastPathComponent)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            metricsView(for: result.screenCaptureKit)

            HStack {
                Text("AVFoundation")
                    .font(.caption)
                    .bold()
                Spacer()
                Text(result.avFoundation.url.lastPathComponent)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            metricsView(for: result.avFoundation)

            if
                let sckFPS = result.screenCaptureKit.nominalFrameRate,
                let avfFPS = result.avFoundation.nominalFrameRate
            {
                Text(
                    String(
                        format: "FPS (nominal): SCK=%.2f  AVF=%.2f  Δ=%.2f",
                        sckFPS,
                        avfFPS,
                        fabs(Double(sckFPS - avfFPS))
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if let diff = result.durationDifference {
                Text(String(format: "Δ duration: %.3fs", diff))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let r = result.fileSizeRatio {
                Text(String(format: "File size ratio (max/min): %.2fx", r))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let r = result.videoBitrateRatio {
                Text(String(format: "Video bitrate ratio (max/min): %.2fx", r))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let r = result.overallBitrateRatio {
                Text(String(format: "Overall bitrate ratio (max/min): %.2fx", r))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func metricsView(for analysis: RecordingAnalysis) -> some View {
        let audioLine: String = {
            if analysis.hasAudio, let codec = analysis.audioCodec {
                if let br = analysis.audioBitrate {
                    return String(format: "Audio: %@, %.2f kbps", codec, br / 1000.0)
                } else {
                    return "Audio: \(codec)"
                }
            } else if analysis.hasAudio {
                return "Audio track: present"
            } else {
                return "Audio track: none"
            }
        }()

        return VStack(alignment: .leading, spacing: 2) {
            if let size = analysis.videoSize {
                Text("Video size: \(Int(size.width))x\(Int(size.height))")
            }
            if let d = analysis.duration {
                Text(String(format: "Duration: %.3fs", d))
            }
            if let fps = analysis.nominalFrameRate, fps > 0 {
                Text(String(format: "FPS (nominal): %.2f", fps))
            }
            if let codec = analysis.videoCodec {
                Text("Video codec: \(codec)")
            }
            if let mb = analysis.fileSizeMegabytes {
                Text(String(format: "File size: %.2f MB", mb))
            }
            if let v = analysis.videoBitrateMbps {
                Text(String(format: "Video bitrate: %.2f Mbps", v))
            }
            if let o = analysis.overallBitrateMbps {
                Text(String(format: "Overall bitrate: %.2f Mbps", o))
            }
            Text(audioLine)
        }
        .foregroundStyle(.secondary)
    }
}

#Preview("AV Screen Recorder Demo") {
    AVScreenRecorderDemoView()
        .frame(width: 640, height: 360)
}

#endif
