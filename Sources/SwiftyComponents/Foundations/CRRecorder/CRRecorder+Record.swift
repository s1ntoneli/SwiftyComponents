//
//  CRRecorder+Record.swift
//  CoreRecorder
//
//  Created by lixindong on 2025/6/6.
//

import AVFoundation
import ReplayKit
//
//enum RecordingError: Error {
//    case deviceNotFound
//    case cannotAddInput
//    case cannotAddOutput
//    case sessionFailedToStart
//    case sessionNotRunning
//    case outputNotConfigured
//    case notPrepared
//    
//    var localizedDescription: String {
//        switch self {
//        case .deviceNotFound:
//            return "找不到指定的录制设备"
//        case .cannotAddInput:
//            return "无法添加输入设备到会话"
//        case .cannotAddOutput:
//            return "无法添加输出设备到会话"
//        case .sessionFailedToStart:
//            return "会话启动失败"
//        case .sessionNotRunning:
//            return "会话未运行"
//        case .outputNotConfigured:
//            return "输出设备未配置"
//        case .notPrepared:
//            return "录制未准备就绪，请先调用 prepare() 方法"
//        }
//    }
//}

class CRCameraRecording {
    var session: AVCaptureSession?
    var delegate: CaptureRecordingDelegate = CaptureRecordingDelegate()
    var startTime: CFAbsoluteTime = 0
    var endTime: CFAbsoluteTime = 0
    var startURL: URL? = nil
    var isPrepared: Bool = false
    // 对外回调（供 CRRecorder 注入）
    var onError: (Error) -> Void = { _ in }
    var onComplete: (URL) -> Void = { _ in }
    // 可配置参数（分辨率/编码器/码率范围）
    var options: CameraRecordingOptions = .init()

    // 手动切换后端：如需回退为文件输出，将下行替换为 FileOutputCamBackend()
    private let backend: CameraBackend = AssetWriterCamBackend()

    init() {
        print("📹 CRCameraRecording 初始化")
        // 将底层委托事件桥接给外部回调
        delegate.onError = { [unowned self] error in
            onError(error)
        }
        delegate.onComplete = { [unowned self] url in
            onComplete(url)
        }
    }

    func prepare(cameraId: String) async throws {
        print("🔧 摄像头录制准备中... - 设备ID: \(cameraId)")

        let device: AVCaptureDevice
        if cameraId == "default" {
            guard let d = AVCaptureDevice.default(for: .video) else { throw RecordingError.deviceNotFound }
            device = d
        } else if let specificDevice = AVCaptureDevice(uniqueID: cameraId) {
            device = specificDevice
        } else {
            guard let d = AVCaptureDevice.default(for: .video) else { throw RecordingError.deviceNotFound }
            device = d
        }

        let input = try AVCaptureDeviceInput(device: device)
        let session = AVCaptureSession()
        session.beginConfiguration()
        // 分辨率开关（默认为 720p，可置空维持设备原生分辨率）
        if let preset = options.preset, session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
        }
        guard session.canAddInput(input) else { throw RecordingError.cannotAddInput }
        session.addInput(input)
        // 不强制降帧，保持设备默认或用户设置的高帧率，体积控制交由编码器码率完成。
        session.commitConfiguration()

        // 传入编码与码率开关
        backend.apply(options: options)
        try backend.configure(session: session, device: device, delegate: delegate, queue: DispatchQueue(label: "com.recorderkit.camera.video", qos: .userInitiated))

