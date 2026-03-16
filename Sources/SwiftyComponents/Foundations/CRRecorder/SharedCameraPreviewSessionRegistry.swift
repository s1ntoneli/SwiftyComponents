import Foundation
@preconcurrency import AVFoundation

public struct SharedCameraPreviewSessionContext {
    public let session: AVCaptureSession
    public let device: AVCaptureDevice

    public init(session: AVCaptureSession, device: AVCaptureDevice) {
        self.session = session
        self.device = device
    }
}

public final class SharedCameraPreviewSessionRegistry: @unchecked Sendable {
    public static let shared = SharedCameraPreviewSessionRegistry()

    private final class Entry {
        weak var session: AVCaptureSession?
        let device: AVCaptureDevice

        init(session: AVCaptureSession, device: AVCaptureDevice) {
            self.session = session
            self.device = device
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    private init() {}

    public func register(session: AVCaptureSession, device: AVCaptureDevice, for cameraIDs: [String]) {
        lock.lock()
        defer { lock.unlock() }

        let entry = Entry(session: session, device: device)
        for cameraID in cameraIDs where !cameraID.isEmpty {
            entries[cameraID] = entry
        }
    }

    public func unregister(cameraIDs: [String]) {
        lock.lock()
        defer { lock.unlock() }

        for cameraID in cameraIDs where !cameraID.isEmpty {
            entries.removeValue(forKey: cameraID)
        }
    }

    public func context(for cameraID: String) -> SharedCameraPreviewSessionContext? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries[cameraID], let session = entry.session else {
            entries.removeValue(forKey: cameraID)
            return nil
        }
        return SharedCameraPreviewSessionContext(session: session, device: entry.device)
    }
}

public final class SharedCameraPreviewVideoOutputRouter: @unchecked Sendable {
    public static let shared = SharedCameraPreviewVideoOutputRouter()

    private final class Forwarder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        var onSample: ((CMSampleBuffer) -> Void)?

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            onSample?(sampleBuffer)
        }
    }

    private final class VideoEntry {
        weak var session: AVCaptureSession?
        let deviceID: String
        let output: AVCaptureVideoDataOutput
        let forwarder: Forwarder
        var consumers: [UUID: (CMSampleBuffer) -> Void] = [:]

        init(session: AVCaptureSession, deviceID: String, output: AVCaptureVideoDataOutput, forwarder: Forwarder) {
            self.session = session
            self.deviceID = deviceID
            self.output = output
            self.forwarder = forwarder
        }
    }

    private let lock = NSLock()
    private var entries: [String: VideoEntry] = [:]
    private var desiredMirroringByDeviceID: [String: Bool] = [:]

    private init() {}

    @MainActor
    @discardableResult
    public func ensureOutputAttached(cameraID: String) -> Bool {
        guard let context = SharedCameraPreviewSessionRegistry.shared.context(for: cameraID) else { return false }
        let deviceID = context.device.uniqueID

        lock.lock()
        if let entry = entries[deviceID], entry.session === context.session {
            let desiredMirroring = desiredMirroringByDeviceID[deviceID] ?? false
            lock.unlock()
            applyMirroring(desiredMirroring, to: entry.output)
            return true
        }
        lock.unlock()

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]

        let forwarder = Forwarder()
        let queue = DispatchQueue(label: "com.gokoding.screensage.shared-preview-video.\(deviceID)", qos: .userInitiated)

        context.session.beginConfiguration()
        guard context.session.canAddOutput(output) else {
            context.session.commitConfiguration()
            return false
        }
        context.session.addOutput(output)
        context.session.commitConfiguration()
        output.setSampleBufferDelegate(forwarder, queue: queue)
        applyMirroring(currentDesiredMirroring(for: deviceID), to: output)

        let entry = VideoEntry(session: context.session, deviceID: deviceID, output: output, forwarder: forwarder)
        forwarder.onSample = { [weak self, weak entry] sampleBuffer in
            guard let self, let entry else { return }
            let consumers = self.currentConsumers(for: entry.deviceID)
            for consumer in consumers {
                consumer(sampleBuffer)
            }
        }

        lock.lock()
        entries[deviceID] = entry
        lock.unlock()
        return true
    }

    @MainActor
    public func setMirroring(_ isMirrored: Bool, for cameraID: String) {
        guard let deviceID = resolvedDeviceID(for: cameraID) else { return }

        lock.lock()
        desiredMirroringByDeviceID[deviceID] = isMirrored
        let output = entries[deviceID]?.output
        lock.unlock()

        if let output {
            applyMirroring(isMirrored, to: output)
        }
    }

    public func addConsumer(cameraID: String, consumerID: UUID, handler: @escaping (CMSampleBuffer) -> Void) {
        guard let deviceID = resolvedDeviceID(for: cameraID) else { return }
        lock.lock()
        entries[deviceID]?.consumers[consumerID] = handler
        lock.unlock()
    }

    public func removeConsumer(cameraID: String, consumerID: UUID) {
        guard let deviceID = resolvedDeviceID(for: cameraID) else { return }
        lock.lock()
        entries[deviceID]?.consumers.removeValue(forKey: consumerID)
        lock.unlock()
    }

    private func resolvedDeviceID(for cameraID: String) -> String? {
        if let context = SharedCameraPreviewSessionRegistry.shared.context(for: cameraID) {
            return context.device.uniqueID
        }
        lock.lock()
        defer { lock.unlock() }
        return entries[cameraID] != nil ? cameraID : nil
    }

    private func currentConsumers(for deviceID: String) -> [(CMSampleBuffer) -> Void] {
        lock.lock()
        defer { lock.unlock() }
        guard let values = entries[deviceID]?.consumers.values else { return [] }
        return Array(values)
    }

    private func currentDesiredMirroring(for deviceID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return desiredMirroringByDeviceID[deviceID] ?? false
    }

    private func applyMirroring(_ isMirrored: Bool, to output: AVCaptureVideoDataOutput) {
        guard let connection = output.connection(with: .video) else { return }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = isMirrored
        }
    }
}
