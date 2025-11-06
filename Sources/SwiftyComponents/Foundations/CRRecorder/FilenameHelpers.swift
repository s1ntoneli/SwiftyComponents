import Foundation

// Internal helper to append duration to the filename and rename the file on disk.
// e.g. "/path/screen-2025-11-03_12-00-00.mov" + 12.6s
//   => "/path/screen-2025-11-03_12-00-00-13s.mov"
@inline(__always)
func renameFileAddingDuration(url: URL, seconds: TimeInterval) -> URL {
    let sec = max(0, Int(round(seconds)))
    guard sec > 0 else { return url }

    let dir = url.deletingLastPathComponent()
    let ext = url.pathExtension
    let stem = url.deletingPathExtension().lastPathComponent
    var candidate = dir.appendingPathComponent("\(stem)-\(sec)s").appendingPathExtension(ext)

    // Ensure uniqueness if needed
    var counter = 1
    let fm = FileManager.default
    while fm.fileExists(atPath: candidate.path) {
        candidate = dir.appendingPathComponent("\(stem)-\(sec)s (\(counter))").appendingPathExtension(ext)
        counter += 1
    }

    do {
        try fm.moveItem(at: url, to: candidate)
        return candidate
    } catch {
        // If renaming fails, return the original URL.
        return url
    }
}

