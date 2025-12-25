import Foundation
import AVFoundation
import ScreenCaptureKit

/// 屏幕录制器（分层：配置/写入/流），默认与 CRRecorder 无缝衔接。
final class ScreenCaptureRecorder: NSObject, @unchecked Sendable {
    // MARK: Callbacks
    var errorHandler: ((Error) -> Void)?
    var videoFPSSink: ScreenVideoFPSEventSink?

    // MARK: State
    private var filePath: String
    private var stream: SCStream?
    private var output: StreamOutput?
    private var writer: WriterPipeline?
    private var options: ScreenRecorderOptions
    private var isStopping: Bool = false
    // 在 finalize 期间拒收后续样本，避免在 markAsFinished() 之后 append 造成 .failed
    private var allowAppend: Bool = true
    private var didDetachOutputs: Bool = false
    // 保证 finish 只触发一次，避免在 .writing 期间二次调用 finishWriting 造成 abort
    private var finalizeStarted: Bool = false

    // timestamps for result
    private var recordingStartTimestamp: CFAbsoluteTime?
    private var firstFrameTimestamp: CFAbsoluteTime?

    init(filePath: String, options: ScreenRecorderOptions = .init()) {
        self.filePath = filePath
        self.options = options
    }

    // MARK: - Start capture (Display)
    func startScreenCapture(
        displayID: CGDirectDisplayID,
        cropRect: CGRect?,
        hdr: Bool,
        showsCursor: Bool,
        includeAudio: Bool,
        excludedWindowTitles: [String]
    ) async throws -> [CRRecorder.BundleInfo.FileAsset] {
        videoFPSSink?.onSessionStart(backend: .screenCaptureKit)
        recordingStartTimestamp = CFAbsoluteTimeGetCurrent()
        do {
            let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecordingError.recordingFailed("Can't find display with ID \(displayID)")
        }
        let opts = options
        // 基于本次录制配置传入的标题列表，屏蔽对应窗口
        let excluded = Self.windows(withTitles: Set(excludedWindowTitles), in: content)
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = try RecorderConfig.make(
            for: display,
            cropRect: cropRect,
            hdr: hdr,
            captureSystemAudio: includeAudio,
            options: opts
        )
        try prepareWriter(urlPath: filePath, configuration: config, hdr: hdr, includeAudio: includeAudio, options: opts)
        try startStream(configuration: config, filter: filter, includeAudio: includeAudio)
        let file = URL(fileURLWithPath: filePath)
        return [CRRecorder.BundleInfo.FileAsset(filename: file.lastPathComponent, tyle: .screen, recordingStartTimestamp: firstFrameTimestamp)]
        } catch {
            videoFPSSink?.onSessionStop()
            throw error
        }
    }

    // MARK: - Start capture (Window)
    func startWindowCapture(
        windowID: CGWindowID,
        displayID: CGDirectDisplayID?,
        hdr: Bool,
        showsCursor: Bool,
        includeAudio: Bool,
        frameRate: Int = 30,
        h265: Bool = false
    ) async throws -> [CRRecorder.BundleInfo.FileAsset] {
        videoFPSSink?.onSessionStart(backend: .screenCaptureKit)
        recordingStartTimestamp = CFAbsoluteTimeGetCurrent()
        do {
            let content = try await SCShareableContent.current
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw RecordingError.recordingFailed("Can't find window with ID \(windowID)")
        }
        var opts = options
        opts.fps = frameRate
        // Per-run 光标可见性由上层 Scheme 控制，这里在原始 options 基础上覆盖一次。
        opts.showsCursor = showsCursor
        opts.useHEVC = (opts.useHEVC || h265)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = RecorderConfig.make(
            for: window,
            hdr: hdr,
            captureSystemAudio: includeAudio,
            options: opts
        )
        try prepareWriter(urlPath: filePath, configuration: config, hdr: hdr, includeAudio: includeAudio, options: opts)
        try startStream(configuration: config, filter: filter, includeAudio: includeAudio)
        let file = URL(fileURLWithPath: filePath)
        return [CRRecorder.BundleInfo.FileAsset(filename: file.lastPathComponent, tyle: .screen, recordingStartTimestamp: firstFrameTimestamp)]
        } catch {
            videoFPSSink?.onSessionStop()
            throw error
        }
    }

    // MARK: - Stop
    func stop() async throws -> [CRRecorder.BundleInfo.FileAsset] {
        try await stopStreamAndFinish()
        let end = CFAbsoluteTimeGetCurrent()
        let start = firstFrameTimestamp ?? recordingStartTimestamp
        let url = URL(fileURLWithPath: filePath)
        return [CRRecorder.BundleInfo.FileAsset(filename: url.lastPathComponent, tyle: .screen, recordingStartTimestamp: start, recordingEndTimestamp: end)]
    }

    func packLastResult() -> [CRRecorder.BundleInfo.FileAsset] {
        let file = URL(fileURLWithPath: filePath)
        return [CRRecorder.BundleInfo.FileAsset(filename: file.lastPathComponent, tyle: .screen, recordingStartTimestamp: firstFrameTimestamp)]
    }

    // MARK: - Internals
    private func prepareWriter(
        urlPath: String,
        configuration: SCStreamConfiguration,
        hdr: Bool,
        includeAudio: Bool,
        options: ScreenRecorderOptions
    ) throws {
        var url = URL(fileURLWithPath: urlPath)
        if url.pathExtension.isEmpty { url.appendPathExtension("mov") }
        self.filePath = url.path
        self.writer = try WriterPipeline.create(
            url: url,
            configuration: configuration,
            hdr: hdr,
            includeAudio: includeAudio,
            options: options,
            videoFPSSink: videoFPSSink
        )
        RecorderDiagnostics.shared.setOutputFileURL(url)
    }

    private func startStream(
        configuration: SCStreamConfiguration,
        filter: SCContentFilter,
        includeAudio: Bool
    ) throws {
        let out = StreamOutput()
        out.videoFPSSink = videoFPSSink
        // 进入写入前，允许接收新样本
        allowAppend = true
        didDetachOutputs = false
        finalizeStarted = false
        out.onVideo = { [weak self] sample in
            guard let self else { return }
            // finalize 后丢弃晚到样本
            guard self.allowAppend else { return }
            if let writer = self.writer, !writer.didStartSession {
                // Use the first video sample's PTS as the recording start time (for A/V alignment)
                let pts = sample.presentationTimeStamp
                writer.startSession(at: pts)
                self.firstFrameTimestamp = pts.seconds
                RecorderDiagnostics.shared.onWriterStarted()
                RecorderDiagnostics.shared.recordEvent("Writer session started")
            }
            self.writer?.appendVideo(sample)
        }
        out.onAudio = { [weak self] sample in
            guard let self else { return }
            guard self.allowAppend else { return }
            // Audio frames may arrive before the first video frame.
            // To avoid AVAssetWriter "Must start a session" crash, ignore audio
            // until the writer session is started by the first video sample.
            guard self.writer?.didStartSession == true else { return }
            self.writer?.appendAudio(sample)
        }
        out.onError = { [weak self] error in
            guard let self else { return }
            // Try to finalize immediately to salvage the file even on early errors
            Task { [weak self] in
                await self?.handleStreamErrorAndFinalize(error)
            }
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: out)
        // 使用同一个串行队列处理音视频样本，降低跨队列并发带来的写入竞争
        let sampleQueue = DispatchQueue(label: "com.swiftycomponents.screen.sample")
        try stream.addStreamOutput(out, type: .screen, sampleHandlerQueue: sampleQueue)
        if includeAudio {
            try stream.addStreamOutput(out, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        RecorderDiagnostics.shared.onStartCapture(configuration: configuration)
        stream.startCapture()
        self.stream = stream
        self.output = out
    }

    private func stopStreamAndFinish(skipStoppingStream: Bool = false) async throws {
        // 进入 finalize：先止血，再停流，最后收尾写入
        allowAppend = false
        detachOutputsIfNeeded()
        // 确保 finish 只发生一次
        if finalizeStarted { return }
        finalizeStarted = true
        if !skipStoppingStream, let stream { try? await stream.stopCapture() }
        self.stream = nil
        RecorderDiagnostics.shared.onStopCapture()
        if let writer = self.writer {
            try await writer.finish()
            RecorderDiagnostics.shared.onWriterStopped()
        }
        videoFPSSink?.onSessionStop()
    }

    @MainActor
    private func handleStreamErrorAndFinalize(_ error: Error) async {
        // Ensure single finalize
        if isStopping { return }
        isStopping = true
        // Forward error
        self.errorHandler?(error)
        // 优先止血，避免 finalize 期间继续 append
        allowAppend = false
        detachOutputsIfNeeded()
        // 针对 -3821（系统/用户外部停止）跳过 stopCapture，直接收尾
        let ns = error as NSError
        if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && ns.code == -3821 {
            do { try await stopStreamAndFinish(skipStoppingStream: true) } catch { /* ignore */ }
        } else {
            // 其他错误：尝试正常 stop 再 finish
            do { try await stopStreamAndFinish() } catch { /* ignore */ }
        }
        isStopping = false
    }

    // 解除输出与委托，阻断回调（可幂等）
    private func detachOutputsIfNeeded() {
        guard !didDetachOutputs else { return }
        didDetachOutputs = true
        if let s = stream, let out = output {
            // 移除屏幕与音频输出（如无音频，remove 也会安全失败）
            try? s.removeStreamOutput(out, type: .screen)
            try? s.removeStreamOutput(out, type: .audio)
        }
        output = nil
    }
}

// MARK: - Per-record exclusion matching
private extension ScreenCaptureRecorder {
    static func windows(withTitles titles: Set<String>, in content: SCShareableContent) -> [SCWindow] {
        guard !titles.isEmpty else { return [] }
        let myBundleID = Bundle.main.bundleIdentifier
        return content.windows.filter { w in
            guard let t = w.title, !t.isEmpty else { return false }
            guard let bid = w.owningApplication?.bundleIdentifier else { return false }
            // 仅过滤当前 App 生成的窗口，避免误伤其他应用
            guard bid == myBundleID else { return false }
            return titles.contains(t)
        }
    }
}
