import Foundation

struct RecordingLogItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var filePath: String
    var startedAt: Date?
    var endedAt: Date?
    var clickDurationSeconds: Double?
    var videoDurationSeconds: Double?
    var offsetSeconds: Double?
    var note: String = ""
}

struct RecordingLogStore {
    let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("recording-log.json") }

    func load() -> [RecordingLogItem] {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([RecordingLogItem].self, from: data)
        } catch {
            return []
        }
    }

    func save(_ items: [RecordingLogItem]) {
        do {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Ignore errors for simplicity
        }
    }
}
