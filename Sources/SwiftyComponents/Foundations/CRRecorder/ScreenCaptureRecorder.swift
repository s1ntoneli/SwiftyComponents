//
//  ScreenCaptureRecorder.swift
//  CoreRecorder
//
//  Created by lixindong on 2025/6/6.
//


//
//  File.swift
//  RecorderKit
//
//  Created by lixindong on 2025/5/29.
//

import Foundation
import ScreenCaptureKit
import AVFoundation

class ScreenCaptureRecorder: @unchecked Sendable {
    private var captureFileOutput: CaptureFileOutput?
    let captureEngine = CaptureEngine()
    
    // 时间戳记录
    private var recordingStartTimestamp: CFAbsoluteTime?
    private var firstFrameTimestamp: CFAbsoluteTime?
    
    // MARK: - 回调
    /// 视频帧预览回调
    var videoFramePreviewHandler: ((CapturedFrame) -> Void)?
    /// 音频电平预览回调
    /// 错误处理回调
    var errorHandler: ((Error) -> Void)?
    
    private var segmentAssetWriter: AVAssetWriter?
    
    private var filePath: String
    
    init(filePath: String) {
        
        self.filePath = filePath
        
        // delegate
        let baseFileURL = URL(fileURLWithPath: filePath)
        
        // 设置第一帧时间戳回调
        captureEngine.firstFrameTimestampHandler = { [weak self] timestamp in
            self?.firstFrameTimestamp = timestamp
            print("RRR🛡️ 首帧时间戳: \(Date().timeIntervalSince1970)")
            print("[record-time] 开始时间: 画面 \(CFAbsoluteTimeGetCurrent())(date\(Date().timeIntervalSince1970)\(timestamp)")
        }
        
        // 设置预览回调
        captureEngine.videoFramePreviewHandler = { [weak self] frame in
            self?.videoFramePreviewHandler?(frame)
        }
        captureEngine.audioLevelPreviewHandler = { [weak self] in
        }
        
        // 设置错误处理回调
        captureEngine.errorHandler = { [weak self] error in
            NSLog("⚡ [SCREEN_RECORDER_ERROR] ScreenCaptureRecorder 接收到错误: %@", error.localizedDescription)
            self?.errorHandler?(error)
        }
    }
    
    func makeCaptureFileOutput(_ configuration: SCStreamConfiguration) throws {
       
        // 生成 video output settings
        let videoSize = (width: configuration.width, height: configuration.height)
        let videoSettings = try Self.generateVideoOutputSettings(videoSize: videoSize, configuration: configuration)
        
        // 生成 audio output settings
        let audioSettings = Self.generateAudioOutputSettings()
        
        // 初始化单文件录制 fileoutput
        let singleFileOutput = try SingleCaptureFileOutput(
            baseFileName: filePath,
            videoOutputSettings: videoSettings,
            audioOutputSettings: audioSettings,
            audioMode: .merged
        )
        
        self.captureFileOutput = singleFileOutput
        
        captureEngine.captureFileOutput = singleFileOutput
    }
    

    func startScreenCapture(
        displayID: CGDirectDisplayID, 
        cropRect: CGRect?,
        hdr: Bool,
        showsCursor: Bool,
        includeAudio: Bool
    ) async throws -> [CRRecorder.BundleInfo.FileAsset] {
        // 记录录制开始时间戳
        recordingStartTimestamp = CFAbsoluteTimeGetCurrent()
        
        let sharableContent = try await SCShareableContent.current
        guard let display = sharableContent.displays.first(where: { $0.displayID == displayID }) else {
            throw RecordingError.recordingFailed("Can't find display with ID \(displayID) in sharable content")
        }
        
        let windows = (try? await SCShareableContent.current.windows) ?? []
        var excludingWindows: [SCWindow] = []
        if let controlPanel = windows.first(where: { $0.title == "com.gokoding.screensage.controlPanel" }) {
            excludingWindows.append(controlPanel)
        }
        if let teleprompter = windows.first(where: { $0.title == "ScreenSageTeleprompterWindow_DO_NOT_RECORD" }) {
            excludingWindows.append(teleprompter)
        }
        if let cameraWindow = windows.first(where: { $0.title == "com.gokoding.screensage.camera_preview" }) {
            excludingWindows.append(cameraWindow)
        }
        if let controlPanel2Window = windows.first(where: { $0.title == "com.gokoding.screensage.controlPanel2_do_not_record" }) {
            excludingWindows.append(controlPanel2Window)
        }

        let filter = SCContentFilter(display: display, excludingWindows: excludingWindows)
        let configuration = try Self.createStreamConfiguration(
            for: display,
            cropRect: cropRect,
            hdr: false,
            mode: .h264_sRGB,
            includeAudio: includeAudio
        )
        
        try makeCaptureFileOutput(configuration)
        
//        for try await frame in captureEngine.startCapture(configuration: configuration, filter: filter) {
//            // 处理捕获的帧（由 CaptureEngine 处理）
//        }
        
        try captureEngine.startCaptureDirectly(configuration: configuration, filter: filter)
        
        let file = URL(fileURLWithPath: filePath)
        return [CRRecorder.BundleInfo.FileAsset(filename: file.lastPathComponent, tyle: .screen, recordingStartTimestamp: firstFrameTimestamp)]
    }
    
