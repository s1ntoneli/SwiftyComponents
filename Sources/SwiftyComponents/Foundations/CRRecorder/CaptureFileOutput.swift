//
//  CaptureFileOutput.swift
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
import AVFoundation
import ScreenCaptureKit

protocol CaptureFileOutput {
    func saveAudio(for sampleBuffer: CMSampleBuffer)
    func saveFrame(for sampleBuffer: CMSampleBuffer)
    func startSession()
    func stopSession() async throws
}

class MultiCaptureFileOutput: CaptureFileOutput {
    var outputs: [SingleCaptureFileOutput] = []
    func saveAudio(for sampleBuffer: CMSampleBuffer) {
        outputs.forEach { $0.saveAudio(for: sampleBuffer) }
    }
    func saveFrame(for sampleBuffer: CMSampleBuffer) {
        outputs.forEach { $0.saveFrame(for: sampleBuffer) }
    }
    func startSession() {
        outputs.forEach { $0.startSession() }
    }
    func stopSession() async throws {
        for output in outputs {
            try await output.stopSession()
        }
    }
}

@preconcurrency
class SingleCaptureFileOutput: CaptureFileOutput {
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput?
    let videoAssetWriter: AVAssetWriter
    let audioAssetWriter: AVAssetWriter?
    
    let audioMode: AudioRecordingMode
    
    var sessionStarted = false
    var firstSampleTime: CMTime = .zero
    var lastSampleBuffer: CMSampleBuffer?
    
    // 固定片段时长：10s（运行中不再动态切换，避免状态错误）
    private static let initialFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
    
    /// 完成写入的回调，在所有 finishWriting 完成后调用
    var finishWritingCompletionHandler: (() -> Void)?
    
    var onError: (Error) -> Void = {_ in}

    // MARK: - Keepalive (duplicate last frame when idle)
    private let writerQueue = DispatchQueue(label: "com.gokoding.recorder.writer")
    private var keepaliveTimer: DispatchSourceTimer? = nil
    private var lastAppendUptime: TimeInterval = 0
    private let keepaliveIntervalSeconds: TimeInterval = 1.0 // emit a dup frame if idle > 1s
    private let keepaliveUseSyntheticTest: Bool = true // 测试：心跳帧使用随机纯色，确保非重复
    private let syntheticAllVideoFramesForTest: Bool = false // 测试：所有正常视频帧也替换为随机纯色
    private var fragmentIntervalSeconds: Double = 10.0
    private var pendingFragmentIntervalSeconds: Double? = nil

    // MARK: - Pull mode (requestMediaDataWhenReady)
    private let usePullMode: Bool = true // 可按需改为开关
    private var pendingVideo: [CMSampleBuffer] = []
    private var pendingAudio: [CMSampleBuffer] = []
    private let maxPendingVideo = 90  // ~1.5s at 60fps
    private let maxPendingAudio = 200

    // 暴露给 Diagnostics 的访问
    static nonisolated(unsafe) weak var current: SingleCaptureFileOutput?
    
