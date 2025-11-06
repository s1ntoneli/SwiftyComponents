//
//  CapturedFrame.swift
//  CoreRecorder
//
//  Created by lixindong on 2025/6/6.
//


/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
An object that captures a stream of captured sample buffers containing screen and audio content.
*/
import Foundation
import AVFAudio
@preconcurrency import ScreenCaptureKit
import OSLog
import Combine

/// A structure that contains the video data to render.
struct CapturedFrame: Sendable {
    static let invalid = CapturedFrame(surface: nil, contentRect: .zero, contentScale: 0, scaleFactor: 0)

    nonisolated(unsafe)
    let surface: IOSurface?
    
    let contentRect: CGRect
    let contentScale: CGFloat
    let scaleFactor: CGFloat
    var size: CGSize { contentRect.size }
}

/// An object that wraps an instance of `SCStream`, and returns its results as an `AsyncThrowingStream`.
@preconcurrency
class CaptureEngine: NSObject, @unchecked Sendable, @preconcurrency SCStreamDelegate {
    
    private let logger = Logger()

    private(set) var stream: SCStream?
    private var streamOutput: CaptureEngineStreamOutput?
    private let videoSampleBufferQueue = DispatchQueue(label: "com.example.apple-samplecode.VideoSampleBufferQueue")
    private let audioSampleBufferQueue = DispatchQueue(label: "com.example.apple-samplecode.AudioSampleBufferQueue")
    
    // Performs average and peak power calculations on the audio samples.
    private let powerMeter = PowerMeter()
    var audioLevels: AudioLevels { powerMeter.levels }
    
    var captureFileOutput: SingleCaptureFileOutput? = nil
    
    // Store the the startCapture continuation, so that you can cancel it when you call stopCapture().
    private var continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation?
    
    // 第一帧标记
    private var hasReceivedFirstFrame = false
    var firstFrameTimestampHandler: ((CFAbsoluteTime) -> Void)?
    
    // MARK: - 预览回调
    /// 视频帧预览回调
    var videoFramePreviewHandler: ((CapturedFrame) -> Void)?
    /// 音频电平预览回调  
    var audioLevelPreviewHandler: (() -> Void)?
    /// 错误处理回调
    var errorHandler: ((Error) -> Void)?

    // 避免重复收尾的标记（系统停止/手动停止等场景）
    private var hasFinalized = false
    
