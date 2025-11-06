import Foundation
import AVFoundation

final class AssetWriterMicBackend: MicrophoneBackend {
    var onFirstPTS: ((CMTime) -> Void)?

    private weak var session: AVCaptureSession?
    private weak var delegate: CaptureRecordingDelegate?
    private var audioDataOutput: AVCaptureAudioDataOutput?

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var writerSessionStarted = false
    private var fileURL: URL?

    private var startContinuation: CheckedContinuation<Void, Error>?
    private var acceptingSamples = true

    func configure(session: AVCaptureSession, device: AVCaptureDevice, delegate: CaptureRecordingDelegate, queue: DispatchQueue) throws {
        self.session = session
        self.delegate = delegate

        let dataOut = AVCaptureAudioDataOutput()
        guard session.canAddOutput(dataOut) else { throw RecordingError.cannotAddOutput }
        session.addOutput(dataOut)
        dataOut.setSampleBufferDelegate(delegate, queue: queue)
        self.audioDataOutput = dataOut

        delegate.onAudioSample = { [weak self] sampleBuffer in
            self?.handleSample(sampleBuffer)
        }
    }

    func start(fileURL: URL) async throws {
        self.fileURL = fileURL
        let writer = try AVAssetWriter(url: fileURL, fileType: .m4a)
        // 固定 10s 片段
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingError.outputNotConfigured }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RecordingError.outputNotConfigured }

        self.writer = writer
        self.input = input
        self.writerSessionStarted = false

        // 等待首帧到来
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.startContinuation = continuation
        }
    }

    func stop() async throws -> URL? {
        guard let session else { return fileURL }
        acceptingSamples = false
        audioDataOutput?.setSampleBufferDelegate(nil, queue: nil)
        input?.markAsFinished()
        if let writer { await writer.finishWriting() }
        AVCaptureSessionHelper.stopRecordingStep2Close(avSession: session)
        return fileURL
    }

    private func handleSample(_ sampleBuffer: CMSampleBuffer) {
        guard acceptingSamples, let writer, let input else { return }
        let pts = sampleBuffer.presentationTimeStamp
        if !writerSessionStarted {
            writer.startSession(atSourceTime: pts)
            writerSessionStarted = true
            onFirstPTS?(pts)
            startContinuation?.resume(returning: ())
            startContinuation = nil
        }
        if input.isReadyForMoreMediaData, writer.status == .writing {
            _ = input.append(sampleBuffer)
        }
    }
}
