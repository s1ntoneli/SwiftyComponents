import Foundation
#if canImport(AVFoundation)
import AVFoundation

/// 每帧波形采样（bins）的数据结构。
public struct FrameWaveform: Sendable {
    public let timeRange: CMTimeRange
    public let bins: [Float] // 0...1 归一化
    public init(timeRange: CMTimeRange, bins: [Float]) {
        self.timeRange = timeRange
        self.bins = bins
    }
}

/// 流式聚合配置。
public struct WaveformStreamConfig: Sendable {
    public enum RetentionPolicy: Sendable, Equatable {
        case none
        case windowSeconds(Double)
        case windowFrames(Int)
        case allInMemory
    }

    public let sampleRate: Double
    public let channel: WaveformChannel
    public let mode: WaveformSampleMode
    public let frameDuration: CMTime
    public let binsPerFrame: Int
    public let retention: RetentionPolicy

    public init(sampleRate: Double,
                channel: WaveformChannel,
                mode: WaveformSampleMode,
                frameDuration: CMTime,
                binsPerFrame: Int,
                retention: RetentionPolicy = .none) {
        self.sampleRate = sampleRate
        self.channel = channel
        self.mode = mode
        self.frameDuration = frameDuration
        self.binsPerFrame = binsPerFrame
        self.retention = retention
    }
}

/// 录制阶段：持续接收 PCM，按帧切分并输出每帧波形 bins。
/// - 仅支持 Float32 PCM（常见于 AVAudioEngine/标准解码），其他格式可在上游先转换。
public final class WaveformStreamAggregator {
    public typealias FramesCallback = ([FrameWaveform]) -> Void

    public let config: WaveformStreamConfig
    private let frameSamples: Int

    // 累积的单声道绝对值样本
    private var monoAbs: [Float] = []
    private var currentPTS: CMTime?

    // 已产出但尚未 pop 的帧
    private var readyQueue: [FrameWaveform] = []

    // 保留（窗口/全量）
    private var retained: [FrameWaveform] = []

    // 新帧回调（可选）
    public var onFrames: FramesCallback?

    public init(config: WaveformStreamConfig) {
        self.config = config
        let durationSeconds = CMTimeGetSeconds(config.frameDuration)
        self.frameSamples = max(1, Int(round(config.sampleRate * durationSeconds)))
    }

    /// 追加一段 PCM 缓冲（Float32）。`time` 为该缓冲的起始 PTS。
    public func append(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { return }
        let ch = Int(buffer.format.channelCount)
        guard ch > 0 else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        // 设置起始 PTS（首包或中断续包）
        if currentPTS == nil { currentPTS = time }

        // 取得指针并按通道策略生成单声道绝对值序列
        let ptrs = buffer.floatChannelData!
        var tmp: [Float] = []
        tmp.reserveCapacity(frameLength)

        switch config.channel {
        case .mix:
            if ch == 1 {
                let p0 = ptrs[0]
                for i in 0..<frameLength { tmp.append( fabsf(p0[i]) ) }
            } else if ch >= 2 {
                let p0 = ptrs[0]
                let p1 = ptrs[1]
                for i in 0..<frameLength { tmp.append( max(fabsf(p0[i]), fabsf(p1[i])) ) }
            } else {
                let p0 = ptrs[0]
                for i in 0..<frameLength { tmp.append( fabsf(p0[i]) ) }
            }
        case .left:
            let idx = min(0, ch-1)
            let p = ptrs[idx]
            for i in 0..<frameLength { tmp.append( fabsf(p[i]) ) }
        case .right:
            let idx = min(1, ch-1)
            let p = ptrs[idx]
            for i in 0..<frameLength { tmp.append( fabsf(p[i]) ) }
        }

        monoAbs.append(contentsOf: tmp)
        produceFramesIfPossible()
    }

    /// 取出已完成帧（并清空队列）。
    @discardableResult
    public func popReadyFrames() -> [FrameWaveform] {
        let out = readyQueue
        readyQueue.removeAll(keepingCapacity: true)
        return out
    }

