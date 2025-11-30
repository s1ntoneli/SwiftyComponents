import SwiftUI
import SwiftyComponents

#if os(macOS)
import AppKit
import CoreGraphics
import AVFoundation

struct AVScreenRecorderDemoView: View {
    private enum Mode: String, CaseIterable {
        case display = "Display"
        case window = "Window"
    }

    private struct DisplayItem: Identifiable {
        let id: CGDirectDisplayID
        let name: String
    }

    private struct WindowItem: Identifiable {
        let id: CGWindowID
        let title: String
        let bounds: CGRect
    }

    @State private var recorder: AVScreenRecorder?
    @State private var isRecording: Bool = false
    @State private var isBusy: Bool = false
    @State private var outputDirectory: URL = Self.defaultOutputDirectory()
    @State private var fileName: String = "av-capture"
    @State private var lastResult: AVScreenRecorder.Result?
    @State private var errorMessage: String?

    // Capture mode & targets
    @State private var mode: Mode = .display
    @State private var displays: [DisplayItem] = []
    @State private var selectedDisplayID: CGDirectDisplayID? = nil
    @State private var windows: [WindowItem] = []
    @State private var selectedWindowID: CGWindowID? = nil

    // Crop rect (manual area)
    @State private var useCropRect: Bool = false
    @State private var cropXText: String = ""
    @State private var cropYText: String = ""
    @State private var cropWidthText: String = ""
    @State private var cropHeightText: String = ""

