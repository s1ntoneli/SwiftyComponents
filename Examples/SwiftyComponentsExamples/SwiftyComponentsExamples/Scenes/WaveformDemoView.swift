import SwiftUI
import AVFoundation
import SwiftyComponents
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct WaveformDemoView: View {
    enum DemoStyle: String {
        case bars
        case outline
        case outlineSmooth
        case filled
    }

    let audioName: String
    let style: DemoStyle

    @State private var samples: [Float] = []
    @State private var loading = true
    @State private var selection: AudioOption? = nil
    @State private var displayMode: DisplayMode = .bipolar // 双极（上下对称）/ 单极（仅上半部）
    @State private var smoothEnabled: Bool = false
    @State private var barWidth: Double = 2
    @State private var spacing: Double = 1
    @State private var cornerRadius: Double = 1
    @State private var lineWidth: Double = 1
    @State private var bins: Int = 200
    @State private var showInspector: Bool = false
    // Appearance
    @State private var tintColor: Color = .accentColor
    @State private var useGradient: Bool = false
    @State private var gradientTop: Color = Color(red: 0.35, green: 0.65, blue: 1.0)
    @State private var gradientBottom: Color = Color(red: 0.2, green: 0.5, blue: 1.0)
    @State private var progressColor: Color = .secondary
    @State private var progressWidth: Double = 1
    @State private var docsExpanded: Bool = false

    struct AudioOption: Identifiable, Hashable {
        let id: String // name.ext
        let name: String
        let ext: String
        let title: String
    }

    enum DisplayMode { case bipolar, unipolar }

    var body: some View {
        VStack(spacing: 12) {
            if loading { ProgressView().controlSize(.small) }
            WaveformView(
                samples: samples,
                style: waveformStyle,
                mirror: displayMode == .bipolar,
                progress: nil,
                tint: tintColor,
                fillGradient: useGradient ? (top: gradientTop, bottom: gradientBottom) : nil,
                progressColor: progressColor,
                progressLineWidth: CGFloat(progressWidth)
            )
                .frame(height: 120)
                .animation(.default, value: samples)
                .accessibilityIdentifier("Waveform.Demo")
            Text("Samples: \(samples.count)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task(id: (selection?.id ?? audioName) + style.rawValue) { await load() }
        .toolbar { toolbar }
        .onAppear { if style == .outlineSmooth { smoothEnabled = true } }
        .modifier(InspectorCompat(isPresented: $showInspector) { inspectorContent })
        .padding()
    }

    private var waveformStyle: WaveformStyle {
        let useSmooth = smoothEnabled || (style == .outlineSmooth)
        switch style {
        case .bars:
            return .bars(barWidth: CGFloat(barWidth), spacing: CGFloat(spacing), cornerRadius: CGFloat(cornerRadius))
        case .outline, .outlineSmooth:
            return .outline(smooth: useSmooth, lineWidth: CGFloat(lineWidth))
        case .filled:
            return .filled(smooth: useSmooth)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let opt = selection ?? defaultInitialOption()
        guard let url = findURL(name: opt.name, ext: opt.ext) else { return }
        do {
            let asset = AVURLAsset(url: url)
            let bins = self.bins
            let range = CMTimeRange(start: .zero, duration: asset.duration)
            let values = try await WaveformAnalyzer.sampleAmplitudes(asset: asset, timeRange: range, samples: bins, mode: .rms, channel: .mix)
            await MainActor.run { samples = values }
        } catch {
            await MainActor.run { samples = [] }
        }
    }

    // MARK: - Toolbar
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button("检查器") { showInspector = true }
                .accessibilityIdentifier("Waveform.Settings")
        }
    }

    // MARK: - Options
    private func availableOptions() -> [AudioOption] {
        func scan(_ sub: String?) -> [AudioOption] {
            let allowed = ["wav", "m4a", "mp3", "aif", "aiff", "caf"]
            var opts: [AudioOption] = []
            for ext in allowed {
                if let urls = Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: sub) {
                    for u in urls {
                        let name = u.deletingPathExtension().lastPathComponent
                        let title = "\(name) (\(ext))"
                        opts.append(.init(id: "\(name).\(ext)", name: name, ext: ext, title: title))
                    }
                }
            }
            return opts
        }
        let a = scan("Audio")
        var set = Set(a)
        var merged = a
        for opt in scan(nil) where !set.contains(opt) {
            set.insert(opt)
            merged.append(opt)
        }
        return merged.sorted { $0.id < $1.id }
    }

    private func defaultInitialOption() -> AudioOption {
        let options = availableOptions()
        if let match = options.first(where: { $0.name == audioName }) { return match }
        return options.first ?? .init(id: "wave-440hz-1s.wav", name: "wave-440hz-1s", ext: "wav", title: "440Hz (wav)")
    }

    private func findURL(name: String, ext: String) -> URL? {
        // Prefer Audio/ subdirectory, fallback to flat bundle
        if let u = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Audio") { return u }
        return Bundle.main.url(forResource: name, withExtension: ext)
    }
}

