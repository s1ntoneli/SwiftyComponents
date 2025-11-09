//
//  RecorderDiagnostics.swift
//  CoreRecorder
//
//  A lightweight diagnostics center to observe recording state without Xcode logs.
//

import Foundation
import Combine
import AVFoundation
import ScreenCaptureKit
import CoreServices
import CoreGraphics
import Darwin

#if DEBUG
public final class RecorderDiagnostics: ObservableObject, @unchecked Sendable {
    public static let shared = RecorderDiagnostics()

    // MARK: - Public published properties for UI
    @Published public private(set) var streamActive: Bool = false
    @Published public private(set) var configuredFPS: Int? = nil
    @Published public private(set) var configuredWidth: Int? = nil
    @Published public private(set) var configuredHeight: Int? = nil
    @Published public private(set) var queueDepth: Int? = nil
    @Published public private(set) var pixelFormatName: String? = nil
    @Published public private(set) var colorSpaceName: String? = nil

    @Published public private(set) var measuredFPS: Double = 0
    @Published public private(set) var lastFrameSize: CGSize = .zero
    @Published public private(set) var lastFrameWallTime: Date? = nil

    @Published public private(set) var writerActive: Bool = false
    @Published public private(set) var outputFileURL: URL? = nil
    @Published public private(set) var currentFileSizeBytes: Int64 = 0
    @Published public private(set) var fileSizeSeries: [FileSizePoint] = []

    // System info
    @Published public private(set) var systemSnapshot: SystemSnapshot? = nil

    @Published public private(set) var errors: [ErrorRecord] = []
    @Published public private(set) var events: [StateEvent] = []
    @Published public private(set) var flowLogs: [StateEvent] = []

    // 队列监控（拉取式写入）
    @Published public private(set) var pendingVideoCount: Int = 0
    @Published public private(set) var pendingVideoCapacity: Int = 0
    @Published public private(set) var pendingAudioCount: Int = 0
    @Published public private(set) var pendingAudioCapacity: Int = 0

    // 临时可调：fragment interval（秒）
    @Published public private(set) var fragmentIntervalSeconds: Double = 10.0

    // MARK: - 控制开关（运行期可切换）
    @Published public var logEventsToConsole: Bool = true
    @Published public var logFlowToConsole: Bool = true

    // MARK: - Flow counters (capture → writer)
    @Published public private(set) var capturedVideoFrames: UInt64 = 0
    @Published public private(set) var capturedAudioSamples: UInt64 = 0
    @Published public private(set) var appendedVideoFrames: UInt64 = 0
    @Published public private(set) var appendedAudioSamples: UInt64 = 0
    @Published public private(set) var droppedVideoNotReady: UInt64 = 0
    @Published public private(set) var droppedAudioNotReady: UInt64 = 0
    @Published public private(set) var writerVideoFailedCount: UInt64 = 0
    @Published public private(set) var lastVideoReadyForMore: Bool = false
    @Published public private(set) var lastAudioReadyForMore: Bool = false
    @Published public private(set) var lastVideoWriterStatus: String = "unknown"
    @Published public private(set) var lastAudioWriterStatus: String = "unknown"

    // MARK: - Private state
    private var frameTimestamps: [Date] = []
    private var fileSizeTimer: Timer? = nil
    private var maxSeriesCount: Int = 180 // ~3 minutes at 1 Hz
    private var lastVideoUIPush: Date = .distantPast
    private let videoUIPushInterval: TimeInterval = 0.1 // publish at most 10 Hz
    private var prevCPUTicks: (active: UInt64, total: UInt64)? = nil
    private var prevProcessCPUTime: TimeInterval? = nil
    private var prevProcessSampleTime: Date? = nil

    private init() {}

