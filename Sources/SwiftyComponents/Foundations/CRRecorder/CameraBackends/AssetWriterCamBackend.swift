import Foundation
import AVFoundation

final class AssetWriterCamBackend: CameraBackend {
    var onFirstPTS: ((CMTime) -> Void)?

    private weak var session: AVCaptureSession?
    private weak var delegate: CaptureRecordingDelegate?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    private weak var device: AVCaptureDevice?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var writerSessionStarted = false
    private var fileURL: URL?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var acceptingSamples = true
    private var options: CameraRecordingOptions = .init()

    func apply(options: CameraRecordingOptions) { self.options = options }

    func configure(session: AVCaptureSession, device: AVCaptureDevice, delegate: CaptureRecordingDelegate, queue: DispatchQueue) throws {
        self.session = session
        self.delegate = delegate
        self.device = device

        session.beginConfiguration()
        // 视频数据输出
        let vdo = AVCaptureVideoDataOutput()
        vdo.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(vdo) else { session.commitConfiguration(); throw RecordingError.cannotAddOutput }
        session.addOutput(vdo)
        vdo.setSampleBufferDelegate(delegate, queue: queue)
        self.videoDataOutput = vdo

        // 如无音频输入，尝试按名称匹配添加对应音频输入
        let hasAudioInput = session.inputs.contains { inp in
            guard let di = inp as? AVCaptureDeviceInput else { return false }
            return di.device.hasMediaType(.audio)
        }

        // 音频数据输出
        let ado = AVCaptureAudioDataOutput()
        if session.canAddOutput(ado) {
            session.addOutput(ado)
            ado.setSampleBufferDelegate(delegate, queue: queue)
            self.audioDataOutput = ado
        }
        session.commitConfiguration()

        delegate.onVideoSample = { [weak self] sampleBuffer in
            self?.handleVideoSample(sampleBuffer)
        }
        delegate.onAudioSample = { [weak self] sampleBuffer in
            self?.handleAudioSample(sampleBuffer)
        }
    }

    func start(fileURL: URL) async throws {
        self.fileURL = fileURL
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.startContinuation = continuation
        }
    }

    func stop() async throws -> URL? {
        guard let session else { return fileURL }
        acceptingSamples = false
        // 停止回调，防止在标记 finished 后仍有 append 发生
        videoDataOutput?.setSampleBufferDelegate(nil, queue: nil)
        audioDataOutput?.setSampleBufferDelegate(nil, queue: nil)
        videoInput?.markAsFinished()
        if let writer { await writer.finishWriting() }
        AVCaptureSessionHelper.stopRecordingStep2Close(avSession: session)
        return fileURL
    }

    private func handleVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard acceptingSamples, CMSampleBufferIsValid(sampleBuffer) else { return }
        let pts = sampleBuffer.presentationTimeStamp
        if writer == nil {
            // 按首帧尺寸创建视频输入与写入器
            guard let url = fileURL else { return }
            do { self.writer = try AVAssetWriter(url: url, fileType: .mov) } catch { return }
            // 固定 10s 片段
            self.writer?.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

            var width = 1280
            var height = 720
            if let img = CMSampleBufferGetImageBuffer(sampleBuffer) {
                width = CVPixelBufferGetWidth(img)
                height = CVPixelBufferGetHeight(img)
            }
            // 依据分辨率与帧率估算目标码率；默认 H.264，可按开关尝试 HEVC
            let fps: Int = {
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
            // 同步创建音频输入
            let aSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVEncoderBitRateKey: 128_000
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
            aInput.expectsMediaDataInRealTime = true

            if let writer, writer.canAdd(vInput) { writer.add(vInput); self.videoInput = vInput }
            if let writer, writer.canAdd(aInput) { writer.add(aInput); self.audioInput = aInput }

            if let writer, writer.startWriting() {
                writer.startSession(atSourceTime: pts)
                writerSessionStarted = true
                onFirstPTS?(pts)
                startContinuation?.resume(returning: ())
                startContinuation = nil
            }
        }

        if acceptingSamples, let input = videoInput, input.isReadyForMoreMediaData, writer?.status == .writing {
            _ = input.append(sampleBuffer)
        }
    }

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        // 仅在会话已启动后写入音频；若音频先到，直接丢弃以避免未 startSession 时 append 触发崩溃。
        guard acceptingSamples, writerSessionStarted, let aIn = audioInput, aIn.isReadyForMoreMediaData, writer?.status == .writing else { return }
        _ = aIn.append(sampleBuffer)
    }

    
}
