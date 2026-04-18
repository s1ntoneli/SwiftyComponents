import Foundation
#if canImport(AVFoundation)
import AVFoundation
import CoreVideo
#endif

public struct RecordingSyncAnalysisOptions: Codable, Sendable {
    public var audioSamplesPerSecond: Double
    public var audioMinimumPeakThreshold: Float
    public var audioThresholdStdDevs: Float
    public var audioMinimumPeakDistance: Double
    public var videoFlashThreshold: Float
    public var videoMinimumFlashDistance: Double
    public var matchingTolerance: Double

    public init(
        audioSamplesPerSecond: Double = 1_000,
        audioMinimumPeakThreshold: Float = 0.55,
        audioThresholdStdDevs: Float = 1.2,
        audioMinimumPeakDistance: Double = 0.20,
        videoFlashThreshold: Float = 0.30,
        videoMinimumFlashDistance: Double = 0.20,
        matchingTolerance: Double = 0.35
    ) {
        self.audioSamplesPerSecond = audioSamplesPerSecond
        self.audioMinimumPeakThreshold = audioMinimumPeakThreshold
        self.audioThresholdStdDevs = audioThresholdStdDevs
        self.audioMinimumPeakDistance = audioMinimumPeakDistance
        self.videoFlashThreshold = videoFlashThreshold
        self.videoMinimumFlashDistance = videoMinimumFlashDistance
        self.matchingTolerance = matchingTolerance
    }
}

public struct RecordingSyncMarkerTrackReport: Codable, Sendable {
    public var role: String
    public var filename: String
    public var markerTimes: [Double]
    public var sampleCount: Int
    public var durationSeconds: Double?
    public var detectionConfidence: Double

    public init(
        role: String,
        filename: String,
        markerTimes: [Double],
        sampleCount: Int,
        durationSeconds: Double?,
        detectionConfidence: Double
    ) {
        self.role = role
        self.filename = filename
        self.markerTimes = markerTimes
        self.sampleCount = sampleCount
        self.durationSeconds = durationSeconds
        self.detectionConfidence = detectionConfidence
    }
}

public struct RecordingSyncComparisonReport: Codable, Sendable {
    public var referenceRole: String
    public var candidateRole: String
    public var referenceMarkerCount: Int
    public var candidateMarkerCount: Int
    public var matchedCount: Int
    public var markerMatchRate: Double
    public var markerMissCount: Int
    public var offsetP50Ms: Double?
    public var offsetP95Ms: Double?
    public var offsetMaxAbsMs: Double?
    public var jitterP95Ms: Double?
    public var driftMsPerMin: Double?

    public init(
        referenceRole: String,
        candidateRole: String,
        referenceMarkerCount: Int,
        candidateMarkerCount: Int,
        matchedCount: Int,
        markerMatchRate: Double,
        markerMissCount: Int,
        offsetP50Ms: Double?,
        offsetP95Ms: Double?,
        offsetMaxAbsMs: Double?,
        jitterP95Ms: Double?,
        driftMsPerMin: Double?
    ) {
        self.referenceRole = referenceRole
        self.candidateRole = candidateRole
        self.referenceMarkerCount = referenceMarkerCount
        self.candidateMarkerCount = candidateMarkerCount
        self.matchedCount = matchedCount
        self.markerMatchRate = markerMatchRate
        self.markerMissCount = markerMissCount
        self.offsetP50Ms = offsetP50Ms
        self.offsetP95Ms = offsetP95Ms
        self.offsetMaxAbsMs = offsetMaxAbsMs
        self.jitterP95Ms = jitterP95Ms
        self.driftMsPerMin = driftMsPerMin
    }
}

public struct RecordingSyncReport: Codable, Sendable {
    public var createdAt: Date
    public var bundleURL: String
    public var options: RecordingSyncAnalysisOptions
    public var screenVideo: RecordingSyncMarkerTrackReport?
    public var cameraVideo: RecordingSyncMarkerTrackReport?
    public var screenAudio: RecordingSyncMarkerTrackReport?
    public var microphoneAudio: RecordingSyncMarkerTrackReport?
    public var screenAV: RecordingSyncComparisonReport?
    public var cameraToScreenVideo: RecordingSyncComparisonReport?
    public var microphoneToScreenAudio: RecordingSyncComparisonReport?
    public var adjustedCameraToScreenVideo: RecordingSyncComparisonReport?
    public var adjustedMicrophoneToScreenAudio: RecordingSyncComparisonReport?

