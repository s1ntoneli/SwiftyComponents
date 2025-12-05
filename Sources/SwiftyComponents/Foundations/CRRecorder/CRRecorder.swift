//
//  File.swift
//  CoreRecorder
//
//  Created by lixindong on 2025/6/6.
//

import Foundation
import AVFoundation
import Combine

public class CRRecorder: @unchecked Sendable {
    
    var outputDirectory: URL
    var schemes: [SchemeItem]
    var captureSessions: [String: AVCaptureSession] = [:]
    var captureDelegates: [String: CaptureRecordingDelegate] = [:]
    /// 当前屏幕录制后端（ScreenCaptureKit 或 AVFoundation），单次录制仅使用一个实例。
    var screenCaptureSessions: ScreenRecorderBackend?
    
    var appleDeviceCaptures: [String: CRAppleDeviceRecording] = [:]
    var cameraCaptures: [String: CRCameraRecording] = [:]
    var microphoneCaptures: [String: CRMicrophoneRecording] = [:]
    // 可切换的麦克风录制后端（默认沿用旧方案）
//    public var microphoneBackend: CRMicrophoneRecording.Backend = .fileOutput
    
    nonisolated(unsafe)
    public var onInterupt: (Error) -> Void = {_ in}
    
    var resultSubject: PassthroughSubject<Result, Error> = .init()
    public var audioLevelSubject: PassthroughSubject<Float, Never> = .init()
    
    // Idempotent stopping guards（标记位方案）
    private var isStoppingAll: Bool = false
    private var stopAllCachedResult: Result? = nil

    /// 屏幕录制后端类型。
    public enum ScreenBackend: String, Sendable {
        case screenCaptureKit
        case avFoundation
    }

    public init(_ schemes: [SchemeItem], outputDirectory: URL) {
        self.schemes = schemes
        self.outputDirectory = outputDirectory
        print("[CRRecorder] 初始化录制器，输出目录: \(outputDirectory.path), 录制方案数量: \(schemes.count)")
    }
    
