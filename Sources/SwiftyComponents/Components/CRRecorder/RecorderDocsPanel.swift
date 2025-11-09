import SwiftUI

#if os(macOS)
import AppKit

struct RecorderDocsPanel: View {
    struct DocItem: Identifiable, Hashable {
        let id = UUID()
        let title: String
        let summary: String
        let code: String
    }

    private let docs: [DocItem] = {
        let baseHeader = """
        import SwiftyComponents
        import ScreenCaptureKit
        import AVFoundation
        
        """

        func mkDirSnippet() -> String {
            """
            // 输出目录（会话子目录）
            let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let session = base.appendingPathComponent("SwiftyRecordings").appendingPathComponent(Formatter.isoNow("capture"))
            try? FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            """
        }

        func commonTail() -> String {
            """
            // 启停
            try await recorder.prepare(schemes)
            try await recorder.startRecording()
            try await Task.sleep(nanoseconds: 3_000_000_000) // 录制3秒
            let result = try await recorder.stopRecordingWithResult()
            print("Saved:", result.bundleInfo.files.map(\\.filename))
            """
        }

        let display = DocItem(
            title: "屏幕录制（显示器/区域）",
            summary: "录制主显示器某个区域；不含系统音频",
            code: baseHeader + mkDirSnippet() + """
            // 方案：显示器 + 区域
            let displayID = CGMainDisplayID()
            let crop = CGRect(x: 0, y: 0, width: 800, height: 600)
            let schemes: [CRRecorder.SchemeItem] = [
                .display(displayID: displayID, area: crop, hdr: false, captureSystemAudio: false, filename: "screen", excludedWindowTitles: [])
            ]
            
            let recorder = CRRecorder(schemes, outputDirectory: session)
            recorder.screenOptions = .init(fps: 60, includeAudio: false, showsCursor: true)
            
            """ + commonTail()
        )

        let displaySys = DocItem(
            title: "屏幕 + 系统音频（合轨）",
            summary: "系统音频随屏幕写入到同一个 .mov",
            code: baseHeader + mkDirSnippet() + """
            let displayID = CGMainDisplayID()
            let schemes: [CRRecorder.SchemeItem] = [
                .display(displayID: displayID, area: nil, hdr: false, captureSystemAudio: true, filename: "screen", excludedWindowTitles: [])
            ]
            let recorder = CRRecorder(schemes, outputDirectory: session)
            recorder.screenOptions = .init(fps: 60, includeAudio: true, showsCursor: true)
            """ + commonTail()
        )

        let windowCap = DocItem(
            title: "窗口录制",
            summary: "录制指定窗口（不含系统音频）",
            code: baseHeader + mkDirSnippet() + """
            // 取前台窗口ID（示例：自行替换为目标窗口）
            let content = try await SCShareableContent.current
            guard let win = content.windows.first else { throw NSError(domain: "Demo", code: -1) }
            let schemes: [CRRecorder.SchemeItem] = [
                .window(displayId: 0, windowID: win.windowID, hdr: false, captureSystemAudio: false, filename: "window")
            ]
            let recorder = CRRecorder(schemes, outputDirectory: session)
            recorder.screenOptions = .init(fps: 60, includeAudio: false)
            """ + commonTail()
        )

        let mic = DocItem(
            title: "屏幕 + 麦克风（分轨）",
            summary: "屏幕视频 + 独立 .m4a 麦克风文件",
            code: baseHeader + mkDirSnippet() + """
            let displayID = CGMainDisplayID()
            let schemes: [CRRecorder.SchemeItem] = [
                .display(displayID: displayID, area: nil, hdr: false, captureSystemAudio: false, filename: "screen", excludedWindowTitles: []),
                .microphone(microphoneID: "default", filename: "screen-mic")
            ]
            let recorder = CRRecorder(schemes, outputDirectory: session)
            recorder.screenOptions = .init(fps: 60, includeAudio: false)
            """ + commonTail()
        )

        let camMic = DocItem(
            title: "屏幕 + 摄像头 + 麦克风",
            summary: "三路并行录制，摄像头与麦克风为独立文件",
            code: baseHeader + mkDirSnippet() + """
            let displayID = CGMainDisplayID()
            let schemes: [CRRecorder.SchemeItem] = [
                .display(displayID: displayID, area: nil, hdr: false, captureSystemAudio: false, filename: "screen", excludedWindowTitles: []),
                .camera(cameraID: "default", filename: "cam"),
                .microphone(microphoneID: "default", filename: "mic")
            ]
            let recorder = CRRecorder(schemes, outputDirectory: session)
            recorder.screenOptions = .init(fps: 60, includeAudio: false, showsCursor: true)
            """ + commonTail()
        )

        let hevcHDR = DocItem(
            title: "HEVC + HDR",
            summary: "启用 HEVC/HDR（Display P3 10-bit），系统音频合流",
            code: baseHeader + mkDirSnippet() + """
            let displayID = CGMainDisplayID()
            let schemes: [CRRecorder.SchemeItem] = [
                .display(displayID: displayID, area: nil, hdr: true, captureSystemAudio: true, filename: "screen-hdr", excludedWindowTitles: [])
            ]
            let recorder = CRRecorder(schemes, outputDirectory: session)
            recorder.screenOptions = .init(fps: 60, includeAudio: true, showsCursor: true, hdr: true, useHEVC: true)
            """ + commonTail()
        )

        let resultRead = DocItem(
            title: "读取结果清单（bundle.json）",
            summary: "读取并遍历每路文件的元信息",
            code: baseHeader + mkDirSnippet() + """
            // 完成录制后：
            let manifest = session.appendingPathComponent("bundle.json")
            let data = try Data(contentsOf: manifest)
            let info = try JSONDecoder().decode(CRRecorder.BundleInfo.self, from: data)
            for f in info.files {
                print("file=", f.filename, "type=", f.tyle.rawValue, "start=", f.recordingStartTimestamp ?? 0)
            }
            """
        )

        return [display, displaySys, windowCap, mic, camMic, hevcHDR, resultRead]
    }()

    @State private var selectionID: UUID? = nil

    var body: some View {
        HStack(spacing: 12) {
            List(selection: $selectionID) {
                ForEach(docs) { d in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.title)
                        Text(d.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(d.id)
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 260, maxWidth: 320)

            VStack(alignment: .leading, spacing: 8) {
                if let d = docs.first(where: { $0.id == (selectionID ?? docs.first?.id) }) ?? docs.first {
                    HStack {
                        Text(d.title).font(.headline)
                        Spacer()
                        Button("复制代码") { copyToPasteboard(d.code) }
                            .buttonStyle(.bordered)
                    }
                    ScrollView {
                        Text(d.code)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.2))
                    .cornerRadius(6)
                }
                Spacer()
            }
        }
        .padding()
        .frame(minWidth: 800, minHeight: 520)
        .onAppear { if selectionID == nil { selectionID = docs.first?.id } }
    }

    private func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}

private enum Formatter {
    static func isoNow(_ prefix: String) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "\(prefix)-\(df.string(from: Date()))"
    }
}

#endif
