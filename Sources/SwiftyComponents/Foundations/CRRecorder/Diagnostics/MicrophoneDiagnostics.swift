import Foundation
import AVFoundation

/// Lightweight diagnostics center for microphone input.
///
/// Used only for debugging/inspection of microphone formats and sample stats.
/// Release builds keep the same surface but perform no work.
public final class RecorderMicDiagnostics: ObservableObject, @unchecked Sendable {
    public static let shared = RecorderMicDiagnostics()

    // MARK: - Public published properties for UI

    /// Selected capture device name (from `AVCaptureDevice.localizedName`).
    @Published public private(set) var deviceName: String? = nil
    /// Selected capture device unique ID.
    @Published public private(set) var deviceID: String? = nil

    /// Capture output's recommended audio settings for `.m4a` writer.
    @Published public private(set) var captureOutputSettings: [String: String] = [:]

    /// Actual writer audio settings used by `AssetWriterMicBackend`.
    @Published public private(set) var writerAudioSettings: [String: String] = [:]

    /// Current per-run microphone processing options.
    @Published public private(set) var processingOptions: MicrophoneProcessingOptions = .init()

    /// Last observed stream basic description derived from incoming sample buffers.
    @Published public private(set) var lastFormat: RecorderMicFormatInfo? = nil

    /// Rolling window of recent sample statistics (throttled).
    @Published public private(set) var recentSamples: [RecorderMicSampleStats] = []

    private let maxSamples = 24

    // Throttle sample analysis to avoid heavy work on every callback.
    private var lastObserveWallTime: Date? = nil
    private let minObserveInterval: TimeInterval = 0.5

    private init() {}

    // MARK: - Capture configuration hooks (called from backend)

