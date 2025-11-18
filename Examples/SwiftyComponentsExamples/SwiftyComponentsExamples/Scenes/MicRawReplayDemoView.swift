import SwiftUI
import SwiftyComponents

#if os(macOS)
import AppKit
#endif

/// 离线重现工具：从 `Mic Diagnostics` 生成的 `*.raw.pcm` 中导出可播放的 WAV。
///
/// 使用方式（给你和测试用户）：
/// 1. 在 “Mic Diagnostics” 页面完成测试（会生成 `mic-*.raw.pcm` + `mic-diagnostics-*.txt`）。 
/// 2. 打开本页面，选择对应的 `MicTests-...` 文件夹。
/// 3. 对每个 Raw 文件，可以导出两种 WAV：
///    - Float32：按设备声明的 32-bit float 方式解释。
///    - Int32：按 32-bit 有符号整数方式解释（用于验证“假 float / 实为整型”场景）。
struct MicRawReplayDemoView: View {
    struct RawItem: Identifiable {
        let id = UUID()
        let label: String
        let rawURL: URL
        let diagURL: URL?
        let sampleRate: Double?
        let channels: Int?
        let isNonInterleaved: Bool
    }

    @State private var directory: URL? = nil
    @State private var items: [RawItem] = []
    @State private var statusMessage: String? = nil
    @State private var showInspector: Bool = false
    @State private var processingOptions: MicrophoneProcessingOptions = .coreRecorderDefault

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                Text("RawReplay.Title")
                    .font(.title2)
                    .bold()

                Text("RawReplay.Description")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                chooseFolderSection
                rawListSection

                if let msg = statusMessage {
                    Divider()
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button("RawReplay.Toolbar.Inspector") { showInspector = true }
            }
        }
        .demoInspector(isPresented: $showInspector) { inspectorContent }
        .accessibilityIdentifier("MicRawReplayDemoView")
    }

    private var chooseFolderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RawReplay.Step1.Title")
                .font(.headline)
            HStack(spacing: 8) {
                Text(directory?.path ?? String(localized: "RawReplay.Step1.Placeholder"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("RawReplay.Step1.ChooseFolder", action: chooseFolder)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var rawListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RawReplay.Step2.Title")
                .font(.headline)
            if items.isEmpty {
                Text("RawReplay.Step2.Description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    rawRow(for: item)
                }
            }
        }
    }

    private func rawRow(for item: RawItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(item.rawURL.lastPathComponent)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("RawReplay.Export.Float32") {
                    export(item: item, mode: MicRawReplayer.Interpretation.float32FirstChannel)
                }
                .buttonStyle(.bordered)
                Button("RawReplay.Export.Int32") {
                    export(item: item, mode: MicRawReplayer.Interpretation.int32FirstChannel)
                }
                .buttonStyle(.bordered)
                #if os(macOS)
                Button("RawReplay.Export.RevealRaw") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.rawURL])
                }
                .buttonStyle(.bordered)
                #endif
            }
            HStack(spacing: 8) {
                if let sr = item.sampleRate, let ch = item.channels {
                    Text("SampleRate=\(Int(sr))Hz, Channels=\(ch)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("RawReplay.Info.DefaultFromDiag")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if item.diagURL != nil {
                    Text("[有诊断文本]")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("[无诊断文本]")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func chooseFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = String(localized: "RawReplay.Step1.PanelTitle")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            directory = url
            loadItems(from: url)
        }
        #endif
    }

    private func loadItems(from dir: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            items = []
            return
        }
        let raws = contents.filter { $0.lastPathComponent.hasPrefix("mic-") && $0.lastPathComponent.hasSuffix(".raw.pcm") }
        var result: [RawItem] = []
        for raw in raws {
            let name = raw.deletingPathExtension().lastPathComponent // mic-<label>.raw
            let label: String = {
                if name.hasPrefix("mic-") {
                    return String(name.dropFirst("mic-".count))
                }
                return name
            }()
            let diag = dir.appendingPathComponent("mic-diagnostics-\(label).txt")
            let diagURL: URL? = fm.fileExists(atPath: diag.path) ? diag : nil
            let parsed = diagURL.flatMap(parseDiagFile(at:))
            let item = RawItem(
                label: label,
                rawURL: raw,
                diagURL: diagURL,
                sampleRate: parsed?.sampleRate,
                channels: parsed?.channels,
                isNonInterleaved: parsed?.isNonInterleaved ?? false
            )
            result.append(item)
        }
        items = result.sorted { $0.rawURL.lastPathComponent < $1.rawURL.lastPathComponent }
        if items.isEmpty {
            statusMessage = String(localized: "RawReplay.Status.NoRawFound")
        } else {
            let fmt = String(localized: "RawReplay.Status.LoadedCount %lld")
            statusMessage = String(format: fmt, items.count)
        }
    }

    private func export(item: RawItem, mode: MicRawReplayer.Interpretation) {
        guard let baseDir = directory else { return }
        let sr = item.sampleRate ?? 48_000
        let ch: Int
        if let rawChannels = item.channels {
            // 对于 Non-Interleaved 格式，调试重放时只取首个通道，
            // 避免错误地按交错布局解码导致的伪随机噪声。
            ch = item.isNonInterleaved ? 1 : rawChannels
        } else {
            ch = 1
        }
        let stem = item.rawURL.deletingPathExtension().lastPathComponent
        let suffix: String = {
            switch mode {
            case .float32FirstChannel: return "float32"
            case .int32FirstChannel: return "int32"
            }
        }()
        let outURL = baseDir.appendingPathComponent("\(stem)-\(suffix).wav")
        do {
            try MicRawReplayer.render(
                rawURL: item.rawURL,
                sampleRate: sr,
                channels: ch,
                interpretation: mode,
                outputURL: outURL,
                processingOptions: processingOptions
            )
            #if os(macOS)
            statusMessage = "\(String(localized: "RawReplay.Status.ExportedPrefix"))\(outURL.lastPathComponent)"
            #else
            statusMessage = "Exported \(outURL.lastPathComponent)"
            #endif
        } catch {
            statusMessage = "\(String(localized: "RawReplay.Status.ExportFailedPrefix"))\(error.localizedDescription)"
        }
    }

    // MARK: - Diag parsing

    private struct ParsedDiag {
        let sampleRate: Double
        let channels: Int
        let isNonInterleaved: Bool
    }

    private func parseDiagFile(at url: URL) -> ParsedDiag? {
        guard let text = try? String(contentsOf: url) else { return nil }
        var sr: Double?
        var ch: Int?
        var isNonInterleaved: Bool?
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SampleRate:") {
                if let v = Double(trimmed.dropFirst("SampleRate:".count).trimmingCharacters(in: .whitespaces)) {
                    sr = v
                }
            } else if trimmed.hasPrefix("Channels:") {
                if let v = Int(trimmed.dropFirst("Channels:".count).trimmingCharacters(in: .whitespaces)) {
                    ch = v
                }
            } else if trimmed.hasPrefix("IsNonInterleaved:") {
                let value = trimmed
                    .dropFirst("IsNonInterleaved:".count)
                    .trimmingCharacters(in: .whitespaces)
                if let boolValue = Bool(value) {
                    isNonInterleaved = boolValue
                }
            }
        }
        if let sr, let ch {
            return ParsedDiag(sampleRate: sr, channels: ch, isNonInterleaved: isNonInterleaved ?? false)
        }
        return nil
    }
}

