import SwiftUI
import AVFoundation
import SwiftyComponents

struct RecorderMicDiagnosticsDemoView: View {
    @ObservedObject private var micDiag = RecorderMicDiagnostics.shared

    @State private var microphones: [AVCaptureDevice] = []
    @State private var selectedMicrophoneID: String = "default"
    @State private var runningProfileID: String? = nil
    @State private var lastFiles: [String] = []
    @State private var lastBundleDirectory: URL? = nil
    @State private var errorMessage: String? = nil
    @State private var showResult: Bool = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                headerSection

                step1MicSelection

                Divider()

                diagnosticsPanel

                if showResult {
                    Divider()
                    savedFilesPanel
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            reloadMicrophones()
        }
        .accessibilityIdentifier("CRRecorder.MicDiagnostics.View")
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MicDiag.Title")
                .font(.title2)
                .bold()
            Text("MicDiag.Goal")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var step1MicSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MicDiag.Step1.Title")
                .font(.headline)
            HStack(spacing: 8) {
                Picker("MicDiag.MicPickerTitle", selection: $selectedMicrophoneID) {
                    Text("MicDiag.SystemDefault").tag("default")
                    ForEach(microphones, id: \.uniqueID) { dev in
                        Text(dev.localizedName).tag(dev.uniqueID)
                    }
                }
                .frame(minWidth: 260)
                Button(action: { reloadMicrophones() }) {
                    Text("MicDiag.RefreshList")
                }
                .buttonStyle(.bordered)
            }
            .accessibilityIdentifier("CRRecorder.MicDiagnostics.Picker")

            Text("MicDiag.Step1.Tip")
                .font(.caption2)
                .foregroundStyle(.secondary)