    /// - Tag: StartCapture
    func startCapture(configuration: SCStreamConfiguration, filter: SCContentFilter) -> AsyncThrowingStream<CapturedFrame, Error> {
        AsyncThrowingStream<CapturedFrame, Error> { continuation in
            // The stream output object. Avoid reassigning it to a new object every time startCapture is called.
            let streamOutput = CaptureEngineStreamOutput(continuation: continuation, captureFileOutput: captureFileOutput, firstFrameTimestampHandler: firstFrameTimestampHandler)
            self.streamOutput = streamOutput
            streamOutput.capturedFrameHandler = { continuation.yield($0) }
            streamOutput.pcmBufferHandler = { self.powerMeter.process(buffer: $0) }

            // 添加预览回调
            streamOutput.videoFramePreviewHandler = { [weak self] frame in
                self?.videoFramePreviewHandler?(frame)
            }
            streamOutput.audioLevelPreviewHandler = { [weak self] in
                self?.audioLevelPreviewHandler?()
            }
            self.continuation = continuation

            do {
                stream = SCStream(filter: filter, configuration: configuration, delegate: streamOutput)
                
                // Add a stream output to capture screen content.
                try stream?.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: videoSampleBufferQueue)
                try stream?.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: audioSampleBufferQueue)
                stream?.startCapture()
                self.captureFileOutput?.startSession()
            } catch {
                print("❌ Failed to start capture: \(error)")
                continuation.finish(throwing: error)
            }
        }
    }
    
    /// - Tag: StartCapture
    func startCaptureDirectly(configuration: SCStreamConfiguration, filter: SCContentFilter) throws {
        // The stream output object. Avoid reassigning it to a new object every time startCapture is called.
        let streamOutput = CaptureEngineStreamOutput(continuation: continuation, captureFileOutput: captureFileOutput, firstFrameTimestampHandler: firstFrameTimestampHandler)
        self.streamOutput = streamOutput
        streamOutput.capturedFrameHandler = { _ in }
        streamOutput.pcmBufferHandler = { self.powerMeter.process(buffer: $0) }
        
        // 添加预览回调
        streamOutput.videoFramePreviewHandler = { [weak self] frame in
            self?.videoFramePreviewHandler?(frame)
        }
        streamOutput.audioLevelPreviewHandler = { [weak self] in
            self?.audioLevelPreviewHandler?()
        }
        streamOutput.onError = { error in
            NSLog("🌊 [STREAM_OUTPUT_DIRECT_ERROR] 直接模式流输出错误: %@", error.localizedDescription)
            let nsError = error as NSError
            Task { [weak self] in
                // 如果系统已停止流 (-3821)，不要再次调用 stopCapture()
                if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsError.code == -3821 {
                    await self?.finalizeAfterExternalStop()
                } else {
                    try await self?.stopCapture()
                }
                self?.errorHandler?(error)
            }
            RecorderDiagnostics.shared.recordError(error)
        }
        captureFileOutput?.onError = { error in
            NSLog("📝 [CAPTURE_FILE_ERROR] 文件输出错误: %@", error.localizedDescription)
            Task { [weak self]  in
                try await self?.stopCapture()
                self?.errorHandler?(error)
            }
        }
        
        stream = SCStream(filter: filter, configuration: configuration, delegate: streamOutput)
        RecorderDiagnostics.shared.onStartCapture(configuration: configuration)
        
        // Add a stream output to capture screen content.
        try stream?.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: videoSampleBufferQueue)
        try stream?.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: audioSampleBufferQueue)
        stream?.startCapture()
        self.captureFileOutput?.startSession()
    }

    /// 当系统已停止 SCStream（如 -3821）时的收尾逻辑：
    /// 跳过对 SCStream 的 stopCapture 调用，仅做本地清理与文件关闭。
    func finalizeAfterExternalStop() async {
        if hasFinalized { return }
        hasFinalized = true
        powerMeter.processSilence()
        do {
            try await Task.sleep(for: .seconds(1))
            try await captureFileOutput?.stopSession()
        } catch {
            NSLog("⚠️ [FINALIZE_AFTER_EXTERNAL_STOP] 关闭文件写入时出错: %@", (error as NSError).localizedDescription)
        }
        // 避免后续重复 stop 调用触发 -3808 日志
        stream = nil
        RecorderDiagnostics.shared.onStopCapture()
    }
    