    /// Call when the capture session is configured for a given device.
    func onConfigureCapture(device: AVCaptureDevice, audioOutput: AVCaptureAudioDataOutput) {
        let recommended = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .m4a) ?? [:]
        setOnMain {
            self.deviceName = device.localizedName
            self.deviceID = device.uniqueID
            self.captureOutputSettings = Self.describe(settings: recommended)
        }
    }

    /// Call when `AssetWriterMicBackend` starts with concrete writer audio settings.
    func onStartWriter(audioSettings: [String: Any], processingOptions: MicrophoneProcessingOptions) {
        setOnMain {
            self.writerAudioSettings = Self.describe(settings: audioSettings)
            self.processingOptions = processingOptions
        }
    }

    /// Observe an incoming audio sample buffer for diagnostics.
    func observe(sampleBuffer: CMSampleBuffer) {
        let now = Date()
        if let last = lastObserveWallTime, now.timeIntervalSince(last) < minObserveInterval {
            return
        }
        lastObserveWallTime = now

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }
        let asbd = asbdPtr.pointee

        let fmt = RecorderMicFormatInfo(
            sampleRate: asbd.mSampleRate,
            channels: Int(asbd.mChannelsPerFrame),
            bitsPerChannel: Int(asbd.mBitsPerChannel),
            bytesPerFrame: Int(asbd.mBytesPerFrame),
            formatID: asbd.mFormatID,
            formatFlags: asbd.mFormatFlags,
            isFloat: (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
            isSignedInteger: (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0,
            isNonInterleaved: (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        )

        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        var stats = RecorderMicSampleStats(
            time: now,
            sampleRate: fmt.sampleRate,
            channels: fmt.channels,
            bitsPerChannel: fmt.bitsPerChannel,
            frames: sampleCount,
            formatID: fmt.formatID,
            formatFlags: fmt.formatFlags,
            isFloat: fmt.isFloat,
            isSignedInteger: fmt.isSignedInteger,
            isNonInterleaved: fmt.isNonInterleaved,
            rms: nil,
            peak: nil,
            minSample: nil,
            maxSample: nil
        )

        // Optional amplitude stats for known-safe Linear PCM formats.
        if fmt.formatID == kAudioFormatLinearPCM {
            if fmt.bitsPerChannel == 16, fmt.isSignedInteger, !fmt.isFloat {
                if let r = Self.computeInt16Stats(sampleBuffer: sampleBuffer, channels: max(fmt.channels, 1)) {
                    stats.rms = r.rms
                    stats.peak = r.peak
                    stats.minSample = r.min
                    stats.maxSample = r.max
                }
            } else if fmt.bitsPerChannel == 32, fmt.isFloat {
                if let r = Self.computeFloat32Stats(sampleBuffer: sampleBuffer, channels: max(fmt.channels, 1)) {
                    stats.rms = r.rms
                    stats.peak = r.peak
                    stats.minSample = r.min
                    stats.maxSample = r.max
                }
            }
        }

        setOnMain {
            self.lastFormat = fmt
            self.recentSamples.append(stats)
            if self.recentSamples.count > self.maxSamples {
                self.recentSamples.removeFirst(self.recentSamples.count - self.maxSamples)
            }
        }
    }

    // MARK: - Helpers

    private static func describe(settings: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (k, v) in settings {
            if let n = v as? NSNumber {
                result[k] = n.stringValue
            } else {
                result[k] = String(describing: v)
            }
        }
        return result
    }

    private static func computeInt16Stats(sampleBuffer: CMSampleBuffer, channels: Int) -> (rms: Double, peak: Double, min: Double, max: Double)? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>? = nil
        let status = CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let basePtr = dataPointer, totalLength > 0 else { return nil }

        // Safe copy with 4-byte alignment so we can bind as Int16.
        let byteCount = totalLength
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<Int16>.alignment
        )
        raw.copyMemory(from: UnsafeRawPointer(basePtr), byteCount: byteCount)
        defer { raw.deallocate() }

        let samples = raw.bindMemory(to: Int16.self, capacity: byteCount / 2)
        let frameCount = (byteCount / 2) / max(channels, 1)
        guard frameCount > 0 else { return nil }

        var rmsAccum: Double = 0
        var minVal: Double = 1.0
        var maxVal: Double = -1.0
        var peak: Double = 0

        for i in 0..<frameCount {
            // Inspect the first channel.
            let s = Float(samples[i * channels]) / Float(Int16.max)
            let d = Double(s)
            rmsAccum += d * d
            minVal = min(minVal, d)
            maxVal = max(maxVal, d)
            peak = max(peak, abs(d))
        }

        let rms = sqrt(rmsAccum / Double(frameCount))
        return (rms: rms, peak: peak, min: minVal, max: maxVal)
    }

    private static func computeFloat32Stats(sampleBuffer: CMSampleBuffer, channels: Int) -> (rms: Double, peak: Double, min: Double, max: Double)? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>? = nil
        let status = CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let basePtr = dataPointer, totalLength > 0 else { return nil }

        let byteCount = totalLength
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<Float>.alignment
        )
        raw.copyMemory(from: UnsafeRawPointer(basePtr), byteCount: byteCount)
        defer { raw.deallocate() }

        let samples = raw.bindMemory(to: Float.self, capacity: byteCount / 4)
        let frameCount = (byteCount / 4) / max(channels, 1)
        guard frameCount > 0 else { return nil }

        var rmsAccum: Double = 0
        var minVal: Double = 1.0
        var maxVal: Double = -1.0
        var peak: Double = 0

        for i in 0..<frameCount {
            let s = Double(samples[i * channels])
            rmsAccum += s * s
            minVal = min(minVal, s)
            maxVal = max(maxVal, s)
            peak = max(peak, abs(s))
        }

        let rms = sqrt(rmsAccum / Double(frameCount))
        return (rms: rms, peak: peak, min: minVal, max: maxVal)
    }

    // Minimal helper to avoid creating Tasks; dispatch to main if needed.
    private func setOnMain(_ apply: @escaping () -> Void) {
        #if DEBUG
        if Thread.isMainThread { apply() }
        else { DispatchQueue.main.async(execute: apply) }
        #else
        apply()
        #endif
    }

    // MARK: - Export

    /// 将当前诊断信息导出到指定目录下的文本文件，方便用户打包发送。
    ///
    /// - Parameters:
    ///   - directory: 录音输出目录（例如某次测试的会话文件夹）。
    ///   - label: 可选标签，用于区分不同测试模式（如 "default-processing"）。
    public func writeSnapshot(to directory: URL, label: String? = nil) {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: directory.path) {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        } catch {
            return
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let now = df.string(from: Date())

        var lines: [String] = []
        lines.append("Mic Diagnostics Snapshot")
        lines.append("CreatedAt: \(now)")
        if let label {
            lines.append("Label: \(label)")
        }
        lines.append("")

        // Device
        lines.append("[Device]")
        lines.append("Name: \(deviceName ?? "-")")
        lines.append("ID: \(deviceID ?? "-")")
        lines.append("")

        // Format
        lines.append("[Stream Format]")
        if let f = lastFormat {
            lines.append("SampleRate: \(f.sampleRate)")
            lines.append("Channels: \(f.channels)")
            lines.append("BitsPerChannel: \(f.bitsPerChannel)")
            lines.append("BytesPerFrame: \(f.bytesPerFrame)")
            lines.append(String(format: "FormatID: 0x%08X", f.formatID))
            lines.append(String(format: "FormatFlags: 0x%08X", f.formatFlags))
            lines.append("IsFloat: \(f.isFloat)")
            lines.append("IsSignedInteger: \(f.isSignedInteger)")
            lines.append("IsNonInterleaved: \(f.isNonInterleaved)")
        } else {
            lines.append("No samples observed yet.")
        }
        lines.append("")

        // Processing options
        lines.append("[Processing Options]")
        lines.append("enableProcessing=\(processingOptions.enableProcessing)")
        lines.append("linearGain=\(processingOptions.linearGain)")
        lines.append("enableAGC=\(processingOptions.enableAGC)")
        lines.append("agcTargetRMS=\(processingOptions.agcTargetRMS)")
        lines.append("agcMaxGainDb=\(processingOptions.agcMaxGainDb)")
        lines.append("enableLimiter=\(processingOptions.enableLimiter)")
        lines.append("channels=\(processingOptions.channels)")
        lines.append("")

        // Capture / writer settings
        lines.append("[Capture Output Settings (.m4a recommended)]")
        if captureOutputSettings.isEmpty {
            lines.append("(empty)")
        } else {
            for (k, v) in captureOutputSettings.sorted(by: { $0.key < $1.key }) {
                lines.append("\(k)=\(v)")
            }
        }
        lines.append("")

        lines.append("[Writer Audio Settings]")
        if writerAudioSettings.isEmpty {
            lines.append("(empty)")
        } else {
            for (k, v) in writerAudioSettings.sorted(by: { $0.key < $1.key }) {
                lines.append("\(k)=\(v)")
            }
        }
        lines.append("")

        // Recent samples
        let dfSample = DateFormatter()
        dfSample.dateFormat = "HH:mm:ss.SSS"
        lines.append("[Recent Sample Buffers]")
        if recentSamples.isEmpty {
            lines.append("No samples.")
        } else {
            for s in recentSamples {
                var parts: [String] = []
                parts.append("t=\(dfSample.string(from: s.time))")
                parts.append("frames=\(s.frames)")
                parts.append("rate=\(Int(s.sampleRate))Hz")
                parts.append("ch=\(s.channels)")
                parts.append("bits=\(s.bitsPerChannel)")
                parts.append("float=\(s.isFloat)")
                parts.append("signed=\(s.isSignedInteger)")
                if let rms = s.rms {
                    parts.append(String(format: "rms=%.3f", rms))
                }
                if let peak = s.peak {
                    parts.append(String(format: "peak=%.3f", peak))
                }
                if let mi = s.minSample, let ma = s.maxSample {
                    parts.append(String(format: "min=%.3f max=%.3f", mi, ma))
                }
                lines.append(parts.joined(separator: "  "))
            }
        }

        let filename: String = {
            if let label, !label.isEmpty {
                return "mic-diagnostics-\(label).txt"
            }
            return "mic-diagnostics.txt"
        }()

        let url = directory.appendingPathComponent(filename)
        let text = lines.joined(separator: "\n")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Best-effort; 失败时静默
        }
    }
}

