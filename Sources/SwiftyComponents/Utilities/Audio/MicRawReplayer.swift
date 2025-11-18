import Foundation
import AVFoundation

/// Utility to render raw microphone PCM dumps (e.g. `*.raw.pcm`) into playable audio files.
///
/// Used by the example app to offline-reproduce microphone behaviour without requiring the device.
public enum MicRawReplayer {
    public enum Interpretation {
        /// Interpret samples as 32-bit float, taking the first channel only.
        case float32FirstChannel
        /// Interpret samples as 32-bit signed integer, taking the first channel only.
        case int32FirstChannel
    }

    /// Render a raw PCM file into a mono WAV file using the given interpretation.
    ///
    /// - Parameters:
    ///   - rawURL: The `*.raw.pcm` file produced by debug dumping.
    ///   - sampleRate: Sample rate in Hz (e.g. 48000).
    ///   - channels: Channel count reported by the device.
    ///   - interpretation: How to interpret the 32-bit words in the raw file.
    ///   - outputURL: Destination WAV file.
    public static func render(
        rawURL: URL,
        sampleRate: Double,
        channels: Int,
        interpretation: Interpretation,
        outputURL: URL,
        processingOptions: MicrophoneProcessingOptions? = nil
    ) throws {
        let data = try Data(contentsOf: rawURL)
        let ch = max(1, channels)
        let bytesPerSample = MemoryLayout<UInt32>.stride
        guard data.count >= bytesPerSample * ch else { return }

        let totalSamples = data.count / bytesPerSample
        let frames = totalSamples / ch
        guard frames > 0 else { return }

        var monoSamples = [Float](repeating: 0, count: frames)

        try data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            switch interpretation {
            case .float32FirstChannel:
                let ptr = base.assumingMemoryBound(to: Float.self)
                let sanityLimit: Float = 8.0
                let sanityFrameCount = min(frames, 4096)
                var hasInsaneSample = false

                // Quick sanity check: if samples interpreted as Float32 contain
                // obviously invalid values (NaN / extremely large), fall back
                // to interpreting the raw words as Int32 instead. This matches
                // the live pipeline's protection against “fake float / real int”
                // USB 麦克风。
                for i in 0..<sanityFrameCount {
                    let v = ptr[i * ch]
                    if !v.isFinite || abs(v) > sanityLimit {
                        hasInsaneSample = true
                        break
                    }
                }

                if hasInsaneSample {
                    let intPtr = base.assumingMemoryBound(to: Int32.self)
                    let denom = Float(Int32.max)
                    for i in 0..<frames {
                        let v = intPtr[i * ch]
                        monoSamples[i] = Float(v) / denom
                    }
                } else {
                    for i in 0..<frames {
                        monoSamples[i] = ptr[i * ch]
                    }
                }
            case .int32FirstChannel:
                let ptr = base.assumingMemoryBound(to: Int32.self)
                let denom = Float(Int32.max)
                for i in 0..<frames {
                    let v = ptr[i * ch]
                    monoSamples[i] = Float(v) / denom
                }
            }
        }

        // Apply the same gain/AGC/limiter chain used in the live pipeline,
        // so离线导出的 WAV 与实时 CRRecorder 输出在响度和听感上保持一致。
        if let opts = processingOptions {
            var chain = MicGainChain(options: opts)
            monoSamples.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                chain.processFloatSamples(base, count: buf.count, channels: 1)
            }
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return
        }
        let frameCount = AVAudioFrameCount(monoSamples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        buffer.frameLength = frameCount
        if let dst = buffer.floatChannelData?[0] {
            monoSamples.withUnsafeBufferPointer { src in
                dst.assign(from: src.baseAddress!, count: monoSamples.count)
            }
        }

        let file = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        try file.write(from: buffer)
    }
}
