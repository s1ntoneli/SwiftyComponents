import Testing
import Foundation
import AppKit
import AVFoundation
import CoreGraphics
@testable import SwiftyComponents

@Test func recordingSync_realCapture_generatesReport() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["RUN_REAL_CAPTURE_SYNC_TEST"] == "1" else { return }

    let cameraID = try #require(env["REAL_CAPTURE_CAMERA_ID"])
    let outputDir = try makeTemporaryDirectory(name: "recording-sync-real")
    print("REAL_SYNC_STEP setup outputDir=\(outputDir.path) cameraID=\(cameraID)")

    let marker = await MainActor.run {
        ScreenSyncMarkerWindow()
    }
    defer {
        Task { @MainActor in
            marker.close()
        }
    }

    let schemes: [CRRecorder.SchemeItem] = [
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
            microphoneID: "default",
            filename: "mic",
            microphoneOptions: .init()
        ),
        .camera(
            cameraID: cameraID,
            filename: "cam",
            cameraOptions: .init()
        )
    ]

    let recorder = CRRecorder(schemes, outputDirectory: outputDir)
    print("REAL_SYNC_STEP prepare")
    try await recorder.prepare(schemes)
    print("REAL_SYNC_STEP startRecording")
    try await recorder.startRecording()

    try await Task.sleep(nanoseconds: 600_000_000)
    print("REAL_SYNC_STEP markerSequence")
    try await MainActor.run {
        try marker.runSequence()
    }
    try await Task.sleep(nanoseconds: 900_000_000)

    print("REAL_SYNC_STEP stopRecording")
    let result = try await recorder.stopRecordingWithResult()
    print("REAL_SYNC_STEP analyze bundle=\(result.bundleURL.path)")
    let report = try await RecordingSyncAnalyzer.analyze(
        bundleURL: result.bundleURL,
        bundleInfo: result.bundleInfo,
        options: .init(audioSamplesPerSecond: 2_000, videoFlashThreshold: 0.18)
    )

    let reportURL = outputDir.appendingPathComponent("sync_report.json")
    print("REAL_SYNC_STEP writeReport path=\(reportURL.path)")
    try RecordingSyncAnalyzer.writeReport(report, to: reportURL)

    print("REAL_SYNC_REPORT \(reportURL.path)")
    print("REAL_SYNC_SCREEN_AV matched=\(report.screenAV?.matchedCount ?? 0) p95=\(report.screenAV?.offsetP95Ms ?? -1)")
    print("REAL_SYNC_MIC matched=\(report.microphoneToScreenAudio?.matchedCount ?? 0) p50=\(report.microphoneToScreenAudio?.offsetP50Ms ?? -1)")
    print("REAL_SYNC_CAM matched=\(report.cameraToScreenVideo?.matchedCount ?? 0) p50=\(report.cameraToScreenVideo?.offsetP50Ms ?? -1)")

    #expect(report.screenVideo?.markerTimes.count ?? 0 >= 2)
    #expect(report.screenAudio?.markerTimes.count ?? 0 >= 2)
    #expect(report.microphoneAudio?.markerTimes.count ?? 0 >= 2)
    #expect(report.screenAV?.matchedCount ?? 0 >= 2)
    #expect(report.microphoneToScreenAudio?.matchedCount ?? 0 >= 2)
    #expect(report.cameraVideo?.markerTimes.count ?? 0 >= 1)
}

private func makeTemporaryDirectory(name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
private final class ScreenSyncMarkerWindow {
    private let window: NSWindow
    private let tonePlayer: MarkerTonePlayer

    init() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let size = NSSize(width: 720, height: 720)
        let origin = NSPoint(
            x: screen.frame.midX - (size.width / 2),
            y: screen.frame.midY - (size.height / 2)
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
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        tonePlayer = MarkerTonePlayer()
    }

    func runSequence() throws {
        let flashDurations: [TimeInterval] = [0.18, 0.18, 0.18]
        for duration in flashDurations {
            window.backgroundColor = .white
            tonePlayer.playBeep()
            RunLoop.current.run(until: Date().addingTimeInterval(duration))
            window.backgroundColor = .black
            RunLoop.current.run(until: Date().addingTimeInterval(0.72))
        }
    }

    func close() {
        window.orderOut(nil)
        tonePlayer.stop()
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
