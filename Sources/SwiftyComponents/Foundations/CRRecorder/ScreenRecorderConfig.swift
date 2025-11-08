import Foundation
import AVFoundation
import ScreenCaptureKit

enum RecordMode { case h264_sRGB, hevc_displayP3 }

enum RecorderConfig {
    static func make(for display: SCDisplay, cropRect: CGRect?, options: ScreenRecorderOptions) throws -> SCStreamConfiguration {
        let size = display.frame.size
        let scale = displayScaleFactor(display.displayID)
        let c = SCStreamConfiguration()
        c.showsCursor = options.showsCursor
        c.capturesAudio = options.includeAudio
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        if let crop = cropRect {
            c.sourceRect = crop
            c.width = Int(crop.width) * scale
            c.height = Int(crop.height) * scale
        } else {
            c.width = Int(size.width) * scale
            c.height = Int(size.height) * scale
        }
        let mode: RecordMode = (options.useHEVC || options.hdr) ? .hevc_displayP3 : .h264_sRGB
        let (w, h) = applyMaxDimensions(width: c.width, height: c.height, max: mode.maxSize)
        c.width = w; c.height = h
        c.queueDepth = options.queueDepth ?? recommendedQueueDepth(width: w, height: h, fps: options.fps)
        switch mode {
        case .h264_sRGB: c.pixelFormat = kCVPixelFormatType_32BGRA; c.colorSpaceName = CGColorSpace.sRGB
        case .hevc_displayP3: c.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked; c.colorSpaceName = CGColorSpace.displayP3
        }
        return c
    }

    static func make(for window: SCWindow, options: ScreenRecorderOptions) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        let scale = windowScale(window)
        c.width = Int(window.frame.width) * Int(scale)
        c.height = Int(window.frame.height) * Int(scale)
        c.showsCursor = options.showsCursor
        c.capturesAudio = options.includeAudio
        c.sampleRate = 48000
        c.channelCount = 2
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        c.queueDepth = options.queueDepth ?? recommendedQueueDepth(width: c.width, height: c.height, fps: options.fps)
        let mode: RecordMode = (options.useHEVC || options.hdr) ? .hevc_displayP3 : .h264_sRGB
        switch mode {
        case .h264_sRGB: c.pixelFormat = kCVPixelFormatType_32BGRA; c.colorSpaceName = CGColorSpace.sRGB
        case .hevc_displayP3: c.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked; c.colorSpaceName = CGColorSpace.displayP3
        }
        return c
    }

    static func videoSettings(for size: (width: Int, height: Int), configuration: SCStreamConfiguration, options: ScreenRecorderOptions) throws -> [String: Any] {
        let mode: RecordMode = (options.useHEVC || options.hdr) ? .hevc_displayP3 : .h264_sRGB
        guard let assistant = AVOutputSettingsAssistant(preset: mode.preset) else {
            throw RecordingError.recordingFailed("Can't create AVOutputSettingsAssistant")
        }
        assistant.sourceVideoFormat = try CMVideoFormatDescription(videoCodecType: mode.videoCodecType, width: size.width, height: size.height)
        guard var output = assistant.videoSettings else { throw RecordingError.recordingFailed("No videoSettings") }
        output[AVVideoWidthKey] = size.width
        output[AVVideoHeightKey] = size.height
        output[AVVideoColorPropertiesKey] = mode.videoColorProperties

        var comp = output[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
        let fps: Int = {
            let t = configuration.minimumFrameInterval
            if t.value != 0 { return max(1, Int(round(Double(t.timescale) / Double(t.value)))) }
            return options.fps
        }()
        let defaultBpp: Double = (mode == .hevc_displayP3) ? 0.008 : 0.012
        let computed = Int(Double(size.width * size.height * max(1, fps)) * defaultBpp)
        let target = options.targetBitRate ?? computed
        comp[AVVideoAverageBitRateKey] = max(1_000_000, target)
        comp[AVVideoExpectedSourceFrameRateKey] = fps
        comp[AVVideoMaxKeyFrameIntervalDurationKey] = 2
        comp[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        output[AVVideoCompressionPropertiesKey] = comp as NSDictionary
        return output
    }

    static func audioSettings(sampleRate: Int? = nil, bitRate: Int? = nil) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate ?? 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: bitRate ?? 128000
        ]
    }

    static func recommendedQueueDepth(width: Int, height: Int, fps: Int) -> Int {
        let area = width * height
        let d1080p = 1920 * 1080
        let d1440p = 2560 * 1440
        let d4k = 3840 * 2160
        var depth: Int
        if area <= d1080p { depth = 8 }
        else if area <= d1440p { depth = 10 }
        else if area <= d4k { depth = 14 }
        else { depth = 16 }
        if fps >= 90 { depth += 2 }
        if fps <= 30 { depth = max(6, depth - 2) }
        return max(6, min(depth, 20))
    }

    // MARK: helpers
    private static func displayScaleFactor(_ id: CGDirectDisplayID) -> Int {
        if let mode = CGDisplayCopyDisplayMode(id) { return mode.pixelWidth / mode.width }
        return 1
    }
    private static func windowScale(_ window: SCWindow) -> CGFloat {
        let p = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(p) }
        return screen?.backingScaleFactor ?? 1.0
    }
    private static func applyMaxDimensions(width: Int, height: Int, max: CGSize) -> (Int, Int) {
        let mw = Int(max.width), mh = Int(max.height)
        if width <= mw && height <= mh { return (width, height) }
        let r = Double(width) / Double(height)
        if Double(mw)/r <= Double(mh) { return (mw, Int(Double(mw)/r)) }
        return (Int(Double(mh)*r), mh)
    }
}

private extension RecordMode {
    var preset: AVOutputSettingsPreset { self == .h264_sRGB ? .preset3840x2160 : .hevc7680x4320 }
    var maxSize: CGSize { self == .h264_sRGB ? CGSize(width: 4096, height: 2304) : CGSize(width: 7680, height: 4320) }
    var videoCodecType: CMFormatDescription.MediaSubType { self == .h264_sRGB ? .h264 : .hevc }
    var videoColorProperties: NSDictionary {
        switch self {
        case .h264_sRGB:
            return [AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        case .hevc_displayP3:
            return [AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        }
    }
}

