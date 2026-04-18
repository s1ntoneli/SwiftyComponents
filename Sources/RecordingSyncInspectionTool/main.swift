import Foundation
import AVFoundation
import SwiftyComponents

@main
enum RecordingSyncInspectionTool {
    static func main() async throws {
        let args = ToolArguments.parse(CommandLine.arguments)
        let recordingDir = args.recordingDirectory
        let bundleURL = recordingDir.appendingPathComponent("bundle.json")
        let bundleData = try Data(contentsOf: bundleURL)
        let bundleInfo = try JSONDecoder().decode(CRRecorder.BundleInfo.self, from: bundleData)

        let report = try await RecordingSyncAnalyzer.analyze(
            bundleURL: recordingDir,
            bundleInfo: bundleInfo,
            options: .init(audioSamplesPerSecond: 2_000, videoFlashThreshold: 0.18)
        )
        let reportURL = recordingDir.appendingPathComponent(args.reportFilename)
        try RecordingSyncAnalyzer.writeReport(report, to: reportURL)

        let inspectionURL = recordingDir.appendingPathComponent(args.videoFilename)
        let exportMode = try await exportInspectionVideo(
            recordingDir: recordingDir,
            bundleInfo: bundleInfo,
            outputURL: inspectionURL,
            includeCamera: args.includeCamera,
            includeMicrophone: args.includeMicrophone
        )

        print("INSPECT_SYNC bundle=\(bundleURL.path)")
        print("INSPECT_SYNC report=\(reportURL.path)")
        print("INSPECT_SYNC video=\(inspectionURL.path)")
        print("INSPECT_SYNC exportMode=\(exportMode)")
        print("INSPECT_SYNC screenAV matched=\(report.screenAV?.matchedCount ?? 0) p95=\(report.screenAV?.offsetP95Ms ?? -1)")
        print("INSPECT_SYNC micAdjusted matched=\(report.adjustedMicrophoneToScreenAudio?.matchedCount ?? 0) p50=\(report.adjustedMicrophoneToScreenAudio?.offsetP50Ms ?? -1)")
        print("INSPECT_SYNC camAdjusted matched=\(report.adjustedCameraToScreenVideo?.matchedCount ?? 0) p50=\(report.adjustedCameraToScreenVideo?.offsetP50Ms ?? -1)")
    }

    private static func exportInspectionVideo(
        recordingDir: URL,
        bundleInfo: CRRecorder.BundleInfo,
        outputURL: URL,
        includeCamera: Bool,
        includeMicrophone: Bool
    ) async throws -> String {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let primaryOptions = MediaCompositionBuilder.Options(
            includeScreen: true,
            includeCamera: includeCamera,
            includeMicrophone: includeMicrophone,
            pipScale: 0.4,
            pipMargin: 16,
            background: includeCamera ? .camera : .screen
        )
        if try await exportComposition(recordingDir: recordingDir, bundleInfo: bundleInfo, outputURL: outputURL, options: primaryOptions) {
            if includeCamera && includeMicrophone {
                return "merged-camera+mic"
            }
            if includeCamera {
                return "merged-camera"
            }
            if includeMicrophone {
                return "merged-screen+mic"
            }
            return "merged-screen-only"
        }

        let fallbackOptions = MediaCompositionBuilder.Options(
            includeScreen: true,
            includeCamera: false,
            includeMicrophone: includeMicrophone,
            pipScale: 0.4,
            pipMargin: 16,
            background: .screen
        )
        if try await exportComposition(recordingDir: recordingDir, bundleInfo: bundleInfo, outputURL: outputURL, options: fallbackOptions) {
            return includeMicrophone ? "fallback-screen+mic" : "fallback-screen-only"
        }

        if let screenFilename = bundleInfo.files.first(where: { $0.tyle == .screen })?.filename {
            let sourceURL = recordingDir.appendingPathComponent(screenFilename)
            try FileManager.default.copyItem(at: sourceURL, to: outputURL)
            return "fallback-screen-copy"
        }

        throw InspectionError.exportFailed(-1)
    }

    private static func exportComposition(
        recordingDir: URL,
        bundleInfo: CRRecorder.BundleInfo,
        outputURL: URL,
        options: MediaCompositionBuilder.Options
    ) async throws -> Bool {
        let built = try MediaCompositionBuilder.build(
            from: .init(bundleInfo: bundleInfo, baseDirectory: recordingDir),
            options: options
        )
        guard let exporter = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else {
            return false
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        exporter.videoComposition = built.videoComposition
        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            exporter.exportAsynchronously {
                if exporter.status == .completed {
                    continuation.resume(returning: true)
                } else if exporter.status == .failed || exporter.status == .cancelled {
                    continuation.resume(returning: false)
                } else if let error = exporter.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

private struct ToolArguments {
    let recordingDirectory: URL
    let videoFilename: String
    let reportFilename: String
    let includeCamera: Bool
    let includeMicrophone: Bool

    static func parse(_ argv: [String]) -> ToolArguments {
        var recordingDirectory: URL?
        var videoFilename = "inspection-merged.mov"
        var reportFilename = "sync_report.json"
        var includeCamera = true
        var includeMicrophone = true
        var index = 1
        while index < argv.count {
            switch argv[index] {
            case "--recording-dir":
                if index + 1 < argv.count {
                    recordingDirectory = URL(fileURLWithPath: argv[index + 1])
                    index += 1
                }
            case "--video-name":
                if index + 1 < argv.count {
                    videoFilename = argv[index + 1]
                    index += 1
                }
            case "--report-name":
                if index + 1 < argv.count {
                    reportFilename = argv[index + 1]
                    index += 1
                }
            case "--no-camera":
                includeCamera = false
            case "--no-microphone":
                includeMicrophone = false
            default:
                break
            }
            index += 1
        }

        guard let recordingDirectory else {
            fputs("Usage: RecordingSyncInspectionTool --recording-dir <recording-dir> [--video-name name.mov] [--report-name name.json] [--no-camera] [--no-microphone]\n", stderr)
            exit(2)
        }
        return ToolArguments(
            recordingDirectory: recordingDirectory,
            videoFilename: videoFilename,
            reportFilename: reportFilename,
            includeCamera: includeCamera,
            includeMicrophone: includeMicrophone
        )
    }
}

private enum InspectionError: Error {
    case exportFailed(Int)
}
