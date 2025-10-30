import SwiftUI

private struct HarnessReduceMotionKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct HarnessHighContrastKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var harnessReduceMotion: Bool {
        get { self[HarnessReduceMotionKey.self] }
        set { self[HarnessReduceMotionKey.self] = newValue }
    }

    var harnessHighContrast: Bool {
        get { self[HarnessHighContrastKey.self] }
        set { self[HarnessHighContrastKey.self] = newValue }
    }
}