//    func stream(_ stream: SCStream, didStopWithError error: any Error) {
//        print("❌ Failed to didStopWithError: \(error)")
//        Task {
//            await safeStopCaptureFileOutput()
//            // 检测内存不足错误
//            if let nsError = error as NSError? {
//                let isMemoryError = checkMemoryError(nsError)
//                if isMemoryError {
//                    print("⚠️ 检测到内存不足问题，请关闭其他应用或降低录制质量")
//                    // 可以通过通知等方式提醒用户
//                    NotificationCenter.default.post(
//                        name: NSNotification.Name("CaptureMemoryWarning"),
//                        object: nil,
//                        userInfo: ["error": error, "suggestion": "内存不足，建议关闭其他应用或降低录制质量"]
//                    )
//                }
//            }
//            
//            // 调用错误处理回调
////            errorHandler?(CRRecordingError.streamError(error))
//            
//            continuation?.finish(throwing: error)
//        }
//    }
    
    func stopCapture() async throws {
        if hasFinalized { return }
        hasFinalized = true
        do {
            try await stream?.stopCapture()
            continuation?.finish()
        } catch {
            continuation?.finish(throwing: error)
        }
        // 标记流已无效，避免后续重复 stop 调用
        stream = nil
        powerMeter.processSilence()
        try await Task.sleep(for: .seconds(1))
        try await captureFileOutput?.stopSession()
        RecorderDiagnostics.shared.onStopCapture()
    }
  
    /// - Tag: UpdateStreamConfiguration
    func update(configuration: SCStreamConfiguration, filter: SCContentFilter) async {
        do {
            try await stream?.updateConfiguration(configuration)
            try await stream?.updateContentFilter(filter)
        } catch {
            logger.error("Failed to update the stream session: \(String(describing: error))")
        }
    }
    
    // MARK: - 私有辅助方法
    
    /// 检测是否为内存相关错误
    private func checkMemoryError(_ error: NSError) -> Bool {
        // 检查错误描述中的内存相关关键词
        let errorDescription = error.localizedDescription.lowercased()
        let memoryKeywords = [
            "memory", "insufficient", "low memory", "out of memory",
            "内存不足", "内存", "insufficient memory"
        ]
        
        for keyword in memoryKeywords {
            if errorDescription.contains(keyword) {
                return true
            }
        }
        
        // 检查具体的错误代码
        switch error.code {
        case -6728, // Memory allocation failed
             -12903, // Insufficient memory
             -34018: // Memory pressure
            return true
        default:
            break
        }
        
        // 检查系统内存压力
        return ProcessInfo.processInfo.thermalState == .critical ||
               isSystemUnderMemoryPressure()
    }
    
    /// 检查系统是否处于内存压力状态
    private func isSystemUnderMemoryPressure() -> Bool {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            let totalMemory = ProcessInfo.processInfo.physicalMemory
            let pageSize = UInt64(sysconf(_SC_PAGESIZE))  // 使用 sysconf 获取页面大小，线程安全
            let freeMemory = UInt64(info.free_count) * pageSize
            let memoryUsageRatio = Double(totalMemory - freeMemory) / Double(totalMemory)
            
            // 如果内存使用率超过 90%，认为是内存压力状态
            return memoryUsageRatio > 0.9
        }
        
        return false
    }
    
    /// 安全停止文件输出
    private func safeStopCaptureFileOutput() async {
        guard let fileOutput = captureFileOutput else { return }
        
        do {
            print("🛡️ 正在安全关闭录制文件写入...")
            try await fileOutput.stopSession()
            print("✅ 录制文件已安全关闭")
        } catch {
            print("⚠️ 关闭录制文件时出错: \(error.localizedDescription)")
            // 即使出错也要尝试清理资源
        }
    }
}

/// A class that handles output from an SCStream, and handles stream errors.
@preconcurrency
private class CaptureEngineStreamOutput: NSObject, SCStreamOutput, @preconcurrency SCStreamDelegate {
    
    var pcmBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    var capturedFrameHandler: ((CapturedFrame) -> Void)?
    
    // Store the  startCapture continuation, so you can cancel it if an error occurs.
    private var continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation?
    
    var captureFileOutput: CaptureFileOutput?
    
    // 第一帧标记
    private var hasReceivedFirstFrame = false
    var firstFrameTimestampHandler: ((CFAbsoluteTime) -> Void)?
    
    private var hasReceivedFirstAudio = false
    
    // MARK: - 预览回调
    /// 视频帧预览回调
    var videoFramePreviewHandler: ((CapturedFrame) -> Void)?
    /// 音频电平预览回调  
    var audioLevelPreviewHandler: (() -> Void)?
    
    var onError: (Error) -> Void = {_ in}
    
    init(continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation?, captureFileOutput: CaptureFileOutput?, firstFrameTimestampHandler: ((CFAbsoluteTime) -> Void)? = nil) {
        self.continuation = continuation
        self.captureFileOutput = captureFileOutput
        self.firstFrameTimestampHandler = firstFrameTimestampHandler
    }
    
    /// - Tag: DidOutputSampleBuffer
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        
        // Return early if the sample buffer is invalid.
        guard sampleBuffer.isValid else { return }
        
