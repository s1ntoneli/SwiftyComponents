import Foundation
import AVFoundation
import ScreenCaptureKit

// Class semantics avoid cross-queue value-copy races when accessed from
// separate audio/video queues and during finalize.
final class WriterPipeline {
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput?
    private(set) var didStartSession: Bool = false
    // Keep last video for final keepalive
    private var lastVideoSample: CMSampleBuffer?
    private var lastVideoPTS: CMTime?
    // 防重入/并发 finish 保护
    private var isFinishing: Bool = false

    init(writer: AVAssetWriter, videoInput: AVAssetWriterInput, audioInput: AVAssetWriterInput?, didStartSession: Bool) {
        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.didStartSession = didStartSession
    }

    static func create(
        url: URL,
        configuration: SCStreamConfiguration,
        hdr: Bool,
        includeAudio: Bool,
        options: ScreenRecorderOptions
    ) throws -> WriterPipeline {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: RecorderDiagnostics.shared.fragmentIntervalSeconds, preferredTimescale: 600)

        let size = (width: configuration.width, height: configuration.height)
        let vSettings = try RecorderConfig.videoSettings(for: size, configuration: configuration, hdr: hdr, options: options)
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(vInput) else { throw RecordingError.recordingFailed("Can't add video input") }
        writer.add(vInput)

        var aInput: AVAssetWriterInput? = nil
        if includeAudio {
            let aSettings = RecorderConfig.audioSettings()
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input); aInput = input }
        }

        guard writer.startWriting() else { throw writer.error ?? RecordingError.recordingFailed("startWriting failed") }
        return WriterPipeline(writer: writer, videoInput: vInput, audioInput: aInput, didStartSession: false)
    }

    func startSession(at pts: CMTime) {
        guard !didStartSession else { return }
        writer.startSession(atSourceTime: pts)
        didStartSession = true
        lastVideoPTS = pts
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        // 若正在 finish 或尚未 startSession（例如“首帧前停止” race），直接丢弃，避免 AVAssetWriter 崩溃
        if isFinishing || !didStartSession { return }
        let ready = videoInput.isReadyForMoreMediaData
        RecorderDiagnostics.shared.beforeAppendVideo(ready: ready, status: writer.status)
        guard writer.status == .writing, ready else {
            if !ready { RecorderDiagnostics.shared.onDroppedVideoNotReady() }
            return
        }
        if videoInput.append(sample) {
            lastVideoSample = sample
            lastVideoPTS = sample.presentationTimeStamp
            RecorderDiagnostics.shared.onAppendedVideo()
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        guard let audioInput else { return }
        if isFinishing || !didStartSession { return }
        let ready = audioInput.isReadyForMoreMediaData
        RecorderDiagnostics.shared.beforeAppendAudio(ready: ready, status: writer.status)
        guard writer.status == .writing, ready else {
            if !ready { RecorderDiagnostics.shared.onDroppedAudioNotReady() }
            return
        }
        if audioInput.append(sample) {
            RecorderDiagnostics.shared.onAppendedAudio()
        }
    }

    func finish() async throws {
        // 防止重入：并发或重复调用 finish()
        if isFinishing { return }
        isFinishing = true
        // 仅当处于 .writing 状态时才允许 finishWriting；否则直接返回或抛出底层错误
        switch writer.status {
        case .completed:
            return
        case .failed:
            if let err = writer.error { throw err }
            return
        case .cancelled:
            return
        case .writing:
            // 若从未 startSession，则不应调用 finishWriting，改为取消写入以避免崩溃
            if !didStartSession {
                writer.cancelWriting()
                return
            }
            // Best-effort: append a duplicated last frame to cover trailing silent period
            appendFinalKeepaliveIfNeeded()
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            let w = writer
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                w.finishWriting {
                    if let err = w.error { cont.resume(throwing: err) } else { cont.resume() }
                }
            }
        case .unknown:
            // 理论上不会出现：create() 已调用 startWriting；稳妥起见直接返回
            return
        @unknown default:
            return
        }
    }

    private func appendFinalKeepaliveIfNeeded() {
        guard let base = lastVideoSample else { return }
        let nowPTS = CMClockGetTime(CMClockGetHostTimeClock())
        if let last = lastVideoPTS {
            if CMTimeCompare(nowPTS, last) <= 0 { return }
            let duration: CMTime = {
                let d = base.duration
                if d.isValid && d.value != 0 { return d }
                return CMTime(value: 1, timescale: 60)
            }()
            var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: nowPTS, decodeTimeStamp: base.decodeTimeStamp)
            if let dup = try? CMSampleBuffer(copying: base, withNewTiming: [timing]) {
                let ready = videoInput.isReadyForMoreMediaData
                RecorderDiagnostics.shared.beforeAppendVideo(ready: ready, status: writer.status)
                if writer.status == .writing, ready, videoInput.append(dup) {
                    RecorderDiagnostics.shared.onAppendedVideo()
                    RecorderDiagnostics.shared.logFlow("keepalive final video appended")
                } else if !ready {
                    RecorderDiagnostics.shared.onDroppedVideoNotReady()
                    RecorderDiagnostics.shared.logFlow("keepalive final drop: not ready")
                }
            }
        }
    }
}
