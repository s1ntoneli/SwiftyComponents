import Foundation
import AVFoundation
import CoreGraphics

public enum MediaCompositionBuilder {
    public struct Options: Sendable {
        public var includeScreen: Bool
        public var includeCamera: Bool
        public var includeMicrophone: Bool
        public var pipScale: CGFloat // 摄像头画中画缩放（相对屏幕）
        public var pipMargin: CGFloat // 画中画边距
        public enum Background: Sendable { case screen, camera }
        public var background: Background

        public init(includeScreen: Bool = true,
                    includeCamera: Bool = true,
                    includeMicrophone: Bool = true,
                    pipScale: CGFloat = 0.25,
                    pipMargin: CGFloat = 16,
                    background: Background = .screen) {
            self.includeScreen = includeScreen
            self.includeCamera = includeCamera
            self.includeMicrophone = includeMicrophone
            self.pipScale = pipScale
            self.pipMargin = pipMargin
            self.background = background
        }
        public static let `default` = Options()
        public static let camMicOnly = Options(includeScreen: false, includeCamera: true, includeMicrophone: true, background: .camera)
    }
    public struct Input: Sendable {
        public let bundleInfo: CRRecorder.BundleInfo
        public let baseDirectory: URL
        public init(bundleInfo: CRRecorder.BundleInfo, baseDirectory: URL) {
            self.bundleInfo = bundleInfo
            self.baseDirectory = baseDirectory
        }
    }

    public struct Output {
        public let composition: AVMutableComposition
        public let videoComposition: AVVideoComposition?
    }

