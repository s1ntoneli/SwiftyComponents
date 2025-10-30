import SwiftUI

/// Rendering styles for `WaveformView`.
/// - `.bars` draws discrete bars whose heights reflect amplitude.
/// - `.outline` draws an envelope line; `smooth=true` uses Catmull‑Rom smoothing.
/// - `.filled` draws a filled area to the baseline; `smooth=true` uses Catmull‑Rom smoothing.
public enum WaveformStyle: Equatable {
    case bars(barWidth: CGFloat = 2, spacing: CGFloat = 1, cornerRadius: CGFloat = 1)
    case outline(smooth: Bool = false, lineWidth: CGFloat = 1)
    case filled(smooth: Bool = false)
}

// Convenience factory methods intentionally omitted to avoid name collisions