        session.startRunning()
        guard session.isRunning else { throw RecordingError.sessionFailedToStart }
        self.session = session
        self.isPrepared = true
        print("✅ 摄像头录制准备完成，数据流已启动")
    }

    func start(fileURL: URL) async throws {
        print("🎬 开始摄像头录制: \(fileURL.lastPathComponent)")
        guard isPrepared else { throw RecordingError.notPrepared }
        guard session?.isRunning == true else { throw RecordingError.sessionNotRunning }
        self.startURL = fileURL
        backend.onFirstPTS = { [weak self] time in self?.startTime = time.seconds }
        try await backend.start(fileURL: fileURL)
    }

    func startWithPrepare(cameraId: String, fileURL: URL) async throws {
        try await prepare(cameraId: cameraId)
        try await start(fileURL: fileURL)
    }

    func stop() async throws -> [CRRecorder.BundleInfo.FileAsset] {
        print("🛑 停止摄像头录制")
        endTime = CFAbsoluteTimeGetCurrent()
        let url = try await backend.stop()
        if let s = session { AVCaptureSessionHelper.stopRecordingStep2Close(avSession: s) }
        if let url {
            return [CRRecorder.BundleInfo.FileAsset(filename: url.lastPathComponent, tyle: .webcam, recordingStartTimestamp: startTime, recordingEndTimestamp: endTime)]
        }
        return []
    }

    func packLastResult() -> [CRRecorder.BundleInfo.FileAsset] {
        if let fileURL = startURL {
            let end = CFAbsoluteTimeGetCurrent()
            let asset = CRRecorder.BundleInfo.FileAsset(filename: fileURL.lastPathComponent, tyle: .webcam, recordingStartTimestamp: startTime, recordingEndTimestamp: end)
            return [asset]
        }
        return []
    }
}

class CRAppleDeviceRecording {
    var session: AVCaptureSession?
    var delegate: CaptureRecordingDelegate = CaptureRecordingDelegate()
    var startTime: CFAbsoluteTime = 0
    var endTime: CFAbsoluteTime = 0
    var startURL: URL? = nil
    var isPrepared: Bool = false
    // 对外回调
    var onError: (Error) -> Void = { _ in }
    var onComplete: ([CRRecorder.BundleInfo.FileAsset]) -> Void = { _ in }

    // 复用相机后端（FileOutput 或 AssetWriter），默认 FileOutput
    private let backend: CameraBackend = AssetWriterCamBackend()
    var options: CameraRecordingOptions = .init()

    init() {
        NSLog("📹 CRAppleDeviceRecording 初始化")
        delegate.onError = { [unowned self] error in onError(error) }
        delegate.onComplete = { [unowned self] url in
            endTime = CFAbsoluteTimeGetCurrent()
            let asset = CRRecorder.BundleInfo.FileAsset(filename: url.lastPathComponent, tyle: .appleDevice, recordingStartTimestamp: startTime, recordingEndTimestamp: endTime)
            onComplete([asset])
        }
    }

    func prepare(deviceId: String) async throws {
        NSLog("🔧 AppleDevice录制准备中... - 设备ID: \(deviceId)")
        guard let device = AVCaptureDevice(uniqueID: deviceId) else { throw RecordingError.deviceNotFound }
        let input = try AVCaptureDeviceInput(device: device)
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input) else { throw RecordingError.cannotAddInput }
        session.addInput(input)
        // 试图为 Apple 设备添加对应的音频输入（名称匹配）
        // QuickTime 的做法是同时选择 iPhone 作为视频源和麦克风源
        session.commitConfiguration()

        backend.apply(options: options)
        try backend.configure(session: session, device: device, delegate: delegate, queue: DispatchQueue(label: "com.recorderkit.appledevice.video", qos: .userInitiated))

        session.startRunning()
        guard session.isRunning else { throw RecordingError.sessionFailedToStart }