    // MARK: - Configuration hooks
    public func onStartCapture(configuration: SCStreamConfiguration) {
        setOnMain {
            self.streamActive = true
            self.configuredWidth = configuration.width
            self.configuredHeight = configuration.height
            self.queueDepth = configuration.queueDepth
            self.configuredFPS = {
                let t = configuration.minimumFrameInterval
                guard t.value != 0 else { return 60 }
                return max(1, Int(round(Double(t.timescale) / Double(t.value))))
            }()
            self.pixelFormatName = self.pixelFormatToName(configuration.pixelFormat)
            self.colorSpaceName = self.colorSpaceToName(configuration.colorSpaceName)
        }
        recordEvent("Stream started")
        startFileSizeSamplingIfNeeded()
    }

    public func onStopCapture() {
        setOnMain { self.streamActive = false }
        recordEvent("Stream stopped")
        stopFileSizeSamplingIfNeeded()
    }

    public func onStreamDidBecomeActive() { setOnMain { self.streamActive = true }; recordEvent("Stream became active") }
    public func onStreamDidBecomeInactive() { setOnMain { self.streamActive = false }; recordEvent("Stream became inactive") }

    // MARK: - Frame hooks
    public func onVideoSample(size: CGSize) {
        let now = Date()
        frameTimestamps.append(now)
        // keep 2 seconds window for FPS calc
        let cutoff = now.addingTimeInterval(-2)
        frameTimestamps = frameTimestamps.filter { $0 >= cutoff }
        if let first = frameTimestamps.first, let last = frameTimestamps.last, first != last {
            let dt = last.timeIntervalSince(first)
            let fps = Double(frameTimestamps.count - 1) / max(dt, 0.0001)
            // push to UI at most 10 Hz
            if now.timeIntervalSince(lastVideoUIPush) >= videoUIPushInterval {
                lastVideoUIPush = now
                setOnMain {
                    self.measuredFPS = fps
                    self.lastFrameSize = size
                    self.lastFrameWallTime = now
                }
            }
        }
    }

    // MARK: - Writer hooks
    public func setOutputFileURL(_ url: URL?) {
        setOnMain { self.outputFileURL = url }
        startFileSizeSamplingIfNeeded()
    }

    public func onWriterStarted() {
        setOnMain { self.writerActive = true }
        recordEvent("Writer started")
        startFileSizeSamplingIfNeeded()
        sampleFileSize()
        sampleSystemInfo()
    }

    public func onWriterStopped() {
        setOnMain { self.writerActive = false }
        recordEvent("Writer stopped")
        stopFileSizeSamplingIfNeeded()
    }

    // MARK: - Errors & events
    public func recordError(_ error: Error) {
        let ns = error as NSError
        let rec = ErrorRecord(time: Date(), domain: ns.domain, code: ns.code, message: ns.localizedDescription, snapshot: makeSnapshot())
        setOnMain {
            self.errors.append(rec)
            if self.errors.count > 200 { self.errors.removeFirst(self.errors.count - 200) }
        }
    }

    public func recordEvent(_ message: String) {
        setOnMain {
            self.events.append(StateEvent(time: Date(), message: message))
            if self.events.count > 400 { self.events.removeFirst(self.events.count - 400) }
        }
        if logEventsToConsole { NSLog("[REC_DIAG] %@", message) }
    }