    // Audio capture (microphone / loopback / etc.)
    @State private var includeAudio: Bool = false
    @State private var audioDevices: [AVCaptureDevice] = []
    @State private var selectedAudioDeviceID: String? = nil  // nil = system default

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            outputControls
            modeControls
            targetSelection
            cropControls
            audioControls
            recordingControls
            resultSection
            Spacer()
        }
        .padding()
        .accessibilityIdentifier("AVScreenRecorderDemo.View")
        .onAppear {
            reloadDisplays()
            reloadWindows()
            reloadAudioDevices()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("AV Screen Recorder (AVCaptureScreenInput)")
                .font(.headline)
            statusDot(isOn: isRecording, label: isRecording ? "Recording" : "Idle")
            Spacer()
        }
    }

    private var outputControls: some View {
        HStack(spacing: 8) {
            Text(outputDirectory.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("AVScreenRecorderDemo.OutputPath")
            Spacer()
            Button("Choose Folder…", action: chooseFolder)
                .accessibilityIdentifier("AVScreenRecorderDemo.ChooseFolder")
            Button("Open Folder", action: openFolder)
                .accessibilityIdentifier("AVScreenRecorderDemo.OpenFolder")
        }
    }

    private var modeControls: some View {
        HStack(spacing: 8) {
            Text("Mode:")
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Spacer()
            Button("Refresh") {
                reloadDisplays()
                reloadWindows()
            }
            .buttonStyle(.bordered)
        }
    }

    private var targetSelection: some View {
        Group {
            if mode == .display {
                HStack(spacing: 8) {
                    Text("Display:")
                    Picker("Display", selection: Binding(
                        get: {
                            selectedDisplayID ?? displays.first?.id ?? CGMainDisplayID()
                        },
                        set: { newValue in
                            selectedDisplayID = newValue
                            updateCropDefaultsForCurrentDisplay()
                        }
                    )) {
                        ForEach(displays) { item in
                            Text(item.name).tag(item.id)
                        }
                    }
                    .frame(minWidth: 260)
                }
            } else {
                HStack(spacing: 8) {
                    Text("Window:")
                    Picker("Window", selection: Binding(
                        get: {
                            selectedWindowID ?? windows.first?.id
                        },
                        set: { newValue in
                            selectedWindowID = newValue
                        }
                    )) {
                        ForEach(windows) { item in
                            Text(item.title).tag(item.id as CGWindowID?)
                        }
                    }
                    .frame(minWidth: 320)
                }
            }
        }
    }

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Use crop rect (x, y, width, height)", isOn: $useCropRect)
            HStack(spacing: 6) {
                TextField("x", text: $cropXText)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                TextField("y", text: $cropYText)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                TextField("width", text: $cropWidthText)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                TextField("height", text: $cropHeightText)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Coordinates are in screen points; origin is bottom-left of the selected display.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Include audio", isOn: $includeAudio)
            if includeAudio {
                HStack(spacing: 8) {
                    Text("Input:")
                    Picker("Input", selection: Binding(
                        get: { selectedAudioDeviceID ?? "default" },
                        set: { newValue in
                            selectedAudioDeviceID = (newValue == "default") ? nil : newValue
                        }
                    )) {
                        Text("System default").tag("default")
                        ForEach(audioDevices, id: \.uniqueID) { d in
                            Text(d.localizedName).tag(d.uniqueID)
                        }
                    }
                    .frame(minWidth: 240)
                }
                Text("Choose a loopback device here if you want pure system audio; choose a microphone to include mic.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("AVScreenRecorderDemo.Audio")
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("File name (no extension)", text: $fileName)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                Spacer()
                Button(action: startRecording) {
                    Text("Start")
                }
                .disabled(isRecording || isBusy)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("AVScreenRecorderDemo.Start")

                Button(action: stopRecording) {
                    Text("Stop")
                }
                .disabled(!isRecording || isBusy)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("AVScreenRecorderDemo.Stop")
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(Color.red)
                    .font(.caption)
            }
        }
    }

    private var resultSection: some View {
        Group {
            if let result = lastResult {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last Recording")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(result.fileURL.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let dims = result.videoDimensions {
                        Text("Size: \(Int(dims.width))x\(Int(dims.height))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    let duration = result.endTimestamp - result.startTimestamp
                    Text(String(format: "Duration: %.2fs", duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([result.fileURL])
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("AVScreenRecorderDemo.Reveal")
                }
                .textSelection(.enabled)
                .accessibilityIdentifier("AVScreenRecorderDemo.Result")
            }
        }
    }

    // MARK: - Actions

    private func startRecording() {
        guard !isRecording, !isBusy else { return }
        isBusy = true
        errorMessage = nil

        Task {
            let displayID = resolveDisplayIDForCurrentSelection()
            let cropRect = resolveCropRectForCurrentSelection(displayID: displayID)

            let config = AVScreenRecorder.Configuration(
                displayID: displayID,
                cropRect: cropRect,
                showsCursor: true,
                capturesMouseClicks: false,
                fps: 30,
                includeAudio: includeAudio,
                audioDeviceUniqueID: selectedAudioDeviceID
            )
            let recorder = AVScreenRecorder(configuration: config)
            self.recorder = recorder
            let url = outputDirectory.appendingPathComponent(fileName).appendingPathExtension("mov")
            do {
                try await recorder.startRecording(to: url)
                isRecording = true
                isBusy = false
            } catch {
                isRecording = false
                isBusy = false
                self.recorder = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func stopRecording() {
        guard let recorder, isRecording, !isBusy else { return }
        isBusy = true
        errorMessage = nil

        Task {
            do {
                let result = try await recorder.stopRecording()
                lastResult = result
                isRecording = false
                isBusy = false
                self.recorder = nil
            } catch {
                isRecording = false
                isBusy = false
                self.recorder = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.title = "Choose Output Folder"
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
        }
    }

    private func openFolder() {
        NSWorkspace.shared.open(outputDirectory)
    }

    private static func defaultOutputDirectory() -> URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    // MARK: - Helpers (targets & crop)

    private func reloadDisplays() {
        var count: UInt32 = 0
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        let err = CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &count)
        if err != .success || count == 0 {
            let mainID = CGMainDisplayID()
            let bounds = CGDisplayBounds(mainID)
            displays = [
                DisplayItem(
                    id: mainID,
                    name: "Display #\(mainID) (\(Int(bounds.width))x\(Int(bounds.height)))"
                )
            ]
            selectedDisplayID = mainID
            updateCropDefaultsForCurrentDisplay()
            return
        }

        let ids = displayIDs.prefix(Int(count))
        displays = ids.map { id in
            let bounds = CGDisplayBounds(id)
            return DisplayItem(
                id: id,
                name: "Display #\(id) (\(Int(bounds.width))x\(Int(bounds.height)))"
            )
        }
        if selectedDisplayID == nil {
            selectedDisplayID = ids.first
        }
        updateCropDefaultsForCurrentDisplay()
    }

    private func reloadAudioDevices() {
        audioDevices = AVCaptureDevice.devices(for: .audio)
        if selectedAudioDeviceID == nil {
            selectedAudioDeviceID = nil
        }
    }

    private func reloadWindows() {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else {
            windows = []
            selectedWindowID = nil
            return
        }

        var items: [WindowItem] = []
        for info in infoList {
            // Only normal windows
            if let layer = info[kCGWindowLayer as String] as? Int, layer != 0 {
                continue
            }
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            let windowID = CGWindowID(number.uint32Value)
            let ownerName = info[kCGWindowOwnerName as String] as? String ?? "App"
            let windowName = info[kCGWindowName as String] as? String
            let title: String
            if let windowName, !windowName.isEmpty {
                title = "\(ownerName) – \(windowName)"
            } else {
                title = ownerName
            }
            guard
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else {
                continue
            }
            items.append(WindowItem(id: windowID, title: title, bounds: bounds))
        }
        windows = items
        if selectedWindowID == nil {
            selectedWindowID = items.first?.id
        }
    }

    private func updateCropDefaultsForCurrentDisplay() {
        guard let displayID = selectedDisplayID ?? displays.first?.id else { return }
        let bounds = CGDisplayBounds(displayID)
        cropXText = String(Int(bounds.origin.x))
        cropYText = String(Int(bounds.origin.y))
        cropWidthText = String(Int(bounds.width))
        cropHeightText = String(Int(bounds.height))
    }

    private func resolveDisplayIDForCurrentSelection() -> CGDirectDisplayID {
        switch mode {
        case .display:
            return selectedDisplayID ?? displays.first?.id ?? CGMainDisplayID()
        case .window:
            guard let windowItem = windows.first(where: { $0.id == selectedWindowID }) ?? windows.first else {
                return CGMainDisplayID()
            }
            let rect = windowItem.bounds
            var displayIDs = [CGDirectDisplayID](repeating: 0, count: 8)
            var count: UInt32 = 0
            let err = CGGetDisplaysWithRect(rect, UInt32(displayIDs.count), &displayIDs, &count)
            if err == .success, count > 0 {
                return displayIDs[0]
            } else {
                return CGMainDisplayID()
            }
        }
    }

    private func resolveCropRectForCurrentSelection(displayID: CGDirectDisplayID) -> CGRect? {
        switch mode {
        case .display:
            guard useCropRect else { return nil }
            guard
                let x = Double(cropXText),
                let y = Double(cropYText),
                let w = Double(cropWidthText),
                let h = Double(cropHeightText),
                w > 0, h > 0
            else {
                return nil
            }
            return CGRect(x: x, y: y, width: w, height: h)
        case .window:
            guard let windowItem = windows.first(where: { $0.id == selectedWindowID }) ?? windows.first else {
                return nil
            }
            // For window mode, crop to the window's bounds on the corresponding display.
            return windowItem.bounds
        }
    }

    private func statusDot(isOn: Bool, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isOn ? Color.red : Color.gray)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("AVScreenRecorderDemo.Status")
    }
}

#Preview("AV Screen Recorder Demo") {
    AVScreenRecorderDemoView()
        .frame(width: 640, height: 360)
}

#endif