        self.session = session
        self.isPrepared = true
        NSLog("✅ AppleDevice录制准备完成，数据流已启动")
    }

    func start(fileURL: URL) async throws {
        NSLog("🎬 开始AppleDevice录制: \(fileURL.lastPathComponent)")
        guard isPrepared else { throw RecordingError.notPrepared }
        guard session?.isRunning == true else { throw RecordingError.sessionNotRunning }
        self.startURL = fileURL
        backend.onFirstPTS = { [weak self] time in self?.startTime = time.seconds }
        try await backend.start(fileURL: fileURL)
    }

    func startWithPrepare(deviceId: String, fileURL: URL) async throws {
        try await prepare(deviceId: deviceId)
        try await start(fileURL: fileURL)
    }

    func stop() async throws -> [CRRecorder.BundleInfo.FileAsset] {
        NSLog("🛑 停止AppleDevice录制")
        endTime = CFAbsoluteTimeGetCurrent()
        let url = try await backend.stop()
        if let s = session { AVCaptureSessionHelper.stopRecordingStep2Close(avSession: s) }
        if let url {
            return [CRRecorder.BundleInfo.FileAsset(filename: url.lastPathComponent, tyle: .appleDevice, recordingStartTimestamp: startTime, recordingEndTimestamp: endTime)]
        }
        return []
    }

    func packLastResult() -> [CRRecorder.BundleInfo.FileAsset] {
        if let fileURL = startURL {
            let end = CFAbsoluteTimeGetCurrent()
            let asset = CRRecorder.BundleInfo.FileAsset(filename: fileURL.lastPathComponent, tyle: .appleDevice, recordingStartTimestamp: startTime, recordingEndTimestamp: end)
            return [asset]
        }
        return []
    }
}

class CRMicrophoneRecording {
    var session: AVCaptureSession?
    var delegate: CaptureRecordingDelegate = CaptureRecordingDelegate()
    var startTime: CFAbsoluteTime = 0
    var endTime: CFAbsoluteTime = 0
    var startURL: URL? = nil
    var isPrepared: Bool = false
    var audioLevelHandler: ((Float, Float) -> Void)?
    let queue = DispatchQueue(label: "com.recorderkit.microphone.audio", qos: .userInitiated)

    // 手动切换后端：如需回退为文件输出，将下行替换为 FileOutputMicBackend()
    private let backend: MicrophoneBackend = AssetWriterMicBackend()
    var processingOptions: MicrophoneProcessingOptions = .init()

    init() {
        print("🎤 CRMicrophoneRecording 初始化")
        delegate.audioLevelHandler = { [unowned self] level, peakLevel in
            audioLevelHandler?(level, peakLevel)
        }
    }

    func prepare(microphoneID: String) async throws {
        print("🔧 麦克风录制准备中... - 设备ID: \(microphoneID)")

        let device: AVCaptureDevice
        if microphoneID == "default" {
            guard let d = AVCaptureDevice.default(for: .audio) else { throw RecordingError.deviceNotFound }
            device = d
        } else if let specificDevice = AVCaptureDevice(uniqueID: microphoneID) {
            device = specificDevice
        } else {
            guard let d = AVCaptureDevice.default(for: .audio) else { throw RecordingError.deviceNotFound }
            device = d
        }

        let input = try AVCaptureDeviceInput(device: device)
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input) else { throw RecordingError.cannotAddInput }
        session.addInput(input)
        session.commitConfiguration()

        backend.processingOptions = processingOptions
        try backend.configure(session: session, device: device, delegate: delegate, queue: queue)

        session.startRunning()
        guard session.isRunning else { throw RecordingError.sessionFailedToStart }

        self.session = session
        self.isPrepared = true
        print("✅ 麦克风录制准备完成，数据流已启动")
    }

    func start(fileURL: URL) async throws {
        print("🎙️ 开始麦克风录制: \(fileURL.lastPathComponent)")
        guard isPrepared else { throw RecordingError.notPrepared }
        guard session?.isRunning == true else { throw RecordingError.sessionNotRunning }

        self.startURL = fileURL
        backend.processingOptions = processingOptions
        backend.onFirstPTS = { [weak self] time in self?.startTime = time.seconds }
        try await backend.start(fileURL: fileURL)
    }

    func startWithPrepare(microphoneID: String, fileURL: URL) async throws {
        try await prepare(microphoneID: microphoneID)
        try await start(fileURL: fileURL)
    }

    func stop() async throws -> [CRRecorder.BundleInfo.FileAsset] {
        print("🛑 停止麦克风录制")
        endTime = CFAbsoluteTimeGetCurrent()
        let url = try await backend.stop()
        if let s = session { AVCaptureSessionHelper.stopRecordingStep2Close(avSession: s) }
        if let url {
            return [CRRecorder.BundleInfo.FileAsset(filename: url.lastPathComponent, tyle: .audio, recordingStartTimestamp: startTime, recordingEndTimestamp: endTime)]
        }
        return []
    }

    func packLastResult() -> [CRRecorder.BundleInfo.FileAsset] {
        if let fileURL = startURL {
            let end = CFAbsoluteTimeGetCurrent()
            let asset = CRRecorder.BundleInfo.FileAsset(filename: fileURL.lastPathComponent, tyle: .audio, recordingStartTimestamp: startTime, recordingEndTimestamp: end)
            return [asset]
        }
        return []
    }
}