    func startWindowCapture(
        windowID: CGWindowID,
        displayID: CGDirectDisplayID?,
        hdr: Bool,
        includeAudio: Bool,
        frameRate: Int = 30,
        h265: Bool = false
    ) async throws -> [CRRecorder.BundleInfo.FileAsset]  {
        // 记录录制开始时间戳
        recordingStartTimestamp = CFAbsoluteTimeGetCurrent()
        
        let sharableContent = try await SCShareableContent.current
        guard let window = sharableContent.windows.first(where: { $0.windowID == windowID }) else {
            throw RecordingError.recordingFailed("Can't find window with ID \(windowID) in sharable content")
        }
//        guard let display = sharableContent.displays.first(where: { $0.displayID == displayID }) else {
//            throw RecordingError.recordingFailed("Can't find display with ID \(displayID) in sharable content")
//        }
        
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
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        
        try makeCaptureFileOutput(configuration)

        try captureEngine.startCaptureDirectly(configuration: configuration, filter: filter)
        
        let file = URL(fileURLWithPath: filePath)
        return [CRRecorder.BundleInfo.FileAsset(filename: file.lastPathComponent, tyle: .screen, recordingStartTimestamp: firstFrameTimestamp)]
    }
    
    func stop() async throws -> [CRRecorder.BundleInfo.FileAsset] {
        try await captureEngine.stopCapture()
        
        let file = URL(fileURLWithPath: filePath)
        return [CRRecorder.BundleInfo.FileAsset(filename: file.lastPathComponent, tyle: .screen, recordingStartTimestamp: firstFrameTimestamp)]
    }
    
    func packLastResult() -> [CRRecorder.BundleInfo.FileAsset] {
        let file = URL(fileURLWithPath: filePath)
        return [CRRecorder.BundleInfo.FileAsset(filename: file.lastPathComponent, tyle: .screen, recordingStartTimestamp: firstFrameTimestamp)]
    }
    
    // MARK: - 时间戳访问方法
    
    /// 获取录制开始时间戳（录制器启动时的时间）
    func getRecordingStartTimestamp() -> CFAbsoluteTime? {
        return recordingStartTimestamp
    }
    
    /// 获取第一帧时间戳（主设备专用，第一帧捕获时的精确时间）
    func getFirstFrameTimestamp() -> CFAbsoluteTime? {
        return firstFrameTimestamp
    }
    
    // MARK: - Private Helper Methods
    
    /// 确定文件资产类型
    private func determineFileAssetType(from scheme: CRRecorder.SchemeItem) -> CRRecorder.BundleInfo.FileAssetType {
        switch scheme {
        case .display: return .screen
        case .window: return .topWindow
        default: return .screen
        }
    }
    
    /// 生成视频输出设置
    private static func generateVideoOutputSettings(videoSize: (width: Int, height: Int), configuration: SCStreamConfiguration) throws -> [String: Any] {
        let mode = RecordMode.h264_sRGB

        // Use the preset as large as possible, size will be reduced to screen size by computed videoSize
        guard let assistant = AVOutputSettingsAssistant(preset: mode.preset) else {
            throw RecordingError.recordingFailed("Can't create AVOutputSettingsAssistant")
        }
        assistant.sourceVideoFormat = try CMVideoFormatDescription(videoCodecType: mode.videoCodecType, width: videoSize.width, height: videoSize.height)

        guard var outputSettings = assistant.videoSettings else {
            throw RecordingError.recordingFailed("AVOutputSettingsAssistant has no videoSettings")
        }
        outputSettings[AVVideoWidthKey] = videoSize.width
        outputSettings[AVVideoHeightKey] = videoSize.height

        // Configure video color properties and compression properties based on RecordMode
        // See AVVideoSettings.h and VTCompressionProperties.h
        outputSettings[AVVideoColorPropertiesKey] = mode.videoColorProperties

        // Always provide explicit compression properties so we can control file size.
        var compressionProperties: [String: Any] = outputSettings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]

