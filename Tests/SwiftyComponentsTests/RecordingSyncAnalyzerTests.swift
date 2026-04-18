import Testing
import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
@testable import SwiftyComponents

@Test func recordingSync_detectPeaks_reportsExpectedTimes() {
    let values: [Float] = [0, 0.1, 0.95, 0.1, 0, 0.2, 0.9, 0.1, 0]
    let times = RecordingSyncAnalyzer.detectPeaks(
        values: values,
        sampleInterval: 0.1,
        threshold: 0.5,
        minimumPeakDistance: 0.15
    )
    #expect(times.count == 2)
    #expect(abs(times[0] - 0.2) < 0.001)
    #expect(abs(times[1] - 0.6) < 0.001)
}

@Test func recordingSync_compareTracks_reportsOffsetAndDrift() {
    let reference = [1.0, 2.0, 3.0, 4.0]
    let candidate = [1.05, 2.06, 3.07, 4.08]
    let report = RecordingSyncAnalyzer.compareMarkerTracks(
        referenceRole: "screen_video",
        referenceTimes: reference,
        candidateRole: "screen_audio",
        candidateTimes: candidate,
        matchingTolerance: 0.2
    )

    #expect(report.matchedCount == 4)
    #expect(report.markerMissCount == 0)
    #expect((report.offsetP50Ms ?? 0) > 55)
    #expect((report.offsetP50Ms ?? 0) < 75)
    #expect((report.driftMsPerMin ?? 0) > 500)
}

@Test func recordingSync_analyzeAudio_detectsGeneratedBeeps() async throws {
    let dir = try makeTemporaryDirectory(name: "recording-sync-audio")
    let url = dir.appendingPathComponent("beeps.wav")
    try makeTestAudio(
        url: url,
        durationSeconds: 3.0,
        sampleRate: 48_000,
        beepTimes: [0.5, 1.5, 2.5]
    )

    let report = try await RecordingSyncAnalyzer.analyzeAudio(
        fileURL: url,
        role: "microphone_audio",
        options: .init(audioSamplesPerSecond: 2_000)
    )

    #expect(report.markerTimes.count == 3)
    #expect(abs(report.markerTimes[0] - 0.5) < 0.05)
    #expect(abs(report.markerTimes[1] - 1.5) < 0.05)
    #expect(abs(report.markerTimes[2] - 2.5) < 0.05)
}

@Test func recordingSync_analyzeScreenVideo_detectsGeneratedFlashes() async throws {
    let dir = try makeTemporaryDirectory(name: "recording-sync-video")
    let url = dir.appendingPathComponent("flashes.mov")
    try await makeTestVideo(
        url: url,
        frameRate: 30,
        frameCount: 90,
        flashFrameIndices: [15, 45, 75]
    )

    let report = try await RecordingSyncAnalyzer.analyzeVideo(
        fileURL: url,
        role: "screen_video",
        options: .init(videoFlashThreshold: 0.20)
    )

    #expect(report.markerTimes.count == 3)
    #expect(abs(report.markerTimes[0] - 0.5) < 0.08)
    #expect(abs(report.markerTimes[1] - 1.5) < 0.08)
    #expect(abs(report.markerTimes[2] - 2.5) < 0.08)
}

@Test func recordingSync_analyzeBundle_generatesEndToEndReport() async throws {
    let dir = try makeTemporaryDirectory(name: "recording-sync-bundle")

    let rawVideoURL = dir.appendingPathComponent("screen-video.mov")
    let screenAudioURL = dir.appendingPathComponent("screen-audio.wav")
    let screenMovieURL = dir.appendingPathComponent("screen.mov")
    let micURL = dir.appendingPathComponent("mic.wav")

    try await makeTestVideo(
        url: rawVideoURL,
        frameRate: 30,
        frameCount: 90,
        flashFrameIndices: [15, 45, 75]
    )
    try makeTestAudio(
        url: screenAudioURL,
        durationSeconds: 3.0,
        sampleRate: 48_000,
        beepTimes: [0.5, 1.5, 2.5]
    )
    try makeTestAudio(
        url: micURL,
        durationSeconds: 3.0,
        sampleRate: 48_000,
        beepTimes: [0.53, 1.53, 2.53]
    )
    try await muxMovie(videoURL: rawVideoURL, audioURL: screenAudioURL, outputURL: screenMovieURL)

    let bundleInfo = CRRecorder.BundleInfo(
        duration: 3.0,
        files: [
            .init(filename: "screen.mov", tyle: .screen, recordingStartTimestamp: 100.03),
            .init(filename: "mic.wav", tyle: .audio, recordingStartTimestamp: 100.00)
        ],
        version: 1
    )

    let report = try await RecordingSyncAnalyzer.analyze(
        bundleURL: dir,
        bundleInfo: bundleInfo,
        options: .init(audioSamplesPerSecond: 2_000, videoFlashThreshold: 0.20)
    )

    #expect(report.screenVideo != nil)
    #expect(report.cameraVideo == nil)
    #expect(report.screenAudio != nil)
    #expect(report.microphoneAudio != nil)
    #expect(report.screenAV?.matchedCount == 3)
    #expect(report.microphoneToScreenAudio?.matchedCount == 3)
    #expect((report.microphoneToScreenAudio?.offsetP50Ms ?? 0) > 15)
    #expect((report.microphoneToScreenAudio?.offsetP50Ms ?? 0) < 45)
    #expect(report.adjustedMicrophoneToScreenAudio?.matchedCount == 3)
    #expect(abs(report.adjustedMicrophoneToScreenAudio?.offsetP50Ms ?? 999) < 5)
}