class AVCaptureSessionHelper {
    
    static func stopRecordingStep1Output(avSession: AVCaptureSession) {
        NSLog("🛑 开始停止设备的录制")
        
        // 首先停止所有录制输出
        let outputs = avSession.outputs
        for output in outputs {
            if let movieOutput = output as? AVCaptureMovieFileOutput, movieOutput.isRecording {
                NSLog("🎬 停止电影文件输出录制")
                movieOutput.stopRecording()
            } else if let audioOutput = output as? AVCaptureAudioFileOutput, audioOutput.isRecording {
                NSLog("🎵 停止音频文件输出录制")
                audioOutput.stopRecording()
            }
        }
    }
    static func stopRecordingStep2Close(avSession: AVCaptureSession) {
        let outputs = avSession.outputs

        // 然后停止会话
        if avSession.isRunning {
            avSession.stopRunning()
            NSLog("📴 会话已停止运行")
        }
        
        // 移除所有输出（先移除输出）
        for output in outputs {
            avSession.removeOutput(output)
            NSLog("🔌 已移除输出: \(type(of: output))")
        }
        
        // 移除所有输入（后移除输入）
        let inputs = avSession.inputs
        for input in inputs {
            avSession.removeInput(input)
            NSLog("🔌 已移除输入: \(type(of: input))")
            
            // 对于设备输入，确保设备被正确释放
            if let deviceInput = input as? AVCaptureDeviceInput {
                let device = deviceInput.device
                NSLog("🎤 释放设备: \(device.localizedName)")
            }
        }
        
        // 从会话字典中移除
        NSLog("✅ 设备的录制已完全停止")
    }
    static func stopRecording(avSession: AVCaptureSession) async throws {
        NSLog("🛑 开始停止设备 \(avSession) 的录制")
        
        // 首先停止所有录制输出
        let outputs = avSession.outputs
        for output in outputs {
            if let movieOutput = output as? AVCaptureMovieFileOutput, movieOutput.isRecording {
                NSLog("🎬 停止电影文件输出录制")
                movieOutput.stopRecording()
            } else if let audioOutput = output as? AVCaptureAudioFileOutput, audioOutput.isRecording {
                NSLog("🎵 停止音频文件输出录制")
                audioOutput.stopRecording()
            }
        }
        
        // 等待一小段时间让录制完成
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 秒
        
        // 然后停止会话
        if avSession.isRunning {
            avSession.stopRunning()
            NSLog("📴 会话已停止运行")
        }
        
        // 移除所有输出（先移除输出）
        for output in outputs {
            avSession.removeOutput(output)
            NSLog("🔌 已移除输出: \(type(of: output))")
        }
        
        // 移除所有输入（后移除输入）
        let inputs = avSession.inputs
        for input in inputs {
            avSession.removeInput(input)
            NSLog("🔌 已移除输入: \(type(of: input))")
            
            // 对于设备输入，确保设备被正确释放
            if let deviceInput = input as? AVCaptureDeviceInput {
                let device = deviceInput.device
                NSLog("🎤 释放设备: \(device.localizedName)")
            }
        }
        
        // 从会话字典中移除
        NSLog("✅ 设备 \(avSession) 的录制已完全停止")
    }
}

