import Foundation
import AVFoundation

final class AssetWriterCamBackend: CameraBackend {
    var onFirstPTS: ((CMTime) -> Void)?
    weak var videoFPSSink: ScreenVideoFPSEventSink?

    private enum SampleRateSource: String {
        case recommended
        case fallback48k
    }

    private enum StopState {
        case idle
        case stopping
        case stopped
    }

    private weak var session: AVCaptureSession?
    private weak var delegate: CaptureRecordingDelegate?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    private weak var device: AVCaptureDevice?
    private var callbackQueue: DispatchQueue?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var writerSessionStarted = false
    private var fileURL: URL?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var acceptingSamples = true
    private var options: CameraRecordingOptions = .init()
    // 仅当会话内存在音频输入时才写入音轨
    private var hasAudioInputInSession: Bool = false
    // 记录最后一帧视频样本以便在收尾时做一次 keepalive（与屏幕录制保持一致）
    private var lastVideoSample: CMSampleBuffer?
    private var lastVideoPTS: CMTime?
    // 对齐音频时间轴：记录首帧视频 PTS 以及音频的时间偏移，避免“系统音频”设备使用不同时钟导致长时间静止帧。
    private var firstVideoPTS: CMTime?
    private var audioTimeOffset: CMTime?

    func apply(options: CameraRecordingOptions) { self.options = options }
    private var didSignalError = false
    private var observers: [Any] = []
    private var observedDeviceID: String?
    private var stopState: StopState = .idle

    func configure(session: AVCaptureSession, device: AVCaptureDevice?, delegate: CaptureRecordingDelegate, queue: DispatchQueue) throws {
        self.session = session
        self.delegate = delegate
        self.device = device
        self.observedDeviceID = device?.uniqueID
        self.callbackQueue = queue

        session.beginConfiguration()
        // 视频数据输出
        let vdo = AVCaptureVideoDataOutput()
        vdo.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(vdo) else { session.commitConfiguration(); throw RecordingError.cannotAddOutput }
        session.addOutput(vdo)
        vdo.setSampleBufferDelegate(delegate, queue: queue)
        self.videoDataOutput = vdo

        // 记录当前会话是否存在音频输入（摄像头方案通常没有，为避免写入空音轨导致分段/刷新异常，仅在存在音频输入时添加音频输出与写入器音轨）
        let hasAudioInput = session.inputs.contains { inp in
            guard let di = inp as? AVCaptureDeviceInput else { return false }
            return di.device.hasMediaType(.audio)
        }
        self.hasAudioInputInSession = hasAudioInput

        // 音频数据输出：仅当会话中确实存在音频输入设备时才添加
        var hasAudioOutput: Bool = false
        if hasAudioInput {
            let ado = AVCaptureAudioDataOutput()
            if session.canAddOutput(ado) {
                session.addOutput(ado)
                ado.setSampleBufferDelegate(delegate, queue: queue)
                self.audioDataOutput = ado
                hasAudioOutput = true
            }
        }
        session.commitConfiguration()
        // Only write an audio track if we can actually receive audio sample buffers.
        self.hasAudioInputInSession = hasAudioInput && hasAudioOutput

        delegate.onVideoSample = { [weak self] sampleBuffer in
            self?.handleVideoSample(sampleBuffer)
        }
        delegate.onAudioSample = { [weak self] sampleBuffer in
            self?.handleAudioSample(sampleBuffer)
        }

        // 仅用于抛错通知上层停止；不在后端做自动重连
        installObservers(for: session)
    }

