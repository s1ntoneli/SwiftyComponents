import Foundation
import AVFoundation

final class AssetWriterMicBackend: MicrophoneBackend {
    var onFirstPTS: ((CMTime) -> Void)?
    var processingOptions: MicrophoneProcessingOptions = .init()

    private enum StopState {
        case idle
        case stopping
        case stopped
    }

    private weak var session: AVCaptureSession?
    private weak var delegate: CaptureRecordingDelegate?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    private var observers: [Any] = []
    private var observedDeviceID: String?
    private var callbackQueue: DispatchQueue?

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var writerSessionStarted = false
    private var fileURL: URL?
    private var deviceSampleRate: Double?
    private var writerAudioSettings: [String: Any]?
    private var writerPreferredVolume: Float = 1.0
    private var didAttemptWriterRecovery: Bool = false
    private var lastAppendedPTS: CMTime?

    private var startContinuation: CheckedContinuation<Void, Error>?
    private var acceptingSamples = true
    private var didSignalError = false
    private var stopState: StopState = .idle
    private var startedWallTime: CFAbsoluteTime?
    private var receivedSampleCount: UInt64 = 0
    private var appendedSampleCount: UInt64 = 0
    private var didLogNoAppendWarning: Bool = false

    private enum SampleRateSource: String {
        case recommended
        case deviceActiveFormat
        case fallback48k
    }

    func configure(session: AVCaptureSession, device: AVCaptureDevice, delegate: CaptureRecordingDelegate, queue: DispatchQueue) throws {
        self.session = session
        self.delegate = delegate
        self.observedDeviceID = device.uniqueID
        self.callbackQueue = queue

        // Cache the device's native format (sample rate / channels) for better compatibility with external microphones.
        let activeFormat = device.activeFormat
        let desc = activeFormat.formatDescription
        if let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
            let asbd = asbdPtr.pointee
            deviceSampleRate = asbd.mSampleRate
        } else {
            deviceSampleRate = nil
        }

        let dataOut = AVCaptureAudioDataOutput()
        guard session.canAddOutput(dataOut) else { throw RecordingError.cannotAddOutput }
        session.addOutput(dataOut)
        dataOut.setSampleBufferDelegate(delegate, queue: queue)
        self.audioDataOutput = dataOut
        RecorderMicDiagnostics.shared.onConfigureCapture(device: device, audioOutput: dataOut)

        delegate.onAudioSample = { [weak self] sampleBuffer in
            self?.handleSample(sampleBuffer)
        }

