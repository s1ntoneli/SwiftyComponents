import Foundation
import AVFoundation

final class FileOutputCamBackend: CameraBackend {
    var onFirstPTS: ((CMTime) -> Void)?

    private weak var session: AVCaptureSession?
    private weak var delegate: CaptureRecordingDelegate?
    private var movieOutput: AVCaptureMovieFileOutput?
    private var videoDataOutput: AVCaptureVideoDataOutput?

    private var startContinuation: CheckedContinuation<Void, Error>?
    private var fileURL: URL?
    func apply(options: CameraRecordingOptions) { /* file-output backend uses system defaults */ }

    func configure(session: AVCaptureSession, device: AVCaptureDevice?, delegate: CaptureRecordingDelegate, queue: DispatchQueue) throws {
        self.session = session
        self.delegate = delegate

        let movie = AVCaptureMovieFileOutput()
        guard session.canAddOutput(movie) else { throw RecordingError.cannotAddOutput }
        session.addOutput(movie)
        self.movieOutput = movie

        // 视频数据探针：仅用于拿首帧 PTS
        let vdo = AVCaptureVideoDataOutput()
        if session.canAddOutput(vdo) {
            session.addOutput(vdo)
            vdo.setSampleBufferDelegate(delegate, queue: queue)
            self.videoDataOutput = vdo
        }

        // 开闸后首帧 PTS 回调
        delegate.onStartTime = { [weak self] time in
            guard let self else { return }
            self.onFirstPTS?(time)
            self.startContinuation?.resume(returning: ())
            self.startContinuation = nil
        }
    }

    func start(fileURL: URL) async throws {
        guard let output = movieOutput else { throw RecordingError.outputNotConfigured }
        self.fileURL = fileURL
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.startContinuation = continuation
            output.startRecording(to: fileURL, recordingDelegate: delegate!)
        }
    }

    func stop() async throws -> URL? {
        guard let session else { return fileURL }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
            self.delegate?.onComplete = { url in
                continuation.resume(returning: url)
            }
            self.delegate?.onError = { error in
                continuation.resume(throwing: error)
            }
            AVCaptureSessionHelper.stopRecordingStep1Output(avSession: session)
        }
    }
}