    func start(fileURL: URL) async throws {
        self.fileURL = fileURL
        // 更新诊断中心文件路径，便于外部观察文件大小增长/片段刷新
        RecorderDiagnostics.shared.setOutputFileURL(fileURL)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.startContinuation = continuation
        }
    }

    func stop() async throws -> URL? {
        let queue = callbackQueue ?? DispatchQueue(label: "com.recorderkit.camera.backend.stop", qos: .userInitiated)
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

                // 停止回调，防止在标记 finished 后仍有 append 发生
                self.videoDataOutput?.setSampleBufferDelegate(nil, queue: nil)
                self.audioDataOutput?.setSampleBufferDelegate(nil, queue: nil)

                func cleanupAndResume(_ result: Result<Void, Error>) {
                    AVCaptureSessionHelper.stopRecordingStep2Close(avSession: session)
                    self.removeObservers()
                    self.stopState = .stopped
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
                        writer.cancelWriting()
                        cleanupAndResume(.success(()))
                        return
                    }
                    // 在 markAsFinished 前尝试注入一次 keepalive，帮助触发尾段刷新
                    self.appendFinalKeepaliveIfNeeded()
                    self.videoInput?.markAsFinished()
                    self.audioInput?.markAsFinished()
                    writer.finishWriting { [weak self] in
                        guard let self else { return }
                        let result: Result<Void, Error>
                        if let err = writer.error {
                            result = .failure(err)
                        } else {
                            RecorderDiagnostics.shared.onWriterStopped()
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

    private func handleVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard acceptingSamples, CMSampleBufferIsValid(sampleBuffer) else { return }
        videoFPSSink?.onCaptureVideoFrame()
        let pts = sampleBuffer.presentationTimeStamp
        if writer == nil {
            // 按首帧尺寸创建视频输入与写入器
            guard let url = fileURL else { return }
            do {
                self.writer = try AVAssetWriter(url: url, fileType: .mov)
                // 与屏幕录制保持一致，使用可调的 fragment 间隔，便于实时分段写入
                self.writer?.movieFragmentInterval = CMTime(seconds: RecorderDiagnostics.shared.fragmentIntervalSeconds, preferredTimescale: 600)
            } catch {
                signalErrorOnce(error)
                return
            }

            guard let img = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                #if DEBUG
                NSLog("📹 [CR_CAM_WRITE] firstFrame missing image buffer; waiting for next frame")
                #endif
                return
            }
            let width = CVPixelBufferGetWidth(img)
            let height = CVPixelBufferGetHeight(img)
            #if DEBUG
            if let d = device {
                let fmt = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
                NSLog(
                    "📹 [CR_CAM_WRITE] firstFrame=%dx%d device=%@ activeFormat=%dx%d",
                    width,
                    height,
                    d.localizedName,
                    fmt.width,
                    fmt.height
                )
            } else {
                NSLog("📹 [CR_CAM_WRITE] firstFrame=%dx%d device=nil", width, height)
            }
            #endif
            // 依据分辨率与帧率估算目标码率；默认 H.264，可按开关尝试 HEVC
            let fps: Int = {
                if let override = options.bitrateFPSOverride, override > 0 {
                    return override
                }
                if let d = device {
                    let min = d.activeVideoMinFrameDuration
                    if min.value != 0 { return max(1, Int(round(Double(min.timescale) / Double(min.value)))) }
                }
                return 60
            }()
            func buildSettings(codec: AVVideoCodecType, bpp: Double) -> [String: Any] {
                let computed = Int(Double(width * height * max(1, fps)) * bpp)
                let targetBitrate = max(options.minBitrate, min(computed, options.maxBitrate))
                var comp: [String: Any] = [
                    AVVideoAverageBitRateKey: targetBitrate,
                    AVVideoMaxKeyFrameIntervalDurationKey: 2,
                    AVVideoExpectedSourceFrameRateKey: fps,
                    AVVideoAllowFrameReorderingKey: true
                ]
                if codec == .h264 {
                    comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
                    comp[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
                }
                return [
                    AVVideoCodecKey: codec,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: comp
                ]
            }

            // 优先选择开关指定的编码器；若 HEVC 不可用则回退 H.264
            let tryHEVC = options.preferHEVC
            let hevcSettings = buildSettings(codec: .hevc, bpp: options.bppHEVC)
            let h264Settings = buildSettings(codec: .h264, bpp: options.bppH264)
            let settings: [String: Any]
            if tryHEVC, let writer, writer.canApply(outputSettings: hevcSettings, forMediaType: .video) {
                settings = hevcSettings
            } else {
                settings = h264Settings
            }
            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            vInput.expectsMediaDataInRealTime = true

            // 同步创建音频输入：仅在会话存在音频输入时添加，避免空音轨阻滞片段刷新
            var aInput: AVAssetWriterInput? = nil
            if hasAudioInputInSession {
                let (aSettings, audioLog) = buildAudioSettings()
                logStartSettings(
                    fileURL: url,
                    writerFileType: .mov,
                    videoWidth: width,
                    videoHeight: height,
                    fps: fps,
                    usedHEVC: settings[AVVideoCodecKey] as? String == AVVideoCodecType.hevc.rawValue,
                    targetVideoBitrate: (settings[AVVideoCompressionPropertiesKey] as? [String: Any]).flatMap { $0[AVVideoAverageBitRateKey] as? NSNumber }?.intValue,
                    audioLog: audioLog
                )

                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
                input.expectsMediaDataInRealTime = true
                aInput = input
            } else {
                logStartSettings(
                    fileURL: url,
                    writerFileType: .mov,
                    videoWidth: width,
                    videoHeight: height,
                    fps: fps,
                    usedHEVC: settings[AVVideoCodecKey] as? String == AVVideoCodecType.hevc.rawValue,
                    targetVideoBitrate: (settings[AVVideoCompressionPropertiesKey] as? [String: Any]).flatMap { $0[AVVideoAverageBitRateKey] as? NSNumber }?.intValue,
                    audioLog: nil
                )
            }

            guard let writer else { signalErrorOnce(RecordingError.outputNotConfigured); return }
            guard writer.canAdd(vInput) else {
                signalErrorOnce(RecordingError.outputNotConfigured)
                return
            }
            writer.add(vInput)
            self.videoInput = vInput

            if let aInput {
                guard writer.canAdd(aInput) else {
                    signalErrorOnce(RecordingError.outputNotConfigured)
                    return
                }
                writer.add(aInput)
                self.audioInput = aInput
            }

            if writer.startWriting() {
                RecorderDiagnostics.shared.onWriterStarted()
                writer.startSession(atSourceTime: pts)
                writerSessionStarted = true
                firstVideoPTS = pts
                onFirstPTS?(pts)
                startContinuation?.resume(returning: ())
                startContinuation = nil
            } else {
                signalErrorOnce(writer.error ?? RecordingError.recordingFailed("Camera writer start failed"))
            }
        }

        if acceptingSamples, let input = videoInput, writer?.status == .writing {
            let ready = input.isReadyForMoreMediaData
            if !ready {
                videoFPSSink?.onDroppedVideoFrameNotReady()
                return
            }
            let ok = input.append(sampleBuffer)
            if ok {
                lastVideoSample = sampleBuffer
                lastVideoPTS = sampleBuffer.presentationTimeStamp
                videoFPSSink?.onAppendedVideoFrame()
            }
            if let w = writer, (!ok || w.status == .failed) {
                signalErrorOnce(w.error ?? RecordingError.recordingFailed("Camera video append failed"))
            }
        }
    }

    private struct CameraAudioSettingsLog {
        let recommendedAvailable: Bool
        let sampleRateHz: Double
        let sampleRateSource: SampleRateSource
        let channelsRecommended: Int?
        let channelsFinal: Int
        let didOverrideChannels: Bool
        let bitrateRecommended: Int?
        let bitrateFinal: Int
        let formatIDFinal: Int
        let hadChannelLayoutRecommended: Bool
        let hasChannelLayoutFinal: Bool
    }

    private func buildAudioSettings() -> ([String: Any], CameraAudioSettingsLog) {
        let rec = audioDataOutput?.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
        var audioSettings: [String: Any] = rec ?? [:]

        let recommendedAvailable = (rec != nil)
        let recommendedSampleRate = (audioSettings[AVSampleRateKey] as? NSNumber)?.doubleValue
        let sampleRateSource: SampleRateSource
        let sampleRate: Double
        if let r = recommendedSampleRate {
            sampleRate = r
            sampleRateSource = .recommended
        } else {
            sampleRate = 48_000
            sampleRateSource = .fallback48k
            audioSettings[AVSampleRateKey] = sampleRate
        }

        if audioSettings[AVFormatIDKey] == nil {
            audioSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
        }

        let channelsRecommended = (audioSettings[AVNumberOfChannelsKey] as? NSNumber)?.intValue
        let channelsFinal: Int
        let didOverrideChannels: Bool
        if let ch = channelsRecommended {
            if ch > 2 {
                channelsFinal = 2
                didOverrideChannels = true
                audioSettings[AVNumberOfChannelsKey] = channelsFinal
                audioSettings.removeValue(forKey: AVChannelLayoutKey)
            } else {
                channelsFinal = max(1, ch)
                didOverrideChannels = false
            }
        } else {
            channelsFinal = 2
            didOverrideChannels = true
            audioSettings[AVNumberOfChannelsKey] = channelsFinal
            audioSettings.removeValue(forKey: AVChannelLayoutKey)
        }

        let hadChannelLayoutRecommended = (rec?[AVChannelLayoutKey] != nil)
        let hasChannelLayoutFinal = (audioSettings[AVChannelLayoutKey] != nil)

        audioSettings.removeValue(forKey: AVEncoderAudioQualityKey)
        let computedBitrate = preferredAudioBitrate(sampleRate: sampleRate, channels: channelsFinal)
        if let existing = (audioSettings[AVEncoderBitRateKey] as? NSNumber)?.intValue {
            // If we changed encoding constraints, cap bitrate conservatively.
            if didOverrideChannels || sampleRateSource != .recommended {
                audioSettings[AVEncoderBitRateKey] = min(existing, computedBitrate)
            }
        } else {
            audioSettings[AVEncoderBitRateKey] = computedBitrate
        }

        let bitrateRecommended = (rec?[AVEncoderBitRateKey] as? NSNumber)?.intValue
        let bitrateFinal = (audioSettings[AVEncoderBitRateKey] as? NSNumber)?.intValue ?? 0
        let formatIDFinal = (audioSettings[AVFormatIDKey] as? NSNumber)?.intValue ?? 0

        let log = CameraAudioSettingsLog(
            recommendedAvailable: recommendedAvailable,
            sampleRateHz: sampleRate,
            sampleRateSource: sampleRateSource,
            channelsRecommended: channelsRecommended,
            channelsFinal: channelsFinal,
            didOverrideChannels: didOverrideChannels,
            bitrateRecommended: bitrateRecommended,
            bitrateFinal: bitrateFinal,
            formatIDFinal: formatIDFinal,
            hadChannelLayoutRecommended: hadChannelLayoutRecommended,
            hasChannelLayoutFinal: hasChannelLayoutFinal
        )
        return (audioSettings, log)
    }

    private func preferredAudioBitrate(sampleRate: Double, channels: Int) -> Int {
        // Conservative defaults; prioritize stability and avoid waste at low sample rates.
        let base: Int = (channels <= 1) ? 96_000 : 192_000
        if sampleRate < 22_050 { return min(64_000, base / 2) }
        if sampleRate < 44_100 { return min(96_000, base / 2) }
        return base
    }

    private func logStartSettings(
        fileURL: URL,
        writerFileType: AVFileType,
        videoWidth: Int,
        videoHeight: Int,
        fps: Int,
        usedHEVC: Bool,
        targetVideoBitrate: Int?,
        audioLog: CameraAudioSettingsLog?
    ) {
        if let audioLog {
            NSLog(
                "📹 [CR_CAM_SETTINGS] file=%@ type=%@ v=%dx%d@%dfps codec=%@ vBR=%@ aRec=%@ aFmt=%d aSR=%.0fHz(%@) aCh=%@->%d overrideCh=%@ aBR=%@->%d layout=%@->%@",
                fileURL.lastPathComponent,
                writerFileType.rawValue,
                videoWidth,
                videoHeight,
                fps,
                usedHEVC ? "hevc" : "h264",
                targetVideoBitrate.map(String.init(describing:)) ?? "nil",
                audioLog.recommendedAvailable ? "ok" : "nil",
                audioLog.formatIDFinal,
                audioLog.sampleRateHz,
                audioLog.sampleRateSource.rawValue,
                audioLog.channelsRecommended.map(String.init(describing:)) ?? "nil",
                audioLog.channelsFinal,
                audioLog.didOverrideChannels ? "yes" : "no",
                audioLog.bitrateRecommended.map(String.init(describing:)) ?? "nil",
                audioLog.bitrateFinal,
                audioLog.hadChannelLayoutRecommended ? "yes" : "no",
                audioLog.hasChannelLayoutFinal ? "yes" : "no"
            )
        } else {
            NSLog(
                "📹 [CR_CAM_SETTINGS] file=%@ type=%@ v=%dx%d@%dfps codec=%@ vBR=%@ (no audio track)",
                fileURL.lastPathComponent,
                writerFileType.rawValue,
                videoWidth,
                videoHeight,
                fps,
                usedHEVC ? "hevc" : "h264",
                targetVideoBitrate.map(String.init(describing:)) ?? "nil"
            )
        }
    }

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        // 仅在会话已启动后写入音频；若音频先到，直接丢弃以避免未 startSession 时 append 触发崩溃。
        guard acceptingSamples, writerSessionStarted, let aIn = audioInput, aIn.isReadyForMoreMediaData, writer?.status == .writing else {
            if let w = writer, w.status == .failed {
                signalErrorOnce(w.error ?? RecordingError.recordingFailed("Camera audio writer failed"))
            }
            return
        }
        // 当屏幕录制附带“系统音频”时，音频设备的时钟可能与视频使用的时钟有较大偏移。
        // 这里按第一次音频与视频的 PTS 差值对齐整条音轨，避免出现“几秒录制 → 数小时静止帧”的情况。
        let bufferToAppend: CMSampleBuffer
        if let base = firstVideoPTS {
            if audioTimeOffset == nil {
                audioTimeOffset = CMTimeSubtract(sampleBuffer.presentationTimeStamp, base)
            }
            if let offset = audioTimeOffset {
                let adjPTS = CMTimeSubtract(sampleBuffer.presentationTimeStamp, offset)
                var timing = CMSampleTimingInfo(
                    duration: sampleBuffer.duration,
                    presentationTimeStamp: adjPTS,
                    decodeTimeStamp: sampleBuffer.decodeTimeStamp
                )
                if let reTimed = try? CMSampleBuffer(copying: sampleBuffer, withNewTiming: [timing]) {
                    bufferToAppend = reTimed
                } else {
                    bufferToAppend = sampleBuffer
                }
            } else {
                bufferToAppend = sampleBuffer
            }
        } else {
            bufferToAppend = sampleBuffer
        }

        let ok = aIn.append(bufferToAppend)
        if let w = writer, (!ok || w.status == .failed) {
            signalErrorOnce(w.error ?? RecordingError.recordingFailed("Camera audio append failed"))
        }
    }

    private func appendFinalKeepaliveIfNeeded() {
        guard let base = lastVideoSample else { return }
        if let last = lastVideoPTS {
            // 在时间轴上紧跟最后一帧追加一个 keepalive 帧，避免使用 hostTime 造成极大时间跳跃。
            let duration: CMTime = {
                let d = base.duration
                if d.isValid && d.value != 0 { return d }
                return CMTime(value: 1, timescale: 60)
            }()
            let newPTS = CMTimeAdd(last, duration)
            var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: newPTS, decodeTimeStamp: base.decodeTimeStamp)
            if let dup = try? CMSampleBuffer(copying: base, withNewTiming: [timing]),
               let input = videoInput, input.isReadyForMoreMediaData, writer?.status == .writing {
                _ = input.append(dup)
            }
        }
    }
}

// MARK: - Observers → onError
extension AssetWriterCamBackend {
    private func installObservers(for session: AVCaptureSession) {
        let nc = NotificationCenter.default
        let o1 = nc.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] _ in
            self?.signalErrorOnce(RecordingError.recordingFailed("Camera session interrupted"))
        }
        let o2 = nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
            if let err = note.userInfo?[AVCaptureSessionErrorKey] as? Error {
                self?.signalErrorOnce(err)
            } else {
                self?.signalErrorOnce(RecordingError.recordingFailed("Camera runtime error"))
            }
        }
        let o3 = nc.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: nil) { [weak self] n in
            guard let self,
                  let dev = n.object as? AVCaptureDevice,
                  let observedID = self.observedDeviceID,
                  dev.uniqueID == observedID else { return }
            self.signalErrorOnce(RecordingError.recordingFailed("Camera disconnected"))
        }
        observers = [o1, o2, o3]
    }
    private func removeObservers() {
        let nc = NotificationCenter.default
        observers.forEach { nc.removeObserver($0) }
        observers.removeAll()
    }
}
