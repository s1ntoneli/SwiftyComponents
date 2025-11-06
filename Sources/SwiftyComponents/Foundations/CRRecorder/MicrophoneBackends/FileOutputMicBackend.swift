import Foundation
import AVFoundation

final class FileOutputMicBackend: MicrophoneBackend {
    var onFirstPTS: ((CMTime) -> Void)?

    private weak var session: AVCaptureSession?
    private weak var delegate: CaptureRecordingDelegate?
    private var audioOutput: AVCaptureAudioFileOutput?
    private var dataOutput: AVCaptureAudioDataOutput?

    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuation: CheckedContinuation<URL, Error>?
    private var fileURL: URL?

    func configure(session: AVCaptureSession, device: AVCaptureDevice, delegate: CaptureRecordingDelegate, queue: DispatchQueue) throws {
        self.session = session
        self.delegate = delegate

        // 文件输出
        let fileOut = AVCaptureAudioFileOutput()
        guard session.canAddOutput(fileOut) else { throw RecordingError.cannotAddOutput }
        session.addOutput(fileOut)
        self.audioOutput = fileOut

        // 数据输出（用于电平/首帧 PTS）
        let dataOut = AVCaptureAudioDataOutput()
        if session.canAddOutput(dataOut) {
            session.addOutput(dataOut)
            dataOut.setSampleBufferDelegate(delegate, queue: queue)
            self.dataOutput = dataOut
        }

        // 事件桥接
        delegate.onStartTime = { [weak self] time in
            guard let self else { return }
            self.onFirstPTS?(time)
            self.startContinuation?.resume(returning: ())
            self.startContinuation = nil
        }
    }

    func start(fileURL: URL) async throws {
        guard let output = audioOutput else { throw RecordingError.outputNotConfigured }
        self.fileURL = fileURL

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.startContinuation = continuation
            output.startRecording(to: fileURL, outputFileType: .m4a, recordingDelegate: delegate!)
        }
    }

    func stop() async throws -> URL? {
        guard let session else { return fileURL }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            self.stopContinuation = continuation
            self.delegate?.onComplete = { [weak self] url in
                guard let self else { return }
                continuation.resume(returning: url)
                self.stopContinuation = nil
            }
            self.delegate?.onError = { error in
                continuation.resume(throwing: error)
            }
            AVCaptureSessionHelper.stopRecordingStep1Output(avSession: session)
        }
    }
}