// MARK: - Inspector (processing presets & parameters)
extension MicRawReplayDemoView {
    @ViewBuilder private var inspectorContent: some View {
        Form {
            Section(header: Text("处理参数")) {
                Toggle("启用处理", isOn: $processingOptions.enableProcessing)
                HStack {
                    Text("线性增益")
                    Slider(value: $processingOptions.linearGain, in: 0...4, step: 0.1)
                    Text(String(format: "%.1fx", processingOptions.linearGain))
                        .frame(width: 48, alignment: .trailing)
                }
                Toggle("自动增益 (AGC)", isOn: $processingOptions.enableAGC)
                HStack {
                    Text("目标 RMS")
                    Slider(value: $processingOptions.agcTargetRMS, in: 0.02...0.6, step: 0.01)
                    Text(String(format: "%.2f", processingOptions.agcTargetRMS))
                        .frame(width: 52, alignment: .trailing)
                }
                Stepper("AGC 最大增益: \(Int(processingOptions.agcMaxGainDb)) dB", value: $processingOptions.agcMaxGainDb, in: 0...24, step: 1)
                Toggle("启用 Limiter", isOn: $processingOptions.enableLimiter)
            }
            Section(header: Text("当前配置摘要")) {
                Text(processingSummary(processingOptions))
                    .font(.caption2)
                    .textSelection(.enabled)
            }
        }
        .padding()
    }

    private func processingSummary(_ opts: MicrophoneProcessingOptions) -> String {
        let gain = String(format: "%.1f", opts.linearGain)
        let target = String(format: "%.2f", opts.agcTargetRMS)
        let maxDb = String(format: "%.1f", opts.agcMaxGainDb)
        return "enableProcessing=\(opts.enableProcessing), gain=\(gain)x, AGC=\(opts.enableAGC) targetRMS=\(target), maxGainDb=\(maxDb), limiter=\(opts.enableLimiter), channels=\(opts.channels)"
    }
}

#Preview("Mic Raw Replay") {
    MicRawReplayDemoView()
        .frame(width: 860, height: 520)
}
