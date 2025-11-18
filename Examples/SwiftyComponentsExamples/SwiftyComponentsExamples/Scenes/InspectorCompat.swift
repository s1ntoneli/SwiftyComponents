import SwiftUI

/// 兼容 macOS / iOS 的简单 Inspector 包装。
///
/// - macOS 13+ / iOS 16+：使用 `inspector(isPresented:)`
/// - 旧系统：回退为 sheet
struct DemoInspectorCompat<InspectorContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let content: () -> InspectorContent

    func body(content host: Content) -> some View {
        #if os(macOS)
        if #available(macOS 13.0, *) {
            host.inspector(isPresented: $isPresented, content: self.content)
        } else {
            host.sheet(isPresented: $isPresented, content: self.content)
        }
        #else
        if #available(iOS 16.0, *) {
            host.inspector(isPresented: $isPresented, content: self.content)
        } else {
            host.sheet(isPresented: $isPresented, content: self.content)
        }
        #endif
    }
}

extension View {
    func demoInspector<InspectorContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> InspectorContent
    ) -> some View {
        modifier(DemoInspectorCompat(isPresented: isPresented, content: content))
    }
}

