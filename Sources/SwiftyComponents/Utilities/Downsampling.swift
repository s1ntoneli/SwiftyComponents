import Foundation

/// Downsampling helpers for waveform magnitudes.
/// Provide magnitude values (absolute PCM or envelopes). Returns 0...1 normalized bins
/// using either RMS or Peak aggregation. Pure function and test-friendly.

public enum WaveformDownsamplingMode {
    case rms
    case peak
}

public enum WaveformDownsampler {
    /// Downsample magnitudes (0...1 or any non-negative values). Returns normalized 0...1.
    public static func downsampleMagnitudes(_ values: [Float], into bins: Int, mode: WaveformDownsamplingMode) -> [Float] {
        guard bins > 0, !values.isEmpty else { return [] }
        if bins >= values.count { // pad or simple normalize
            let maxv = max(1e-9, values.max() ?? 1)
            return values.map { max(0, $0) / maxv }
        }
        let step = Double(values.count) / Double(bins)
        var out: [Float] = []
        out.reserveCapacity(bins)
        var i = 0
        while i < bins {
            let start = Int((Double(i) * step).rounded(.down))
            let end = min(values.count, Int((Double(i + 1) * step).rounded(.down)))
            if end <= start { out.append(0); i += 1; continue }
            let slice = values[start..<end]
            let v: Float
            switch mode {
            case .peak:
                v = slice.max() ?? 0
            case .rms:
                var acc: Double = 0
                var c: Double = 0
                for s in slice { acc += Double(s*s); c += 1 }
                v = c > 0 ? Float(sqrt(acc / c)) : 0
            }
            out.append(v)
            i += 1
        }
        let mx = max(1e-9, out.max() ?? 1)
        for j in out.indices { out[j] = max(0, out[j] / mx) }
        return out
    }
}
