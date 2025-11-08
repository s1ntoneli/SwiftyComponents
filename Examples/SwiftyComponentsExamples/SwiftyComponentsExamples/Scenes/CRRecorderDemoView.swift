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
                Text("Saved Files:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lastFiles, id: \.self) { name in
                        Text(name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
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

// No helpers
