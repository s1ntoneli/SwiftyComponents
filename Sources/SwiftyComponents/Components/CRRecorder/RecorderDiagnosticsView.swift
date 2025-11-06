import SwiftUI
import Foundation
#if canImport(Charts)
import Charts
#endif

public struct RecorderDiagnosticsView: View {
    @ObservedObject var diag = RecorderDiagnostics.shared

    public init() {}

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                header
            HStack(spacing: 16) {
                Toggle("Console Events Log", isOn: $diag.logEventsToConsole)
                Toggle("Console Flow Log", isOn: $diag.logFlowToConsole)
                Spacer()
                HStack(spacing: 6) {
                    Text("Fragment(s)")
                    Stepper(value: Binding(
                        get: { diag.fragmentIntervalSeconds },
                        set: { diag.setFragmentInterval(seconds: $0) }
                    ), in: 0.2...30.0, step: 0.2) {
                        Text(String(format: "%.1f", diag.fragmentIntervalSeconds))
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            .toggleStyle(.switch)
                Divider()
                HStack(alignment: .top, spacing: 16) {
                    statsPanel
                    filePanel
                }
                .frame(maxWidth: .infinity)
                Divider()
                flowPanel
                Divider()
                HStack(alignment: .top, spacing: 16) {
                    errorsPanel
                    eventsPanel
                }
                .frame(maxWidth: .infinity)
                Divider()
                logsPanel
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 820, minHeight: 560)
        .accessibilityIdentifier("RecorderDiagnosticsView")
    }
    
    private var flowPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Flow").font(.headline)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Video").font(.subheadline).foregroundStyle(.secondary)
                    gridRow("Captured", value: String(diag.capturedVideoFrames))
                    gridRow("Appended", value: String(diag.appendedVideoFrames))
                    gridRow("Dropped (not ready)", value: String(diag.droppedVideoNotReady))
                    gridRow("Writer Failed", value: String(diag.writerVideoFailedCount))
                    gridRow("isReadyForMore", value: diag.lastVideoReadyForMore.description)
                    gridRow("Writer Status", value: diag.lastVideoWriterStatus)
                    gridRow("Pending", value: "\(diag.pendingVideoCount)/\(diag.pendingVideoCapacity)")
                }
                Spacer(minLength: 24)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Audio").font(.subheadline).foregroundStyle(.secondary)
                    gridRow("Captured", value: String(diag.capturedAudioSamples))
                    gridRow("Appended", value: String(diag.appendedAudioSamples))
                    gridRow("Dropped (not ready)", value: String(diag.droppedAudioNotReady))
                    gridRow("isReadyForMore", value: diag.lastAudioReadyForMore.description)
                    gridRow("Writer Status", value: diag.lastAudioWriterStatus)
                    gridRow("Pending", value: "\(diag.pendingAudioCount)/\(diag.pendingAudioCapacity)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Recorder Diagnostics").font(.title2).bold()
            statusDot(on: diag.streamActive, label: diag.streamActive ? "Stream Active" : "Stream Inactive")
            statusDot(on: diag.writerActive, label: diag.writerActive ? "Writer Active" : "Writer Stopped")
            Spacer()
            if let t = diag.lastFrameWallTime {
                Text("Last frame: \(relativeDate(t))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stream").font(.headline)
            gridRow("Configured FPS", value: diag.configuredFPS.map(String.init) ?? "-")
            gridRow("Measured FPS", value: String(format: "%.1f", diag.measuredFPS))
            gridRow("Resolution", value: sizeLabel(width: diag.configuredWidth, height: diag.configuredHeight))
            gridRow("Last Frame", value: "\(Int(diag.lastFrameSize.width))×\(Int(diag.lastFrameSize.height))")
            gridRow("Queue Depth", value: diag.queueDepth.map(String.init) ?? "-")
            gridRow("Pixel Format", value: diag.pixelFormatName ?? "-")
            gridRow("Color Space", value: diag.colorSpaceName ?? "-")
            Divider()
            Text("System").font(.headline)
            if let s = diag.systemSnapshot {
                gridRow("Thermal", value: s.thermalState)
                gridRow("Memory Used", value: bytesLabel(Int64(s.usedMemoryBytes)) + " / " + bytesLabel(Int64(s.totalMemoryBytes)))
                gridRow("Memory Usage", value: String(format: "%.0f%%", s.memoryUsageRatio * 100))
                if let r = s.systemCPUUsageRatio {
                    gridRow("CPU (System)", value: String(format: "%.0f%%", r * 100))
                }
                if let p = s.processCPUPercent {
                    gridRow("CPU (Process)", value: String(format: "%.0f%%", p))
                }
                gridRow("RSS (Process)", value: bytesLabel(Int64(s.processRSSBytes)))
                if let f = s.processFootprintBytes { gridRow("Footprint (Process)", value: bytesLabel(Int64(f))) }
                if let v = s.processVirtualBytes { gridRow("Virtual (Process)", value: bytesLabel(Int64(v))) }
                if let v = s.volumeAvailableBytes, let t = s.volumeTotalBytes {
                    gridRow("Disk Free", value: bytesLabel(v) + " / " + bytesLabel(t))
                }
            } else {
                Text("Collecting system snapshot…").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File").font(.headline)
            gridRow("Path", value: diag.outputFileURL?.lastPathComponent ?? "-")
            gridRow("Size", value: bytesLabel(diag.currentFileSizeBytes))
            #if canImport(Charts)
            if #available(macOS 13.0, *) {
                Chart(diag.fileSizeSeries) { p in
                    LineMark(
                        x: .value("Time", p.time),
                        y: .value("Size(MB)", Double(p.bytes) / 1_048_576.0)
                    )
                }
                .chartYScale(domain: .automatic(includesZero: true))
                .frame(minHeight: 180)
            } else {
                Text("Size timeline requires macOS 13+")
                    .foregroundStyle(.secondary)
            }
            #else
            Text("Charts not available on this platform")
                .foregroundStyle(.secondary)
            #endif
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var errorsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Errors").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(diag.errors.suffix(50)) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(relativeDate(e.time)).frame(width: 120, alignment: .leading)
                                Text("\(e.domain) [\(e.code)] — \(e.message)")
                            }
                            Group {
                                Text("Snapshot: ") + Text(snapshotSummary(e.snapshot)).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 240)
    }

    private var eventsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Events").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(diag.events.suffix(100)) { ev in
                        HStack {
                            Text(relativeDate(ev.time)).frame(width: 120, alignment: .leading)
                            Text(ev.message)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 240)
    }

    private var logsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Logs").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(diag.flowLogs.suffix(200)) { l in
                        HStack(alignment: .top) {
                            Text(relativeDate(l.time)).frame(width: 120, alignment: .leading)
                            Text(l.message).textSelection(.enabled)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func statusDot(on: Bool, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(on ? Color.green : Color.red).frame(width: 10, height: 10)
            Text(label).foregroundStyle(.secondary)
        }
    }

    private func gridRow(_ key: String, value: String) -> some View {
        HStack {
            Text(key).frame(width: 140, alignment: .leading).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func sizeLabel(width: Int?, height: Int?) -> String {
        guard let w = width, let h = height else { return "-" }
        return "\(w)×\(h)"
    }

    private func bytesLabel(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    private func relativeDate(_ d: Date) -> String {
        let df = RelativeDateTimeFormatter()
        df.unitsStyle = .short
        return df.localizedString(for: d, relativeTo: Date())
    }

    private func snapshotSummary(_ s: DiagnosticsSnapshot) -> String {
        let size = "\(Int(s.lastFrameSize.width))×\(Int(s.lastFrameSize.height))"
        let res = sizeLabel(width: s.configuredWidth, height: s.configuredHeight)
        let file = s.outputFileURL?.lastPathComponent ?? "-"
        var sys = ""
        if let ss = s.system {
            var parts: [String] = []
            if let c = ss.systemCPUUsageRatio { parts.append("sysCPU=\(String(format: "%.0f%%", c*100))") }
            if let p = ss.processCPUPercent { parts.append("procCPU=\(String(format: "%.0f%%", p))") }
            parts.append("rss=\(bytesLabel(Int64(ss.processRSSBytes)))")
            sys = " [" + parts.joined(separator: ", ") + "]"
        }
        return "active=\(s.streamActive) fps=\(String(format: "%.1f", s.measuredFPS)) cfgFPS=\(s.configuredFPS ?? 0) res=\(res) last=\(size) q=\(s.queueDepth ?? 0) writer=\(s.writerActive) file=\(file) size=\(bytesLabel(s.currentFileSizeBytes))" + sys
    }
}
