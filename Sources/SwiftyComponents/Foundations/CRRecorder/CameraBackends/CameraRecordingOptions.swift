import Foundation
import AVFoundation

public struct CameraRecordingOptions: Sendable, Equatable, Hashable {
    public enum VideoOrientationPreference: String, Sendable, Equatable, Hashable {
        /// Do not touch `device.activeFormat`; keep whatever the device/session negotiates.
        case auto
        /// Best-effort switch `device.activeFormat` to a landscape format.
        case landscape
        /// Best-effort switch `device.activeFormat` to a portrait format.
        case portrait
    }

    // Resolution preset; nil keeps device default
    public var preset: AVCaptureSession.Preset? = nil
    /// Whether to prefer a portrait or landscape output canvas for camera recording.
    ///
    /// - Important: This only affects *pixel buffer geometry* by selecting `AVCaptureDevice.activeFormat`.
    ///   It does not perform any crop.
    /// - Note: Default is `.auto` to avoid impacting normal cameras.
    public var videoOrientationPreference: VideoOrientationPreference = .auto
    // Mirror the captured video horizontally.
    public var isMirrored: Bool = false
    // Prefer HEVC encoding when available
    public var preferHEVC: Bool = false
    // Bitrate estimation coefficients (bits-per-pixel per frame)
    public var bppH264: Double = 0.060
    public var bppHEVC: Double = 0.035
    // Bitrate clamp in bps
    public var minBitrate: Int = 1_200_000
    public var maxBitrate: Int = 10_000_000
    /// Optional override for the FPS used in bitrate estimation.
    /// If nil, the backend derives FPS from the active device or falls back to a default.
    public var bitrateFPSOverride: Int? = nil

    public init(preset: AVCaptureSession.Preset? = nil,
                videoOrientationPreference: VideoOrientationPreference = .auto,
                isMirrored: Bool = false,
                preferHEVC: Bool = false,
                bppH264: Double = 0.060,
                bppHEVC: Double = 0.035,
                minBitrate: Int = 1_200_000,
                maxBitrate: Int = 10_000_000,
                bitrateFPSOverride: Int? = nil) {
        self.preset = preset
        self.videoOrientationPreference = videoOrientationPreference
        self.isMirrored = isMirrored
        self.preferHEVC = preferHEVC
        self.bppH264 = bppH264
        self.bppHEVC = bppHEVC
        self.minBitrate = minBitrate
        self.maxBitrate = maxBitrate
        self.bitrateFPSOverride = bitrateFPSOverride
    }
}