extension CRRecorder {
    func recordCamera(cameraId: String, fileURL: URL) async throws -> [CRRecorder.BundleInfo.FileAsset] {
        try await withCheckedThrowingContinuation { continuation in

            let output = AVCaptureMovieFileOutput()
            let input = try! AVCaptureDeviceInput(device: AVCaptureDevice(uniqueID: cameraId)!)
            let session = AVCaptureSession()
            session.beginConfiguration()
            if session.canAddInput(input) {
                session.addInput(input)
            }
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            session.commitConfiguration()
            
            session.startRunning()
            
            let delegate = CaptureRecordingDelegate()
            var startTime: CFAbsoluteTime = 0
            var endTime: CFAbsoluteTime = 0
            delegate.onStart = { [unowned self] in
                startTime = CFAbsoluteTimeGetCurrent()
            }
            delegate.onError = { [unowned self] error in
                endTime = CFAbsoluteTimeGetCurrent()
                // TODO: maybe has file
                continuation.resume(throwing: error)
                captureDelegates.removeValue(forKey: cameraId)
            }
            delegate.onComplete = { [unowned self] url in
                endTime = CFAbsoluteTimeGetCurrent()
                let duration = endTime - startTime
                let asset = CRRecorder.BundleInfo.FileAsset(filename: url.lastPathComponent, tyle: .webcam)
                continuation.resume(returning: [asset])
                captureDelegates.removeValue(forKey: cameraId)
            }
            
            captureSessions[cameraId] = session
            captureDelegates[cameraId] = delegate
            output.startRecording(to: fileURL, recordingDelegate: delegate)
        }
    }
    
    func recordMicrophone(microphoneID: String, fileURL: URL) async throws -> [CRRecorder.BundleInfo.FileAsset] {
        try await withCheckedThrowingContinuation { continuation in

            let output = AVCaptureAudioFileOutput()
            let device: AVCaptureDevice
            
            // 处理默认设备的情况
            if microphoneID == "default" {
                // 使用系统默认音频输入设备
                device = AVCaptureDevice.default(for: .audio)!
                print("🎙️ 使用默认音频设备: \(device.localizedName)")
            } else {
                // 使用指定的设备ID
                device = AVCaptureDevice(uniqueID: microphoneID)!
            }
            
            let input = try! AVCaptureDeviceInput(device: device)
            let session = AVCaptureSession()
            session.beginConfiguration()
            if session.canAddInput(input) {
                session.addInput(input)
            }
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            session.commitConfiguration()
            
            session.startRunning()
            
            let delegate = CaptureRecordingDelegate()
            var startTime: CFAbsoluteTime = 0
            var endTime: CFAbsoluteTime = 0
            delegate.onStart = { [unowned self] in
                startTime = CFAbsoluteTimeGetCurrent()
            }
            delegate.onError = { [unowned self] error in
                endTime = CFAbsoluteTimeGetCurrent()
                // TODO: maybe has file
                continuation.resume(throwing: error)
                captureDelegates.removeValue(forKey: microphoneID)
            }
            delegate.onComplete = { [unowned self] url in
                endTime = CFAbsoluteTimeGetCurrent()
                let duration = endTime - startTime
                let asset = CRRecorder.BundleInfo.FileAsset(filename: url.lastPathComponent, tyle: .audio)
                continuation.resume(returning: [asset])
                captureDelegates.removeValue(forKey: microphoneID)
            }
            
            captureSessions[microphoneID] = session
            captureDelegates[microphoneID] = delegate

            output.startRecording(to: fileURL, outputFileType: .m4a, recordingDelegate: delegate)
        }
    }
    
