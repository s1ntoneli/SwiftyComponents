import Foundation
import ScreenCaptureKit

final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    var onVideo: ((CMSampleBuffer) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch outputType {
        case .screen:
            if let arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let meta = arr.first,
               let raw = meta[SCStreamFrameInfo.status] as? Int,
               let status = SCFrameStatus(rawValue: raw), status == .complete {
                // Diagnostics: capture stats + fps measurement
                if let buf = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    let w = CVPixelBufferGetWidth(buf)
                    let h = CVPixelBufferGetHeight(buf)
                    RecorderDiagnostics.shared.onCaptureVideoFrame()
                    RecorderDiagnostics.shared.onVideoSample(size: CGSize(width: w, height: h))
                }
                onVideo?(sampleBuffer)
            }
        case .audio:
            RecorderDiagnostics.shared.onCaptureAudioSample()
            onAudio?(sampleBuffer)
#if compiler(>=6.0)
        case .microphone:
            break
#endif
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error) }
}
