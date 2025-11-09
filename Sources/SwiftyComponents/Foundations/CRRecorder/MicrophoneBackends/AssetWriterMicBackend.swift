import Foundation
import AVFoundation

final class AssetWriterMicBackend: MicrophoneBackend {
    var onFirstPTS: ((CMTime) -> Void)?
    var processingOptions: MicrophoneProcessingOptions = .init()

    private weak var session: AVCaptureSession?
    private weak var delegate: CaptureRecordingDelegate?
    private var audioDataOutput: AVCaptureAudioDataOutput?

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var writerSessionStarted = false
    private var fileURL: URL?

    private var startContinuation: CheckedContinuation<Void, Error>?
    private var acceptingSamples = true

    func configure(session: AVCaptureSession, device: AVCaptureDevice, delegate: CaptureRecordingDelegate, queue: DispatchQueue) throws {
        self.session = session
        self.delegate = delegate

        let dataOut = AVCaptureAudioDataOutput()
        guard session.canAddOutput(dataOut) else { throw RecordingError.cannotAddOutput }
        session.addOutput(dataOut)
        dataOut.setSampleBufferDelegate(delegate, queue: queue)
        self.audioDataOutput = dataOut

        delegate.onAudioSample = { [weak self] sampleBuffer in
            self?.handleSample(sampleBuffer)
        }
    }

    func start(fileURL: URL) async throws {
        self.fileURL = fileURL
        let writer = try AVAssetWriter(url: fileURL, fileType: .m4a)
        // 固定 10s 片段
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        let ch = max(1, processingOptions.channels)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: ch,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 192_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingError.outputNotConfigured }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RecordingError.outputNotConfigured }

        self.writer = writer
        self.input = input
        self.writerSessionStarted = false

        // 等待首帧到来
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.startContinuation = continuation
        }
    }

    func stop() async throws -> URL? {
        guard let session else { return fileURL }
        acceptingSamples = false
        audioDataOutput?.setSampleBufferDelegate(nil, queue: nil)
        input?.markAsFinished()
        if let writer { await writer.finishWriting() }
        AVCaptureSessionHelper.stopRecordingStep2Close(avSession: session)
        return fileURL
    }

    // Simple gain/AGC processing without AVAudioEngine.
    private var agcSmoothedGain: Float = 1.0
    private func handleSample(_ sampleBuffer: CMSampleBuffer) {
        guard acceptingSamples, let writer, let input else { return }
        let pts = sampleBuffer.presentationTimeStamp
        if !writerSessionStarted {
            writer.startSession(atSourceTime: pts)
            writerSessionStarted = true
            onFirstPTS?(pts)
            startContinuation?.resume(returning: ())
            startContinuation = nil
        }
        guard input.isReadyForMoreMediaData, writer.status == .writing else { return }

        if processingOptions.enableProcessing || processingOptions.linearGain != 1.0 {
            if let processed = process(sampleBuffer) {
                _ = input.append(processed)
            } else {
                _ = input.append(sampleBuffer)
            }
        } else {
            _ = input.append(sampleBuffer)
        }
    }

    private func process(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        let asbd = asbdPtr.pointee
        let channels = Int(asbd.mChannelsPerFrame)
        let bits = Int(asbd.mBitsPerChannel)
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>? = nil
        let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == noErr, let basePtr = dataPointer, totalLength > 0 else { return nil }

        // Copy samples into new buffer we can modify safely
        let byteCount = totalLength
        let newData = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<Int16>.alignment)
        newData.copyMemory(from: UnsafeRawPointer(basePtr), byteCount: byteCount)

        // Apply gain/AGC/limiter in-place
        let gainLinearBase: Float = max(0.0, processingOptions.linearGain)
        let enableAGC = processingOptions.enableAGC
        let targetRMS = max(1e-4, min(0.9, processingOptions.agcTargetRMS))
        let maxAGCLinear = powf(10.0, processingOptions.agcMaxGainDb / 20.0)
        let enableLimiter = processingOptions.enableLimiter

        if bits == 16 {
            let samples = newData.bindMemory(to: Int16.self, capacity: byteCount / 2)
            let frameCount = (byteCount / 2) / max(1, channels)

            // Compute RMS per buffer (use first channel)
            var rmsAccum: Double = 0
            for i in 0..<frameCount {
                let s = Float(samples[i * channels]) / Float(Int16.max)
                rmsAccum += Double(s * s)
            }
            let rms = sqrt(rmsAccum / Double(max(1, frameCount)))

            var agcGain: Float = 1.0
            if enableAGC {
                let desired = Float(targetRMS) / max(1e-6, Float(rms))
                agcGain = min(maxAGCLinear, desired)
                // Smooth the AGC gain to avoid pumping
                let alpha: Float = 0.1
                agcSmoothedGain = alpha * agcGain + (1 - alpha) * agcSmoothedGain
                agcGain = agcSmoothedGain
            }
            let totalGain = max(0.0, gainLinearBase) * agcGain

            for i in 0..<(frameCount * channels) {
                let x = Float(samples[i]) / Float(Int16.max)
                var y = x * totalGain
                if enableLimiter {
                    // simple soft clip
                    y = tanh(y * 2.0)
                }
                let clamped = max(-1.0, min(1.0, y))
                samples[i] = Int16(clamped * Float(Int16.max))
            }
        } else if bits == 32 {
            // Assume 32-bit float
            let samples = newData.bindMemory(to: Float.self, capacity: byteCount / 4)
            let frameCount = (byteCount / 4) / max(1, channels)

            var rmsAccum: Double = 0
            for i in 0..<frameCount {
                let s = samples[i * channels]
                rmsAccum += Double(s * s)
            }
            let rms = sqrt(rmsAccum / Double(max(1, frameCount)))

            var agcGain: Float = 1.0
            if enableAGC {
                let desired = Float(targetRMS) / max(1e-6, Float(rms))
                agcGain = min(maxAGCLinear, desired)
                let alpha: Float = 0.1
                agcSmoothedGain = alpha * agcGain + (1 - alpha) * agcSmoothedGain
                agcGain = agcSmoothedGain
            }
            let totalGain = max(0.0, gainLinearBase) * agcGain

            for i in 0..<(frameCount * channels) {
                var y = samples[i] * totalGain
                if enableLimiter {
                    y = tanh(y * 2.0)
                }
                samples[i] = max(-1.0, min(1.0, y))
            }
        } else {
            // Unsupported format - fallback
            newData.deallocate()
            return nil
        }

        // Build new CMBlockBuffer / CMSampleBuffer with modified data
        var newBlock: CMBlockBuffer? = nil
        var status2 = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: newData,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &newBlock
        )
        guard status2 == kCMBlockBufferNoErr, let newBlockUnwrapped = newBlock else {
            newData.deallocate()
            return nil
        }

        var newSample: CMSampleBuffer? = nil
        var timingInfoCount: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingInfoCount)
        var timingInfo = [CMSampleTimingInfo](repeating: .init(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: timingInfoCount)
        if timingInfoCount > 0 {
            CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: timingInfoCount, arrayToFill: &timingInfo, entriesNeededOut: &timingInfoCount)
        }
        status2 = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: newBlockUnwrapped,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: CMSampleBufferGetNumSamples(sampleBuffer),
            sampleTimingEntryCount: timingInfoCount,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &newSample
        )
        guard status2 == noErr, let newSampleUnwrapped = newSample else {
            return nil
        }
        return newSampleUnwrapped
    }
}