        // 内部监听设备/会话状态变化：仅用于转发错误并让上层终止，不做自动重连
        installObservers(for: session)
    }

    func start(fileURL: URL) async throws {
        // Reset per-run state (this backend can be reused by higher-level flows like re-recording).
        // If these flags are left as-is after a previous stop, we may accept audio level callbacks
        // but silently stop writing samples, resulting in a 0-byte output file.
        acceptingSamples = true
        didSignalError = false
        stopState = .idle
        startContinuation = nil
        writerSessionStarted = false
        startedWallTime = nil
        receivedSampleCount = 0
        appendedSampleCount = 0
        didLogNoAppendWarning = false
        didAttemptWriterRecovery = false
        lastAppendedPTS = nil

        self.fileURL = fileURL

        // Best-effort: ensure parent directory exists and remove any stale file.
        // This makes re-recording more resilient when a previous run left a 0-byte placeholder behind.
        let parent = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let writer = try AVAssetWriter(url: fileURL, fileType: .m4a)
        // 固定 10s 片段
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let recommendedSettings = audioDataOutput?.recommendedAudioSettingsForAssetWriter(writingTo: .m4a) as? [String: Any]
        var audioSettings: [String: Any] = recommendedSettings ?? [:]

        // Make sure we always have a concrete sample rate for bitrate decisions / encoder stability.
        let recommendedSampleRate = (audioSettings[AVSampleRateKey] as? NSNumber)?.doubleValue
        let sampleRateSource: SampleRateSource
        let sampleRate: Double
        if let r = recommendedSampleRate {
            sampleRate = r
            sampleRateSource = .recommended
        } else if let r = deviceSampleRate {
            sampleRate = r
            sampleRateSource = .deviceActiveFormat
            audioSettings[AVSampleRateKey] = sampleRate
        } else {
            sampleRate = 48_000
            sampleRateSource = .fallback48k
            audioSettings[AVSampleRateKey] = sampleRate
        }

        // Keep the recommended encoding format when present; default to AAC for `.m4a` otherwise.
        if audioSettings[AVFormatIDKey] == nil {
            audioSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
        }

        // For stability/compatibility, clamp to <= 2 channels only when the recommended setting exceeds 2.
        let recommendedChannels = (audioSettings[AVNumberOfChannelsKey] as? NSNumber)?.intValue
        let finalChannels: Int
        let didOverrideChannels: Bool
        if let ch = recommendedChannels {
            if ch > 2 {
                finalChannels = 2
                didOverrideChannels = true
                audioSettings[AVNumberOfChannelsKey] = finalChannels
                audioSettings.removeValue(forKey: AVChannelLayoutKey)
            } else {
                finalChannels = max(1, ch)
                didOverrideChannels = false
            }
        } else {
            finalChannels = 2
            didOverrideChannels = true
            audioSettings[AVNumberOfChannelsKey] = finalChannels
            audioSettings.removeValue(forKey: AVChannelLayoutKey)
        }

        // Avoid having two "knobs" fighting; pick bitrate only.
        audioSettings.removeValue(forKey: AVEncoderAudioQualityKey)
        let computedBitrate = preferredBitrate(sampleRate: sampleRate, channels: finalChannels)
        if let existing = (audioSettings[AVEncoderBitRateKey] as? NSNumber)?.intValue {
            // If we changed the effective encoding constraints (e.g. clamped channels or had to supply our own sample rate),
            // keep bitrate within a conservative computed bound to avoid waste and potential encoder constraints.
            if didOverrideChannels || sampleRateSource != .recommended {
                audioSettings[AVEncoderBitRateKey] = min(existing, computedBitrate)
            }
        } else {
            audioSettings[AVEncoderBitRateKey] = computedBitrate
        }

        logStartSettings(
            fileURL: fileURL,
            recommendedSettings: recommendedSettings,
            finalSettings: audioSettings,
            sampleRateSource: sampleRateSource,
            recommendedChannels: recommendedChannels,
            finalChannels: finalChannels,
            didOverrideChannels: didOverrideChannels
        )

        RecorderMicDiagnostics.shared.onStartWriter(audioSettings: audioSettings, processingOptions: processingOptions)

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true
        // Use linearGain as a simple per-track volume preference; keep processing in the writer to avoid manual PCM munging.
        let preferredVolume = max(0.0, min(processingOptions.linearGain, 4.0))
        input.preferredVolume = preferredVolume
        guard writer.canAdd(input) else { throw RecordingError.outputNotConfigured }
        writer.add(input)
        guard writer.startWriting() else {
            if let e = writer.error { delegate?.onError(e) }
            throw writer.error ?? RecordingError.outputNotConfigured
        }

        self.writer = writer
        self.input = input
        self.writerSessionStarted = false
        self.writerAudioSettings = audioSettings
        self.writerPreferredVolume = preferredVolume
        self.lastAppendedPTS = nil

        // 等待首帧到来
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.startContinuation = continuation
        }
    }

    private func preferredBitrate(sampleRate: Double, channels: Int) -> Int {
        // Default: 192 kbps stereo AAC (good quality / reasonable size).
        // For low sample rates, drop bitrate to avoid waste and potential encoder constraints.
        let base: Int = (channels <= 1) ? 96_000 : 192_000
        if sampleRate < 22_050 { return min(64_000, base / 2) }
        if sampleRate < 44_100 { return min(96_000, base / 2) }
        return base
    }

    private func logStartSettings(
        fileURL: URL,
        recommendedSettings: [String: Any]?,
        finalSettings: [String: Any],
        sampleRateSource: SampleRateSource,
        recommendedChannels: Int?,
        finalChannels: Int,
        didOverrideChannels: Bool
    ) {
        func num<T: BinaryInteger>(_ key: String, in dict: [String: Any]) -> T? {
            (dict[key] as? NSNumber).map { T($0.int64Value) }
        }
        func numDouble(_ key: String, in dict: [String: Any]) -> Double? {
            (dict[key] as? NSNumber)?.doubleValue
        }
        func has(_ key: String, in dict: [String: Any]) -> Bool {
            dict[key] != nil
        }

        let recSR = recommendedSettings.flatMap { numDouble(AVSampleRateKey, in: $0) }
        let finSR = numDouble(AVSampleRateKey, in: finalSettings) ?? 0
        let recBR: Int? = recommendedSettings.flatMap { num(AVEncoderBitRateKey, in: $0) as Int? }
        let finBR: Int = num(AVEncoderBitRateKey, in: finalSettings) ?? 0
        let recFmt: Int? = recommendedSettings.flatMap { num(AVFormatIDKey, in: $0) as Int? }
        let finFmt: Int = num(AVFormatIDKey, in: finalSettings) ?? 0

        let recLayout = recommendedSettings.map { has(AVChannelLayoutKey, in: $0) } ?? false
        let finLayout = has(AVChannelLayoutKey, in: finalSettings)

        NSLog(
            "🎤 [CR_MIC_SETTINGS] file=%@ rec=%@ -> final: fmt=%d sr=%.0fHz(%@) ch=%@->%d overrideCh=%@ br=%@->%d layout=%@->%@",
            fileURL.lastPathComponent,
            recommendedSettings == nil ? "nil" : "ok",
            finFmt,
            finSR,
            sampleRateSource.rawValue,
            recommendedChannels.map(String.init(describing:)) ?? "nil",
            finalChannels,
            didOverrideChannels ? "yes" : "no",
            recBR.map(String.init(describing:)) ?? "nil",
            finBR,
            recLayout ? "yes" : "no",
            finLayout ? "yes" : "no"
        )
        if let recSR, abs(recSR - finSR) > 0.5 {
            NSLog("🎤 [CR_MIC_SETTINGS] sampleRate adjusted: rec=%.0fHz final=%.0fHz", recSR, finSR)
        }
        if let recFmt, recFmt != finFmt {
            NSLog("🎤 [CR_MIC_SETTINGS] formatID adjusted: rec=%d final=%d", recFmt, finFmt)
        }
    }

    func stop() async throws -> URL? {
        let queue = callbackQueue ?? DispatchQueue(label: "com.recorderkit.microphone.backend.stop", qos: .userInitiated)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL?, Error>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(returning: nil); return }
                guard let session = self.session else { cont.resume(returning: self.fileURL); return }

                switch self.stopState {
                case .idle:
                    self.stopState = .stopping
                case .stopping, .stopped:
                    cont.resume(returning: self.fileURL)
                    return
                }

                self.acceptingSamples = false
                if let startContinuation = self.startContinuation {
                    self.startContinuation = nil
                    startContinuation.resume(throwing: RecordingError.userAbort)
                }

                self.audioDataOutput?.setSampleBufferDelegate(nil, queue: nil)

                func cleanupAndResume(_ result: Result<Void, Error>) {
                    AVCaptureSessionHelper.stopRecordingStep2Close(avSession: session)
                    self.removeObservers()
                    self.stopState = .stopped
                    self.writer = nil
                    self.input = nil
                    self.writerSessionStarted = false
                    self.startContinuation = nil
                    switch result {
                    case .success:
                        cont.resume(returning: self.fileURL)
                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                }

                guard let writer = self.writer else {
                    cleanupAndResume(.success(()))
                    return
                }

                switch writer.status {
                case .writing:
                    guard self.writerSessionStarted else {
                        if let file = self.fileURL?.lastPathComponent {
                            NSLog("🎤 [CR_MIC_STOP] Writer never started session; cancelling. file=%@", file)
                        } else {
                            NSLog("🎤 [CR_MIC_STOP] Writer never started session; cancelling.")
                        }
                        writer.cancelWriting()
                        cleanupAndResume(.success(()))
                        return
                    }
                    self.input?.markAsFinished()
                    writer.finishWriting { [weak self] in
                        guard let self else { return }
                        let result: Result<Void, Error>
                        if let err = writer.error {
                            result = .failure(err)
                        } else {
                            result = .success(())
                        }
                        queue.async { cleanupAndResume(result) }
                    }
                case .failed:
                    cleanupAndResume(.failure(writer.error ?? RecordingError.recordingFailed("AVAssetWriter failed")))
                case .cancelled, .completed, .unknown:
                    cleanupAndResume(.success(()))
                @unknown default:
                    cleanupAndResume(.success(()))
                }
            }
        }
    }

    private func signalErrorOnce(_ error: Error) {
        if !didSignalError {
            didSignalError = true
            delegate?.onError(error)
        }
        if let startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: error)
        }
    }

    // Simple gain/AGC processing without AVAudioEngine.
    private var agcSmoothedGain: Float = 1.0
    private func handleSample(_ sampleBuffer: CMSampleBuffer) {
        guard acceptingSamples, let writer, let input else { return }
        receivedSampleCount &+= 1
        RecorderMicDiagnostics.shared.observe(sampleBuffer: sampleBuffer)

        // Defensive guards: AVAssetWriter can fail (often -11800 with an OSStatus underlying error)
        // if we append a malformed / not-ready / non-monotonic sample buffer.
        if !CMSampleBufferDataIsReady(sampleBuffer) {
            if !didLogNoAppendWarning {
                didLogNoAppendWarning = true
                let file = fileURL?.lastPathComponent ?? "<nil>"
                NSLog("⚠️ [CR_MIC_SAMPLE_NOT_READY] file=%@", file)
            }
            return
        }
        if CMSampleBufferGetNumSamples(sampleBuffer) <= 0 {
            return
        }
        guard sampleBuffer.formatDescription != nil else {
            if !didLogNoAppendWarning {
                didLogNoAppendWarning = true
                let file = fileURL?.lastPathComponent ?? "<nil>"
                NSLog("⚠️ [CR_MIC_SAMPLE_NO_FORMAT] file=%@", file)
            }
            return
        }

        if writer.status == .failed {
            let err = writer.error
            let ns = err.map { $0 as NSError }
            let file = fileURL?.lastPathComponent ?? "<nil>"
            if let ns {
                let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
                if let underlying {
                    NSLog(
                        "❌ [CR_MIC_WRITER_FAILED] file=%@ domain=%@ code=%ld msg=%@ underlying=%@/%ld %@",
                        file,
                        ns.domain,
                        ns.code,
                        ns.localizedDescription,
                        underlying.domain,
                        underlying.code,
                        underlying.localizedDescription
                    )
                } else {
                    NSLog("❌ [CR_MIC_WRITER_FAILED] file=%@ domain=%@ code=%ld msg=%@", file, ns.domain, ns.code, ns.localizedDescription)
                }
            } else {
                NSLog("❌ [CR_MIC_WRITER_FAILED] file=%@ msg=%@", file, "nil error")
            }

            // One-shot recovery attempt: keep the overall recording running if possible.
            if !didAttemptWriterRecovery {
                didAttemptWriterRecovery = true
                attemptWriterRecovery()
                return
            }

            signalErrorOnce(err ?? RecordingError.recordingFailed("Audio writer failed"))
            return
        }
        let pts = sampleBuffer.presentationTimeStamp
        if !pts.isValid || !pts.isNumeric {
            if !didLogNoAppendWarning {
                didLogNoAppendWarning = true
                let file = fileURL?.lastPathComponent ?? "<nil>"
                NSLog("⚠️ [CR_MIC_PTS_INVALID] file=%@ dropping", file)
            }
            return
        }
        if !writerSessionStarted {
            writer.startSession(atSourceTime: pts)
            writerSessionStarted = true
            startedWallTime = CFAbsoluteTimeGetCurrent()
            onFirstPTS?(pts)
            startContinuation?.resume(returning: ())
            startContinuation = nil
        }

        // Guard against non-monotonic timestamps. A single bad PTS can make AVAssetWriter fail with -11800.
        if let last = lastAppendedPTS, pts < last {
            if !didLogNoAppendWarning {
                didLogNoAppendWarning = true
                let file = fileURL?.lastPathComponent ?? "<nil>"
                NSLog(
                    "⚠️ [CR_MIC_PTS_NON_MONOTONIC] file=%@ pts=%.6f last=%.6f dropping",
                    file,
                    pts.seconds,
                    last.seconds
                )
            }
            return
        }

        guard input.isReadyForMoreMediaData, writer.status == .writing else {
            if writer.status == .failed {
                signalErrorOnce(writer.error ?? RecordingError.recordingFailed("Audio writer failed"))
            }

            // If we see a lot of audio samples but never append any, the file can remain 0 bytes.
            // Log once to speed up debugging for probabilistic re-record issues.
            if !didLogNoAppendWarning,
               appendedSampleCount == 0,
               receivedSampleCount > 80,
               let startedWallTime,
               CFAbsoluteTimeGetCurrent() - startedWallTime > 1.0
            {
                didLogNoAppendWarning = true
                let path = self.fileURL?.path(percentEncoded: false) ?? "<nil>"
                let size: Int64 = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? -1
                NSLog(
                    "⚠️ [CR_MIC_NO_APPEND] file=%@ size=%lld writerStatus=%ld ready=%@ received=%llu appended=%llu",
                    (self.fileURL?.lastPathComponent ?? "<nil>"),
                    size,
                    writer.status.rawValue,
                    input.isReadyForMoreMediaData ? "yes" : "no",
                    receivedSampleCount,
                    appendedSampleCount
                )
            }

            if appendedSampleCount == 0,
               !didAttemptWriterRecovery,
               receivedSampleCount > 120,
               let startedWallTime,
               CFAbsoluteTimeGetCurrent() - startedWallTime > 1.5
            {
                didAttemptWriterRecovery = true
                attemptWriterRecovery()
            }

            return
        }

        // For maximum compatibility with external microphones, avoid manual PCM processing
        // and delegate resampling/mixing to AVAssetWriter.
        let ok = input.append(sampleBuffer)
        if ok {
            appendedSampleCount &+= 1
            lastAppendedPTS = pts
        }
        if !ok {
            // One-shot recovery attempt before propagating an error (which would interrupt the whole recording).
            if !didAttemptWriterRecovery {
                didAttemptWriterRecovery = true
                attemptWriterRecovery()
                return
            }
            // `append` can fail without immediately switching `writer.status` to `.failed` in some edge cases.
            // Treat this as an error to avoid silently producing a 0-byte file.
            signalErrorOnce(writer.error ?? RecordingError.recordingFailed("Audio append returned false"))
        }
    }

    private func attemptWriterRecovery() {
        guard let fileURL else { return }
        guard let audioSettings = writerAudioSettings else { return }

        if let file = fileURL.lastPathComponent as String? {
            NSLog("🛠️ [CR_MIC_RECOVER] Attempting writer recovery. file=%@", file)
        } else {
            NSLog("🛠️ [CR_MIC_RECOVER] Attempting writer recovery.")
        }

        writer?.cancelWriting()
        writer = nil
        input = nil
        writerSessionStarted = false
        startedWallTime = nil
        receivedSampleCount = 0
        appendedSampleCount = 0
        didLogNoAppendWarning = false
        lastAppendedPTS = nil

        // Best-effort: reset the file and restart the writer with the same settings.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }

        do {
            let writer = try AVAssetWriter(url: fileURL, fileType: .m4a)
            writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            input.preferredVolume = writerPreferredVolume
            guard writer.canAdd(input) else {
                signalErrorOnce(RecordingError.outputNotConfigured)
                return
            }
            writer.add(input)
            guard writer.startWriting() else {
                signalErrorOnce(writer.error ?? RecordingError.outputNotConfigured)
                return
            }

            self.writer = writer
            self.input = input
            self.writerSessionStarted = false
            self.lastAppendedPTS = nil
        } catch {
            signalErrorOnce(error)
        }
    }

    // MARK: - Observers → onError
    private func installObservers(for session: AVCaptureSession) {
        let nc = NotificationCenter.default
        let o1 = nc.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] note in
            self?.signalErrorOnce(RecordingError.recordingFailed("Microphone session interrupted"))
        }
        let o2 = nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
            if let err = note.userInfo?[AVCaptureSessionErrorKey] as? Error {
                self?.signalErrorOnce(err)
            } else {
                self?.signalErrorOnce(RecordingError.recordingFailed("Microphone runtime error"))
            }
        }
        let o3 = nc.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: nil) { [weak self] n in
            guard let self else { return }
            guard let dev = n.object as? AVCaptureDevice else { return }
            if dev.uniqueID == self.observedDeviceID {
                self.signalErrorOnce(RecordingError.recordingFailed("Microphone disconnected"))
            }
        }
        observers = [o1, o2, o3]
    }
    private func removeObservers() {
        let nc = NotificationCenter.default
        observers.forEach { nc.removeObserver($0) }
        observers.removeAll()
    }
}