    public init(
        createdAt: Date = Date(),
        bundleURL: String,
        options: RecordingSyncAnalysisOptions,
        screenVideo: RecordingSyncMarkerTrackReport?,
        cameraVideo: RecordingSyncMarkerTrackReport?,
        screenAudio: RecordingSyncMarkerTrackReport?,
        microphoneAudio: RecordingSyncMarkerTrackReport?,
        screenAV: RecordingSyncComparisonReport?,
        cameraToScreenVideo: RecordingSyncComparisonReport?,
        microphoneToScreenAudio: RecordingSyncComparisonReport?,
        adjustedCameraToScreenVideo: RecordingSyncComparisonReport?,
        adjustedMicrophoneToScreenAudio: RecordingSyncComparisonReport?
    ) {
        self.createdAt = createdAt
        self.bundleURL = bundleURL
        self.options = options
        self.screenVideo = screenVideo
        self.cameraVideo = cameraVideo
        self.screenAudio = screenAudio
        self.microphoneAudio = microphoneAudio
        self.screenAV = screenAV
        self.cameraToScreenVideo = cameraToScreenVideo
        self.microphoneToScreenAudio = microphoneToScreenAudio
        self.adjustedCameraToScreenVideo = adjustedCameraToScreenVideo
        self.adjustedMicrophoneToScreenAudio = adjustedMicrophoneToScreenAudio
    }
}

public enum RecordingSyncAnalyzerError: Error {
    case missingScreenAsset
    case assetHasNoVideoTrack(URL)
}

public enum RecordingSyncAnalyzer {
    #if canImport(AVFoundation)
    public static func analyze(
        bundleURL: URL,
        bundleInfo: CRRecorder.BundleInfo,
        options: RecordingSyncAnalysisOptions = .init()
    ) async throws -> RecordingSyncReport {
        let screenAsset = bundleInfo.files.first(where: { $0.tyle == .screen })
        guard let screenAsset else {
            throw RecordingSyncAnalyzerError.missingScreenAsset
        }

        let micAsset = bundleInfo.files.first(where: { $0.tyle == .audio })
        let cameraAsset = bundleInfo.files.first(where: { $0.tyle == .webcam })
        let earliestStart = bundleInfo.files.compactMap(\.recordingStartTimestamp).min()
        let screenURL = bundleURL.appendingPathComponent(screenAsset.filename)
        let screenVideo = try await analyzeVideo(fileURL: screenURL, role: "screen_video", options: options)
        let screenAudio = try await analyzeAudio(fileURL: screenURL, role: "screen_audio", options: options)
        let cameraVideo: RecordingSyncMarkerTrackReport?
        if let cameraAsset {
            let cameraURL = bundleURL.appendingPathComponent(cameraAsset.filename)
            cameraVideo = try await analyzeVideo(fileURL: cameraURL, role: "camera_video", options: options)
        } else {
            cameraVideo = nil
        }

        let microphoneAudio: RecordingSyncMarkerTrackReport?
        if let micAsset {
            let micURL = bundleURL.appendingPathComponent(micAsset.filename)
            microphoneAudio = try await analyzeAudio(fileURL: micURL, role: "microphone_audio", options: options)
        } else {
            microphoneAudio = nil
        }

        let screenAV = compareMarkerTracks(
            referenceRole: screenVideo.role,
            referenceTimes: screenVideo.markerTimes,
            candidateRole: screenAudio.role,
            candidateTimes: screenAudio.markerTimes,
            matchingTolerance: options.matchingTolerance
        )
        let cameraToScreenVideo = cameraVideo.map { cameraVideo in
            compareMarkerTracks(
                referenceRole: screenVideo.role,
                referenceTimes: screenVideo.markerTimes,
                candidateRole: cameraVideo.role,
                candidateTimes: cameraVideo.markerTimes,
                matchingTolerance: options.matchingTolerance
            )
        }
        let adjustedCameraToScreenVideo = cameraVideo.flatMap { cameraVideo in
            adjustedComparison(
                bundleInfo: bundleInfo,
                earliestStart: earliestStart,
                referenceRole: screenVideo.role,
                referenceFilename: screenVideo.filename,
                referenceTimes: screenVideo.markerTimes,
                candidateRole: cameraVideo.role,
                candidateFilename: cameraVideo.filename,
                candidateTimes: cameraVideo.markerTimes,
                matchingTolerance: options.matchingTolerance
            )
        }

        let microphoneToScreenAudio = microphoneAudio.map { microphoneAudio in
            compareMarkerTracks(
                referenceRole: screenAudio.role,
                referenceTimes: screenAudio.markerTimes,
                candidateRole: microphoneAudio.role,
                candidateTimes: microphoneAudio.markerTimes,
                matchingTolerance: options.matchingTolerance
            )
        }
        let adjustedMicrophoneToScreenAudio = microphoneAudio.flatMap { microphoneAudio in
            adjustedComparison(
                bundleInfo: bundleInfo,
                earliestStart: earliestStart,
                referenceRole: screenAudio.role,
                referenceFilename: screenAudio.filename,
                referenceTimes: screenAudio.markerTimes,
                candidateRole: microphoneAudio.role,
                candidateFilename: microphoneAudio.filename,
                candidateTimes: microphoneAudio.markerTimes,
                matchingTolerance: options.matchingTolerance
            )
        }

        return RecordingSyncReport(
            bundleURL: bundleURL.path,
            options: options,
            screenVideo: screenVideo,
            cameraVideo: cameraVideo,
            screenAudio: screenAudio,
            microphoneAudio: microphoneAudio,
            screenAV: screenAV,
            cameraToScreenVideo: cameraToScreenVideo,
            microphoneToScreenAudio: microphoneToScreenAudio,
            adjustedCameraToScreenVideo: adjustedCameraToScreenVideo,
            adjustedMicrophoneToScreenAudio: adjustedMicrophoneToScreenAudio
        )
    }