    // MARK: - File size sampling
    private func startFileSizeSamplingIfNeeded() {
        guard outputFileURL != nil else { return }
        setOnMain {
            guard self.fileSizeTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.sampleFileSize()
                self?.sampleSystemInfo()
            }
            self.fileSizeTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            // Prime immediate samples so UI shows data instantly
            self.sampleFileSize()
            self.sampleSystemInfo()
        }
    }

    private func stopFileSizeSamplingIfNeeded() {
        if !streamActive && !writerActive {
            fileSizeTimer?.invalidate()
            fileSizeTimer = nil
        }
    }

    private func sampleFileSize() {
        guard let url = outputFileURL else { return }
        // Try URL resource values first, then fall back to FileManager attributes,
        // and finally to FileHandle.seekToEnd.
        var bytes: Int64? = nil
        if let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) {
            if let t = vals.totalFileAllocatedSize { bytes = Int64(t) }
            else if let a = vals.fileAllocatedSize { bytes = Int64(a) }
            else if let s = vals.fileSize { bytes = Int64(s) }
        }
        if bytes == nil {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let num = attrs[.size] as? NSNumber { bytes = num.int64Value }
        }
        if bytes == nil {
            if let fh = try? FileHandle(forReadingFrom: url) {
                let end = try? fh.seekToEnd()
                try? fh.close()
                if let end = end { bytes = Int64(end) }
            }
        }
        if let bytes = bytes {
            setOnMain {
                self.currentFileSizeBytes = bytes
                self.fileSizeSeries.append(FileSizePoint(time: Date(), bytes: bytes))
                if self.fileSizeSeries.count > self.maxSeriesCount {
                    self.fileSizeSeries.removeFirst(self.fileSizeSeries.count - self.maxSeriesCount)
                }
            }
        }
    }

    // MARK: - Flow hooks
    public func logFlow(_ message: String) {
        // UI log
        setOnMain {
            self.flowLogs.append(StateEvent(time: Date(), message: message))
            if self.flowLogs.count > 600 { self.flowLogs.removeFirst(self.flowLogs.count - 600) }
        }
        // Console log
        if logFlowToConsole { NSLog("[REC_FLOW] %@", message) }
    }

    // 队列数量更新（由 writer 调用）
    public func updatePendingCounts(video: Int, videoCap: Int, audio: Int, audioCap: Int) {
        setOnMain {
            self.pendingVideoCount = video
            self.pendingVideoCapacity = videoCap
            self.pendingAudioCount = audio
            self.pendingAudioCapacity = audioCap
        }
    }

    // 设置 fragment interval（秒）
    public func setFragmentInterval(seconds: Double) {
        let s = max(0.2, min(30.0, seconds))
        setOnMain { self.fragmentIntervalSeconds = s }
        SingleCaptureFileOutput.setFragmentIntervalForCurrent(seconds: s)
        recordEvent("Set movieFragmentInterval to \(String(format: "%.2f", s))s")
    }
    public func onCaptureVideoFrame() {
        setOnMain { self.capturedVideoFrames &+= 1 }
    }
    public func onCaptureAudioSample() {
        setOnMain { self.capturedAudioSamples &+= 1 }
    }
    public func beforeAppendVideo(ready: Bool, status: AVAssetWriter.Status) {
        setOnMain {
            self.lastVideoReadyForMore = ready
            self.lastVideoWriterStatus = status.label
        }
    }
    public func beforeAppendAudio(ready: Bool, status: AVAssetWriter.Status) {
        setOnMain {
            self.lastAudioReadyForMore = ready
            self.lastAudioWriterStatus = status.label
        }
    }
    public func onAppendedVideo() {
        setOnMain { self.appendedVideoFrames &+= 1 }
    }
    public func onAppendedAudio() {
        setOnMain { self.appendedAudioSamples &+= 1 }
    }
    public func onDroppedVideoNotReady() {
        setOnMain { self.droppedVideoNotReady &+= 1 }
    }
    public func onDroppedAudioNotReady() {
        setOnMain { self.droppedAudioNotReady &+= 1 }
    }
    public func onWriterVideoFailed() {
        setOnMain { self.writerVideoFailedCount &+= 1 }
    }

    // MARK: - Helpers
    private func pixelFormatToName(_ fmt: OSType) -> String {
        switch fmt {
        case kCVPixelFormatType_32BGRA: return "BGRA"
        case kCVPixelFormatType_ARGB2101010LEPacked: return "ARGB2101010LE"
        default:
            // UTCreateStringForOSType returns Unmanaged<CFString>!
            // Avoid optional chaining on IUO; take the retained value directly.
            let cf = UTCreateStringForOSType(fmt)
            let s = cf.takeRetainedValue() as String
            return s
        }
    }

    private func colorSpaceToName(_ cs: CFString) -> String {
        if cs == CGColorSpace.sRGB { return "sRGB" }
        if cs == CGColorSpace.displayP3 { return "Display P3" }
        return (cs as String)
    }

    // MARK: - System info
    private func sampleSystemInfo() {
        // Memory
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        var freeBytes: UInt64 = 0
        var activeBytes: UInt64 = 0
        let pageSize = UInt64(sysconf(_SC_PAGESIZE))
        let totalMem = ProcessInfo.processInfo.physicalMemory
        let _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        freeBytes = UInt64(info.free_count) * pageSize
        activeBytes = (UInt64(info.active_count) + UInt64(info.inactive_count) + UInt64(info.wire_count)) * pageSize
        let usedBytes = min(totalMem, activeBytes)
        let ratio = totalMem > 0 ? Double(usedBytes) / Double(totalMem) : 0

        // CPU usage (system)
        let sysCPU: Double? = {
            var cpu = host_cpu_load_info()
            var c = mach_msg_type_number_t(MemoryLayout.size(ofValue: cpu) / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &cpu) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) {
                    host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &c)
                }
            }
            guard kr == KERN_SUCCESS else { return nil }
            let user = UInt64(cpu.cpu_ticks.0)
            let system = UInt64(cpu.cpu_ticks.1)
            let idle = UInt64(cpu.cpu_ticks.2)
            let nice = UInt64(cpu.cpu_ticks.3)
            let active = user + system + nice
            let total = active + idle
            if let prev = prevCPUTicks, total > prev.total {
                let dActive = Double(active - prev.active)
                let dTotal = Double(total - prev.total)
                prevCPUTicks = (active, total)
                return max(0, min(1, dActive / dTotal))
            } else {
                prevCPUTicks = (active, total)
                return nil
            }
        }()

        // Process CPU% and RSS
        var procCPU: Double? = nil
        var procRSS: UInt64 = 0
        var procFoot: UInt64? = nil
        var procVirt: UInt64? = nil
        if let p = fetchProcessInfo() {
            procRSS = p.rss
            procFoot = p.footprint
            procVirt = p.virtual
            let now = Date()
            let procTime = p.user + p.system
            if let prevTime = prevProcessCPUTime, let prevWall = prevProcessSampleTime {
                let dt = now.timeIntervalSince(prevWall)
                if dt > 0 {
                    procCPU = max(0, (procTime - prevTime) / dt * 100.0)
                }
            }
            prevProcessCPUTime = procTime
            prevProcessSampleTime = now
        }

        // Disk (for output file volume if available)
        var volAvail: Int64? = nil
        var volTotal: Int64? = nil
        let volURL = outputFileURL ?? URL(fileURLWithPath: NSHomeDirectory())
        if let vals = try? volURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            if let a = vals.volumeAvailableCapacityForImportantUsage { volAvail = Int64(a) }
            if let t = vals.volumeTotalCapacity { volTotal = Int64(t) }
        }

        let thermal: String = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return "nominal"
            case .fair: return "fair"
            case .serious: return "serious"
            case .critical: return "critical"
            @unknown default: return "unknown"
            }
        }()

        let snap = SystemSnapshot(
            time: Date(),
            thermalState: thermal,
            totalMemoryBytes: totalMem,
            usedMemoryBytes: usedBytes,
            freeMemoryBytes: freeBytes,
            memoryUsageRatio: ratio,
            volumeAvailableBytes: volAvail,
            volumeTotalBytes: volTotal,
            systemCPUUsageRatio: sysCPU,
            processCPUPercent: procCPU,
            processRSSBytes: procRSS,
            processFootprintBytes: procFoot,
            processVirtualBytes: procVirt
        )
        setOnMain { self.systemSnapshot = snap }
    }

    private func fetchProcessInfo() -> (user: TimeInterval, system: TimeInterval, rss: UInt64, footprint: UInt64?, virtual: UInt64?)? {
        // Basic times and RSS
        var countBasic = mach_msg_type_number_t(MemoryLayout<task_basic_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        var tbi = task_basic_info_data_t()
        let kr1 = withUnsafeMutablePointer(to: &tbi) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(countBasic)) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &countBasic)
            }
        }
        guard kr1 == KERN_SUCCESS else { return nil }
        let user = TimeInterval(tbi.user_time.seconds) + TimeInterval(tbi.user_time.microseconds) / 1_000_000
        let sys = TimeInterval(tbi.system_time.seconds) + TimeInterval(tbi.system_time.microseconds) / 1_000_000
        let rss = UInt64(tbi.resident_size)

        // Footprint and virtual size
        var countVM = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var tvmi = task_vm_info_data_t()
        let kr2 = withUnsafeMutablePointer(to: &tvmi) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(countVM)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &countVM)
            }
        }
        let footprint = (kr2 == KERN_SUCCESS) ? UInt64(tvmi.phys_footprint) : nil
        let virt = (kr2 == KERN_SUCCESS) ? UInt64(tvmi.virtual_size) : nil

        return (user, sys, rss, footprint, virt)
    }
}
#else
// MARK: - Release build lightweight stub (no overhead)
public final class RecorderDiagnostics: ObservableObject, @unchecked Sendable {
    public static let shared = RecorderDiagnostics()

