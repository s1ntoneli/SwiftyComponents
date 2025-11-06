//
//  ScreenCaptureRecorder.swift
//  SwiftyComponents
//
//  Reimplemented to align with QuickRecorder approach:
//  - startWriting() before capture
//  - startSession(atSourceTime:) at first video frame PTS
//  - append screen/audio samples directly when inputs are ready

import Foundation
import AVFoundation
import ScreenCaptureKit

final class ScreenCaptureRecorder: NSObject, @unchecked Sendable {
    // MARK: - Public callbacks
    var errorHandler: ((Error) -> Void)?

    // MARK: - Private state
    private var filePath: String
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var stream: SCStream?
    private var output: StreamOutput?
    private var firstVideoPTS: CMTime?

    // timestamps for result
    private var recordingStartTimestamp: CFAbsoluteTime?
    private var firstFrameTimestamp: CFAbsoluteTime?

    init(filePath: String) {
        self.filePath = filePath
    }

    // MARK: - Start capture (Display)
    func startScreenCapture(
        displayID: CGDirectDisplayID,
        cropRect: CGRect?,
        hdr: Bool,
        showsCursor: Bool,
        includeAudio: Bool
    ) async throws -> [CRRecorder.BundleInfo.FileAsset] {
        recordingStartTimestamp = CFAbsoluteTimeGetCurrent()

        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecordingError.recordingFailed("Can't find display with ID \(displayID)")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = try Self.createStreamConfiguration(
            for: display,
            cropRect: cropRect,
            hdr: hdr,
            mode: .h264_sRGB,
            includeAudio: includeAudio
        )

        try prepareWriter(configuration: configuration, includeAudio: includeAudio)
        try startStream(configuration: configuration, filter: filter, includeAudio: includeAudio)

        let file = URL(fileURLWithPath: filePath)
        return [CRRecorder.BundleInfo.FileAsset(filename: file.lastPathComponent, tyle: .screen, recordingStartTimestamp: firstFrameTimestamp)]
    }

    // MARK: - Start capture (Window)
    func startWindowCapture(
        windowID: CGWindowID,
        displayID: CGDirectDisplayID?,
        hdr: Bool,
        includeAudio: Bool,
        frameRate: Int = 30,
        h265: Bool = false
    ) async throws -> [CRRecorder.BundleInfo.FileAsset] {
        recordingStartTimestamp = CFAbsoluteTimeGetCurrent()

        let content = try await SCShareableContent.current
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw RecordingError.recordingFailed("Can't find window with ID \(windowID)")
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width) * Int(filter.pointPixelScale)
        configuration.height = Int(filter.contentRect.height) * Int(filter.pointPixelScale)
        configuration.showsCursor = false
        configuration.capturesAudio = includeAudio
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.queueDepth = Self.recommendedQueueDepth(width: configuration.width, height: configuration.height, fps: frameRate)
        if h265 {
            configuration.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked
            configuration.colorSpaceName = CGColorSpace.displayP3
        } else {
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.sRGB
        }

        try prepareWriter(configuration: configuration, includeAudio: includeAudio)
        try startStream(configuration: configuration, filter: filter, includeAudio: includeAudio)