        // Profile/level if provided by mode
        if let videoProfileLevel = mode.videoProfileLevel {
            compressionProperties[AVVideoProfileLevelKey] = videoProfileLevel
        }

        // Compute a target bitrate using a bpp-based formula to reduce file size
        // bitrate ≈ width × height × fps × bpp
        let fps: Int = {
            let t = configuration.minimumFrameInterval
            if t.value != 0 { return max(1, Int(round(Double(t.timescale) / Double(t.value)))) }
            return 60
        }()
        let isHEVC = (mode == .hevc_displayP3)
        let bpp: Double = isHEVC ? 0.008 : 0.012 // conservative for screen content
        let computedBitrate = Int(Double(videoSize.width * videoSize.height * max(1, fps)) * bpp)
        let targetBitRate = max(1_000_000, computedBitrate) // keep a floor at ~1 Mbps

        compressionProperties[AVVideoAverageBitRateKey] = targetBitRate
        compressionProperties[AVVideoExpectedSourceFrameRateKey] = fps
        compressionProperties[AVVideoMaxKeyFrameIntervalDurationKey] = 2 // 2-second GOP for stability

        // Prefer CABAC entropy for H.264 when available (slightly better compression)
        compressionProperties[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC

        outputSettings[AVVideoCompressionPropertiesKey] = compressionProperties as NSDictionary

        // Set pixel format and color space, see CVPixelBuffer.h
        switch mode {
        case .h264_sRGB:
            configuration.pixelFormat = kCVPixelFormatType_32BGRA // 'BGRA'
            configuration.colorSpaceName = CGColorSpace.sRGB
        case .hevc_displayP3:
            configuration.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked // 'l10r'
            configuration.colorSpaceName = CGColorSpace.displayP3
        }

        return outputSettings
    }
    
   
    // AVAssetWriterInput supports maximum resolution of 4096x2304 for H.264
    private static func downsizedVideoSize(source: CGSize, scaleFactor: Int, mode: RecordMode) -> (width: Int, height: Int) {
        let maxSize = mode.maxSize

        let w = source.width * Double(scaleFactor)
        let h = source.height * Double(scaleFactor)
        let r = max(w / maxSize.width, h / maxSize.height)

        return r > 1
            ? (width: Int(w / r), height: Int(h / r))
            : (width: Int(w), height: Int(h))
    }
    /// 生成音频输出设置
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
    
    /// 根据分辨率与 fps 推荐 queueDepth，兼顾抗抖动与内存占用
    private static func recommendedQueueDepth(width: Int, height: Int, fps: Int) -> Int {
        let area = width * height
        // 阈值：1080p、1440p、4K
        let d1080p = 1920 * 1080
        let d1440p = 2560 * 1440
        let d4k = 3840 * 2160
        var depth: Int
        if area <= d1080p { depth = 8 }
        else if area <= d1440p { depth = 10 }
        else if area <= d4k { depth = 14 }
        else { depth = 16 }
        // 极端高帧率时略微加深；低帧率则保守
        if fps >= 90 { depth += 2 }
        if fps <= 30 { depth = max(6, depth - 2) }
        return max(6, min(depth, 20))
    }

