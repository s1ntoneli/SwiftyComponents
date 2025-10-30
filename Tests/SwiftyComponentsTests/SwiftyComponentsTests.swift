import Testing
import AVFoundation
@testable import SwiftyComponents

@Test func streamAggregator_producesFrames_andRetention() throws {
    // sample rate 48000, frameDuration 1/60s => 800 samples per frame
    let sampleRate: Double = 48_000
    let frameDuration = CMTime(value: 1, timescale: 60)
    let frameSamples = Int(round(sampleRate * CMTimeGetSeconds(frameDuration)))
    let bins = 4
    let cfg = WaveformStreamConfig(
        sampleRate: sampleRate,
        channel: .mix,
        mode: .peak,
        frameDuration: frameDuration,
        binsPerFrame: bins,
        retention: .windowFrames(2)
    )
    let agg = WaveformStreamAggregator(config: cfg)

    // Build a mono Float32 buffer containing two frames: first frame ~1.0, second frame ~0.0
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    let total = frameSamples * 2
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(total))!
    buf.frameLength = AVAudioFrameCount(total)
    let p = buf.floatChannelData![0]
    for i in 0..<frameSamples { p[i] = 1.0 } // first frame
    for i in frameSamples..<total { p[i] = 0.0 } // second frame

    agg.append(buf, at: .zero)
    let frames = agg.popReadyFrames()
    #expect(frames.count >= 2)
    #expect(frames[0].bins.count == bins)
    // First frame should be normalized around 1, second around 0
    let f0max = frames[0].bins.max() ?? -1
    let f1max = frames[1].bins.max() ?? -1
    #expect(f0max > 0.9)
    #expect(f1max < 0.1)

    // Retention keeps last 2 frames even after pop (readyQueue cleared, retained kept)
    let snap = agg.snapshotAll()
    #expect(snap.count <= 2)
}