        let file = URL(fileURLWithPath: filePath)
        return [CRRecorder.BundleInfo.FileAsset(filename: file.lastPathComponent, tyle: .screen, recordingStartTimestamp: firstFrameTimestamp)]
    }

    // MARK: - Stop
    func stop() async throws -> [CRRecorder.BundleInfo.FileAsset] {
        try await stopStreamAndFinish()
        let end = CFAbsoluteTimeGetCurrent()
        let start = firstFrameTimestamp ?? recordingStartTimestamp
        var url = URL(fileURLWithPath: filePath)
        if let s = start { url = renameFileAddingDuration(url: url, seconds: max(0, end - s)) }
        filePath = url.path
        return [CRRecorder.BundleInfo.FileAsset(filename: url.lastPathComponent, tyle: .screen, recordingStartTimestamp: start, recordingEndTimestamp: end)]
    }

    func packLastResult() -> [CRRecorder.BundleInfo.FileAsset] {
        let file = URL(fileURLWithPath: filePath)
        return [CRRecorder.BundleInfo.FileAsset(filename: file.lastPathComponent, tyle: .screen, recordingStartTimestamp: firstFrameTimestamp)]
    }

    // MARK: - Writer + Stream
    private func prepareWriter(configuration: SCStreamConfiguration, includeAudio: Bool) throws {
        var outURL = URL(fileURLWithPath: filePath)
        if outURL.pathExtension.isEmpty { outURL.appendPathExtension("mov") }
        filePath = outURL.path

        let writer = try AVAssetWriter(url: outURL, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: RecorderDiagnostics.shared.fragmentIntervalSeconds, preferredTimescale: 600)
        RecorderDiagnostics.shared.setOutputFileURL(outURL)

        let videoSize = (width: configuration.width, height: configuration.height)
        let videoSettings = try Self.generateVideoOutputSettings(videoSize: videoSize, configuration: configuration)
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(vInput) else { throw RecordingError.recordingFailed("Can't add video input to writer") }
        writer.add(vInput)

        var aInput: AVAssetWriterInput? = nil
        if includeAudio {
            let audioSettings = Self.generateAudioOutputSettings()
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            ai.expectsMediaDataInRealTime = true
            if writer.canAdd(ai) { writer.add(ai); aInput = ai }
        }

        guard writer.startWriting() else { throw writer.error ?? RecordingError.recordingFailed("startWriting failed") }

        self.writer = writer
        self.videoInput = vInput
        self.audioInput = aInput
    }

    private func startStream(configuration: SCStreamConfiguration, filter: SCContentFilter, includeAudio: Bool) throws {
        let output = StreamOutput()
        output.onVideo = { [weak self] sample in
            guard let self, let writer = self.writer, let vInput = self.videoInput else { return }
            if self.firstVideoPTS == nil {
                self.firstVideoPTS = sample.presentationTimeStamp
                self.firstFrameTimestamp = CFAbsoluteTimeGetCurrent()
                writer.startSession(atSourceTime: self.firstVideoPTS!)
                RecorderDiagnostics.shared.onWriterStarted()
                RecorderDiagnostics.shared.recordEvent("Writer session started")
            }
            guard writer.status == .writing else { return }
            if vInput.isReadyForMoreMediaData { _ = vInput.append(sample) }
        }
        output.onAudio = { [weak self] sample in
            guard let self, let writer = self.writer, let aInput = self.audioInput else { return }
            guard writer.status == .writing else { return }
            if aInput.isReadyForMoreMediaData { _ = aInput.append(sample) }
        }
        output.onError = { [weak self] error in
            self?.errorHandler?(error)
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "com.swiftycomponents.screen.video"))
        if includeAudio {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.swiftycomponents.screen.audio"))
        }
        RecorderDiagnostics.shared.onStartCapture(configuration: configuration)
        stream.startCapture()
        self.stream = stream
        self.output = output
    }

    private func stopStreamAndFinish() async throws {
        if let stream = self.stream {
            try await stream.stopCapture()
        }
        self.stream = nil
        RecorderDiagnostics.shared.onStopCapture()

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        if let writer = writer {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                writer.finishWriting {
                    RecorderDiagnostics.shared.onWriterStopped()
                    cont.resume()
                }
            }
        }
    }

    // MARK: - Helpers
    private static func generateVideoOutputSettings(videoSize: (width: Int, height: Int), configuration: SCStreamConfiguration) throws -> [String: Any] {
        let mode = RecordMode.h264_sRGB

        guard let assistant = AVOutputSettingsAssistant(preset: mode.preset) else {
            throw RecordingError.recordingFailed("Can't create AVOutputSettingsAssistant")
        }
        assistant.sourceVideoFormat = try CMVideoFormatDescription(videoCodecType: mode.videoCodecType, width: videoSize.width, height: videoSize.height)

        guard var outputSettings = assistant.videoSettings else {
            throw RecordingError.recordingFailed("AVOutputSettingsAssistant has no videoSettings")
        }
        outputSettings[AVVideoWidthKey] = videoSize.width
        outputSettings[AVVideoHeightKey] = videoSize.height
        outputSettings[AVVideoColorPropertiesKey] = mode.videoColorProperties

        var compressionProperties: [String: Any] = outputSettings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]

        if let videoProfileLevel = mode.videoProfileLevel {
            compressionProperties[AVVideoProfileLevelKey] = videoProfileLevel
        }

        let fps: Int = {
            let t = configuration.minimumFrameInterval
            if t.value != 0 { return max(1, Int(round(Double(t.timescale) / Double(t.value)))) }
            return 60
        }()
        let isHEVC = (mode == .hevc_displayP3)
        let bpp: Double = isHEVC ? 0.008 : 0.012
        let computedBitrate = Int(Double(videoSize.width * videoSize.height * max(1, fps)) * bpp)
        let targetBitRate = max(1_000_000, computedBitrate)

        compressionProperties[AVVideoAverageBitRateKey] = targetBitRate
        compressionProperties[AVVideoExpectedSourceFrameRateKey] = fps
        compressionProperties[AVVideoMaxKeyFrameIntervalDurationKey] = 2
        compressionProperties[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        outputSettings[AVVideoCompressionPropertiesKey] = compressionProperties as NSDictionary

        switch mode {
        case .h264_sRGB:
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.sRGB
        case .hevc_displayP3:
            configuration.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked
            configuration.colorSpaceName = CGColorSpace.displayP3
        }

        return outputSettings
    }

    private static func generateAudioOutputSettings(sampleRate: Int? = nil, bitRate: Int? = nil) -> [String: Any] {
        let sampleRate = sampleRate ?? 44100
        let bitRate = bitRate ?? 128000
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: bitRate
        ]
    }

    private static func recommendedQueueDepth(width: Int, height: Int, fps: Int) -> Int {
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

    private static func createStreamConfiguration(
        for display: SCDisplay,
        cropRect: CGRect?,
        hdr: Bool,
        mode: RecordMode,
        includeAudio: Bool,
        fps: Int = 60
    ) throws -> SCStreamConfiguration {
        let displaySize = display.frame.size
        let displayScaleFactor = Self.getDisplayScaleFactor(for: display.displayID)

        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.capturesAudio = includeAudio
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))

        if let cropRect = cropRect {
            configuration.sourceRect = cropRect
            configuration.width = Int(cropRect.width) * displayScaleFactor
            configuration.height = Int(cropRect.height) * displayScaleFactor
        } else {
            configuration.width = Int(displaySize.width) * displayScaleFactor
            configuration.height = Int(displaySize.height) * displayScaleFactor
        }

        let maxDimensions = mode.maxSize
        let (width, height) = Self.applyMaxDimensions(width: configuration.width, height: configuration.height, maxDimensions: maxDimensions)
        configuration.width = width
        configuration.height = height
        configuration.queueDepth = Self.recommendedQueueDepth(width: width, height: height, fps: fps)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        return configuration
    }

    private static func getDisplayScaleFactor(for displayID: CGDirectDisplayID) -> Int {
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            return mode.pixelWidth / mode.width
        } else {
            return 1
        }
    }

    private static func getWindowScaleFactor(for window: SCWindow) -> CGFloat {
        let windowCenter = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let targetScreen = NSScreen.screens.first { screen in
            screen.frame.contains(windowCenter)
        }
        return targetScreen?.backingScaleFactor ?? 1.0
    }

    private static func applyMaxDimensions(width: Int, height: Int, maxDimensions: CGSize) -> (width: Int, height: Int) {
        let maxWidth = Int(maxDimensions.width)
        let maxHeight = Int(maxDimensions.height)
        if width <= maxWidth && height <= maxHeight { return (width, height) }
        let aspectRatio = Double(width) / Double(height)
        if Double(maxWidth) / aspectRatio <= Double(maxHeight) {
            return (maxWidth, Int(Double(maxWidth) / aspectRatio))
        } else {
            return (Int(Double(maxHeight) * aspectRatio), maxHeight)
        }
    }

    // No-op helper kept for potential future extension
}