    /// 创建流配置（显示器版本）
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
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps)) // 30fps for better quality
        
        // 计算录制尺寸
        if let cropRect = cropRect {
            configuration.sourceRect = cropRect
            configuration.width = Int(cropRect.width) * displayScaleFactor
            configuration.height = Int(cropRect.height) * displayScaleFactor
        } else {
            configuration.width = Int(displaySize.width) * displayScaleFactor
            configuration.height = Int(displaySize.height) * displayScaleFactor
        }
        
        // 应用最大尺寸限制
        let maxDimensions = mode.maxSize
        let (width, height) = Self.applyMaxDimensions(
            width: configuration.width,
            height: configuration.height,
            maxDimensions: maxDimensions
        )
        configuration.width = width
        configuration.height = height
        // 根据有效分辨率与 fps 设置合适的队列深度
        configuration.queueDepth = Self.recommendedQueueDepth(width: width, height: height, fps: fps)
        
        // 设置像素格式和色彩空间
        Self.configurePixelFormat(configuration: configuration, colorSpace: .sRGB)
        
        return configuration
    }
    
    /// 创建流配置（窗口版本）
    private static func createStreamConfiguration(
        for window: SCWindow,
        colorSpace: RKColorSpace,
        minimumFrameInterval: CMTime,
        maxVideoDimensions: CGSize?,
        showsCursor: Bool,
        includeAudio: Bool
    ) throws -> SCStreamConfiguration {
        let windowSize = window.frame.size
        let scaleFactor = Self.getWindowScaleFactor(for: window)
        
        let configuration = SCStreamConfiguration()
        configuration.minimumFrameInterval = minimumFrameInterval
        configuration.showsCursor = showsCursor
        configuration.capturesAudio = includeAudio
        
        // 计算录制尺寸
        configuration.width = Int(windowSize.width * scaleFactor)
        configuration.height = Int(windowSize.height * scaleFactor)
        
        // 应用最大尺寸限制
        if let maxDimensions = maxVideoDimensions {
            let (width, height) = Self.applyMaxDimensions(
                width: configuration.width,
                height: configuration.height,
                maxDimensions: maxDimensions
            )
            configuration.width = width
            configuration.height = height
        }
        // 根据最终分辨率与 fps 推荐 queueDepth
        let fps = max(1, Int(round(Double(minimumFrameInterval.timescale) / Double(minimumFrameInterval.value))))
        configuration.queueDepth = Self.recommendedQueueDepth(width: configuration.width, height: configuration.height, fps: fps)

        // 设置像素格式和色彩空间
        Self.configurePixelFormat(configuration: configuration, colorSpace: colorSpace)
        
        return configuration
    }
    
    /// 获取显示器缩放因子
    private static func getDisplayScaleFactor(for displayID: CGDirectDisplayID) -> Int {
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            return mode.pixelWidth / mode.width
        } else {
            return 1
        }
    }
    
    /// 获取窗口缩放因子
    private static func getWindowScaleFactor(for window: SCWindow) -> CGFloat {
        // 查找窗口所在的屏幕
        let windowCenter = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let targetScreen = NSScreen.screens.first { screen in
            screen.frame.contains(windowCenter)
        }
        return targetScreen?.backingScaleFactor ?? 1.0
    }
    
    /// 应用最大尺寸限制
    private static func applyMaxDimensions(
        width: Int,
        height: Int,
        maxDimensions: CGSize
    ) -> (width: Int, height: Int) {
        let maxWidth = Int(maxDimensions.width)
        let maxHeight = Int(maxDimensions.height)
        
        if width <= maxWidth && height <= maxHeight {
            return (width, height)
        }
        
        let aspectRatio = Double(width) / Double(height)
        
        if Double(maxWidth) / aspectRatio <= Double(maxHeight) {
            return (maxWidth, Int(Double(maxWidth) / aspectRatio))
        } else {
            return (Int(Double(maxHeight) * aspectRatio), maxHeight)
        }
    }
    
    /// 配置像素格式和色彩空间
    private static func configurePixelFormat(configuration: SCStreamConfiguration, colorSpace: RKColorSpace) {
        switch colorSpace {
        case .sRGB, .rec709:
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.sRGB
        case .displayP3, .rec2020:
            configuration.pixelFormat = kCVPixelFormatType_ARGB2101010LEPacked
            configuration.colorSpaceName = CGColorSpace.displayP3
        }
    }
}
enum RecordMode {
    case h264_sRGB
    case hevc_displayP3

    // I haven't gotten HDR recording working yet.
    // The commented out code is my best attempt, but still results in "blown out whites".
    //
    // Any tips are welcome!
    // - Tom
//    case hevc_displayP3_HDR
}
// Extension properties for values that differ per record mode
extension RecordMode {
    var preset: AVOutputSettingsPreset {
        switch self {
        case .h264_sRGB: return .preset3840x2160
        case .hevc_displayP3: return .hevc7680x4320
//        case .hevc_displayP3_HDR: return .hevc7680x4320
        }
    }

    var maxSize: CGSize {
        switch self {
        case .h264_sRGB: return CGSize(width: 4096, height: 2304)
        case .hevc_displayP3: return CGSize(width: 7680, height: 4320)
//        case .hevc_displayP3_HDR: return CGSize(width: 7680, height: 4320)
        }
    }

    var videoCodecType: CMFormatDescription.MediaSubType {
        switch self {
        case .h264_sRGB: return .h264
        case .hevc_displayP3: return .hevc
//        case .hevc_displayP3_HDR: return .hevc
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
//        case .hevc_displayP3_HDR:
//            return [
//                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
//                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
//                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
//            ]
        }
    }

    var videoProfileLevel: CFString? {
        switch self {
        case .h264_sRGB:
            return nil
        case .hevc_displayP3:
            return nil
//        case .hevc_displayP3_HDR:
//            return kVTProfileLevel_HEVC_Main10_AutoLevel
        }
    }
}
/// 颜色空间
public enum RKColorSpace: Sendable {
    case sRGB
    case displayP3
    case rec709
    case rec2020
    
    // TODO: 添加更多颜色空间支持
}