    public static func writeReport(_ report: RecordingSyncReport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }

    static func analyzeAudio(
        fileURL: URL,
        role: String,
        options: RecordingSyncAnalysisOptions
    ) async throws -> RecordingSyncMarkerTrackReport {
        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = duration.seconds
        let sampleCount = max(256, Int(ceil(max(durationSeconds, 0.001) * options.audioSamplesPerSecond)))
        let amplitudes = try await WaveformAnalyzer.sampleAmplitudes(
            asset: asset,
            timeRange: CMTimeRange(start: .zero, duration: duration),
            samples: sampleCount,
            mode: .peak,
            channel: .mix
        )
        let threshold = dynamicThreshold(
            values: amplitudes,
            minimum: options.audioMinimumPeakThreshold,
            stdDevs: options.audioThresholdStdDevs
        )
        let markerTimes = detectPeaks(
            values: amplitudes,
            sampleInterval: durationSeconds / Double(max(sampleCount, 1)),
            threshold: threshold,
            minimumPeakDistance: options.audioMinimumPeakDistance
        )
        let confidence = detectionConfidence(values: amplitudes, markerTimes: markerTimes, sampleInterval: durationSeconds / Double(max(sampleCount, 1)))
        return RecordingSyncMarkerTrackReport(
            role: role,
            filename: fileURL.lastPathComponent,
            markerTimes: markerTimes,
            sampleCount: sampleCount,
            durationSeconds: durationSeconds,
            detectionConfidence: confidence
        )
    }

    static func analyzeVideo(
        fileURL: URL,
        role: String,
        options: RecordingSyncAnalysisOptions
    ) async throws -> RecordingSyncMarkerTrackReport {
        let (frameTimes, brightness) = try await sampleVideoBrightness(fileURL: fileURL)
        let flashSignal = makePositiveEdgeSignal(values: brightness)
        let sampleInterval = inferredSampleInterval(times: frameTimes)
        let markerTimes = detectPeaks(
            values: flashSignal,
            sampleInterval: sampleInterval,
            threshold: options.videoFlashThreshold,
            minimumPeakDistance: options.videoMinimumFlashDistance,
            timeProvider: { idx in frameTimes[idx] }
        )
        let confidence = detectionConfidence(values: flashSignal, markerTimes: markerTimes, timeProvider: frameTimes)
        return RecordingSyncMarkerTrackReport(
            role: role,
            filename: fileURL.lastPathComponent,
            markerTimes: markerTimes,
            sampleCount: frameTimes.count,
            durationSeconds: frameTimes.last,
            detectionConfidence: confidence
        )
    }

    static func compareMarkerTracks(
        referenceRole: String,
        referenceTimes: [Double],
        candidateRole: String,
        candidateTimes: [Double],
        matchingTolerance: Double
    ) -> RecordingSyncComparisonReport {
        let deltas = greedyMatchDeltas(referenceTimes: referenceTimes, candidateTimes: candidateTimes, tolerance: matchingTolerance)
        let offsetsMs = deltas.map { $0.deltaSeconds * 1_000.0 }
        let jitterMs = zip(offsetsMs.dropFirst(), offsetsMs).map { newer, older in
            abs(newer - older)
        }
        let driftMsPerMin = linearDriftMsPerMin(referenceTimes: deltas.map(\.referenceTime), offsetsMs: offsetsMs)
        let matchRate = referenceTimes.isEmpty ? 0.0 : Double(deltas.count) / Double(referenceTimes.count)
        return RecordingSyncComparisonReport(
            referenceRole: referenceRole,
            candidateRole: candidateRole,
            referenceMarkerCount: referenceTimes.count,
            candidateMarkerCount: candidateTimes.count,
            matchedCount: deltas.count,
            markerMatchRate: matchRate,
            markerMissCount: max(0, referenceTimes.count - deltas.count),
            offsetP50Ms: percentile(offsetsMs, p: 0.50),
            offsetP95Ms: percentile(offsetsMs.map(abs), p: 0.95),
            offsetMaxAbsMs: offsetsMs.map(abs).max(),
            jitterP95Ms: percentile(jitterMs, p: 0.95),
            driftMsPerMin: driftMsPerMin
        )
    }