    public func prepare(_ schemes: [SchemeItem]) async throws {
        print("[CRRecorder] 开始准备录制方案，共 \(schemes.count) 个")
        self.schemes = schemes
        
        for scheme in schemes {
            print("[CRRecorder] 准备录制方案: \(scheme.id)")
            switch scheme {
            case .display(
                let displayId,
                let area,
                let fps,
                let showsCursor,
                let hdr,
                let useHEVC,
                let captureSystemAudio,
                let queueDepth,
                let targetBitRate,
                let filename,
                let backend,
                let excludedWindowTitles
            ):
                print("[CRRecorder] 准备屏幕录制 - 显示器ID: \(displayId), 文件名: \(filename), HDR: \(hdr), 系统音频: \(captureSystemAudio)")
                screenCaptureSessions = makeScreenBackend(
                    backend: backend,
                    filename: filename,
                    fps: fps,
                    queueDepth: queueDepth,
                    targetBitRate: targetBitRate,
                    showsCursor: showsCursor,
                    useHEVC: useHEVC
                )
            case .window(
                displayId: let displayId,
                windowID: let windowID,
                let fps,
                let showsCursor,
                hdr: let hdr,
                captureSystemAudio: let captureSystemAudio,
                filename: let filename,
                let backend,
                let queueDepth,
                let targetBitRate
            ):
                print("[CRRecorder] 准备窗口录制 - 显示器ID: \(displayId), 窗口ID: \(windowID), 文件名: \(filename)")
                screenCaptureSessions = makeScreenBackend(
                    backend: backend,
                    filename: filename,
                    fps: fps,
                    queueDepth: queueDepth,
                    targetBitRate: targetBitRate,
                    showsCursor: showsCursor,
                    useHEVC: false
                )
            case .camera(cameraID: let cameraID, filename: let filename, let cameraOptions):
                print("[CRRecorder] 准备摄像头录制 - 摄像头ID: \(cameraID), 文件名: \(filename)")
//                prepareCameraSession(cameraID: cameraID, filename: filename)
                let cameraRecording = CRCameraRecording()
                cameraRecording.options = cameraOptions
                cameraRecording.onError = { err in
                    NSLog("📹 [CR_RECORDER_CAMERA_ERROR] CRRecorder 接收到摄像头错误: %@", err.localizedDescription)
                    self.onInterupt(err)
                }
                cameraRecording.onComplete = { [unowned self] url in}
                try await cameraRecording.prepare(cameraId: cameraID)
                
                cameraCaptures[cameraID] = cameraRecording
                break
            case .microphone(microphoneID: let microphoneID, filename: let filename, let microphoneOptions):
                print("[CRRecorder] 准备麦克风录制 - 麦克风ID: \(microphoneID), 文件名: \(filename)")
//                prepareMicrophoneSession(microphoneID: microphoneID, filename: filename)
                let microphoneRecording = CRMicrophoneRecording()
                microphoneRecording.audioLevelHandler = { [weak self] level, peak in
                    self?.audioLevelSubject.send(level)
                }
                microphoneRecording.onError = { [weak self] err in
                    NSLog("🎤 [CR_RECORDER_MIC_ERROR] CRRecorder 接收到麦克风错误: %@", err.localizedDescription)
                    self?.onInterupt(err)
                }
                // Apply per-run mic options
                microphoneRecording.processingOptions = microphoneOptions
                try await microphoneRecording.prepare(microphoneID: microphoneID)
                microphoneCaptures[microphoneID] = microphoneRecording
                break
            case .appleDevice(appleDeviceID: let appleDeviceID, filename: let filename, let cameraOptions):
                print("[CRRecorder] 准备苹果设备录制 - 设备ID: \(appleDeviceID), 文件名: \(filename)")
                let appleDeviceRecording = CRAppleDeviceRecording()
                appleDeviceRecording.options = cameraOptions
                appleDeviceRecording.onError = { err in
                    NSLog("📱 [CR_RECORDER_APPLE_DEVICE_ERROR] CRRecorder 接收到 Apple 设备错误: %@", err.localizedDescription)
                    self.onInterupt(err)
                }
                try await appleDeviceRecording.prepare(deviceId: appleDeviceID)
                appleDeviceCaptures[appleDeviceID] = appleDeviceRecording
                break
            }
        }
        print("[CRRecorder] 录制方案准备完成")
    }
    
