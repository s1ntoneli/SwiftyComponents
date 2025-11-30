#if os(macOS)

import Foundation
import AVFoundation
import CoreGraphics

/// Traditional macOS screen recorder based on `AVCaptureScreenInput` + `AVCaptureMovieFileOutput`.
///
/// This recorder is independent from `CRRecorder` / ScreenCaptureKit and is intended
/// as a more conservative fallback: it asks AVFoundation to capture a display into
/// a `.mov` file and relies on the system's own handling of frame drops.
public final class AVScreenRecorder: NSObject, @unchecked Sendable {

    /// Configuration for a single recording session.
    public struct Configuration: Equatable, Sendable {
        /// Display to capture. Defaults to the main display.
        public var displayID: CGDirectDisplayID
        /// Optional crop rect in screen coordinates (origin at bottom-left). `nil` = full display.
        public var cropRect: CGRect?
        /// Whether to render the mouse cursor into the captured video.
        public var showsCursor: Bool
        /// Whether to highlight mouse clicks in the captured video.
        public var capturesMouseClicks: Bool
        /// Target frame rate. The actual frame rate may be lower depending on system load.
        public var fps: Int
        /// Include audio from the default audio input device (e.g. a virtual loopback device).
        ///
        /// Note: AVFoundation does not directly expose "system audio". To capture what the user
        /// hears from the speakers, a virtual loopback device (or similar) must be configured
        /// as an audio input. When this flag is `true`, the recorder will attach the system
        /// default audio input device if possible.
        public var includeAudio: Bool
        /// Optional audio device unique ID to capture from when `includeAudio` is true.
        /// If `nil`, the system default audio input device is used.
        public var audioDeviceUniqueID: String?

        public init(
            displayID: CGDirectDisplayID = CGMainDisplayID(),
            cropRect: CGRect? = nil,
            showsCursor: Bool = true,
            capturesMouseClicks: Bool = false,
            fps: Int = 30,
            includeAudio: Bool = false,
            audioDeviceUniqueID: String? = nil
        ) {
            self.displayID = displayID
            self.cropRect = cropRect
            self.showsCursor = showsCursor
            self.capturesMouseClicks = capturesMouseClicks
            self.fps = max(1, fps)
            self.includeAudio = includeAudio
            self.audioDeviceUniqueID = audioDeviceUniqueID
        }
    }

    /// Result of a completed recording.
    public struct Result: Sendable {
        public let fileURL: URL
        /// Wall-clock start time (CFAbsoluteTime) when recording began.
        public let startTimestamp: CFAbsoluteTime
        /// Wall-clock end time (CFAbsoluteTime) when recording stopped.
        public let endTimestamp: CFAbsoluteTime
        /// Captured video dimensions (after transforms), if known.
        public let videoDimensions: CGSize?
        /// PTS（秒）of the first captured video frame, if available.
        public let firstVideoPTS: Double?
    }

