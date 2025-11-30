import Foundation
import AVFoundation

protocol CameraBackend: AnyObject {
    /// Called when the first video sample PTS is known (source time space).
    var onFirstPTS: ((CMTime) -> Void)? { get set }

    /// Configure the backend with an already-prepared capture session.
    ///
    /// - Parameters:
    ///   - session: The session that already contains the desired inputs (camera, screen, etc.).
    ///   - device: Optional backing `AVCaptureDevice` associated with the primary video source.
    ///             For screen-based capture there may be no physical device, so this can be `nil`.
    ///   - delegate: A shared capture delegate which will receive sample buffers.
    ///   - queue: Dispatch queue used for sample callbacks.
    func configure(session: AVCaptureSession, device: AVCaptureDevice?, delegate: CaptureRecordingDelegate, queue: DispatchQueue) throws
    func start(fileURL: URL) async throws
    func stop() async throws -> URL?
    func apply(options: CameraRecordingOptions)
}

extension CameraBackend {
    func apply(options: CameraRecordingOptions) { /* default no-op */ }
}
