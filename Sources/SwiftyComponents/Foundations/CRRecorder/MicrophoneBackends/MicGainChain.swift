import Foundation

/// Shared microphone gain / AGC / limiter chain.
///
/// This is used both by the live recorder backend and the offline replayer,
/// so tuning here keeps behaviour consistent between real-time和离线重现。
struct MicGainChain {
    var options: MicrophoneProcessingOptions
    /// Smoothed AGC gain (stateful across buffers).
    var agcSmoothedGain: Float = 1.0

    init(options: MicrophoneProcessingOptions) {
        self.options = options
    }

    mutating func processInt16Samples(
        _ samples: UnsafeMutablePointer<Int16>,
        count sampleCount: Int,
        channels: Int
    ) {
        guard options.enableProcessing || options.linearGain != 1.0 else { return }
        let ch = max(1, channels)
        let frameCount = sampleCount / ch
        guard frameCount > 0 else { return }

        let gainLinearBase: Float = max(0.0, options.linearGain)
        let enableAGC = options.enableAGC
        let targetRMS = max(1e-4, min(0.9, options.agcTargetRMS))
        let maxAGCLinear = powf(10.0, options.agcMaxGainDb / 20.0)
        let enableLimiter = options.enableLimiter

        var rmsAccum: Double = 0
        for i in 0..<frameCount {
            let s = Float(samples[i * ch]) / Float(Int16.max)
            rmsAccum += Double(s * s)
        }
        let rms = sqrt(rmsAccum / Double(max(1, frameCount)))

        var agcGain: Float = 1.0
        if enableAGC {
            let desired = Float(targetRMS) / max(1e-6, Float(rms))
            agcGain = min(maxAGCLinear, desired)
            let alpha: Float = 0.1
            agcSmoothedGain = alpha * agcGain + (1 - alpha) * agcSmoothedGain
            agcGain = agcSmoothedGain
        }
        let totalGain = max(0.0, gainLinearBase) * agcGain

        let totalSamples = frameCount * ch
        for i in 0..<totalSamples {
            let x = Float(samples[i]) / Float(Int16.max)
            var y = x * totalGain
            if enableLimiter {
                y = tanh(y * 2.0)
            }
            let clamped = max(-1.0, min(1.0, y))
            samples[i] = Int16(clamped * Float(Int16.max))
        }
    }

    mutating func processFloatSamples(
        _ samples: UnsafeMutablePointer<Float>,
        count sampleCount: Int,
        channels: Int
    ) {
        guard options.enableProcessing || options.linearGain != 1.0 else { return }
        let ch = max(1, channels)
        let frameCount = sampleCount / ch
        guard frameCount > 0 else { return }

        let gainLinearBase: Float = max(0.0, options.linearGain)
        let enableAGC = options.enableAGC
        let targetRMS = max(1e-4, min(0.9, options.agcTargetRMS))
        let maxAGCLinear = powf(10.0, options.agcMaxGainDb / 20.0)
        let enableLimiter = options.enableLimiter

        var rmsAccum: Double = 0
        for i in 0..<frameCount {
            let s = samples[i * ch]
            rmsAccum += Double(s * s)
        }
        let rms = sqrt(rmsAccum / Double(max(1, frameCount)))

        var agcGain: Float = 1.0
        if enableAGC {
            let desired = Float(targetRMS) / max(1e-6, Float(rms))
            agcGain = min(maxAGCLinear, desired)
            let alpha: Float = 0.1
            agcSmoothedGain = alpha * agcGain + (1 - alpha) * agcSmoothedGain
            agcGain = agcSmoothedGain
        }
        let totalGain = max(0.0, gainLinearBase) * agcGain

        let totalSamples = frameCount * ch
        for i in 0..<totalSamples {
            var y = samples[i] * totalGain
            if enableLimiter {
                y = tanh(y * 2.0)
            }
            samples[i] = max(-1.0, min(1.0, y))
        }
    }
}