    public enum RecorderError: LocalizedError {
        case alreadyRecording
        case notRecording
        case configurationFailed(String)
        case recordingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "AVScreenRecorder is already recording."
            case .notRecording:
                return "AVScreenRecorder is not currently recording."
            case .configurationFailed(let message):
                return "AVScreenRecorder configuration failed: \(message)"
            case .recordingFailed(let message):
                return "AVScreenRecorder recording failed: \(message)"
            }
        }
    }

    private enum State {
        case idle
        case starting
        case recording
        case stopping
    }

    private let configuration: Configuration
    private let sessionQueue = DispatchQueue(label: "com.swiftycomponents.avscreenrecorder.session")

    private var session: AVCaptureSession?
    private var screenInput: AVCaptureScreenInput?
    private var audioInput: AVCaptureDeviceInput?
    /// Reuse the same AssetWriter-based backend as camera recording, so PTS and file contents
    /// come from the same data-output pipeline.
    private let backend = AssetWriterCamBackend()
    private var captureDelegate: CaptureRecordingDelegate?

    private var state: State = .idle
    private var outputURL: URL?
    private var startTimestamp: CFAbsoluteTime?
    private var firstVideoPTSSeconds: Double?

    /// Optional async error callback, e.g. to propagate errors to higher-level coordinators.
    public var errorHandler: (@Sendable (Error) -> Void)?

    // MARK: - Init

    public init(configuration: Configuration) {
        self.configuration = configuration
        super.init()
    }

    deinit {
        // Best-effort cleanup; avoid leaving capture sessions running.
        sessionQueue.async { [session] in
            session?.stopRunning()
        }
    }

    // MARK: - Public API

    /// Start recording the configured display to the given file URL.
    ///
    /// - Parameter url: Target file URL. If it has no extension, `.mov` will be appended.
    ///   The parent directory will be created if needed.
    public func startRecording(to url: URL) async throws {
        guard case .idle = state else {
            throw RecorderError.alreadyRecording
        }
        state = .starting

        let resolvedURL = ensureMovExtension(for: url)
        // Ensure directory exists
        let dir = resolvedURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        do {
            try await configureSession()
            try await startWriter(to: resolvedURL)
            state = .recording
        } catch {
            state = .idle
            outputURL = nil
            throw error
        }
    }

    /// Stop recording and finalize the movie file.
    ///
    /// This method waits until AVFoundation finishes writing the file and returns
    /// basic metadata (timestamps and video dimensions).
    public func stopRecording() async throws -> Result {
        switch state {
        case .idle, .starting:
            throw RecorderError.notRecording
        case .stopping:
            // 不支持并发多次 stop 调用；与之前行为保持一致。
            throw RecorderError.recordingFailed("Multiple callers waiting for stopRecording() are not supported.")
        case .recording:
            break
        }

        state = .stopping

        // 让后端完成写入并关闭会话。
        guard let url = try await backend.stop() ?? outputURL else {
            state = .idle
            throw RecorderError.recordingFailed("No output URL from backend.")
        }

        let end = CFAbsoluteTimeGetCurrent()
        // 对外暴露的 start/endTimestamp 仅用于 UI 显示/日志；不再参与多轨对齐。
        let start = end
        let dims = loadVideoDimensions(from: url)

        state = .idle
        // 清理强引用
        session = nil
        screenInput = nil
        audioInput = nil
        captureDelegate = nil

        return Result(
            fileURL: url,
            startTimestamp: start,
            endTimestamp: end,
            videoDimensions: dims,
            firstVideoPTS: firstVideoPTSSeconds
        )
    }

    // MARK: - Internals

    /// Configure capture session (inputs + data outputs via backend).
    private func configureSession() async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let session = AVCaptureSession()
                    session.sessionPreset = .high

                    guard let screenInput = AVCaptureScreenInput(displayID: self.configuration.displayID) else {
                        throw RecorderError.configurationFailed("Cannot create AVCaptureScreenInput for display \(self.configuration.displayID)")
                    }

                    screenInput.capturesCursor = self.configuration.showsCursor
                    screenInput.capturesMouseClicks = self.configuration.capturesMouseClicks
                    if let crop = self.configuration.cropRect {
                        // ScreenCaptureKit / 上层配置使用的是“左上角为原点”的坐标系；
                        // AVCaptureScreenInput.cropRect 使用的是“左下角为原点”的坐标系。
                        // 这里将 Y 轴翻转到 AVFoundation 期望的坐标系。
                        let displayBounds = CGDisplayBounds(self.configuration.displayID)
                        let height = displayBounds.height
                        let convertedY = height - crop.origin.y - crop.height
                        let converted = CGRect(x: crop.origin.x, y: convertedY, width: crop.width, height: crop.height)
                        screenInput.cropRect = converted
                    }
                    let fps = max(1, self.configuration.fps)
                    screenInput.minFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))

                    guard session.canAddInput(screenInput) else {
                        throw RecorderError.configurationFailed("Cannot add screen input to capture session.")
                    }
                    session.addInput(screenInput)

                    var audioInput: AVCaptureDeviceInput?
                    if self.configuration.includeAudio {
                        let audioDevice: AVCaptureDevice?
                        if let uniqueID = self.configuration.audioDeviceUniqueID {
                            audioDevice = AVCaptureDevice.devices(for: .audio).first(where: { $0.uniqueID == uniqueID })
                        } else {
                            audioDevice = AVCaptureDevice.default(for: .audio)
                        }
                        if let audioDevice {
                            let input = try AVCaptureDeviceInput(device: audioDevice)
                            if session.canAddInput(input) {
                                session.addInput(input)
                                audioInput = input
                            }
                        }
                    }

                    // 复用 CRRecorder 里的 CaptureRecordingDelegate 作为数据输出代理。
                    let delegate = CaptureRecordingDelegate()
                    delegate.onError = { [weak self] error in
                        self?.errorHandler?(error)
                    }
                    captureDelegate = delegate

                    // 映射简单编码选项：优先保持行为稳定，其次再暴露更细粒度配置。
                    var options = CameraRecordingOptions()
                    options.preferHEVC = false // AVScreenRecorder 传统路径默认 H.264；如需 HEVC 可后续扩展

                    backend.apply(options: options)
                    // 将首帧 PTS 与文件写入绑定到同一数据输出流。
                    backend.onFirstPTS = { [weak self] time in
                        self?.firstVideoPTSSeconds = time.seconds
                        print("[AVScreenRecorder] 首帧 PTS: \(time.seconds)")
                    }
                    try backend.configure(
                        session: session,
                        device: audioInput?.device, // 仅用于观察断连/估算 fps，可为空
                        delegate: delegate,
                        queue: self.sessionQueue
                    )

                    self.session = session
                    self.screenInput = screenInput
                    self.audioInput = audioInput
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Start capture session and wait for the writer pipeline to observe the first frame.
    private func startWriter(to url: URL) async throws {
        // 先启动会话，让数据输出开始产生样本。
        sessionQueue.async { [weak self] in
            self?.session?.startRunning()
        }
        do {
            try await backend.start(fileURL: url)
        } catch let err {
            throw RecorderError.recordingFailed(err.localizedDescription)
        }
    }

    private func ensureMovExtension(for url: URL) -> URL {
        if url.pathExtension.isEmpty {
            return url.appendingPathExtension("mov")
        }
        return url
    }

    private func loadVideoDimensions(from url: URL) -> CGSize? {
        let asset = AVAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let size = track.naturalSize.applying(track.preferredTransform)
        return CGSize(width: abs(size.width), height: abs(size.height))
    }
}

#endif
