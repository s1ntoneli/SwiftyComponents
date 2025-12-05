import Foundation

/// Per-run microphone processing options.
/// Default keeps behavior simple and compatible: no software processing, unity gain, mono output.
public struct MicrophoneProcessingOptions: Sendable, Equatable, Hashable {
    /// Enable software processing (gain / AGC / limiter). Default: false
    public var enableProcessing: Bool = false
    /// Linear gain applied before limiter/AGC / preferredVolume on writer. 1.0 = no change.
    public var linearGain: Float = 1.0
    /// Enable a simple automatic gain control (targets `agcTargetRMS`). Default: false
    public var enableAGC: Bool = false
    /// Target RMS for AGC in linear scale [0,1]. Example: 0.2 ≈ -14 dBFS
    public var agcTargetRMS: Float = 0.2
    /// Max additional gain the AGC can apply (in dB). Default: +12 dB
    public var agcMaxGainDb: Float = 12.0
    /// Soft limiter to prevent clipping after gain/AGC. Default: true (only used when `enableProcessing == true`)
    public var enableLimiter: Bool = true
    /// Output channel count. Default mono to avoid upmix attenuation.
    public var channels: Int = 1
}

public extension MicrophoneProcessingOptions {
    /// Default options preferred by CoreRecorder integration.
    /// External modules can use this as a safe baseline without needing direct access to initializers.
    static var coreRecorderDefault: MicrophoneProcessingOptions {
        MicrophoneProcessingOptions()
    }
}