// Stream output → forward raw CMSampleBuffers
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    var onVideo: ((CMSampleBuffer) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch outputType {
        case .screen:
            if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let attachments = attachmentsArray.first,
               let statusRaw = attachments[SCStreamFrameInfo.status] as? Int,
               let status = SCFrameStatus(rawValue: statusRaw), status == .complete {
                onVideo?(sampleBuffer)
            }
        case .audio:
            onAudio?(sampleBuffer)
        case .microphone:
            // Ignore for now; handled via `.audio` when capturesAudio is enabled
            break
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}

enum RecordMode {
    case h264_sRGB
    case hevc_displayP3
}

extension RecordMode {
    var preset: AVOutputSettingsPreset {
        switch self {
        case .h264_sRGB: return .preset3840x2160
        case .hevc_displayP3: return .hevc7680x4320
        }
    }
    var maxSize: CGSize {
        switch self {
        case .h264_sRGB: return CGSize(width: 4096, height: 2304)
        case .hevc_displayP3: return CGSize(width: 7680, height: 4320)
        }
    }
    var videoCodecType: CMFormatDescription.MediaSubType {
        switch self {
        case .h264_sRGB: return .h264
        case .hevc_displayP3: return .hevc
        }
    }
    var videoColorProperties: NSDictionary {
        switch self {
        case .h264_sRGB:
            return [
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        case .hevc_displayP3:
            return [
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        }
    }
    var videoProfileLevel: CFString? { nil }
}
