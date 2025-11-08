import Foundation

public struct ScreenRecorderOptions: Sendable, Equatable {
    public var fps: Int
    public var queueDepth: Int?
    public var targetBitRate: Int? // bps
    public var includeAudio: Bool
    public var showsCursor: Bool
    public var hdr: Bool
    public var useHEVC: Bool

    public init(
        fps: Int = 60,
        queueDepth: Int? = nil,
        targetBitRate: Int? = nil,
        includeAudio: Bool = false,
        showsCursor: Bool = false,
        hdr: Bool = false,
        useHEVC: Bool = false
    ) {
        self.fps = max(1, fps)
        self.queueDepth = queueDepth
        self.targetBitRate = targetBitRate
        self.includeAudio = includeAudio
        self.showsCursor = showsCursor
        self.hdr = hdr
        self.useHEVC = useHEVC
    }
}

