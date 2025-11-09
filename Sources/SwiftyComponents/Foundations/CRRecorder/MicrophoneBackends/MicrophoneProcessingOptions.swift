import Foundation

/// Per-run microphone processing options.
/// Default keeps current behavior: processing disabled, but channels defaults to mono to avoid upmix attenuation.
public struct MicrophoneProcessingOptions: Sendable, Equatable {
    /// Enable software processing (gain / AGC / limiter). Default: false
    public var enableProcessing: Bool = true
    /// Linear gain applied before limiter/AGC. 1.0 = no change.
    public var linearGain: Float = 2.0
    /// Enable a simple automatic gain control (targets `agcTargetRMS`). Default: false
    public var enableAGC: Bool = true
    /// Target RMS for AGC in linear scale [0,1]. Example: 0.2 ≈ -14 dBFS
    public var agcTargetRMS: Float = 0.2
    /// Max additional gain the AGC can apply (in dB). Default: +12 dB
    public var agcMaxGainDb: Float = 12.0
    /// Soft limiter to prevent clipping after gain/AGC. Default: true
    public var enableLimiter: Bool = true
    /// Output channel count. Default mono to avoid upmix attenuation.
    public var channels: Int = 1
}
