import Foundation
import AVFoundation

protocol MicrophoneBackend: AnyObject {
    // 首帧媒体 PTS 回调（用于对齐）
    var onFirstPTS: ((CMTime) -> Void)? { get set }

    // Per-run processing options (default: disabled)
    var processingOptions: MicrophoneProcessingOptions { get set }

    // 配置会话与输出
    func configure(session: AVCaptureSession, device: AVCaptureDevice, delegate: CaptureRecordingDelegate, queue: DispatchQueue) throws

    // 启动录制，返回时机：首帧 PTS 确认后
    func start(fileURL: URL) async throws

    // 停止录制，返回生成的文件 URL（若有）
    func stop() async throws -> URL?
}