    /// 查看已完成帧（不清空）。
    public func peekReadyFrames() -> [FrameWaveform] { readyQueue }

    /// 查看保留窗口内的全部帧（ready + retained）。
    public func snapshotAll() -> [FrameWaveform] { retained + readyQueue }

    /// 收尾并输出剩余的不足一帧的样本（按比例聚合为一帧）。
    public func flush() -> [FrameWaveform] {
        guard let start = currentPTS, !monoAbs.isEmpty else { return [] }
        let bins = aggregateBins(for: monoAbs, bins: config.binsPerFrame, mode: config.mode)
        let tr = CMTimeRange(start: start, duration: config.frameDuration)
        let frame = FrameWaveform(timeRange: tr, bins: bins)
        appendToQueues(frame)
        monoAbs.removeAll(keepingCapacity: true)
        currentPTS = start + config.frameDuration
        let out = readyQueue
        readyQueue.removeAll(keepingCapacity: true)
        return out
    }

    /// 粗略的内存占用估算（字节）。
    public func memoryFootprintBytes() -> Int {
        let fBins = (retained + readyQueue).reduce(0) { $0 + $1.bins.count }
        let buf = monoAbs.count
        return (fBins + buf) * MemoryLayout<Float>.size
    }

    // MARK: - 内部
    private func aggregateBins(for values: [Float], bins: Int, mode: WaveformSampleMode) -> [Float] {
        guard bins > 0, !values.isEmpty else { return [] }
        let step = Double(values.count) / Double(bins)
        var out: [Float] = []
        out.reserveCapacity(bins)
        for i in 0..<bins {
            let s = Int((Double(i) * step).rounded(.down))
            let e = i == bins-1 ? values.count : Int((Double(i+1) * step).rounded(.down))
            if e <= s { out.append(0); continue }
            let slice = values[s..<e]
            switch mode {
            case .peak:
                out.append(slice.max() ?? 0)
            case .rms:
                var acc: Double = 0
                var c: Double = 0
                for v in slice { acc += Double(v*v); c += 1 }
                out.append(c > 0 ? Float(sqrt(acc/c)) : 0)
            }
        }
        // 归一化到 0..1
        let mx = max(1e-9, out.max() ?? 1)
        for i in out.indices { out[i] = max(0, out[i] / mx) }
        return out
    }

    private func produceFramesIfPossible() {
        guard currentPTS != nil else { return }
        var produced: [FrameWaveform] = []
        while monoAbs.count >= frameSamples {
            let frameVals = Array(monoAbs[0..<frameSamples])
            monoAbs.removeFirst(frameSamples)
            let bins = aggregateBins(for: frameVals, bins: config.binsPerFrame, mode: config.mode)
            let tr = CMTimeRange(start: currentPTS!, duration: config.frameDuration)
            let frame = FrameWaveform(timeRange: tr, bins: bins)
            appendToQueues(frame)
            currentPTS = currentPTS! + config.frameDuration
            produced.append(frame)
        }
        if !produced.isEmpty { onFrames?(produced) }
    }

    private func appendToQueues(_ frame: FrameWaveform) {
        readyQueue.append(frame)

        switch config.retention {
        case .none:
            break
        case .allInMemory:
            retained.append(frame)
        case .windowFrames(let n):
            retained.append(frame)
            if retained.count > n { retained.removeFirst(retained.count - n) }
        case .windowSeconds(let sec):
            retained.append(frame)
            trimWindow(seconds: sec)
        }
    }

    private func trimWindow(seconds: Double) {
        guard seconds > 0 else { retained.removeAll(keepingCapacity: true); return }
        guard let last = retained.last else { return }
        let lowerBound = last.timeRange.end - CMTime(seconds: seconds, preferredTimescale: last.timeRange.duration.timescale)
        while let first = retained.first, first.timeRange.end < lowerBound {
            retained.removeFirst()
        }
    }
}
#endif
