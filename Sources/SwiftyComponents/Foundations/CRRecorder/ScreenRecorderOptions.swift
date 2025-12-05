import Foundation

/// 内部使用的屏幕录制调优参数聚合体。
/// 外部请通过 `CRRecorder.SchemeItem` 直接传入 fps / 光标 / HEVC / HDR / 音频等语义字段。
struct ScreenRecorderOptions: Sendable, Equatable, Hashable {
    /// 期望帧率（用于估算编码码率与队列深度）；实际帧率仍由上层 Scheme 控制。
    public var fps: Int
    /// 覆盖默认的 `SCStreamConfiguration.queueDepth`；`nil` 时由分辨率+fps 自动推断。
    public var queueDepth: Int?
    /// 覆盖自动估算的视频平均码率（bps）；`nil` 时按分辨率+fps+bpp 计算。
    public var targetBitRate: Int? // bps
    /// 是否在录制中显示光标（仅部分后端有效）。
    public var showsCursor: Bool
    /// 是否优先使用 HEVC 编码（具体行为由后端/平台决定）。
    public var useHEVC: Bool

    public init(
        fps: Int = 60,
        queueDepth: Int? = nil,
        targetBitRate: Int? = nil,
        showsCursor: Bool = false,
        useHEVC: Bool = false
    ) {
        self.fps = max(1, fps)
        self.queueDepth = queueDepth
        self.targetBitRate = targetBitRate
        self.showsCursor = showsCursor
        self.useHEVC = useHEVC
    }
}
