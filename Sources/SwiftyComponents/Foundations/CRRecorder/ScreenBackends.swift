#if os(macOS)

import Foundation
import AVFoundation
import CoreGraphics

/// 抽象一条“屏幕录制后端”。
/// 约束为与 `ScreenCaptureRecorder` 相同的接口，这样 CRRecorder 的流程基本不用改，
/// 只需在构造时选择具体实现即可。
protocol ScreenRecorderBackend: AnyObject, Sendable {
    /// 错误回调，由 CRRecorder 注入，用于统一中断处理。
    var errorHandler: ((Error) -> Void)? { get set }

    /// 开始整屏录制。
    func startScreenCapture(
        displayID: CGDirectDisplayID,
        cropRect: CGRect?,
        hdr: Bool,
        showsCursor: Bool,
        includeAudio: Bool,
        excludedWindowTitles: [String]
    ) async throws -> [CRRecorder.BundleInfo.FileAsset]

    /// 开始窗口录制。
    func startWindowCapture(
        windowID: CGWindowID,
        displayID: CGDirectDisplayID?,
        hdr: Bool,
        includeAudio: Bool,
        frameRate: Int,
        h265: Bool
    ) async throws -> [CRRecorder.BundleInfo.FileAsset]

    /// 停止录制并返回最终文件信息。
    func stop() async throws -> [CRRecorder.BundleInfo.FileAsset]

    /// 返回最近一次录制的基本信息（用于 `packLastResult`）。
    func packLastResult() -> [CRRecorder.BundleInfo.FileAsset]
}

// ScreenCaptureKit 路径：原有实现已经具备完全匹配的接口，这里只需声明遵守协议。
extension ScreenCaptureRecorder: ScreenRecorderBackend {}

// MARK: - AVFoundation 后端

/// 使用传统 AVFoundation（AVCaptureScreenInput + AVScreenRecorder）的屏幕录制后端。
///
/// 通过实现与 ScreenCaptureRecorder 相同的接口，让 CRRecorder 可以在两种实现之间无感切换。
final class AVFoundationScreenRecorderBackend: NSObject, @unchecked Sendable, ScreenRecorderBackend {
    // MARK: - Public API

    var errorHandler: ((Error) -> Void)?

    // MARK: - Private state

    private let outputDirectory: URL
    private let baseFilename: String
    private let options: ScreenRecorderOptions
    private var recorder: AVScreenRecorder?
    private var lastAsset: CRRecorder.BundleInfo.FileAsset?

    init(outputDirectory: URL, baseFilename: String, options: ScreenRecorderOptions) {
        self.outputDirectory = outputDirectory
        self.baseFilename = baseFilename
        self.options = options
    }

    // MARK: - ScreenRecorderBackend

    func startScreenCapture(
        displayID: CGDirectDisplayID,
        cropRect: CGRect?,
        hdr: Bool,
        showsCursor: Bool,
        includeAudio: Bool,
        excludedWindowTitles: [String]
    ) async throws -> [CRRecorder.BundleInfo.FileAsset] {
        let config = AVScreenRecorder.Configuration(
            displayID: displayID,
            cropRect: cropRect,
            showsCursor: showsCursor,
            capturesMouseClicks: false,
            fps: options.fps,
            includeAudio: includeAudio,
            audioDeviceUniqueID: nil
        )
        try await startWithConfiguration(config)
        // 与 ScreenCaptureRecorder 一致：启动阶段仅返回文件名/起始时间占位信息，
        // 精确的 PTS/时长在 stop() 阶段统一汇总。
        let url = makeFileURL()
        let asset = CRRecorder.BundleInfo.FileAsset(
            filename: url.lastPathComponent,
            tyle: .screen,
            recordingStartTimestamp: nil,
            recordingEndTimestamp: nil
        )
        lastAsset = asset
        return [asset]
    }

