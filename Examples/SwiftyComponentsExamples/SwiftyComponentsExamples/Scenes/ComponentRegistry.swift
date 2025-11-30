import SwiftUI
import SwiftyComponents

enum ComponentRegistry {
    static var groups: [ComponentGroup] {
        [mediaGroup]
    }

    static let mediaGroup: ComponentGroup = {
        let screenRecorder = ComponentDemo(
            id: "cr-recorder-demo",
            title: String(localized: "Catalog.CRRecorderDemo.Title"),
            summary: String(localized: "Catalog.CRRecorderDemo.Summary"),
            variants: [
                DemoVariant(
                    id: "default",
                    title: "Default",
                    makeView: { AnyView(CRRecorderDemoView()) }
                )
            ]
        )
        let permissions = ComponentDemo(
            id: "cr-permissions",
            title: String(localized: "Catalog.RecorderPermissions.Title"),
            summary: String(localized: "Catalog.RecorderPermissions.Summary"),
            variants: [
                DemoVariant(
                    id: "default",
                    title: "Default",
                    makeView: { AnyView(RecorderPermissionsView()) }
                )
            ]
        )
        let micDiagnostics = ComponentDemo(
            id: "cr-mic-diagnostics",
            title: String(localized: "Catalog.MicDiagnostics.Title"),
            summary: String(localized: "Catalog.MicDiagnostics.Summary"),
            variants: [
                DemoVariant(
                    id: "default",
                    title: "Default",
                    makeView: { AnyView(RecorderMicDiagnosticsDemoView()) }
                )
            ]
        )
        let micRawReplay = ComponentDemo(
            id: "cr-mic-offline-replay",
            title: String(localized: "Catalog.MicRawReplay.Title"),
            summary: String(localized: "Catalog.MicRawReplay.Summary"),
            variants: [
                DemoVariant(
                    id: "default",
                    title: "Default",
                    makeView: { AnyView(MicRawReplayDemoView()) }
                )
            ]
        )
        let avScreenRecorder = ComponentDemo(
            id: "av-screen-recorder-demo",
            title: String(localized: "Catalog.AVScreenRecorderDemo.Title"),
            summary: String(localized: "Catalog.AVScreenRecorderDemo.Summary"),
            variants: [
                DemoVariant(
                    id: "default",
                    title: "Default",
                    makeView: { AnyView(AVScreenRecorderDemoView()) }
                )
            ]
        )
        let waveform = ComponentDemo(
            id: "waveform-demo",
            title: String(localized: "Catalog.WaveformDemo.Title"),
            summary: String(localized: "Catalog.WaveformDemo.Summary"),
            variants: [
                DemoVariant(
                    id: "bars",
                    title: "Bars",
                    makeView: { AnyView(WaveformDemoView(audioName: "wave-440hz-1s", style: .bars)) }
                ),
                DemoVariant(
                    id: "outline",
                    title: "Outline",
                    makeView: { AnyView(WaveformDemoView(audioName: "wave-440hz-1s", style: .outline)) }
                ),
                DemoVariant(
                    id: "filled",
                    title: "Filled",
                    makeView: { AnyView(WaveformDemoView(audioName: "wave-440hz-1s", style: .filled)) }
                )
            ]
        )
        return ComponentGroup(
            id: "media",
            title: String(localized: "Catalog.Group.Media"),
            demos: [screenRecorder, avScreenRecorder, permissions, micDiagnostics, micRawReplay, waveform]
        )
    }()
}

// Placeholder removed; real demo view now used