    func stopRecording(deviceID: String) async throws {
        guard let avSession = captureSessions[deviceID] else {
            print("⚠️ 未找到设备ID为 \(deviceID) 的会话")
            return 
        }
        
        print("🛑 开始停止设备 \(deviceID) 的录制")
        
        // 首先停止所有录制输出
        let outputs = avSession.outputs
        for output in outputs {
            if let movieOutput = output as? AVCaptureMovieFileOutput, movieOutput.isRecording {
                print("🎬 停止电影文件输出录制")
                movieOutput.stopRecording()
            } else if let audioOutput = output as? AVCaptureAudioFileOutput, audioOutput.isRecording {
                print("🎵 停止音频文件输出录制")
                audioOutput.stopRecording()
            }
        }
        
        // 等待一小段时间让录制完成
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 秒
        
        // 然后停止会话
        if avSession.isRunning {
            avSession.stopRunning()
            print("📴 会话已停止运行")
        }
        
        // 移除所有输出（先移除输出）
        for output in outputs {
            avSession.removeOutput(output)
            print("🔌 已移除输出: \(type(of: output))")
        }
        
        // 移除所有输入（后移除输入）
        let inputs = avSession.inputs
        for input in inputs {
            avSession.removeInput(input)
            print("🔌 已移除输入: \(type(of: input))")
            
            // 对于设备输入，确保设备被正确释放
            if let deviceInput = input as? AVCaptureDeviceInput {
                let device = deviceInput.device
                print("🎤 释放设备: \(device.localizedName)")
            }
        }
        
        // 从会话字典中移除
        captureSessions.removeValue(forKey: deviceID)
        print("✅ 设备 \(deviceID) 的录制已完全停止")
    }
}

class CaptureRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onStart: () -> Void = {}
    var onStartTime: (CMTime) -> Void = {_ in}
    var onError: (Error) -> Void = {_ in}
    var onComplete: (URL) -> Void = { _ in }
    
    private let powerMeter = PowerMeter()
    var audioLevelHandler: ((Float, Float) -> Void)?
    var onAudioSample: ((CMSampleBuffer) -> Void)?
    var onVideoSample: ((CMSampleBuffer) -> Void)?
    var isFirstReceived = false
    var didStartFile = false
    var lastPTS: CMTime = .zero
    
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: (any Error)?) {
        if let error = error {
            // 检查是否是"成功完成"的错误（比如达到文件大小或时间限制）
            if let userInfo = (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool,
               userInfo == true {
                print("✅ 录制正常完成（达到预设限制）: \(outputFileURL.path)")
                onComplete(outputFileURL)
            } else {
                NSLog("⚠️ [CAPTURE_DELEGATE_ERROR] AVCaptureFileOutput 录制错误: %@", error.localizedDescription)
                print("❌ 录制错误: \(error.localizedDescription)")
                onError(error)
            }
        } else {
            // 没有错误，录制正常完成
            print(" ✅ 录制正常完成: \(outputFileURL.path)")
            onComplete(outputFileURL)
        }
    }
    
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        print("🎬 开始录制到: \(fileURL.path)")
        didStartFile = true
        onStart()
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // 将音频样本缓冲区转换为PCM缓冲区并处理
        if didStartFile && !isFirstReceived {
            isFirstReceived = true
            print("[record-time] 开始时间: 麦克风data \(CFAbsoluteTimeGetCurrent()) \(sampleBuffer.presentationTimeStamp.seconds)")
            onStartTime(sampleBuffer.presentationTimeStamp)
        }
        lastPTS = sampleBuffer.presentationTimeStamp
        // 根据媒体类型分发样本
        if sampleBuffer.formatDescription?.mediaType == .audio {
            onAudioSample?(sampleBuffer)
            handleAudio(for: sampleBuffer)
        } else if sampleBuffer.formatDescription?.mediaType == .video {
            onVideoSample?(sampleBuffer)
        }
    }
    
    private func handleAudio(for buffer: CMSampleBuffer) {
            let (avg, peak, db) = AudioVolumeCalculator.calculateDetailedVolume(from: buffer)
            let volume = AudioVolumeCalculator.calculateVolume(from: buffer)
            // 直接回调，不切换线程
            audioLevelHandler?(volume, peak)
    }
}
