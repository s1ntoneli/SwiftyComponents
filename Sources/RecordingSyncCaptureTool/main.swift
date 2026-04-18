import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import SwiftyComponents

@main
enum RecordingSyncCaptureTool {
    static func main() async throws {
        let arguments = ToolArguments.parse(CommandLine.arguments)
        let outputDir = arguments.outputDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("recording-sync-real-" + timestampString(), isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        print("REAL_SYNC_TOOL setup outputDir=\(outputDir.path)")
        print("REAL_SYNC_TOOL cameraID=\(arguments.cameraID ?? "none")")
        print("REAL_SYNC_TOOL micID=\(arguments.microphoneID)")

        let _ = NSApplication.shared
        let marker = await MainActor.run { SyncMarkerWindow() }
        defer {
            Task { @MainActor in marker.close() }
        }

        var schemes: [CRRecorder.SchemeItem] = [
            .display(
                displayID: CGMainDisplayID(),
                area: nil,
                fps: 60,
                showsCursor: false,
                hdr: false,
                useHEVC: false,
                captureSystemAudio: true,
                queueDepth: nil,
                targetBitRate: nil,
                filename: "screen",
                backend: .screenCaptureKit,
                excludedWindowTitles: []
            ),
            .microphone(
                microphoneID: arguments.microphoneID,
                filename: "mic",
                microphoneOptions: .coreRecorderDefault
            )
        ]
        if let cameraID = arguments.cameraID {
            schemes.append(
                .camera(
                    cameraID: cameraID,
                    filename: "cam",
                    cameraOptions: .init()
                )
            )
        }

        let recorder = CRRecorder(schemes, outputDirectory: outputDir)
        print("REAL_SYNC_TOOL prepare")
        try await recorder.prepare(schemes)
        print("REAL_SYNC_TOOL startRecording")
        try await recorder.startRecording()

        let preheatSeconds = 5.0
        print("REAL_SYNC_TOOL preheatSeconds=\(preheatSeconds)")
        try await Task.sleep(nanoseconds: UInt64(preheatSeconds * 1_000_000_000))
        print("REAL_SYNC_TOOL markerSequence")
        try await MainActor.run {
            try marker.runSequence()
        }
        let postSequenceSeconds = 2.0
        print("REAL_SYNC_TOOL postSequenceSeconds=\(postSequenceSeconds)")
        try await Task.sleep(nanoseconds: UInt64(postSequenceSeconds * 1_000_000_000))

        print("REAL_SYNC_TOOL stopRecording")
        let result = try await recorder.stopRecordingWithResult()

        print("REAL_SYNC_TOOL analyze")
        let report = try await RecordingSyncAnalyzer.analyze(
            bundleURL: result.bundleURL,
            bundleInfo: result.bundleInfo,
            options: .init(audioSamplesPerSecond: 2_000, videoFlashThreshold: 0.18)
        )

        let reportURL = outputDir.appendingPathComponent("sync_report.json")
        try RecordingSyncAnalyzer.writeReport(report, to: reportURL)
        print("REAL_SYNC_TOOL report=\(reportURL.path)")
        print("REAL_SYNC_TOOL screenAV matched=\(report.screenAV?.matchedCount ?? 0) p95=\(report.screenAV?.offsetP95Ms ?? -1)")
        print("REAL_SYNC_TOOL mic matched=\(report.microphoneToScreenAudio?.matchedCount ?? 0) p50=\(report.microphoneToScreenAudio?.offsetP50Ms ?? -1)")
        print("REAL_SYNC_TOOL micAdjusted matched=\(report.adjustedMicrophoneToScreenAudio?.matchedCount ?? 0) p50=\(report.adjustedMicrophoneToScreenAudio?.offsetP50Ms ?? -1)")
        print("REAL_SYNC_TOOL cam matched=\(report.cameraToScreenVideo?.matchedCount ?? 0) p50=\(report.cameraToScreenVideo?.offsetP50Ms ?? -1)")
        print("REAL_SYNC_TOOL camAdjusted matched=\(report.adjustedCameraToScreenVideo?.matchedCount ?? 0) p50=\(report.adjustedCameraToScreenVideo?.offsetP50Ms ?? -1)")
    }
}

private struct ToolArguments {
    let cameraID: String?
    let microphoneID: String
    let outputDirectory: URL?

    static func parse(_ argv: [String]) -> ToolArguments {
        var cameraID: String?
        var microphoneID = "default"
        var outputDirectory: URL?
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            switch arg {
            case "--camera-id":
                if index + 1 < argv.count { cameraID = argv[index + 1]; index += 1 }
            case "--microphone-id":
                if index + 1 < argv.count { microphoneID = argv[index + 1]; index += 1 }
            case "--output-dir":
                if index + 1 < argv.count { outputDirectory = URL(fileURLWithPath: argv[index + 1]); index += 1 }
            default:
                break
            }
            index += 1
        }

        return ToolArguments(cameraID: cameraID, microphoneID: microphoneID, outputDirectory: outputDirectory)
    }
}

@MainActor
private final class SyncMarkerWindow {
    private let window: NSWindow
    private let tonePlayer: MarkerTonePlayer
    private let timeLabel: NSTextField
    private var displayTimer: Timer?
    private let startWallTime = CFAbsoluteTimeGetCurrent()

    init() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let size = NSSize(width: 720, height: 720)
        let margin: CGFloat = 48
        let origin = NSPoint(
            x: screen.frame.maxX - size.width - margin,
            y: screen.frame.minY + margin
        )
        window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        let contentView = NSView(frame: NSRect(origin: .zero, size: size))
        contentView.wantsLayer = true
        window.contentView = contentView

        timeLabel = NSTextField(labelWithString: "0.000 s")
        timeLabel.alignment = .center
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 56, weight: .bold)
        timeLabel.textColor = .systemGreen
        timeLabel.backgroundColor = .clear
        timeLabel.frame = NSRect(x: 40, y: size.height - 120, width: size.width - 80, height: 70)
        timeLabel.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(timeLabel)

        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        tonePlayer = MarkerTonePlayer()
        startDisplayTimer()
    }

    func runSequence() throws {
        let flashDurations: [TimeInterval] = [0.45, 0.45, 0.45, 0.45]
        let gapSeconds: TimeInterval = 1.05
        for duration in flashDurations {
            window.backgroundColor = .white
            tonePlayer.playBeep()
            RunLoop.current.run(until: Date().addingTimeInterval(duration))
            window.backgroundColor = .black
            RunLoop.current.run(until: Date().addingTimeInterval(gapSeconds))
        }
    }

    func close() {
        displayTimer?.invalidate()
        displayTimer = nil
        window.orderOut(nil)
        tonePlayer.stop()
    }

    private func startDisplayTimer() {
        updateTimeLabel()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateTimeLabel()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func updateTimeLabel() {
        let total = CFAbsoluteTimeGetCurrent() - startWallTime
        timeLabel.stringValue = String(format: "%.3f s", total)
    }
}

@MainActor
private final class MarkerTonePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let beepBuffer: AVAudioPCMBuffer

    init() {
        let sampleRate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(sampleRate * 0.08)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            channel[i] = Float(sin(2.0 * Double.pi * 1_000.0 * t) * 0.8)
        }
        self.beepBuffer = buffer
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    func playBeep() {
        if !player.isPlaying {
            player.play()
        }
        player.scheduleBuffer(beepBuffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    func stop() {
        player.stop()
        engine.stop()
    }
}

private func timestampString() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return formatter.string(from: Date())
}
