import AppKit
import AVFoundation
import Foundation

@main
enum RecordingSyncTargetApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = TargetAppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}

@MainActor
private final class TargetAppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: SyncTargetWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = SyncTargetWindowController()
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
private final class SyncTargetWindowController: NSWindowController {
    private let contentView = SyncTargetView(frame: NSRect(x: 0, y: 0, width: 720, height: 720))

    init() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let size = NSSize(width: 720, height: 720)
        let margin: CGFloat = 48
        let origin = NSPoint(
            x: screen.frame.maxX - size.width - margin,
            y: screen.frame.minY + margin
        )
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Recording Sync Target"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .black
        window.contentView = contentView
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
private final class SyncTargetView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Recording Sync Target")
    private let timeLabel = NSTextField(labelWithString: "0.000 s")
    private let statusLabel = NSTextField(labelWithString: "Flash + Beep loop active")
    private let hintLabel = NSTextField(labelWithString: "Cmd+Q to quit")
    private let tonePlayer = DualBeepPlayer()
    private var timer: Timer?
    private var sequenceTask: Task<Void, Never>?
    private let startWallTime = CFAbsoluteTimeGetCurrent()
    private var isFlashing = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setupLabels()
        startClock()
        startSequenceLoop()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = isFlashing ? NSColor.white : NSColor.black
        fill.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    private func setupLabels() {
        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.frame = NSRect(x: 32, y: bounds.height - 60, width: bounds.width - 64, height: 34)
        titleLabel.autoresizingMask = [.width, .minYMargin]
        addSubview(titleLabel)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 88, weight: .bold)
        timeLabel.alignment = .center
        timeLabel.textColor = .systemGreen
        timeLabel.frame = NSRect(x: 40, y: bounds.midY - 60, width: bounds.width - 80, height: 100)
        timeLabel.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        addSubview(timeLabel)

        statusLabel.font = .systemFont(ofSize: 22, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.textColor = NSColor(white: 0.85, alpha: 1)
        statusLabel.frame = NSRect(x: 40, y: 120, width: bounds.width - 80, height: 28)
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        addSubview(statusLabel)

        hintLabel.font = .systemFont(ofSize: 16, weight: .regular)
        hintLabel.alignment = .center
        hintLabel.textColor = NSColor(white: 0.65, alpha: 1)
        hintLabel.frame = NSRect(x: 40, y: 80, width: bounds.width - 80, height: 22)
        hintLabel.autoresizingMask = [.width, .maxYMargin]
        addSubview(hintLabel)
    }

    private func startClock() {
        updateClock()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateClock()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func updateClock() {
        let total = CFAbsoluteTimeGetCurrent() - startWallTime
        timeLabel.stringValue = String(format: "%.3f s", total)
    }

    private func startSequenceLoop() {
        sequenceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self.playFlashAndBeeps()
            }
        }
    }

    private func playFlashAndBeeps() async {
        statusLabel.stringValue = "Flash + Beep active"
        isFlashing = true
        tonePlayer.playDoubleBeep()
        try? await Task.sleep(nanoseconds: 450_000_000)
        isFlashing = false
        statusLabel.stringValue = "Flash + Beep loop active"
    }
}

private final class DualBeepPlayer {
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
        beepBuffer = buffer
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    func playDoubleBeep() {
        if !player.isPlaying {
            player.play()
        }
        player.scheduleBuffer(beepBuffer, at: nil, options: .interrupts, completionHandler: nil)
        let gap = AVAudioTime(sampleTime: 7_200, atRate: 48_000)
        player.scheduleBuffer(beepBuffer, at: gap, options: [], completionHandler: nil)
    }

    func stop() {
        player.stop()
        engine.stop()
    }
}
