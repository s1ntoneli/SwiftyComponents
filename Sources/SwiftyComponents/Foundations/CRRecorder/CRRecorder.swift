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
    var screenCaptureSessions: ScreenCaptureRecorder?
    
    var appleDeviceCaptures: [String: CRAppleDeviceRecording] = [:]
    var cameraCaptures: [String: CRCameraRecording] = [:]
    var microphoneCaptures: [String: CRMicrophoneRecording] = [:]
    // 可切换的麦克风录制后端（默认沿用旧方案）
//    public var microphoneBackend: CRMicrophoneRecording.Backend = .fileOutput
    
    nonisolated(unsafe)
    var onInterupt: (Error) -> Void = {_ in}
    
    var resultSubject: PassthroughSubject<Result, Error> = .init()
    var audioLevelSubject: PassthroughSubject<Float, Never> = .init()
    
    init(_ schemes: [SchemeItem], outputDirectory: URL) {
        self.schemes = schemes
        self.outputDirectory = outputDirectory
        print("[CRRecorder] 初始化录制器，输出目录: \(outputDirectory.path), 录制方案数量: \(schemes.count)")
    }
    
    func prepare(_ schemes: [SchemeItem]) async throws {
        print("[CRRecorder] 开始准备录制方案，共 \(schemes.count) 个")
        self.schemes = schemes
        
        for scheme in schemes {
            print("[CRRecorder] 准备录制方案: \(scheme.id)")
            switch scheme {
            case .display(let displayId, let area, let hdr, let captureSystemAudio, let filename):
                print("[CRRecorder] 准备屏幕录制 - 显示器ID: \(displayId), 文件名: \(filename), HDR: \(hdr), 系统音频: \(captureSystemAudio)")
                screenCaptureSessions = ScreenCaptureRecorder(filePath: outputDirectory.appendingPathComponent(filename).appendingPathExtension("mov").path(percentEncoded: false))
                screenCaptureSessions?.errorHandler = {
                    NSLog("🔥 [CR_RECORDER_ERROR] CRRecorder 接收到屏幕录制错误: %@", $0.localizedDescription)
                    self.onInterupt($0)
                }
            case .window(displayId: let displayId, windowID: let windowID, hdr: let hdr, captureSystemAudio: let captureSystemAudio, filename: let filename):
                print("[CRRecorder] 准备窗口录制 - 显示器ID: \(displayId), 窗口ID: \(windowID), 文件名: \(filename)")
                screenCaptureSessions = ScreenCaptureRecorder(filePath: outputDirectory.appendingPathComponent(filename).appendingPathExtension("mov").path(percentEncoded: false))
                screenCaptureSessions?.errorHandler = {
                    NSLog("🔥 [CR_RECORDER_ERROR] CRRecorder 接收到窗口录制错误: %@", $0.localizedDescription)
                    self.onInterupt($0)
                }
            case .camera(cameraID: let cameraID, filename: let filename):
                print("[CRRecorder] 准备摄像头录制 - 摄像头ID: \(cameraID), 文件名: \(filename)")
//                prepareCameraSession(cameraID: cameraID, filename: filename)
                let cameraRecording = CRCameraRecording()
                cameraRecording.onError = { err in
                    NSLog("📹 [CR_RECORDER_CAMERA_ERROR] CRRecorder 接收到摄像头错误: %@", err.localizedDescription)
                    self.onInterupt(err)
                }
                cameraRecording.onComplete = { [unowned self] url in}
                try await cameraRecording.prepare(cameraId: cameraID)
                
                cameraCaptures[cameraID] = cameraRecording
                break
            case .microphone(microphoneID: let microphoneID, filename: let filename):
                print("[CRRecorder] 准备麦克风录制 - 麦克风ID: \(microphoneID), 文件名: \(filename)")
//                prepareMicrophoneSession(microphoneID: microphoneID, filename: filename)
                let microphoneRecording = CRMicrophoneRecording()
                microphoneRecording.audioLevelHandler = { [weak self] level, peak in
                    self?.audioLevelSubject.send(level)
                }
                try await microphoneRecording.prepare(microphoneID: microphoneID)
                microphoneCaptures[microphoneID] = microphoneRecording
                break
            case .appleDevice(appleDeviceID: let appleDeviceID, filename: let filename):
                print("[CRRecorder] 准备苹果设备录制 - 设备ID: \(appleDeviceID), 文件名: \(filename)")
                let appleDeviceRecording = CRAppleDeviceRecording()
                try await appleDeviceRecording.prepare(deviceId: appleDeviceID)
                appleDeviceCaptures[appleDeviceID] = appleDeviceRecording
                break
            }
        }
        print("[CRRecorder] 录制方案准备完成")
    }
    
    func startRecording() async throws {
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
            case .display(displayID: let displayID, area: let area, hdr: let hdr, captureSystemAudio: let captureSystemAudio, filename: let filename):
                let assets = screenCaptureSessions?.packLastResult() ?? []
                fileAssets.append(contentsOf: assets)
            case .window(displayId: let displayId, windowID: let windowID, hdr: let hdr, captureSystemAudio: let captureSystemAudio, filename: let filename):
                let assets = screenCaptureSessions?.packLastResult() ?? []
                fileAssets.append(contentsOf: assets)
            case .camera(cameraID: let cameraID, filename: let filename):
                if let cameraCapture = cameraCaptures[cameraID] {
                    let fileAsset = cameraCapture.packLastResult()
                    fileAssets.append(contentsOf: fileAsset)
                }
            case .microphone(microphoneID: let microphoneID, filename: let filename):
                if let avCapture = microphoneCaptures[microphoneID] {
                    let fileAsset = avCapture.packLastResult()
                    fileAssets.append(contentsOf: fileAsset)
                }
            case .appleDevice(appleDeviceID: let appleDeviceID, filename: let filename):
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
        case .display(displayID: let displayID, area: let area, hdr: let hdr, captureSystemAudio: let captureSystemAudio, filename: let filename):
            try await screenCaptureSessions?.startScreenCapture(displayID: displayID, cropRect: area, hdr: hdr, showsCursor: false, includeAudio: captureSystemAudio)
        case .window(displayId: let displayId, windowID: let windowID, hdr: let hdr, captureSystemAudio: let captureSystemAudio, filename: let filename):
            try await screenCaptureSessions?.startWindowCapture(windowID: windowID, displayID: displayId, hdr: hdr, includeAudio: captureSystemAudio)
        case .camera(cameraID: let cameraID, filename: let filename):
            if let cameraCapture = cameraCaptures[cameraID] {
                let fileURL = outputDirectory.appendingPathComponent(filename, conformingTo: .mpeg4Movie)
                try await cameraCapture.start(fileURL: fileURL)
            }
        case .microphone(microphoneID: let microphoneID, filename: let filename):
            if let avCapture = microphoneCaptures[microphoneID] {
                let fileURL = outputDirectory.appendingPathComponent(filename, conformingTo: .mpeg4Audio)
                try await avCapture.start(fileURL: fileURL)
            }
        case .appleDevice(appleDeviceID: let appleDeviceID, filename: let filename):
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
        case .display(let displayId, let area, let hdr, let captureSystemAudio, let filename):
            print("[CRRecorder] 开始屏幕录制")
            return try await screenCaptureSessions?.startScreenCapture(displayID: displayId, cropRect: area, hdr: hdr, showsCursor: false, includeAudio: captureSystemAudio) ?? []
        case .window(displayId: let displayId, windowID: let windowID, hdr: let hdr, captureSystemAudio: let captureSystemAudio, filename: let filename):
            print("[CRRecorder] 开始窗口录制")
            return try await screenCaptureSessions?.startWindowCapture(windowID: windowID, displayID: displayId, hdr: hdr, includeAudio: captureSystemAudio) ?? []
        case .camera(cameraID: let cameraID, filename: let filename):
            print("[CRRecorder] 开始摄像头录制")
            let fileURL = outputDirectory.appendingPathComponent(filename, conformingTo: .mpeg4Movie)
            return try await recordCamera(cameraId: cameraID, fileURL: fileURL)
        case .microphone(microphoneID: let microphoneID, filename: let filename):
            print("[CRRecorder] 开始麦克风录制")
            let fileURL = outputDirectory.appendingPathComponent(filename, conformingTo: .mpeg4Audio)
            return try await recordMicrophone(microphoneID: microphoneID, fileURL: fileURL)
        case .appleDevice(appleDeviceID: let appleDeviceID, filename: let filename):
            print("[CRRecorder] 开始苹果设备录制")
            break
        }
        return []
    }
    
    func stopRecording() async throws {
        print("[CRRecorder] 开始停止录制")
        try await withThrowingTaskGroup { group in
            for scheme in schemes {
                group.addTask {
                    print("[CRRecorder] 停止录制方案: \(scheme.id)")
                    switch scheme {
                    case .display(let displayId, let area, let hdr, let captureSystemAudio, let filename):
                        print("[CRRecorder] 停止屏幕录制")
                        try await self.screenCaptureSessions?.stop()
                        break
                    case .window(displayId: let displayId, windowID: let windowID, hdr: let hdr, captureSystemAudio: let captureSystemAudio, filename: let filename):
                        print("[CRRecorder] 停止窗口录制")
                        try await self.screenCaptureSessions?.stop()
                        break
                    case .camera(cameraID: let cameraID, filename: let filename):
                        print("[CRRecorder] 停止摄像头录制")
                        //                    let fileURL = outputDirectory.appendingPathComponent(filename, conformingTo: .mpeg4Movie)
                        //                    try await recordCamera(cameraId: cameraID, fileURL: fileURL)
                        try await self.stopRecording(deviceID: cameraID)
                    case .microphone(microphoneID: let microphoneID, filename: let filename):
                        print("[CRRecorder] 停止麦克风录制")
                        //                    let fileURL = outputDirectory.appendingPathComponent(filename, conformingTo: .mpeg4Audio)
                        //                    try await recordMicrophone(microphoneId: microphoneID, fileURL: fileURL)
                        try await self.stopRecording(deviceID: microphoneID)
                    case .appleDevice(appleDeviceID: let appleDeviceID, filename: let filename):
                        print("[CRRecorder] 停止苹果设备录制")
                        break
                    }
                }
            }
            for try await result in group {}
        }
        print("[CRRecorder] 所有录制已停止")
    }
    
    
    public func stopRecordingWithResult() async throws -> Result {
        
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
        return result
    }
    
    func stopRecordingWithResult(scheme: SchemeItem) async throws -> [BundleInfo.FileAsset] {
        switch scheme {
        case .display(let displayId, let area, let hdr, let captureSystemAudio, let filename):
            print("[CRRecorder] 停止屏幕录制")
            return try await screenCaptureSessions?.stop() ?? []
        case .window(displayId: let displayId, windowID: let windowID, hdr: let hdr, captureSystemAudio: let captureSystemAudio, filename: let filename):
            print("[CRRecorder] 停止窗口录制")
            return try await screenCaptureSessions?.stop() ?? []
        case .camera(cameraID: let cameraID, filename: let filename):
            print("[CRRecorder] 停止摄像头录制")
            if let avCapture = cameraCaptures[cameraID] {
                return try await avCapture.stop()
            } else {
                return []
            }
        case .microphone(microphoneID: let microphoneID, filename: let filename):
            print("[CRRecorder] 停止麦克风录制")
            if let avCapture = microphoneCaptures[microphoneID] {
                return try await avCapture.stop()
            } else {
                return []
            }
        case .appleDevice(appleDeviceID: let appleDeviceID, filename: let filename):
            print("[CRRecorder] 停止苹果设备录制")
            if let avCapture = appleDeviceCaptures[appleDeviceID] {
                return try await avCapture.stop()
            } else {
                return []
            }
        }
        return []
    }
    
    func clear() {
        captureSessions.removeAll()
        cameraCaptures.removeAll()
        microphoneCaptures.removeAll()
        appleDeviceCaptures.removeAll()
        screenCaptureSessions = nil
    }
    
    public enum SchemeItem: Identifiable, Hashable, Equatable, Sendable {
        case display(displayID: CGDirectDisplayID, area: CGRect?, hdr: Bool, captureSystemAudio: Bool, filename: String)
        case window(displayId: CGDirectDisplayID, windowID: CGWindowID, hdr: Bool, captureSystemAudio: Bool, filename: String)
        case camera(cameraID: String, filename: String)
        case microphone(microphoneID: String, filename: String)
        case appleDevice(appleDeviceID: String, filename: String)
        
        public var id: String {
            switch self {
            case .display(let displayId, _, _, _, _):
                return "display_\(displayId)"
            case .window(let displayId, let windowID, _, _, _):
                return "window_\(displayId)_\(windowID)"
            case .camera(let cameraID, _):
                return "camera_\(cameraID)"
            case .microphone(let microphoneID, _):
                return "microphone_\(microphoneID)"
            case .appleDevice(let appleDeviceID, _):
                return "apple_device_\(appleDeviceID)"
            }
        }
    }
    
    public struct Result: Sendable {
        public var bundleURL: URL
        public var bundleInfo: BundleInfo
    }
    
    public struct BundleInfo: Sendable {
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