    // Keep the same published surface to avoid API changes
    @Published public private(set) var streamActive: Bool = false
    @Published public private(set) var configuredFPS: Int? = nil
    @Published public private(set) var configuredWidth: Int? = nil
    @Published public private(set) var configuredHeight: Int? = nil
    @Published public private(set) var queueDepth: Int? = nil
    @Published public private(set) var pixelFormatName: String? = nil
    @Published public private(set) var colorSpaceName: String? = nil

    @Published public private(set) var measuredFPS: Double = 0
    @Published public private(set) var lastFrameSize: CGSize = .zero
    @Published public private(set) var lastFrameWallTime: Date? = nil

    @Published public private(set) var writerActive: Bool = false
    @Published public private(set) var outputFileURL: URL? = nil
    @Published public private(set) var currentFileSizeBytes: Int64 = 0
    @Published public private(set) var fileSizeSeries: [FileSizePoint] = []

    @Published public private(set) var systemSnapshot: SystemSnapshot? = nil

    @Published public private(set) var errors: [ErrorRecord] = []
    @Published public private(set) var events: [StateEvent] = []
    @Published public private(set) var flowLogs: [StateEvent] = []

    @Published public private(set) var pendingVideoCount: Int = 0
    @Published public private(set) var pendingVideoCapacity: Int = 0
    @Published public private(set) var pendingAudioCount: Int = 0
    @Published public private(set) var pendingAudioCapacity: Int = 0