    /// 基于 bundle.json 描述，将屏幕视频、摄像头、麦克风按开始时间对齐，生成可播放的合成。
    /// - 规则：
    ///   - 以最早的 recordingStartTimestamp 作为时间零点；各轨道按 (start - earliestStart) 插入。
    ///   - 屏幕轨作为背景视频；摄像头轨按画中画缩放到右下角。
    ///   - 音频：保留屏幕文件自带音频 + 叠加麦克风独立音频。
    public static func build(from input: Input, options: Options = .default) throws -> Output {
        let info = input.bundleInfo
        let dir = input.baseDirectory

        // 计算最早开始时间
        let starts = info.files.compactMap { $0.recordingStartTimestamp }
        let earliestStart = starts.min() ?? 0

        let comp = AVMutableComposition()

        // 创建轨道
        let screenVideoTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let camVideoTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let screenAudioTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let micAudioTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var screenAsset: AVAsset? = nil
        var camAsset: AVAsset? = nil

        for f in info.files {
            let url = dir.appendingPathComponent(f.filename)
            let asset = AVURLAsset(url: url)
            let insertion = CMTime(seconds: max(0, (f.recordingStartTimestamp ?? earliestStart) - earliestStart), preferredTimescale: 600)
            let duration = asset.duration
            let range = CMTimeRange(start: .zero, duration: duration)

            switch f.tyle {
            case .screen:
                guard options.includeScreen else { break }
                if let v = asset.tracks(withMediaType: .video).first {
                    try? screenVideoTrack?.insertTimeRange(range, of: v, at: insertion)
                    screenAsset = asset
                }
                if let a = asset.tracks(withMediaType: .audio).first {
                    try? screenAudioTrack?.insertTimeRange(range, of: a, at: insertion)
                }
            case .webcam:
                guard options.includeCamera else { break }
                if let v = asset.tracks(withMediaType: .video).first {
                    try? camVideoTrack?.insertTimeRange(range, of: v, at: insertion)
                    camAsset = asset
                }
                if let a = asset.tracks(withMediaType: .audio).first {
                    try? micAudioTrack?.insertTimeRange(range, of: a, at: insertion)
                }
            case .audio:
                if options.includeMicrophone, let a = asset.tracks(withMediaType: .audio).first {
                    try? micAudioTrack?.insertTimeRange(range, of: a, at: insertion)
                }
            default:
                break
            }
        }

        // 构建视频合成（通用：背景 + 画中画）
        var videoComp: AVMutableVideoComposition? = nil
        let screenVsrc = screenAsset?.tracks(withMediaType: .video).first
        let camVsrc = camAsset?.tracks(withMediaType: .video).first
        let useCameraAsBackground = (options.background == .camera && camVsrc != nil)

        if useCameraAsBackground, let camV = camVsrc, let camTrack = camVideoTrack {
            let n = camV.naturalSize.applying(camV.preferredTransform)
            let renderSize = CGSize(width: abs(n.width), height: abs(n.height))
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)

            let bg = AVMutableVideoCompositionLayerInstruction(assetTrack: camTrack)
            bg.setTransform(camV.preferredTransform, at: .zero)

            var overlays: [AVMutableVideoCompositionLayerInstruction] = []
            if options.includeScreen, let sV = screenVsrc, let sTrack = screenVideoTrack {
                let pip = AVMutableVideoCompositionLayerInstruction(assetTrack: sTrack)
                let sn = sV.naturalSize.applying(sV.preferredTransform)
                let sSize = CGSize(width: abs(sn.width), height: abs(sn.height))
                let scale = max(0.05, min(1.0, options.pipScale))
                let margin = max(0, options.pipMargin)
                let targetW = renderSize.width * scale
                let targetH = targetW * (sSize.height / max(1, sSize.width))
                var t = sV.preferredTransform
                let sx = targetW / max(1, sSize.width)
                let sy = targetH / max(1, sSize.height)
                t = t.concatenating(CGAffineTransform(scaleX: sx, y: sy))
                t = t.concatenating(CGAffineTransform(translationX: renderSize.width - targetW - margin, y: renderSize.height - targetH - margin))
                pip.setTransform(t, at: .zero)
                overlays.append(pip)
            }
            instruction.layerInstructions = overlays + [bg]
            let vc = AVMutableVideoComposition()
            vc.instructions = [instruction]
            vc.renderSize = renderSize
            vc.frameDuration = CMTime(value: 1, timescale: 30)
            videoComp = vc
        } else if let sV = screenVsrc, let sTrack = screenVideoTrack { // 背景：屏幕
            let n = sV.naturalSize.applying(sV.preferredTransform)
            let renderSize = CGSize(width: abs(n.width), height: abs(n.height))
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
            let bg = AVMutableVideoCompositionLayerInstruction(assetTrack: sTrack)
            bg.setTransform(sV.preferredTransform, at: .zero)
            var overlays: [AVMutableVideoCompositionLayerInstruction] = []
            if options.includeCamera, let camV = camVsrc, let camTrack = camVideoTrack {
                let pip = AVMutableVideoCompositionLayerInstruction(assetTrack: camTrack)
                let cn = camV.naturalSize.applying(camV.preferredTransform)
                let cSize = CGSize(width: abs(cn.width), height: abs(cn.height))
                let scale = max(0.05, min(1.0, options.pipScale))
                let margin = max(0, options.pipMargin)
                let targetW = renderSize.width * scale
                let targetH = targetW * (cSize.height / max(1, cSize.width))
                var t = camV.preferredTransform
                let sx = targetW / max(1, cSize.width)
                let sy = targetH / max(1, cSize.height)
                t = t.concatenating(CGAffineTransform(scaleX: sx, y: sy))
                t = t.concatenating(CGAffineTransform(translationX: renderSize.width - targetW - margin, y: renderSize.height - targetH - margin))
                pip.setTransform(t, at: .zero)
                overlays.append(pip)
            }
            instruction.layerInstructions = overlays + [bg]
            let vc = AVMutableVideoComposition()
            vc.instructions = [instruction]
            vc.renderSize = renderSize
            vc.frameDuration = CMTime(value: 1, timescale: 30)
            videoComp = vc
        }

        return Output(composition: comp, videoComposition: videoComp)
    }
}