    convenience init(
        baseFileName: String,
        videoOutputSettings: [String: Any],
        audioOutputSettings: [String: Any]?,
        audioMode: AudioRecordingMode,
    ) throws {
        // 生成文件 URL
        var videoURL = URL(fileURLWithPath: baseFileName)
        if videoURL.pathExtension.isEmpty {
            // 与 fileType 一致，默认 mov 容器
            videoURL.appendPathExtension("mov")
        }
        var audioURL = URL(fileURLWithPath: baseFileName)
        audioURL.deletePathExtension()
        audioURL = audioURL.appendingPathExtension("m4a") // 独立音频始终用 m4a
        
        // 创建视频 AssetWriter
        let videoAssetWriter = try AVAssetWriter(url: videoURL, fileType: .mov)
        // 在 startWriting 之前设置 fragment interval（运行时禁止修改）
        let initialFrag = CMTime(seconds: RecorderDiagnostics.shared.fragmentIntervalSeconds, preferredTimescale: 600)
        videoAssetWriter.movieFragmentInterval = initialFrag
        // Publish file URL for diagnostics
        RecorderDiagnostics.shared.setOutputFileURL(videoURL)
        
        // 创建音频 AssetWriter （如果需要）
        var audioAssetWriter: AVAssetWriter? = nil
        if audioMode == .separate, let audioSettings = audioOutputSettings {
            audioAssetWriter = try AVAssetWriter(url: audioURL, fileType: .m4a)
            audioAssetWriter?.movieFragmentInterval = initialFrag
        } else {
            audioAssetWriter = nil
        }
        
        try self.init(
            videoAssetWriter: videoAssetWriter, 
            audioAssetWriter: audioAssetWriter, 
            videoOutputSettings: videoOutputSettings, 
            audioOutputSettings: audioOutputSettings, 
            audioMode: audioMode,
        )
    }
    
    init(
        videoAssetWriter: AVAssetWriter,
        audioAssetWriter: AVAssetWriter?,
        videoOutputSettings: [String: Any],
        audioOutputSettings: [String: Any]?,
        audioMode: AudioRecordingMode,
    ) throws {
        self.audioMode = audioMode
    
        self.videoAssetWriter = videoAssetWriter
        self.audioAssetWriter = audioAssetWriter
        
        // 创建视频输入
        self.videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings)
        videoInput.expectsMediaDataInRealTime = true
        
        // 创建音频输入
        if let audioSettings = audioOutputSettings, audioMode != .none {
            if audioMode == .merged {
                // 音频合并到视频文件中
                self.audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioInput?.expectsMediaDataInRealTime = true
                audioInput?.metadata = createMetadataItems(title: "System Audio", artist: "", album: "")
            } else if audioMode == .separate, let audioWriter = audioAssetWriter {
                // 音频单独文件
                self.audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioInput?.expectsMediaDataInRealTime = true
                audioInput?.metadata = createMetadataItems(title: "System Audio", artist: "", album: "")
            } else {
                self.audioInput = nil
            }
        } else {
            self.audioInput = nil
        }
        
        // 添加输入到对应的 AssetWriter
        guard videoAssetWriter.canAdd(videoInput) else {
            throw CRRecordingError.recordingFailed("Can't add video input to asset writer")
        }
        videoAssetWriter.add(videoInput)
        
        if let audioInput = audioInput {
            if audioMode == .merged {
                // 音频合并到视频文件
                guard videoAssetWriter.canAdd(audioInput) else {
                    throw CRRecordingError.recordingFailed("Can't add audio input to video asset writer")
                }
                videoAssetWriter.add(audioInput)
            } else if audioMode == .separate, let audioWriter = audioAssetWriter {
                // 音频单独文件
                guard audioWriter.canAdd(audioInput) else {
                    throw CRRecordingError.recordingFailed("Can't add audio input to audio asset writer")
                }
                audioWriter.add(audioInput)
            }
        }
        
        // 开始写入
        guard videoAssetWriter.startWriting() else {
            if let error = videoAssetWriter.error {
                throw error
            }
            throw CRRecordingError.recordingFailed("Couldn't start writing to video AVAssetWriter")
        }
        
        if let audioWriter = audioAssetWriter {
            guard audioWriter.startWriting() else {
                if let error = audioWriter.error {
                    throw error
                }
                throw CRRecordingError.recordingFailed("Couldn't start writing to audio AVAssetWriter")
            }
        }