    @Published public private(set) var fragmentIntervalSeconds: Double = 10.0

    @Published public var logEventsToConsole: Bool = false
    @Published public var logFlowToConsole: Bool = false

    @Published public private(set) var capturedVideoFrames: UInt64 = 0
    @Published public private(set) var capturedAudioSamples: UInt64 = 0
    @Published public private(set) var appendedVideoFrames: UInt64 = 0
    @Published public private(set) var appendedAudioSamples: UInt64 = 0
    @Published public private(set) var droppedVideoNotReady: UInt64 = 0
    @Published public private(set) var droppedAudioNotReady: UInt64 = 0
    @Published public private(set) var writerVideoFailedCount: UInt64 = 0
    @Published public private(set) var lastVideoReadyForMore: Bool = false
    @Published public private(set) var lastAudioReadyForMore: Bool = false
    @Published public private(set) var lastVideoWriterStatus: String = "unknown"
    @Published public private(set) var lastAudioWriterStatus: String = "unknown"

    private init() {}

    // No-op APIs to avoid any runtime overhead in release builds
    public func onStartCapture(configuration: SCStreamConfiguration) {}
    public func onStopCapture() {}
    public func onStreamDidBecomeActive() {}
    public func onStreamDidBecomeInactive() {}

    public func onVideoSample(size: CGSize) {}

