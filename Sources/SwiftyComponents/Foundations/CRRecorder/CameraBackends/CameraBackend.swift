import Foundation
import AVFoundation

protocol CameraBackend: AnyObject {
    var onFirstPTS: ((CMTime) -> Void)? { get set }

    func configure(session: AVCaptureSession, device: AVCaptureDevice, delegate: CaptureRecordingDelegate, queue: DispatchQueue) throws
    func start(fileURL: URL) async throws
    func stop() async throws -> URL?
}