        // 记录当前实例
        Self.current = self
        // 注意：运行期不允许修改 fragmentInterval（系统限制），动态调整将延迟到下次会话
    }
    
    func saveAudio(for sampleBuffer: CMSampleBuffer) {
        writerQueue.async {
            let isReady = (self.audioInput?.isReadyForMoreMediaData == true)
            RecorderDiagnostics.shared.beforeAppendAudio(ready: isReady, status: self.audioAssetWriter?.status ?? self.videoAssetWriter.status)
            if self.firstSampleTime == .zero { return }
            let lastSampleTime = sampleBuffer.presentationTimeStamp - self.firstSampleTime
            let timing = CMSampleTimingInfo(duration: sampleBuffer.duration, presentationTimeStamp: lastSampleTime, decodeTimeStamp: sampleBuffer.decodeTimeStamp)
            guard let retimed = try? CMSampleBuffer(copying: sampleBuffer, withNewTiming: [timing]) else {
                print("Couldn't copy CMSampleBuffer, dropping frame")
                return
            }
            if self.usePullMode {
                if self.pendingAudio.count >= self.maxPendingAudio { self.pendingAudio.removeFirst(self.pendingAudio.count - self.maxPendingAudio + 1) }
                self.pendingAudio.append(retimed)
                self.drainAudioQueue()
                RecorderDiagnostics.shared.updatePendingCounts(video: self.pendingVideo.count, videoCap: self.maxPendingVideo, audio: self.pendingAudio.count, audioCap: self.maxPendingAudio)
            } else if isReady {
                if let ok = self.audioInput?.append(retimed), ok { RecorderDiagnostics.shared.onAppendedAudio() }
            } else {
                RecorderDiagnostics.shared.onDroppedAudioNotReady()
                RecorderDiagnostics.shared.logFlow("drop audio: not ready")
            }
        }
    }
    
    func saveFrame(for sampleBuffer: CMSampleBuffer) {
        writerQueue.async {
            let ready = self.videoInput.isReadyForMoreMediaData
            let vstatus = self.videoAssetWriter.status
            RecorderDiagnostics.shared.beforeAppendVideo(ready: ready, status: vstatus)
            if self.videoAssetWriter.status == .failed {
                let underlyingError = self.videoAssetWriter.error
                print("AVAssetWriter failed with error: \(underlyingError?.localizedDescription ?? "Unknown error")")
                if let error = underlyingError {
                    print("Error domain: \(error._domain), code: \(error._code)")
                    print("Full error: \(error)")
                }
                self.onError(CRRecordingError.videoWriterFailedWithDetail(underlyingError))
                RecorderDiagnostics.shared.onWriterVideoFailed()
                if let err = underlyingError { RecorderDiagnostics.shared.recordError(err) }
            } else {
                // Retiming
                if self.firstSampleTime == .zero {
                    self.firstSampleTime = sampleBuffer.presentationTimeStamp
                }
                let lastSampleTime = sampleBuffer.presentationTimeStamp - self.firstSampleTime
                self.lastSampleBuffer = sampleBuffer
                let timing = CMSampleTimingInfo(duration: sampleBuffer.duration, presentationTimeStamp: lastSampleTime, decodeTimeStamp: sampleBuffer.decodeTimeStamp)
                guard let retimed = try? CMSampleBuffer(copying: sampleBuffer, withNewTiming: [timing]) else {
                    print("Couldn't copy CMSampleBuffer, dropping frame")
                    return
                }

                // 若启用测试模式，则生成随机纯色帧替换正常帧
                let toStore: CMSampleBuffer
                if self.syntheticAllVideoFramesForTest, let synth = self.makeSyntheticSampleLike(sampleBuffer, color: self.randomBGRA(), timing: timing) {
                    toStore = synth
                } else {
                    toStore = retimed
                }

                if self.usePullMode {
                    // enqueue and drain via requestMediaDataWhenReady
                    if self.pendingVideo.count >= self.maxPendingVideo { self.pendingVideo.removeFirst(self.pendingVideo.count - self.maxPendingVideo + 1) }
                    self.pendingVideo.append(toStore)
                    // 更新最近样本引用，便于 keepalive 基于同尺寸生成
                    self.lastSampleBuffer = toStore
                    self.drainVideoQueue()
                } else if ready && vstatus == .writing {
                    if self.videoInput.append(toStore) {
                        RecorderDiagnostics.shared.onAppendedVideo()
                        self.lastAppendUptime = ProcessInfo.processInfo.systemUptime
                        self.lastSampleBuffer = toStore
                    }
                } else {
                    RecorderDiagnostics.shared.onDroppedVideoNotReady()
                    RecorderDiagnostics.shared.logFlow("drop video: ready=\(ready) writer=\(vstatus.rawValue)")
                }
            }
        }
    }

    
    
    func startSession() {
        // Start the AVAssetWriter session at source time .zero, sample buffers will need to be re-timed
        videoAssetWriter.startSession(atSourceTime: .zero)
        if let audioWriter = audioAssetWriter {
            audioWriter.startSession(atSourceTime: .zero)
        }
        sessionStarted = true
        RecorderDiagnostics.shared.onWriterStarted()
        RecorderDiagnostics.shared.recordEvent("Writer session started")
        startKeepalive()
        if usePullMode {
//            startRequestCallbacks()
        }
    }
    
    func stopSession() async throws {
        // Repeat the last frame and add it at the current time
        // In case no changes happend on screen, and the last frame is from long ago
        // This ensures the recording is of the expected length
        stopKeepalive()
        if let originalBuffer = lastSampleBuffer, originalBuffer.formatDescription?.mediaType == .video, videoInput.isReadyForMoreMediaData {
            let additionalTime = CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 100) - firstSampleTime
            let timing = CMSampleTimingInfo(duration: originalBuffer.duration, presentationTimeStamp: additionalTime, decodeTimeStamp: originalBuffer.decodeTimeStamp)
            let additionalSampleBuffer = try CMSampleBuffer(copying: originalBuffer, withNewTiming: [timing])
            videoInput.append(additionalSampleBuffer)
            lastSampleBuffer = additionalSampleBuffer
        }
        
        videoInput.markAsFinished()
        
        // Stop the AVAssetWriter session at time of the repeated frame
        print("CaptureFileOutput ", videoAssetWriter.status.rawValue)
        if videoAssetWriter.status == .writing {
//            videoAssetWriter.endSession(atSourceTime: lastSampleBuffer?.presentationTimeStamp ?? .zero)
            print("CaptureFileOutput afterEndSession", videoAssetWriter.status.rawValue)
            if let audioWriter = audioAssetWriter {
                audioWriter.endSession(atSourceTime: lastSampleBuffer?.presentationTimeStamp ?? .zero)
            }
            
            // Finish writing
            if let audioInput = audioInput {
                audioInput.markAsFinished()
            }
            await videoAssetWriter.finishWriting()
            print("CaptureFileOutput afterFinishWriting", videoAssetWriter.status.rawValue)
            if let audioWriter = audioAssetWriter {
                await audioWriter.finishWriting()
            }
        }

        // 调用完成写入的回调
        finishWritingCompletionHandler?()
        RecorderDiagnostics.shared.onWriterStopped()
        RecorderDiagnostics.shared.recordEvent("Writer session finished with status=\(videoAssetWriter.status.rawValue)")
    }

    // MARK: - Keepalive helpers
    private func startKeepalive() {
        lastAppendUptime = ProcessInfo.processInfo.systemUptime
        let t = DispatchSource.makeTimerSource(queue: writerQueue)
        t.schedule(deadline: .now() + keepaliveIntervalSeconds, repeating: keepaliveIntervalSeconds)
        t.setEventHandler { [weak self] in self?.keepaliveTick() }
        keepaliveTimer = t
        t.resume()
    }

    private func stopKeepalive() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    private func keepaliveTick() {
        guard sessionStarted, videoAssetWriter.status == .writing else { return }
        guard let originalBuffer = lastSampleBuffer else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastAppendUptime < keepaliveIntervalSeconds { return }
        let ready = self.videoInput.isReadyForMoreMediaData
        let vstatus = self.videoAssetWriter.status
        RecorderDiagnostics.shared.beforeAppendVideo(ready: ready, status: vstatus)

        guard videoInput.isReadyForMoreMediaData else { return }
        let additionalTime = CMTime(seconds: now, preferredTimescale: 100) - firstSampleTime
        let timing = CMSampleTimingInfo(duration: originalBuffer.duration, presentationTimeStamp: additionalTime, decodeTimeStamp: originalBuffer.decodeTimeStamp)

        func enqueueOrAppend(_ sb: CMSampleBuffer) {
            if usePullMode {
                if pendingVideo.count >= maxPendingVideo { pendingVideo.removeFirst(pendingVideo.count - maxPendingVideo + 1) }
                pendingVideo.append(sb)
                drainVideoQueue()
                RecorderDiagnostics.shared.updatePendingCounts(video: pendingVideo.count, videoCap: maxPendingVideo, audio: pendingAudio.count, audioCap: maxPendingAudio)
                RecorderDiagnostics.shared.logFlow("keepalive video appended")
            } else if videoInput.append(sb) {
                lastSampleBuffer = sb
                lastAppendUptime = now
                RecorderDiagnostics.shared.onAppendedVideo()
                RecorderDiagnostics.shared.logFlow("keepalive video appended")
            }
        }

        if keepaliveUseSyntheticTest {
            if let synth = makeSyntheticSampleLike(originalBuffer, color: randomBGRA(), timing: timing) {
                enqueueOrAppend(synth)
            }
        } else if let dup = try? CMSampleBuffer(copying: originalBuffer, withNewTiming: [timing]) {
            enqueueOrAppend(dup)
        }
    }

    // 生成随机 BGRA 纯色样本（与参考缓冲区尺寸匹配）
    private func makeSyntheticSampleLike(_ ref: CMSampleBuffer, color: UInt32, timing: CMSampleTimingInfo) -> CMSampleBuffer? {
        guard let refImg = ref.imageBuffer else { return nil }
        let width = CVPixelBufferGetWidth(refImg)
        let height = CVPixelBufferGetHeight(refImg)
        var px: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &px) == kCVReturnSuccess, let pb = px else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let rowPixels = bpr / 4
            var line = [UInt32](repeating: color, count: rowPixels)
            for y in 0..<height {
                memcpy(base.advanced(by: y * bpr), &line, rowPixels * 4)
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        var fmt: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fmt) == noErr, let f = fmt else { return nil }
        var sb: CMSampleBuffer?
        var localTiming = timing
        let rc = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: f, sampleTiming: &localTiming, sampleBufferOut: &sb)
        guard rc == noErr, let out = sb else { return nil }
        return out
    }

    private func randomBGRA() -> UInt32 {
        let b = UInt32.random(in: 0...255)
        let g = UInt32.random(in: 0...255)
        let r = UInt32.random(in: 0...255)
        let a: UInt32 = 255
        return (a << 24) | (r << 16) | (g << 8) | b
    }

    // 动态设置 fragmentInterval（秒）
    func updateFragmentInterval(seconds: Double) {
        // 运行期（status=writing）不能调用 setMovieFragmentInterval，会抛异常
        let s = max(0.2, min(30.0, seconds))
        fragmentIntervalSeconds = s
        if videoAssetWriter.status == .writing || (audioAssetWriter?.status == .writing) {
            pendingFragmentIntervalSeconds = s
            RecorderDiagnostics.shared.recordEvent("Defer movieFragmentInterval=\(String(format: "%.2f", s))s until next session")
        } else {
            let t = CMTime(seconds: s, preferredTimescale: 600)
            videoAssetWriter.movieFragmentInterval = t
            audioAssetWriter?.movieFragmentInterval = t
            RecorderDiagnostics.shared.recordEvent("Applied movieFragmentInterval=\(String(format: "%.2f", s))s")
        }
    }
    static func setFragmentIntervalForCurrent(seconds: Double) {
        current?.updateFragmentInterval(seconds: seconds)
    }

    // MARK: - Pull mode helpers
    private func startRequestCallbacks() {
        // Video drain
        videoInput.requestMediaDataWhenReady(on: writerQueue) { [weak self] in
            self?.drainVideoQueue()
        }
        // Audio drain (if merged audio input exists)
        if let _ = audioInput {
            audioInput?.requestMediaDataWhenReady(on: writerQueue) { [weak self] in
                self?.drainAudioQueue()
            }
        }
    }

    private func drainVideoQueue() {
        guard sessionStarted else { return }
        RecorderDiagnostics.shared.updatePendingCounts(video: pendingVideo.count, videoCap: maxPendingVideo, audio: pendingAudio.count, audioCap: maxPendingAudio)
        while videoInput.isReadyForMoreMediaData, !pendingVideo.isEmpty {
            let sb = pendingVideo.removeFirst()
            let ok = videoInput.append(sb)
            if ok {
                lastAppendUptime = ProcessInfo.processInfo.systemUptime
                RecorderDiagnostics.shared.onAppendedVideo()
            } else {
                // append failed unexpectedly; break to avoid spin
                break
            }
        }
        RecorderDiagnostics.shared.updatePendingCounts(video: pendingVideo.count, videoCap: maxPendingVideo, audio: pendingAudio.count, audioCap: maxPendingAudio)
    }

    private func drainAudioQueue() {
        guard sessionStarted else { return }
        guard let audioInput = audioInput else { return }
        RecorderDiagnostics.shared.updatePendingCounts(video: pendingVideo.count, videoCap: maxPendingVideo, audio: pendingAudio.count, audioCap: maxPendingAudio)
        while audioInput.isReadyForMoreMediaData, !pendingAudio.isEmpty {
            let sb = pendingAudio.removeFirst()
            if audioInput.append(sb) {
                RecorderDiagnostics.shared.onAppendedAudio()
            } else {
                break
            }
        }
        RecorderDiagnostics.shared.updatePendingCounts(video: pendingVideo.count, videoCap: maxPendingVideo, audio: pendingAudio.count, audioCap: maxPendingAudio)
    }
}