    public func setOutputFileURL(_ url: URL?) {}
    public func onWriterStarted() {}
    public func onWriterStopped() {}

    public func recordError(_ error: Error) {}
    public func recordEvent(_ message: String) {}

    public func startFileSizeSamplingIfNeeded() {}
    public func stopFileSizeSamplingIfNeeded() {}

    public func logFlow(_ message: String) {}

    public func updatePendingCounts(video: Int, videoCap: Int, audio: Int, audioCap: Int) {}

    public func setFragmentInterval(seconds: Double) {}
    public func onCaptureVideoFrame() {}
    public func onCaptureAudioSample() {}
    public func beforeAppendVideo(ready: Bool, status: AVAssetWriter.Status) {}
    public func beforeAppendAudio(ready: Bool, status: AVAssetWriter.Status) {}
    public func onAppendedVideo() {}
    public func onAppendedAudio() {}
    public func onDroppedVideoNotReady() {}
    public func onDroppedAudioNotReady() {}
    public func onWriterVideoFailed() {}
}
#endif

// MARK: - DTOs for UI
public struct ErrorRecord: Identifiable, Sendable {
    public var id = UUID()
    public let time: Date
    public let domain: String
    public let code: Int
    public let message: String
    public let snapshot: DiagnosticsSnapshot
}

public struct StateEvent: Identifiable, Sendable {
    public var id = UUID()
    public let time: Date
    public let message: String
}

public struct FileSizePoint: Identifiable, Sendable {
    public var id = UUID()
    public let time: Date
    public let bytes: Int64
}

// MARK: - Snapshot
public struct DiagnosticsSnapshot: Sendable {
    public let streamActive: Bool
    public let configuredFPS: Int?
    public let configuredWidth: Int?
    public let configuredHeight: Int?
    public let queueDepth: Int?
    public let pixelFormatName: String?
    public let colorSpaceName: String?
    public let measuredFPS: Double
    public let lastFrameSize: CGSize
    public let writerActive: Bool
    public let currentFileSizeBytes: Int64
    public let outputFileURL: URL?
    public let system: SystemSnapshot?
}

public struct SystemSnapshot: Sendable {
    public let time: Date
    public let thermalState: String
    public let totalMemoryBytes: UInt64
    public let usedMemoryBytes: UInt64
    public let freeMemoryBytes: UInt64
    public let memoryUsageRatio: Double
    public let volumeAvailableBytes: Int64?
    public let volumeTotalBytes: Int64?
    public let systemCPUUsageRatio: Double?
    public let processCPUPercent: Double?
    public let processRSSBytes: UInt64
    public let processFootprintBytes: UInt64?
    public let processVirtualBytes: UInt64?
}

extension RecorderDiagnostics {
    fileprivate func makeSnapshot() -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            streamActive: streamActive,
            configuredFPS: configuredFPS,
            configuredWidth: configuredWidth,
            configuredHeight: configuredHeight,
            queueDepth: queueDepth,
            pixelFormatName: pixelFormatName,
            colorSpaceName: colorSpaceName,
            measuredFPS: measuredFPS,
            lastFrameSize: lastFrameSize,
            writerActive: writerActive,
            currentFileSizeBytes: currentFileSizeBytes,
            outputFileURL: outputFileURL,
            system: systemSnapshot
        )
    }

    // Minimal helper to avoid creating Tasks; dispatch to main if needed.
    private func setOnMain(_ apply: @escaping () -> Void) {
        #if DEBUG
        if Thread.isMainThread { apply() }
        else { DispatchQueue.main.async(execute: apply) }
        #else
        apply()
        #endif
    }
}

extension AVAssetWriter.Status {
    var label: String {
        switch self {
        case .unknown: return "unknown"
        case .writing: return "writing"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        @unknown default: return "unknown"
        }
    }
}