    static func adjustedComparison(
        bundleInfo: CRRecorder.BundleInfo,
        earliestStart: CFAbsoluteTime?,
        referenceRole: String,
        referenceFilename: String,
        referenceTimes: [Double],
        candidateRole: String,
        candidateFilename: String,
        candidateTimes: [Double],
        matchingTolerance: Double
    ) -> RecordingSyncComparisonReport? {
        guard let earliestStart else { return nil }
        let referenceOffset = bundleInfo.files.first(where: { $0.filename == referenceFilename }).flatMap { file in
            file.recordingStartTimestamp.map { max(0, $0 - earliestStart) }
        } ?? 0
        let candidateOffset = bundleInfo.files.first(where: { $0.filename == candidateFilename }).flatMap { file in
            file.recordingStartTimestamp.map { max(0, $0 - earliestStart) }
        } ?? 0
        let adjustedReferenceTimes = referenceTimes.map { $0 + referenceOffset }
        let adjustedCandidateTimes = candidateTimes.map { $0 + candidateOffset }
        return compareMarkerTracks(
            referenceRole: referenceRole + "_adjusted",
            referenceTimes: adjustedReferenceTimes,
            candidateRole: candidateRole + "_adjusted",
            candidateTimes: adjustedCandidateTimes,
            matchingTolerance: matchingTolerance
        )
    }

    static func detectPeaks(
        values: [Float],
        sampleInterval: Double,
        threshold: Float,
        minimumPeakDistance: Double,
        timeProvider: ((Int) -> Double)? = nil
    ) -> [Double] {
        guard values.count >= 3, sampleInterval > 0 else { return [] }
        let minPeakDistanceSamples = max(1, Int(ceil(minimumPeakDistance / sampleInterval)))
        var peaks: [Double] = []
        peaks.reserveCapacity(32)
        var lastAcceptedIndex = -minPeakDistanceSamples
        for index in 1..<(values.count - 1) {
            let value = values[index]
            guard value >= threshold else { continue }
            guard value >= values[index - 1], value >= values[index + 1] else { continue }
            guard index - lastAcceptedIndex >= minPeakDistanceSamples else { continue }
            peaks.append(timeProvider?(index) ?? (Double(index) * sampleInterval))
            lastAcceptedIndex = index
        }
        return peaks
    }

    static func dynamicThreshold(values: [Float], minimum: Float, stdDevs: Float) -> Float {
        guard !values.isEmpty else { return minimum }
        let count = Float(values.count)
        let mean = values.reduce(0, +) / count
        let variance = values.reduce(Float.zero) { partial, value in
            let delta = value - mean
            return partial + (delta * delta)
        } / count
        let std = sqrt(max(variance, 0))
        return max(minimum, mean + (std * stdDevs))
    }

    static func makePositiveEdgeSignal(values: [Float]) -> [Float] {
        guard !values.isEmpty else { return [] }
        var signal = [Float](repeating: 0, count: values.count)
        for index in 1..<values.count {
            signal[index] = max(0, values[index] - values[index - 1])
        }
        return signal
    }

    static func percentile(_ values: [Double], p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let clamped = min(max(p, 0), 1)
        let position = Double(sorted.count - 1) * clamped
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + ((sorted[upper] - sorted[lower]) * fraction)
    }

