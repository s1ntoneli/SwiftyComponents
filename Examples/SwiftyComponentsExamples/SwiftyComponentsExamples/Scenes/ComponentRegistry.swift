import SwiftUI
import SwiftyComponents

enum ComponentRegistry {
    static var groups: [ComponentGroup] {
        [mediaGroup]
    }

    static let mediaGroup: ComponentGroup = {
        let waveform = ComponentDemo(
            id: "waveform",
            title: "Waveform",
            summary: "音频波形可视化（Bars / Outline / Filled）",
            variants: [
                DemoVariant(
                    id: "bars-440hz",
                    title: "Bars • 440Hz",
                    makeView: { AnyView(WaveformDemoView(audioName: "wave-440hz-1s", style: .bars)) }
                ),
                DemoVariant(
                    id: "outline-440hz",
                    title: "Outline • 440Hz",
                    makeView: { AnyView(WaveformDemoView(audioName: "wave-440hz-1s", style: .outline)) }
                ),
                DemoVariant(
                    id: "outline-smooth-440hz",
                    title: "Outline • Smooth • 440Hz",
                    makeView: { AnyView(WaveformDemoView(audioName: "wave-440hz-1s", style: .outlineSmooth)) }
                ),
                DemoVariant(
                    id: "filled-880hz",
                    title: "Filled • 880Hz",
                    makeView: { AnyView(WaveformDemoView(audioName: "wave-880hz-1s", style: .filled)) }
                )
            ]
        )
        let recorder = ComponentDemo(
            id: "crrecorder",
            title: "Screen Recorder",
            summary: "屏幕录制（左上角 200×200）+ 诊断视图",
            variants: [
                DemoVariant(
                    id: "control",
                    title: "Control",
                    makeView: { AnyView(CRRecorderDemoView()) }
                ),
                DemoVariant(
                    id: "diagnostics",
                    title: "Diagnostics",
                    makeView: { AnyView(RecorderDiagnosticsView()) }
                )
            ]
        )
        return ComponentGroup(id: "media", title: "媒体 / Media", demos: [waveform, recorder])
    }()
}

// Placeholder removed; real demo view now used