// MARK: - Docs helpers
extension WaveformDemoView {
    private func loadDocs() -> String? {
        let url = Bundle.main.url(forResource: "Waveform", withExtension: "md", subdirectory: "Docs")
            ?? Bundle.main.url(forResource: "Waveform", withExtension: "md")
        guard let u = url, let data = try? Data(contentsOf: u), let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    private func copyIntegrationSnippet() {
        let snippet = """
        import AVFoundation
        import SwiftyComponents

        let asset = AVURLAsset(url: url)
        let range = CMTimeRange(start: .zero, duration: asset.duration)
        let values = try await WaveformAnalyzer.sampleAmplitudes(
            asset: asset,
            timeRange: range,
            samples: 200,
            mode: .rms,
            channel: .mix
        )

        WaveformView(samples: values, style: .filled(smooth: true), mirror: true)
        """
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        #else
        UIPasteboard.general.string = snippet
        #endif
    }
}

// MARK: - Settings Sheet
extension WaveformDemoView {
    @ViewBuilder private var inspectorContent: some View {
        Form {
            Section(header: Text("数据")) {
                Picker("音频", selection: Binding(
                    get: { selection?.id ?? defaultInitialOption().id },
                    set: { id in
                        let options = availableOptions()
                        selection = options.first(where: { $0.id == id })
                    }
                )) {
                    ForEach(availableOptions()) { opt in
                        Text(opt.title).tag(opt.id)
                    }
                }
                Stepper("Bins: \(Int(bins))", value: $bins, in: 50...1000, step: 50)
            }
            Section(header: Text("显示")) {
                Picker("显示模式", selection: $displayMode) {
                    Text("双极（上下对称）").tag(DisplayMode.bipolar)
                    Text("单极（仅上半部）").tag(DisplayMode.unipolar)
                }
                Toggle("平滑曲线", isOn: $smoothEnabled)
            }
            if style == .bars {
                Section(header: Text("柱状样式")) {
                    Stepper("柱宽: \(Int(barWidth))", value: $barWidth, in: 1...8, step: 1)
                    Stepper("间距: \(Int(spacing))", value: $spacing, in: 0...6, step: 1)
                    Stepper("圆角: \(Int(cornerRadius))", value: $cornerRadius, in: 0...6, step: 1)
                }
            } else if style == .outline || style == .outlineSmooth {
                Section(header: Text("线框样式")) {
                    Stepper("线宽: \(String(format: "%.1f", lineWidth))", value: $lineWidth, in: 0.5...6, step: 0.5)
                }
            }
            Section(header: Text("外观")) {
                ColorPicker("主色（Tint）", selection: $tintColor)
                if style == .filled {
                    Toggle("使用渐变填充", isOn: $useGradient)
                    if useGradient {
                        ColorPicker("填充-顶部", selection: $gradientTop)
                        ColorPicker("填充-底部", selection: $gradientBottom)
                    }
                }
                ColorPicker("进度线颜色", selection: $progressColor)
                Stepper("进度线宽: \(String(format: "%.1f", progressWidth))", value: $progressWidth, in: 0.5...6, step: 0.5)
            }
            Section {
                DisclosureGroup(isExpanded: $docsExpanded) {
                    Button("复制接入示例") { copyIntegrationSnippet() }
                    if let md = loadDocs() {
                        ScrollView {
                            if let attr = try? AttributedString(markdown: md) {
                                Text(attr)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text(md)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(minHeight: 160)
                    } else {
                        Text("未找到 Docs/Waveform.md（已回退展示）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Text("示例与文档")
                }
            }
        }
        .padding()
    }
}

// MARK: - Inspector Compatibility Modifier
private struct InspectorCompat<InspectorContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let content: () -> InspectorContent

    func body(content host: Content) -> some View {
        #if os(macOS)
        if #available(macOS 13.0, *) {
            host.inspector(isPresented: $isPresented, content: self.content)
        } else {
            host.sheet(isPresented: $isPresented, content: self.content)
        }
        #else
        if #available(iOS 16.0, *) {
            host.inspector(isPresented: $isPresented, content: self.content)
        } else {
            host.sheet(isPresented: $isPresented, content: self.content)
        }
        #endif
    }
}
