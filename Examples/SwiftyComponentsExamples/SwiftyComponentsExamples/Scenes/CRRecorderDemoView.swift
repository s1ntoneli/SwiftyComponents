import SwiftUI
import SwiftyComponents

struct CRRecorderDemoView: View {
    @State private var lastFiles: [String] = []
    @State private var showResult: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScreenRecorderControl { result in
                lastFiles = result.bundleInfo.files.map { $0.filename }
                showResult = true
            }
            .accessibilityIdentifier("CRRecorder.Demo.Control")

            if showResult {
                Divider()
                Text("Saved Files (含时长):")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lastFiles, id: \.self) { name in
                        HStack(spacing: 8) {
                            Text(name)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let secs = parseDuration(from: name) {
                                Text("(\(secs)s)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                .accessibilityIdentifier("CRRecorder.Demo.Result")
            }
            Spacer()
        }
        .padding()
        .accessibilityIdentifier("CRRecorder.Demo.View")
    }
}

#Preview("Demo") {
    CRRecorderDemoView()
        .frame(width: 640, height: 400)
}

// MARK: - Helpers
private func parseDuration(from filename: String) -> Int? {
    // Match "-<secs>s" before extension
    // e.g. screen-...-13s.mov => 13
    guard let range = filename.range(of: "-\\d+s", options: .regularExpression) else { return nil }
    let token = filename[range] // like "-13s"
    let digits = token.dropFirst().dropLast() // "13"
    return Int(digits)
}
