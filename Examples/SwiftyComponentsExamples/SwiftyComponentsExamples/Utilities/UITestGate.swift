import Foundation

enum UITestGate {
    static var isUITest: Bool {
        ProcessInfo.processInfo.arguments.contains("UI_TEST")
    }

    static func argument(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i+1 < args.count else { return nil }
        return args[i+1]
    }
}

