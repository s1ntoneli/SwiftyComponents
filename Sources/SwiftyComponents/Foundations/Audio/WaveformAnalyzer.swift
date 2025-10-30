import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Analyzer utilities to sample audio amplitudes over a time range.
///
/// Produces normalized magnitudes in 0...1 using either RMS or Peak aggregation
/// and supports mixing or selecting channels.
public enum WaveformAnalyzerError: Error {
    case unsupportedPlatform
    case cannotReadTrack
    case invalidTimeRange
}

/// Channel selection strategy for sampling.
public enum WaveformChannel: Sendable {
    case mix
    case left
    case right
}

/// Aggregation mode when sampling audio frames into bins.
public enum WaveformSampleMode: Sendable {
    case rms
    case peak
}

public enum WaveformAnalyzer {
    #if canImport(AVFoundation)
    @discardableResult
    /// Sample amplitudes from a file URL in a given time range.
    public static func sampleAmplitudes(
        fileURL: URL,
        timeRange: CMTimeRange,
        samples: Int,
        mode: WaveformSampleMode = .rms,
        channel: WaveformChannel = .mix
    ) async throws -> [Float] {
        let asset = AVURLAsset(url: fileURL)
        return try await sampleAmplitudes(asset: asset, timeRange: timeRange, samples: samples, mode: mode, channel: channel)
    }

    /// Sample amplitudes from an AVAsset.
    public static func sampleAmplitudes(
        asset: AVAsset,
        timeRange: CMTimeRange,
        samples: Int,
        mode: WaveformSampleMode = .rms,
        channel: WaveformChannel = .mix
    ) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw WaveformAnalyzerError.cannotReadTrack }
        return try await sampleAmplitudes(track: track, timeRange: timeRange, samples: samples, mode: mode, channel: channel)
    }

    /// Sample amplitudes from an AVAssetTrack.
    public static func sampleAmplitudes(
        track: AVAssetTrack,
        timeRange: CMTimeRange,
        samples: Int,
        mode: WaveformSampleMode = .rms,
        channel: WaveformChannel = .mix
    ) async throws -> [Float] {
        guard samples > 0 else { return [] }
        guard timeRange.isValid, timeRange.duration.isNumeric && timeRange.duration.seconds > 0 else {
            throw WaveformAnalyzerError.invalidTimeRange
        }

        let reader = try AVAssetReader(asset: track.asset!)
        reader.timeRange = timeRange

        // Decode to 32-bit float, mono if mix, or keep 2 channels for selection
        var outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
        ]
        if channel == .mix { outputSettings[AVNumberOfChannelsKey] = 1 }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        guard reader.canAdd(output) else { throw WaveformAnalyzerError.cannotReadTrack }
        reader.add(output)
        reader.startReading()

        let totalDuration = timeRange.duration.seconds
        let timePerBin = totalDuration / Double(samples)
        var curTime: Double = 0
        var binIndex = 0
        var bins: [Float] = Array(repeating: 0, count: samples)
        var counts: [Int] = Array(repeating: 0, count: samples)

        func commit(_ value: Float, duration: Double) {
            guard binIndex < samples else { return }
            switch mode {
            case .peak:
                bins[binIndex] = max(bins[binIndex], value)
            case .rms:
                // accumulate squares, average later
                bins[binIndex] += value * value
            }
            counts[binIndex] += 1
            curTime += duration
            while curTime >= timePerBin && binIndex < samples {
                curTime -= timePerBin
                binIndex += 1
            }
        }

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sampleBuffer) }
            let duration = CMSampleBufferGetDuration(sampleBuffer)
            let bufferDurationSec = duration.isValid ? duration.seconds : 0
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length: Int = 0
            var dataPointer: UnsafeMutablePointer<Int8>? = nil
            let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &dataPointer)
            if status != kCMBlockBufferNoErr || dataPointer == nil || length <= 0 { continue }

            let bytes = dataPointer!.withMemoryRebound(to: Float.self, capacity: length / MemoryLayout<Float>.size) { ptr in
                UnsafeBufferPointer(start: ptr, count: length / MemoryLayout<Float>.size)
            }

            // Determine channel stride
            let channelCount: Int
            if channel == .mix { channelCount = 1 } else { channelCount = 2 }
            let frameCount = bytes.count / channelCount
            let sampleDurationSec = frameCount > 0 ? bufferDurationSec / Double(frameCount) : 0

            for f in 0..<frameCount {
                let v: Float
                if channelCount == 1 {
                    v = abs(bytes[f])
                } else {
                    let l = abs(bytes[f * 2 + 0])
                    let r = abs(bytes[f * 2 + 1])
                    switch channel {
                    case .left: v = l
                    case .right: v = r
                    case .mix: v = max(l, r) // should not reach here when channelCount==2 for mix
                    }
                }
                commit(v, duration: sampleDurationSec)
                if binIndex >= samples { break }
            }
            if binIndex >= samples { break }
        }

        // finalize RMS and normalize
        var maxVal: Float = 0
        for i in 0..<samples {
            if counts[i] == 0 { bins[i] = 0; continue }
            switch mode {
            case .rms: bins[i] = sqrt(bins[i] / Float(counts[i]))
            case .peak: break
            }
            if bins[i].isFinite { maxVal = max(maxVal, bins[i]) } else { bins[i] = 0 }
        }
        let norm = max(1e-9, maxVal)
        for i in 0..<samples { bins[i] = max(0, bins[i] / norm) }
        return bins
    }
    #else
    public static func sampleAmplitudes(fileURL: URL, timeRange: Any, samples: Int, mode: WaveformSampleMode, channel: WaveformChannel) async throws -> [Float] {
        throw WaveformAnalyzerError.unsupportedPlatform
    }
    #endif
}