        // Determine which type of data the sample buffer contains.
        switch outputType {
        case .screen:
            // Create a CapturedFrame structure for a video sample buffer.
            guard let frame = createFrame(for: sampleBuffer) else { return }
            RecorderDiagnostics.shared.onCaptureVideoFrame()
            
            // 捕获第一帧的时间戳
            if !hasReceivedFirstFrame {
                hasReceivedFirstFrame = true
                let firstFrameTimestamp = CFAbsoluteTimeGetCurrent()
                firstFrameTimestampHandler?(sampleBuffer.presentationTimeStamp.seconds)
                print("[record-time] 开始时间: 系统画面 \(CFAbsoluteTimeGetCurrent()) time \(sampleBuffer.presentationTimeStamp.seconds)")
            }
            
            capturedFrameHandler?(frame)
            captureFileOutput?.saveFrame(for: sampleBuffer)

            // 调用视频帧预览回调
            videoFramePreviewHandler?(frame)
            RecorderDiagnostics.shared.onVideoSample(size: frame.size)
            
        case .audio:
            // Process audio as an AVAudioPCMBuffer for level calculation.
            if !hasReceivedFirstFrame {
                print("[record-time] 开始时间: 系统声音 \(CFAbsoluteTimeGetCurrent())(date\(Date().timeIntervalSince1970) time\(sampleBuffer.presentationTimeStamp.seconds)")
            }
            RecorderDiagnostics.shared.onCaptureAudioSample()
            handleAudio(for: sampleBuffer)
            captureFileOutput?.saveAudio(for: sampleBuffer)
            
            // 调用音频电平预览回调
            audioLevelPreviewHandler?()
            
        @unknown default:
            fatalError("Encountered unknown stream output type: \(outputType)")
        }
    }
    
    /// Create a `CapturedFrame` for the video sample buffer.
    private func createFrame(for sampleBuffer: CMSampleBuffer) -> CapturedFrame? {
        
        // Retrieve the array of metadata attachments from the sample buffer.
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                             createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first else { return nil }
        
        // Validate the status of the frame. If it isn't `.complete`, return nil.
        guard let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue),
              status == .complete else { return nil }
        
        // Get the pixel buffer that contains the image data.
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return nil }
        
        // Get the backing IOSurface.
        guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return nil }
        let surface = unsafeBitCast(surfaceRef, to: IOSurface.self)
        
        // Retrieve the content rectangle, scale, and scale factor.
        guard let contentRectDict = attachments[.contentRect],
              let contentRect = CGRect(dictionaryRepresentation: contentRectDict as! CFDictionary),
              let contentScale = attachments[.contentScale] as? CGFloat,
              let scaleFactor = attachments[.scaleFactor] as? CGFloat else { return nil }
        
        // Create a new frame with the relevant data.
        let frame = CapturedFrame(surface: surface,
                                  contentRect: contentRect,
                                  contentScale: contentScale,
                                  scaleFactor: scaleFactor)
        return frame
    }
    
    private func handleAudio(for buffer: CMSampleBuffer) -> Void? {
        // Create an AVAudioPCMBuffer from an audio sample buffer.
        try? buffer.withAudioBufferList { audioBufferList, blockBuffer in
            guard let description = buffer.formatDescription?.audioStreamBasicDescription,
                  let format = AVAudioFormat(standardFormatWithSampleRate: description.mSampleRate, channels: description.mChannelsPerFrame),
                  let samples = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
            else { return }
            pcmBufferHandler?(samples)
        }
    }
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("💢 [STREAM_OUTPUT_ERROR] CaptureEngineStreamOutput 检测到流错误: %@", error.localizedDescription)
        print("❌ CaptureEngineStreamOutput - 流出错: \(error.localizedDescription)")
        // 获取更详细的错误信息
        let nsError = error as NSError
        NSLog("错误域: %@", nsError.domain)
        NSLog("错误代码: %ld", nsError.code)
        NSLog("用户信息: %@", nsError.userInfo)
        NSLog("底层错误: %@", nsError.underlyingErrors.map({ $0.localizedDescription }) ?? "无")
        print("错误对象", error)

        Task {
            await self.onError(error)
        }
        continuation?.finish(throwing: error)
        RecorderDiagnostics.shared.recordError(error)
    }

    func streamDidBecomeActive(_ stream: SCStream) {
        RecorderDiagnostics.shared.onStreamDidBecomeActive()
    }

    func streamDidBecomeInactive(_ stream: SCStream) {
        RecorderDiagnostics.shared.onStreamDidBecomeInactive()
    }
    
    /// 安全停止文件输出
    private func safeStopCaptureFileOutput() async {
        guard let fileOutput = captureFileOutput else { return }
        
        do {
            print("🛡️ 正在安全关闭录制文件写入...")
            try await fileOutput.stopSession()
            print("✅ 录制文件已安全关闭")
        } catch {
            print("⚠️ 关闭录制文件时出错: \(error.localizedDescription)")
            // 即使出错也要尝试清理资源
        }
    }
}
