import SwiftUI

struct DemoHarness<Content: View>: View {
    @State private var colorScheme: ColorScheme? = nil // nil = 跟随系统
    @State private var layoutDirection: LayoutDirection = .leftToRight
    @State private var highContrast: Bool = false
    @State private var reduceMotion: Bool = UITestGate.isUITest

    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(title)
        .toolbar { toolbar }
        .environment(\.layoutDirection, layoutDirection)
        .preferredColorScheme(colorScheme)
        // Harness 自定义环境，供 Demo/组件选择性读取
        .environment(\.harnessReduceMotion, reduceMotion)
        .environment(\.harnessHighContrast, highContrast)
        // 在 Harness 层统一调整 Transaction，减少动效
        .transaction { txn in if reduceMotion { txn.animation = nil } }
        .accessibilityIdentifier("Harness.Root")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Menu("主题") {
                Button("系统") { colorScheme = nil }
                Button("浅色") { colorScheme = .light }
                Button("深色") { colorScheme = .dark }
            }
            .accessibilityIdentifier("Harness.Theme")

            Menu("布局") {
                Button("从左到右") { layoutDirection = .leftToRight }
                Button("从右到左") { layoutDirection = .rightToLeft }
            }
            .accessibilityIdentifier("Harness.Layout")

            Toggle(isOn: $highContrast) { Text("高对比") }
                .accessibilityIdentifier("Harness.HighContrast")

            Toggle(isOn: $reduceMotion) { Text("少动效") }
                .accessibilityIdentifier("Harness.ReduceMotion")
        }
    }
}