    static func greedyMatchDeltas(
        referenceTimes: [Double],
        candidateTimes: [Double],
        tolerance: Double
    ) -> [(referenceTime: Double, deltaSeconds: Double)] {
        guard !referenceTimes.isEmpty, !candidateTimes.isEmpty else { return [] }
        var matches: [(referenceTime: Double, deltaSeconds: Double)] = []
        var candidateIndex = 0

        for referenceTime in referenceTimes {
            while candidateIndex + 1 < candidateTimes.count,
                  candidateTimes[candidateIndex + 1] <= referenceTime {
                candidateIndex += 1
            }

            var bestIndex: Int?
            var bestDistance = Double.greatestFiniteMagnitude
            for index in max(0, candidateIndex - 1)...min(candidateTimes.count - 1, candidateIndex + 1) {
                let distance = abs(candidateTimes[index] - referenceTime)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }

            guard let bestIndex, bestDistance <= tolerance else { continue }
            let deltaSeconds = candidateTimes[bestIndex] - referenceTime
            matches.append((referenceTime: referenceTime, deltaSeconds: deltaSeconds))
            candidateIndex = min(bestIndex + 1, candidateTimes.count - 1)
        }

        return matches
    }

    static func linearDriftMsPerMin(referenceTimes: [Double], offsetsMs: [Double]) -> Double? {
        guard referenceTimes.count == offsetsMs.count, referenceTimes.count >= 2 else { return nil }
        let n = Double(referenceTimes.count)
        let meanX = referenceTimes.reduce(0, +) / n
        let meanY = offsetsMs.reduce(0, +) / n
        var numerator = 0.0
        var denominator = 0.0
        for (x, y) in zip(referenceTimes, offsetsMs) {
            let dx = x - meanX
            numerator += dx * (y - meanY)
            denominator += dx * dx
        }
        guard denominator > 0 else { return nil }
        let slopeMsPerSec = numerator / denominator
        return slopeMsPerSec * 60.0
    }

    static func detectionConfidence(
        values: [Float],
        markerTimes: [Double],
        sampleInterval: Double
    ) -> Double {
        detectionConfidence(values: values, markerTimes: markerTimes) { index in
            Double(index) * sampleInterval
        }
    }

    static func detectionConfidence(
        values: [Float],
        markerTimes: [Double],
        timeProvider: [Double]
    ) -> Double {
        detectionConfidence(values: values, markerTimes: markerTimes) { index in
            timeProvider[index]
        }
    }

    private static func detectionConfidence(
        values: [Float],
        markerTimes: [Double],
        timeForIndex: (Int) -> Double
    ) -> Double {
        guard !values.isEmpty, !markerTimes.isEmpty else { return 0 }
        let peakValues: [Double] = markerTimes.compactMap { markerTime in
            guard let nearest = values.enumerated().min(by: { lhs, rhs in
                abs(timeForIndex(lhs.offset) - markerTime) < abs(timeForIndex(rhs.offset) - markerTime)
            }) else {
                return nil
            }
            return Double(nearest.element)
        }
        guard !peakValues.isEmpty else { return 0 }
        let meanPeak = peakValues.reduce(0, +) / Double(peakValues.count)
        return min(max(meanPeak, 0), 1)
    }

    static func inferredSampleInterval(times: [Double]) -> Double {
        guard times.count >= 2 else { return 1.0 / 30.0 }
        let deltas = zip(times.dropFirst(), times).map { newer, older in
            newer - older
        }
        return percentile(deltas, p: 0.50) ?? (1.0 / 30.0)
    }

    private static func sampleVideoBrightness(fileURL: URL) async throws -> ([Double], [Float]) {
        let asset = AVURLAsset(url: fileURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw RecordingSyncAnalyzerError.assetHasNoVideoTrack(fileURL)
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
        )
        guard reader.canAdd(output) else {
            throw RecordingSyncAnalyzerError.assetHasNoVideoTrack(fileURL)
        }
        reader.add(output)
        reader.startReading()

        var times: [Double] = []
        var brightness: [Float] = []
        times.reserveCapacity(256)
        brightness.reserveCapacity(256)

        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sample) }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            times.append(max(0, pts.seconds))
            brightness.append(averageBrightness(pixelBuffer: buffer))
        }

        let maxValue = brightness.max() ?? 0
        let normalized = maxValue > 0 ? brightness.map { $0 / maxValue } : brightness
        return (times, normalized)
    }

    private static func averageBrightness(pixelBuffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow > 0 else { return 0 }

        let stepX = max(1, width / 16)
        let stepY = max(1, height / 16)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        var luminanceSum = 0.0
        var sampleCount = 0

        for y in stride(from: 0, to: height, by: stepY) {
            let row = buffer.advanced(by: y * bytesPerRow)
            for x in stride(from: 0, to: width, by: stepX) {
                let pixel = row.advanced(by: x * 4)
                let blue = Double(pixel[0])
                let green = Double(pixel[1])
                let red = Double(pixel[2])
                luminanceSum += (0.0722 * blue) + (0.7152 * green) + (0.2126 * red)
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return 0 }
        return Float(luminanceSum / Double(sampleCount) / 255.0)
    }
    #endif
}
