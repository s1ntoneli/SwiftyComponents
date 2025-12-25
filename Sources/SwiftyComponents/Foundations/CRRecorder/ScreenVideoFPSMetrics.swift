import Foundation

// MARK: - Internal sink (hot path)

protocol ScreenVideoFPSEventSink: AnyObject {
    func onCaptureVideoFrame()
    func onAppendedVideoFrame()
    func onDroppedVideoFrameNotReady()
    func onSessionStart(backend: CRRecorder.ScreenBackend)
    func onSessionStop()
}

// MARK: - Timer-driven meter (release-safe)

final class ScreenVideoFPSMeter: @unchecked Sendable {
    private let intervalSeconds: TimeInterval
    private let publish: (CRRecorder.ScreenVideoFPSMetrics) -> Void

    private let lock = NSLock()
    private var backend: CRRecorder.ScreenBackend = .screenCaptureKit
    private var isActive: Bool = false

    private var totalCaptured: UInt64 = 0
    private var totalAppended: UInt64 = 0
    private var totalDroppedNotReady: UInt64 = 0

    private var lastTickUptime: TimeInterval?
    private var lastTickCounts: (captured: UInt64, appended: UInt64, droppedNotReady: UInt64) = (0, 0, 0)
    private var lastMetrics: CRRecorder.ScreenVideoFPSMetrics?

    private let timerQueue = DispatchQueue(label: "com.swiftycomponents.crrecorder.screenfps.timer")
    private var timer: DispatchSourceTimer?

    init(
        intervalSeconds: TimeInterval,
        publish: @escaping (CRRecorder.ScreenVideoFPSMetrics) -> Void
    ) {
        self.intervalSeconds = max(0.5, intervalSeconds)
        self.publish = publish
    }

    deinit {
        stopTimer()
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + intervalSeconds, repeating: intervalSeconds, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            self?.emitSnapshot()
        }
        timer = t
        t.resume()
    }

    private func stopTimer() {
        if let t = timer {
            t.setEventHandler {}
            t.cancel()
            timer = nil
        }
    }

    private func resetForNewSession(backend: CRRecorder.ScreenBackend) {
        self.backend = backend
        isActive = true
        totalCaptured = 0
        totalAppended = 0
        totalDroppedNotReady = 0
        // Initialize tick markers immediately so the first timer tick uses the real elapsed time.
        lastTickUptime = ProcessInfo.processInfo.systemUptime
        lastTickCounts = (0, 0, 0)
        lastMetrics = CRRecorder.ScreenVideoFPSMetrics(
            time: Date(),
            backend: backend,
            isActive: true,
            intervalSeconds: intervalSeconds,
            captureFPS: 0,
            appendFPS: 0,
            dropNotReadyFPS: 0,
            totalCaptured: 0,
            totalAppended: 0,
            totalDroppedNotReady: 0
        )
    }

    private func emitSnapshot() {
        let nowUptime = ProcessInfo.processInfo.systemUptime
        let snapshot: (backend: CRRecorder.ScreenBackend, active: Bool, totals: (UInt64, UInt64, UInt64), lastTick: TimeInterval?, lastCounts: (UInt64, UInt64, UInt64))

        lock.lock()
        snapshot = (
            backend: backend,
            active: isActive,
            totals: (totalCaptured, totalAppended, totalDroppedNotReady),
            lastTick: lastTickUptime,
            lastCounts: (lastTickCounts.captured, lastTickCounts.appended, lastTickCounts.droppedNotReady)
        )
        // update last tick markers (even if inactive, to avoid huge dt on next start without reset)
        lastTickUptime = nowUptime
        lastTickCounts = (snapshot.totals.0, snapshot.totals.1, snapshot.totals.2)
        lock.unlock()

        guard snapshot.active else { return }

        let dt: TimeInterval = {
            if let last = snapshot.lastTick {
                return max(0.0001, nowUptime - last)
            }
            return intervalSeconds
        }()

        let dCaptured = Double(snapshot.totals.0 &- snapshot.lastCounts.0)
        let dAppended = Double(snapshot.totals.1 &- snapshot.lastCounts.1)
        let dDropped = Double(snapshot.totals.2 &- snapshot.lastCounts.2)

        let metrics = CRRecorder.ScreenVideoFPSMetrics(
            time: Date(),
            backend: snapshot.backend,
            isActive: true,
            intervalSeconds: dt,
            captureFPS: dCaptured / dt,
            appendFPS: dAppended / dt,
            dropNotReadyFPS: dDropped / dt,
            totalCaptured: snapshot.totals.0,
            totalAppended: snapshot.totals.1,
            totalDroppedNotReady: snapshot.totals.2
        )

        lock.lock()
        lastMetrics = metrics
        lock.unlock()

        publish(metrics)
    }
}

extension ScreenVideoFPSMeter: ScreenVideoFPSEventSink {
    func onSessionStart(backend: CRRecorder.ScreenBackend) {
        lock.lock()
        resetForNewSession(backend: backend)
        lock.unlock()
        startTimerIfNeeded()
        // Publish an immediate baseline snapshot so UI can show "active" instantly.
        publish(CRRecorder.ScreenVideoFPSMetrics(
            time: Date(),
            backend: backend,
            isActive: true,
            intervalSeconds: 0,
            captureFPS: 0,
            appendFPS: 0,
            dropNotReadyFPS: 0,
            totalCaptured: 0,
            totalAppended: 0,
            totalDroppedNotReady: 0
        ))
    }

    func onSessionStop() {
        let final: CRRecorder.ScreenVideoFPSMetrics?
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        isActive = false
        final = lastMetrics
        lock.unlock()

        stopTimer()

        if let final {
            publish(CRRecorder.ScreenVideoFPSMetrics(
                time: Date(),
                backend: final.backend,
                isActive: false,
                intervalSeconds: final.intervalSeconds,
                captureFPS: final.captureFPS,
                appendFPS: final.appendFPS,
                dropNotReadyFPS: final.dropNotReadyFPS,
                totalCaptured: final.totalCaptured,
                totalAppended: final.totalAppended,
                totalDroppedNotReady: final.totalDroppedNotReady
            ))
        } else {
            publish(CRRecorder.ScreenVideoFPSMetrics(
                time: Date(),
                backend: backend,
                isActive: false,
                intervalSeconds: 0,
                captureFPS: 0,
                appendFPS: 0,
                dropNotReadyFPS: 0,
                totalCaptured: 0,
                totalAppended: 0,
                totalDroppedNotReady: 0
            ))
        }
    }

    func onCaptureVideoFrame() {
        lock.lock()
        if isActive { totalCaptured &+= 1 }
        lock.unlock()
    }

    func onAppendedVideoFrame() {
        lock.lock()
        if isActive { totalAppended &+= 1 }
        lock.unlock()
    }

    func onDroppedVideoFrameNotReady() {
        lock.lock()
        if isActive { totalDroppedNotReady &+= 1 }
        lock.unlock()
    }
}
