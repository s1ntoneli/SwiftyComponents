import Foundation
import AVFoundation

public struct CameraRecordingOptions: Sendable {
    // Resolution preset; nil keeps device default
    public var preset: AVCaptureSession.Preset? = .hd1280x720
    // Prefer HEVC encoding when available
    public var preferHEVC: Bool = false
    // Bitrate estimation coefficients (bits-per-pixel per frame)
    public var bppH264: Double = 0.060
    public var bppHEVC: Double = 0.035
    // Bitrate clamp in bps
    public var minBitrate: Int = 1_200_000
    public var maxBitrate: Int = 10_000_000

    public init(preset: AVCaptureSession.Preset? = .hd1280x720,
                preferHEVC: Bool = false,
                bppH264: Double = 0.060,
                bppHEVC: Double = 0.035,
                minBitrate: Int = 1_200_000,
                maxBitrate: Int = 10_000_000) {
        self.preset = preset
        self.preferHEVC = preferHEVC
        self.bppH264 = bppH264
        self.bppHEVC = bppHEVC
        self.minBitrate = minBitrate
        self.maxBitrate = maxBitrate
    }
}