private func makeTemporaryDirectory(name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeTestAudio(
    url: URL,
    durationSeconds: Double,
    sampleRate: Double,
    beepTimes: [Double]
) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let frameCount = Int(durationSeconds * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
    buffer.frameLength = AVAudioFrameCount(frameCount)
    let channel = buffer.floatChannelData![0]
    for index in 0..<frameCount {
        channel[index] = 0
    }

    let beepLength = Int(0.04 * sampleRate)
    let frequency = 1_000.0
    for beepTime in beepTimes {
        let start = max(0, Int(beepTime * sampleRate))
        let end = min(frameCount, start + beepLength)
        guard start < end else { continue }
        for frame in start..<end {
            let t = Double(frame - start) / sampleRate
            channel[frame] = Float(sin(2.0 * Double.pi * frequency * t) * 0.8)
        }
    }

    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}

private func makeTestVideo(
    url: URL,
    frameRate: Int32,
    frameCount: Int,
    flashFrameIndices: [Int]
) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 16,
        AVVideoHeightKey: 16
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: 16,
            kCVPixelBufferHeightKey as String: 16
        ]
    )
    #expect(writer.canAdd(input))
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    let frameDuration = CMTime(value: 1, timescale: frameRate)
    for frameIndex in 0..<frameCount {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(2))
        }
        let isFlash = flashFrameIndices.contains(frameIndex)
        let pixelBuffer = try makePixelBuffer(isWhite: isFlash)
        let time = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
        #expect(adaptor.append(pixelBuffer, withPresentationTime: time))
    }

    input.markAsFinished()
    await withCheckedContinuation { continuation in
        writer.finishWriting {
            continuation.resume()
        }
    }
    #expect(writer.status == .completed)
}

private func makePixelBuffer(isWhite: Bool) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        16,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw NSError(domain: "RecordingSyncAnalyzerTests", code: Int(status))
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let value: UInt8 = isWhite ? 255 : 0
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let buffer = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        let row = buffer.advanced(by: y * bytesPerRow)
        for x in 0..<width {
            let pixel = row.advanced(by: x * 4)
            pixel[0] = value
            pixel[1] = value
            pixel[2] = value
            pixel[3] = 255
        }
    }
    return pixelBuffer
}

private func muxMovie(videoURL: URL, audioURL: URL, outputURL: URL) async throws {
    let composition = AVMutableComposition()
    let videoAsset = AVURLAsset(url: videoURL)
    let audioAsset = AVURLAsset(url: audioURL)

    let videoTrack = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
    let audioTrack = try #require(try await audioAsset.loadTracks(withMediaType: .audio).first)

    let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    let videoDuration = try await videoAsset.load(.duration)
    let audioDuration = try await audioAsset.load(.duration)
    let duration = CMTimeMinimum(videoDuration, audioDuration)
    let range = CMTimeRange(start: .zero, duration: duration)

    try compVideoTrack?.insertTimeRange(range, of: videoTrack, at: .zero)
    try compAudioTrack?.insertTimeRange(range, of: audioTrack, at: .zero)

    guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
        throw NSError(domain: "RecordingSyncAnalyzerTests", code: -200)
    }
    export.outputURL = outputURL
    export.outputFileType = .mov
    export.timeRange = range

    await withCheckedContinuation { continuation in
        export.exportAsynchronously {
            continuation.resume()
        }
    }

    guard export.status == .completed else {
        throw export.error ?? NSError(domain: "RecordingSyncAnalyzerTests", code: -201)
    }
}