internal func createMetadataItems(title: String, artist: String, album: String) -> [AVMutableMetadataItem] {
    var metadataItems: [AVMutableMetadataItem] = []
    
    // 创建标题元数据
    let titleItem = AVMutableMetadataItem()
    titleItem.identifier = .commonIdentifierTitle
    titleItem.value = title as NSString
    titleItem.extendedLanguageTag = "und" // undefined (通用)
    metadataItems.append(titleItem)
    
    // 创建艺术家元数据
    let artistItem = AVMutableMetadataItem()
    artistItem.identifier = .commonIdentifierArtist
    artistItem.value = artist as NSString
    artistItem.extendedLanguageTag = "und"
    metadataItems.append(artistItem)
    
    // 创建专辑元数据
    let albumItem = AVMutableMetadataItem()
    albumItem.identifier = .commonIdentifierAlbumName
    albumItem.value = album as NSString
    albumItem.extendedLanguageTag = "und"
    metadataItems.append(albumItem)
    
    return metadataItems
}
/// 录制错误枚举
public enum CRRecordingError: Error {
    case noSourcePrepared
    case invalidState
    case recordingFailed(String)
    case userAbort
    case videoWriterFailed
    case videoWriterFailedWithDetail(Error?)
    
    var localizedDescription: String {
        switch self {
        case .noSourcePrepared:
            return "No source prepared"
        case .invalidState:
            return "Invalid state"
        case .recordingFailed(let message):
            return message
        case .userAbort:
            return "User abort"
        case .videoWriterFailed:
            return "Video writer failed"
        case .videoWriterFailedWithDetail(let error):
            if let error = error {
                return "Video writer failed: \(error.localizedDescription)"
            } else {
                return "Video writer failed with unknown error"
            }
        }
    }
}