    func startWindowCapture(
        windowID: CGWindowID,
        displayID: CGDirectDisplayID?,
        hdr: Bool,
        includeAudio: Bool,
        frameRate: Int,
        h265: Bool
    ) async throws -> [CRRecorder.BundleInfo.FileAsset] {
        guard let bounds = windowBounds(for: windowID) else {
            throw AVScreenRecorder.RecorderError.configurationFailed("Cannot resolve bounds for window \(windowID)")
        }
        let resolvedDisplay = displayIDForWindow(bounds: bounds, fallback: displayID ?? CGMainDisplayID())
        let config = AVScreenRecorder.Configuration(
            displayID: resolvedDisplay,
            cropRect: bounds,
            showsCursor: options.showsCursor,
            capturesMouseClicks: false,
            fps: frameRate,
            includeAudio: includeAudio,
            audioDeviceUniqueID: nil
        )
        try await startWithConfiguration(config)
        let url = makeFileURL()
        let asset = CRRecorder.BundleInfo.FileAsset(
            filename: url.lastPathComponent,
            tyle: .screen,
            recordingStartTimestamp: nil,
            recordingEndTimestamp: nil
        )
        lastAsset = asset
        return [asset]
    }

    func stop() async throws -> [CRRecorder.BundleInfo.FileAsset] {
        guard let recorder else { return [] }
        do {
            let res = try await recorder.stopRecording()
            let dims: CRRecorder.BundleInfo.Size? = res.videoDimensions.map {
                .init(width: Int($0.width), height: Int($0.height))
            }
            let asset = CRRecorder.BundleInfo.FileAsset(
                filename: res.fileURL.lastPathComponent,
                recordingSize: nil,
                tyle: .screen,
                videoDimensions: dims,
                // 仅使用首帧 PTS（秒）作为录制起点；如缺失则不填，避免混入墙钟时间。
                recordingStartTimestamp: res.firstVideoPTS,
                recordingEndTimestamp: nil
            )
            lastAsset = asset
            return [asset]
        } catch let err as AVScreenRecorder.RecorderError {
            // 针对 notRecording 等情况：如文件已在磁盘上存在，可选地提供一个“无对齐时间戳”的占位结果，
            // 但不再尝试用墙钟时间推算录制起止，避免污染对齐语义。
            if case .notRecording = err {
                let url = makeFileURL()
                if FileManager.default.fileExists(atPath: url.path) {
                    let asset = AVURLAsset(url: url)
                    let track = asset.tracks(withMediaType: .video).first
                    let size: CGSize? = track.map {
                        let s = $0.naturalSize.applying($0.preferredTransform)
                        return CGSize(width: abs(s.width), height: abs(s.height))
                    }
                    let dims: CRRecorder.BundleInfo.Size? = size.map {
                        .init(width: Int($0.width), height: Int($0.height))
                    }
                    let fa = CRRecorder.BundleInfo.FileAsset(
                        filename: url.lastPathComponent,
                        recordingSize: nil,
                        tyle: .screen,
                        videoDimensions: dims,
                        recordingStartTimestamp: nil,
                        recordingEndTimestamp: nil
                    )
                    lastAsset = fa
                    return [fa]
                }
            }
            throw err
        }
    }

    func packLastResult() -> [CRRecorder.BundleInfo.FileAsset] {
        if let lastAsset {
            return [lastAsset]
        }
        let url = makeFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let asset = CRRecorder.BundleInfo.FileAsset(
            filename: url.lastPathComponent,
            tyle: .screen,
            recordingStartTimestamp: nil,
            recordingEndTimestamp: nil
        )
        return [asset]
    }

    // MARK: - Helpers

    private func startWithConfiguration(_ config: AVScreenRecorder.Configuration) async throws {
        let rec = AVScreenRecorder(configuration: config)
        rec.errorHandler = { [weak self] error in
            self?.errorHandler?(error)
        }
        self.recorder = rec
        try await rec.startRecording(to: makeFileURL())
    }

    private func makeFileURL() -> URL {
        var url = outputDirectory.appendingPathComponent(baseFilename)
        if url.pathExtension.isEmpty { url.appendPathExtension("mov") }
        return url
    }

    /// 查询指定 window 的 bounds（全局坐标）。
    private func windowBounds(for windowID: CGWindowID) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        // 使用 kCGNullWindowID 获取全局窗口列表，再按 windowID 过滤；
        // 直接把 windowID 传给 API 会导致部分标志组合下返回为空。
        guard
            let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        for info in infoList {
            guard
                let number = info[kCGWindowNumber as String] as? NSNumber,
                number.uint32Value == windowID,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            return bounds
        }
        return nil
    }

    /// 根据 window bounds 反推所在显示器。
    private func displayIDForWindow(bounds: CGRect, fallback: CGDirectDisplayID) -> CGDirectDisplayID {
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        let err = CGGetDisplaysWithRect(bounds, UInt32(displays.count), &displays, &count)
        if err == .success, count > 0 {
            return displays[0]
        }
        return fallback
    }
}

#endif
