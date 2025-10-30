import SwiftUI

enum ComponentRegistry {
    static var groups: [ComponentGroup] {
        [mediaGroup]
    }

    static let mediaGroup: ComponentGroup = {
        let waveform = ComponentDemo(
            id: "waveform",
            title: "Waveform",
            summary: "音频波形可视化（占位示例）",
            variants: [
                DemoVariant(
                    id: "bars-440hz",
                    title: "Bars • 440Hz",
                    makeView: { AnyView(WaveformPlaceholder(title: "440Hz", audioName: "wave-440hz-1s")) }
                ),
                DemoVariant(
                    id: "bars-880hz",
                    title: "Bars • 880Hz",
                    makeView: { AnyView(WaveformPlaceholder(title: "880Hz", audioName: "wave-880hz-1s")) }
                )
            ]
        )
        return ComponentGroup(id: "media", title: "媒体 / Media", demos: [waveform])
    }()
}

private struct WaveformPlaceholder: View {
    let title: String
    let audioName: String

    var body: some View {
        VStack(spacing: 12) {
            Text("Waveform Placeholder • \(title)")
                .font(.title3)
            if let url = Bundle.main.url(forResource: audioName, withExtension: "wav", subdirectory: "Audio") {
                Text("Resource: \(url.lastPathComponent)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("Waveform.Resource")
            } else {
                Text("未找到音频资源")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("Waveform.ResourceMissing")
            }
            PlaceholderBars()
                .frame(height: 80)
                .accessibilityIdentifier("Waveform.PlaceholderBars")
        }
        .padding()
    }
}

private struct PlaceholderBars: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let count = max(Int(w / 4), 10)
            let bars = (0..<count)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(bars, id: \.self) { i in
                    let t = Double(i) / Double(count)
                    let value = 0.5 + 0.5 * sin(t * .pi * 4)
                    Rectangle()
                        .fill(.tint)
                        .frame(width: 2, height: max(2, CGFloat(value) * h))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