// MARK: - DTOs

/// Stream format info extracted from `AudioStreamBasicDescription`.
public struct RecorderMicFormatInfo: Sendable {
    public let sampleRate: Double
    public let channels: Int
    public let bitsPerChannel: Int
    public let bytesPerFrame: Int
    public let formatID: UInt32
    public let formatFlags: UInt32
    public let isFloat: Bool
    public let isSignedInteger: Bool
    public let isNonInterleaved: Bool

    /// Convenience human-readable description for debugging.
    public var summary: String {
        let idHex = "0x" + String(formatID, radix: 16)
        let flagsHex = "0x" + String(formatFlags, radix: 16)
        return "rate=\(sampleRate) Hz, ch=\(channels), bits=\(bitsPerChannel), bytes/frame=\(bytesPerFrame), id=\(idHex), flags=\(flagsHex), float=\(isFloat), signed=\(isSignedInteger), nonInterleaved=\(isNonInterleaved)"
    }
}

/// Per-sample-buffer statistics (mostly for display, not for processing).
public struct RecorderMicSampleStats: Identifiable, Sendable {
    public let id = UUID()
    public let time: Date
    public let sampleRate: Double
    public let channels: Int
    public let bitsPerChannel: Int
    public let frames: Int
    public let formatID: UInt32
    public let formatFlags: UInt32
    public let isFloat: Bool
    public let isSignedInteger: Bool
    public let isNonInterleaved: Bool
    public var rms: Double?
    public var peak: Double?
    public var minSample: Double?
    public var maxSample: Double?
}