            step2RecordTests
        }
    }

    private var step2RecordTests: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MicDiag.Step2.Title")
                .font(.headline)

            Text("MicDiag.Step2.Description")
                .font(.caption2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                testRow(
                    id: "default-processing",
                    title: String(localized: "MicDiag.ModeA.Title"),
                    detail: String(localized: "MicDiag.ModeA.Detail"),
                    options: .coreRecorderDefault
                )
            }

            if let msg = errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Panels

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Microphone Diagnostics")
                .font(.headline)

            devicePanel
            formatPanel
            samplesPanel
            settingsPanel
        }
    }

    private var devicePanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Device")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Text("Name:")
                    .frame(width: 80, alignment: .leading)
                    .foregroundStyle(.secondary)
                Text(micDiag.deviceName ?? "-")
            }
            HStack {
                Text("ID:")
                    .frame(width: 80, alignment: .leading)
                    .foregroundStyle(.secondary)
                Text(micDiag.deviceID ?? "-")
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("CRRecorder.MicDiagnostics.Device")
    }

    private var formatPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stream Format (from samples)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let fmt = micDiag.lastFormat {
                VStack(alignment: .leading, spacing: 2) {
                    labeledRow("Sample Rate", value: String(format: "%.0f Hz", fmt.sampleRate))
                    labeledRow("Channels", value: "\(fmt.channels)")
                    labeledRow("Bits/Channel", value: "\(fmt.bitsPerChannel)")
                    labeledRow("Bytes/Frame", value: "\(fmt.bytesPerFrame)")
                    labeledRow("Format ID", value: "0x" + String(fmt.formatID, radix: 16))
                    labeledRow("Format Flags", value: "0x" + String(fmt.formatFlags, radix: 16))
                    labeledRow("Float", value: fmt.isFloat.description)
                    labeledRow("Signed Int", value: fmt.isSignedInteger.description)
                    labeledRow("Non-Interleaved", value: fmt.isNonInterleaved.description)
                }
                .font(.caption)
            } else {
                Text("Waiting for microphone samples…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("CRRecorder.MicDiagnostics.Format")
    }

    private var samplesPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MicDiag.Samples.Title")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if micDiag.recentSamples.isEmpty {
                Text("MicDiag.Samples.Empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(micDiag.recentSamples) { s in
                            Text(sampleSummary(s))
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .accessibilityIdentifier("CRRecorder.MicDiagnostics.Samples")
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MicDiag.Settings.Title")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Group {
                Text("MicDiag.Settings.Processing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(processingSummary(micDiag.processingOptions))
                    .font(.caption2)
                    .textSelection(.enabled)
                Text("MicDiag.Settings.Capture")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                keyValueList(micDiag.captureOutputSettings)
                Text("MicDiag.Settings.Writer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                keyValueList(micDiag.writerAudioSettings)
            }
        }
        .accessibilityIdentifier("CRRecorder.MicDiagnostics.Settings")
    }

    private var savedFilesPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MicDiag.Files.Title")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if lastFiles.isEmpty {
                Text("MicDiag.Files.Empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if let dir = lastBundleDirectory {
                    Text("\(String(localized: "MicDiag.Files.DirectoryPrefix"))\(dir.path)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                ForEach(lastFiles, id: \.self) { name in
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                #if os(macOS)
                if let dir = lastBundleDirectory {
                    HStack {
                        Button("MicDiag.Files.Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([dir])
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                }
                #endif
            }
        }
        .textSelection(.enabled)
        .accessibilityIdentifier("CRRecorder.MicDiagnostics.Files")
    }

    // MARK: - Formatting helpers

    private func labeledRow(_ key: String, value: String) -> some View {
        HStack {
            Text(key)
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func keyValueList(_ dict: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if dict.isEmpty {
                Text("—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(dict.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack(alignment: .top, spacing: 4) {
                        Text(key + ":")
                            .frame(width: 120, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Text(value)
                            .font(.caption2)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .font(.caption2)
    }

    private func processingSummary(_ opts: MicrophoneProcessingOptions) -> String {
        "enableProcessing=\(opts.enableProcessing), gain=\(opts.linearGain), AGC=\(opts.enableAGC) targetRMS=\(opts.agcTargetRMS), maxGainDb=\(opts.agcMaxGainDb), limiter=\(opts.enableLimiter), channels=\(opts.channels)"
    }

    private func sampleSummary(_ s: RecorderMicSampleStats) -> String {
        let timeLabel: String = {
            struct Holder {
                static let df: DateFormatter = {
                    let f = DateFormatter()
                    f.dateFormat = "HH:mm:ss.SSS"
                    return f
                }()
            }
            return Holder.df.string(from: s.time)
        }()
        var parts: [String] = []
        parts.append("t=\(timeLabel)")
        parts.append("frames=\(s.frames)")
        parts.append("rate=\(Int(s.sampleRate))Hz")
        parts.append("ch=\(s.channels)")
        parts.append("bits=\(s.bitsPerChannel)")
        parts.append("float=\(s.isFloat)")
        parts.append("signed=\(s.isSignedInteger)")
        if let rms = s.rms {
            parts.append(String(format: "rms=%.3f", rms))
        }
        if let peak = s.peak {
            parts.append(String(format: "peak=%.3f", peak))
        }
        if let mi = s.minSample, let ma = s.maxSample {
            parts.append(String(format: "min=%.3f max=%.3f", mi, ma))
        }
        return parts.joined(separator: "  ")
    }

    // MARK: - Test helpers

    private func testRow(id: String, title: String, detail: String, options: MicrophoneProcessingOptions) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline)
                if runningProfileID == id {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button(runningProfileID == id ? String(localized: "MicDiag.Test.Recording") : String(localized: "MicDiag.Test.Button")) {
                    guard runningProfileID == nil else { return }
                    Task { await runMicTest(id: id, options: options) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(runningProfileID != nil)
            }
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("CRRecorder.MicDiagnostics.Test.\(id)")
    }

    private func reloadMicrophones() {
        #if os(macOS)
        microphones = AVCaptureDevice.devices(for: .audio)
        #else
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone], mediaType: .audio, position: .unspecified).devices
        #endif
    }

    @MainActor
    private func runMicTest(id: String, options: MicrophoneProcessingOptions) async {
        runningProfileID = id
        errorMessage = nil
        lastFiles = []
        showResult = false

        let micID = selectedMicrophoneID.isEmpty ? "default" : selectedMicrophoneID

        // 输出目录：Downloads/SwiftyRecordings/MicTests-<timestamp>
        let base = Self.defaultOutputDirectory()
        let sessionDir = base.appendingPathComponent(Self.timestampedFilenamePrefix("MicTests"))
        do {
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        } catch { }

        let filename = "mic-\(id)"
        let schemes: [CRRecorder.SchemeItem] = [
            .microphone(microphoneID: micID, filename: filename)
        ]

        let recorder = CRRecorder(schemes, outputDirectory: sessionDir)
        recorder.microphoneOptions = options

        do {
            try await recorder.prepare(schemes)
            try await recorder.startRecording()
            try await Task.sleep(nanoseconds: 10_000_000_000)
            let result = try await recorder.stopRecordingWithResult()
            lastFiles = result.bundleInfo.files.map { $0.filename }
            lastBundleDirectory = result.bundleURL
            showResult = true

            // 将当前诊断信息写入同一目录，方便用户一起打包发送。
            RecorderMicDiagnostics.shared.writeSnapshot(to: sessionDir, label: id)
        } catch {
            errorMessage = error.localizedDescription
        }

        runningProfileID = nil
    }

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
}

#Preview("Mic Diagnostics") {
    RecorderMicDiagnosticsDemoView()
        .frame(width: 860, height: 520)
}