    public func startRecording() async throws {
        // 确保输出目录存在
        if !FileManager.default.fileExists(atPath: outputDirectory.path) {
            print("[CRRecorder] 创建输出目录: \(outputDirectory.path)")
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        // 按设备类型分组
        let auxiliarySchemes = schemes.filter { scheme in
            switch scheme {
            case .camera, .microphone:
                return true // 辅助设备
            default:
                return false
            }
        }
        
        let primarySchemes = schemes.filter { scheme in
            switch scheme {
            case .display, .window, .appleDevice:
                return true // 主设备（屏幕/窗口录制）
            default:
                return false
            }
        }
        
        try await withThrowingTaskGroup { group  in
            for scheme in auxiliarySchemes {
                group.addTask {
                    try await self.startRecord(scheme: scheme)
                }
            }
            try await group.waitForAll()
        }
        print("[CRRecorder] 所有 auxiliary 录制任务全部开始")
        try await withThrowingTaskGroup { group in
            for scheme in primarySchemes {
                group.addTask {
                    try await self.startRecord(scheme: scheme)
                }
            }
            try await group.waitForAll()
        }
        
        print("[CRRecorder] 所有录制任务全部开始")
        packLastResult()
    }
    
    // 整理 result
    public func packLastResult() -> Result? {
        var fileAssets: [BundleInfo.FileAsset] = []
        for scheme in schemes {
            switch scheme {
            case .display:
                let assets = screenCaptureSessions?.packLastResult() ?? []
                fileAssets.append(contentsOf: assets)
            case .window:
                let assets = screenCaptureSessions?.packLastResult() ?? []
                fileAssets.append(contentsOf: assets)
            case .camera(cameraID: let cameraID, filename: _, cameraOptions: _):
                if let cameraCapture = cameraCaptures[cameraID] {
                    let fileAsset = cameraCapture.packLastResult()
                    fileAssets.append(contentsOf: fileAsset)
                }
            case .microphone(microphoneID: let microphoneID, filename: _, microphoneOptions: _):
                if let avCapture = microphoneCaptures[microphoneID] {
                    let fileAsset = avCapture.packLastResult()
                    fileAssets.append(contentsOf: fileAsset)
                }
            case .appleDevice(appleDeviceID: let appleDeviceID, filename: _, cameraOptions: _):
                if let avCapture = appleDeviceCaptures[appleDeviceID] {
                    let fileAsset = avCapture.packLastResult()
                    fileAssets.append(contentsOf: fileAsset)
                }
            }
        }
        
        let result = Result(bundleURL: outputDirectory, bundleInfo: BundleInfo(duration: 0, files: fileAssets, version: 0))
        print("[CRRecorder] 所有录制任务完成，总文件数量: \(fileAssets.count)")
        
        resultSubject.send(result)
        
        return result
    }
    
    func startRecord(scheme: SchemeItem) async throws {
        switch scheme {
        case .display(
            displayID: let displayID,
            area: let area,
            fps: _,
            showsCursor: let showsCursor,
            hdr: let hdr,
            useHEVC: _,
            captureSystemAudio: let captureSystemAudio,
            queueDepth: _,
            targetBitRate: _,
            filename: _,
            backend: _,
            excludedWindowTitles: let excludedWindowTitles
        ):
            // 在 prepare 阶段已根据 backend 初始化好 screenCaptureSessions，这里直接启动。
            _ = try await screenCaptureSessions?.startScreenCapture(
                displayID: displayID,
                cropRect: area,
                hdr: hdr,
                showsCursor: showsCursor,
                includeAudio: captureSystemAudio,
                excludedWindowTitles: excludedWindowTitles
            )
        case .window(
            displayId: let displayId,
            windowID: let windowID,
            fps: let fps,
            showsCursor: let showsCursor,
            hdr: let hdr,
            captureSystemAudio: let captureSystemAudio,
            filename: _,
            backend: _,
            queueDepth: _,
            targetBitRate: _
        ):
            _ = try await screenCaptureSessions?.startWindowCapture(
                windowID: windowID,
                displayID: displayId,
                hdr: hdr,
                showsCursor: showsCursor,
                includeAudio: captureSystemAudio,
                frameRate: fps,
                h265: false
            )
        case .camera(cameraID: let cameraID, filename: let filename, cameraOptions: _):
            if let cameraCapture = cameraCaptures[cameraID] {
                let fileURL = outputDirectory.appendingPathComponent(filename, conformingTo: .movie).appendingPathExtension("mov")
                try await cameraCapture.start(fileURL: fileURL)
            }
        case .microphone(microphoneID: let microphoneID, filename: let filename, microphoneOptions: _):
            if let avCapture = microphoneCaptures[microphoneID] {
                let fileURL = outputDirectory.appendingPathComponent(filename, conformingTo: .mpeg4Audio)
                try await avCapture.start(fileURL: fileURL)
            }
        case .appleDevice(appleDeviceID: let appleDeviceID, filename: let filename, cameraOptions: _):
            if let avCapture = appleDeviceCaptures[appleDeviceID] {
                let fileURL = outputDirectory.appendingPathComponent(filename, conformingTo: .movie).appendingPathExtension("mov")
                try await avCapture.start(fileURL: fileURL)
            }
        }
    }
    
    func startRecordingWithResult() async throws -> Result {
        print("[CRRecorder] 开始录制")
        return try await withThrowingTaskGroup { group in
            // 确保输出目录存在
            if !FileManager.default.fileExists(atPath: outputDirectory.path) {
                print("[CRRecorder] 创建输出目录: \(outputDirectory.path)")
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            }
            
            for scheme in schemes {
                print("[CRRecorder] 启动录制任务: \(scheme.id)")
                group.addTask {
                    return try await self.startRecordWithResult(scheme)
                }
            }
            
            var fileAssets: [BundleInfo.FileAsset] = []
            for try await result in group {
                fileAssets.append(contentsOf: result)
                print("[CRRecorder] 录制任务完成，生成文件数量: \(result.count)")
            }
            
            let bundleInfo = BundleInfo(duration: 0, files: fileAssets, version: 0)
            let result = Result(bundleURL: outputDirectory, bundleInfo: bundleInfo)
            print("[CRRecorder] 所有录制任务完成，总文件数量: \(fileAssets.count)")
            return result
        }
    }
    
    func startRecordWithResult(_ scheme: SchemeItem) async throws -> [BundleInfo.FileAsset] {
        print("[CRRecorder] 开始执行录制方案: \(scheme.id)")
        
        switch scheme {
        case .display(
            displayID: let displayId,
            area: let area,
            fps: let fps,
            showsCursor: let showsCursor,
            hdr: let hdr,
            useHEVC: let useHEVC,
            captureSystemAudio: let captureSystemAudio,
            queueDepth: let queueDepth,
            targetBitRate: let targetBitRate,
            filename: let filename,
            backend: let backend,
            excludedWindowTitles: let excludedWindowTitles
        ):
            print("[CRRecorder] 开始屏幕录制")
            return try await screenCaptureSessions?.startScreenCapture(
                displayID: displayId,
                cropRect: area,
                hdr: hdr,
                showsCursor: showsCursor,
                includeAudio: captureSystemAudio,
                excludedWindowTitles: excludedWindowTitles
            ) ?? []
        case .window(
            displayId: let displayId,
            windowID: let windowID,
            let fps,
            let showsCursor,
            hdr: let hdr,
            captureSystemAudio: let captureSystemAudio,
            filename: let filename,
            let backend,
            let queueDepth,
            let targetBitRate
        ):
            print("[CRRecorder] 开始窗口录制")
            return try await screenCaptureSessions?.startWindowCapture(
                windowID: windowID,
                displayID: displayId,
                hdr: hdr,
                showsCursor: showsCursor,
                includeAudio: captureSystemAudio,
                frameRate: fps,
                h265: false
            ) ?? []
        case .camera(cameraID: let cameraID, filename: let filename, cameraOptions: _):
            print("[CRRecorder] 开始摄像头录制")
            let fileURL = outputDirectory.appendingPathComponent(filename, conformingTo: .mpeg4Movie)
            return try await recordCamera(cameraId: cameraID, fileURL: fileURL)
        case .microphone(microphoneID: let microphoneID, filename: let filename, microphoneOptions: _):
            print("[CRRecorder] 开始麦克风录制")
            let fileURL = outputDirectory.appendingPathComponent(filename, conformingTo: .mpeg4Audio)
            return try await recordMicrophone(microphoneID: microphoneID, fileURL: fileURL)
        case .appleDevice(appleDeviceID: let appleDeviceID, filename: let filename, cameraOptions: _):
            print("[CRRecorder] 开始苹果设备录制")
            break
        }
        return []
    }
    
    func stopRecording() async throws {
        // 旧的 stopRecording 仅用于简单调用场景，这里直接复用带 result 的实现。
        _ = try await stopRecordingWithResult()
    }
    
    
    public func stopRecordingWithResult() async throws -> Result {
        if let cached = stopAllCachedResult { return cached }
        if isStoppingAll {
            // 简单等待一小段时间，给首个 stop 完成落盘
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let cached = stopAllCachedResult { return cached }
        }
        isStoppingAll = true
        defer { isStoppingAll = false }
        let res = try await _stopAllWithResultImpl()
        stopAllCachedResult = res
        return res
    }

    // Real stop implementation. Do not call directly; use stopRecordingWithResult().
    private func _stopAllWithResultImpl() async throws -> Result {
        
        // 按设备类型分组
        let auxiliarySchemes = schemes.filter { scheme in
            switch scheme {
            case .camera, .microphone:
                return true // 辅助设备
            default:
                return false
            }
        }
        
        let primarySchemes = schemes.filter { scheme in
            switch scheme {
            case .display, .window, .appleDevice:
                return true // 主设备（屏幕/窗口录制）
            default:
                return false
            }
        }
        
        var fileAssets: [BundleInfo.FileAsset] = []

        try await withThrowingTaskGroup { group in
            for scheme in primarySchemes {
                group.addTask {
                    try await self.stopRecordingWithResult(scheme: scheme)
                }
            }
            
            for try await result in group {
                fileAssets.append(contentsOf: result)
                print("[CRRecorder] primarySchemes 录制任务完成，生成文件数量: \(result.count)")
            }
        }
        print("[CRRecorder] 所有 primary 录制任务全部结束")

        try await withThrowingTaskGroup { group in
            for scheme in auxiliarySchemes {
                group.addTask {
                    try await self.stopRecordingWithResult(scheme: scheme)
                }
            }
            for try await result in group {
                fileAssets.append(contentsOf: result)
                print("[CRRecorder] auxiliarySchemes 录制任务完成，生成文件数量: \(result.count)")
            }
        }
        
        let bundleInfo = BundleInfo(duration: 0, files: fileAssets, version: 0)
        let result = Result(bundleURL: outputDirectory, bundleInfo: bundleInfo)
        print("[CRRecorder] 所有录制任务完成，总文件数量: \(fileAssets.count)")
        writeBundleManifestIfPossible(bundleInfo)
        return result
    }
    
    func stopRecordingWithResult(scheme: SchemeItem) async throws -> [BundleInfo.FileAsset] {
        switch scheme {
        case .display:
            print("[CRRecorder] 停止屏幕录制")
            return try await screenCaptureSessions?.stop() ?? []
        case .window:
            print("[CRRecorder] 停止窗口录制")
            return try await screenCaptureSessions?.stop() ?? []
        case .camera(cameraID: let cameraID, filename: _, cameraOptions: _):
            print("[CRRecorder] 停止摄像头录制")
            if let avCapture = cameraCaptures[cameraID] {
                return try await avCapture.stop()
            } else {
                return []
            }
        case .microphone(microphoneID: let microphoneID, filename: _, microphoneOptions: _):
            print("[CRRecorder] 停止麦克风录制")
            if let avCapture = microphoneCaptures[microphoneID] {
                return try await avCapture.stop()
            } else {
                return []
            }
        case .appleDevice(appleDeviceID: let appleDeviceID, filename: _, cameraOptions: _):
            print("[CRRecorder] 停止苹果设备录制")
            if let avCapture = appleDeviceCaptures[appleDeviceID] {
                return try await avCapture.stop()
            } else {
                return []
            }
        }
    }
    
        func clear() {
        captureSessions.removeAll()
        cameraCaptures.removeAll()
        microphoneCaptures.removeAll()
        appleDeviceCaptures.removeAll()
        screenCaptureSessions = nil
    }
    
    public enum SchemeItem: Identifiable, Hashable, Equatable, Sendable {
        case display(
            displayID: CGDirectDisplayID,
            area: CGRect?,
            fps: Int,
            showsCursor: Bool,
            hdr: Bool,
            useHEVC: Bool,
            captureSystemAudio: Bool,
            queueDepth: Int?,
            targetBitRate: Int?,
            filename: String,
            backend: ScreenBackend,
            excludedWindowTitles: [String]
        )
        case window(
            displayId: CGDirectDisplayID,
            windowID: CGWindowID,
            fps: Int,
            showsCursor: Bool,
            hdr: Bool,
            captureSystemAudio: Bool,
            filename: String,
            backend: ScreenBackend,
            queueDepth: Int?,
            targetBitRate: Int?
        )
        case camera(
            cameraID: String,
            filename: String,
            cameraOptions: CameraRecordingOptions
        )
        case microphone(
            microphoneID: String,
            filename: String,
            microphoneOptions: MicrophoneProcessingOptions
        )
        case appleDevice(
            appleDeviceID: String,
            filename: String,
            cameraOptions: CameraRecordingOptions
        )
        
        public var id: String {
            switch self {
            case .display(let displayId, _, _, _, _, _, _, _, _, _, _, _):
                return "display_\(displayId)"
            case .window(let displayId, let windowID, _, _, _, _, _, _, _, _):
                return "window_\(displayId)_\(windowID)"
            case .camera(let cameraID, _, _):
                return "camera_\(cameraID)"
            case .microphone(let microphoneID, _, _):
                return "microphone_\(microphoneID)"
            case .appleDevice(let appleDeviceID, _, _):
                return "apple_device_\(appleDeviceID)"
            }
        }
    }
    
    public struct Result: Sendable {
        public var bundleURL: URL
        public var bundleInfo: BundleInfo
    }
    
    public struct BundleInfo: Codable, Sendable {
        public var duration: TimeInterval
        public var files: [FileAsset]
        public var version: Int
        
        public struct FileAsset: Codable, Sendable {
            public var filename: String
            public var recordingSize: Size?
            public var tyle: FileAssetType
            public var videoDimensions: Size?
            public var recordingStartTimestamp: CFAbsoluteTime?
            public var recordingEndTimestamp: CFAbsoluteTime?
            
            public init(
                filename: String,
                recordingSize: Size? = nil,
                tyle: FileAssetType,
                videoDimensions: Size? = nil,
                recordingStartTimestamp: CFAbsoluteTime? = nil,
                recordingEndTimestamp: CFAbsoluteTime? = nil
            ) {
                self.filename = filename
                self.recordingSize = recordingSize
                self.tyle = tyle
                self.videoDimensions = videoDimensions
                self.recordingStartTimestamp = recordingStartTimestamp
                self.recordingEndTimestamp = recordingEndTimestamp
            }
        }
        
        public struct Size: Codable, Sendable {
            public var width: Int
            public var height: Int
        }
        
        public enum FileAssetType: String, Equatable, Codable, Sendable {
            case appleDevice
            case audio
            case mouse
            case screen
            case systemAudio
            case topWindow
            case webcam
        }
    }
}

// MARK: - Helpers
extension CRRecorder {
    /// 根据 backend 创建对应的屏幕录制实现；集中做一次 switch，后续流程统一走 `ScreenRecorderBackend` 接口。
    fileprivate func makeScreenBackend(
        backend: ScreenBackend,
        filename: String,
        fps: Int,
        queueDepth: Int?,
        targetBitRate: Int?,
        showsCursor: Bool,
        useHEVC: Bool
    ) -> ScreenRecorderBackend {
        // 内部仍然使用 ScreenRecorderOptions 作为聚合体，但该类型不再暴露给外部 API。
        let options = ScreenRecorderOptions(
            fps: fps,
            queueDepth: queueDepth,
            targetBitRate: targetBitRate,
            showsCursor: showsCursor,
            useHEVC: useHEVC
        )
        let filePath = outputDirectory
            .appendingPathComponent(filename)
            .appendingPathExtension("mov")
            .path(percentEncoded: false)
        switch backend {
        case .screenCaptureKit:
            let recorder = ScreenCaptureRecorder(filePath: filePath, options: options)
            recorder.errorHandler = { [weak self] error in
                guard let self else { return }
                NSLog("🔥 [CR_RECORDER_ERROR] CRRecorder 接收到屏幕/窗口录制错误: %@", error.localizedDescription)
                self.onInterupt(error)
            }
            return recorder
        case .avFoundation:
            let backendRecorder = AVFoundationScreenRecorderBackend(outputDirectory: outputDirectory, baseFilename: filename, options: options)
            backendRecorder.errorHandler = { [weak self] error in
                guard let self else { return }
                let ns = error as NSError
                NSLog("🔥 [CR_RECORDER_AVSCREEN_ERROR] domain=%@ code=%ld msg=%@", ns.domain, ns.code, ns.localizedDescription)
                self.onInterupt(error)
            }
            return backendRecorder
        }
    }

    // MARK: - Persist manifest
    fileprivate func writeBundleManifestIfPossible(_ info: BundleInfo) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let data = try encoder.encode(info)
            if !FileManager.default.fileExists(atPath: outputDirectory.path) {
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            }
            let url = outputDirectory.appendingPathComponent("bundle.json")
            try data.write(to: url, options: .atomic)
            print("[CRRecorder] 已写入清单: \(url.path)")
        } catch {
            print("[CRRecorder] 写入清单失败: \(error.localizedDescription)")
        }
    }
}
