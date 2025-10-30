import SwiftUI

struct DemoVariant: Identifiable {
    let id: String
    let title: String
    let makeView: () -> AnyView
}

struct ComponentDemo: Identifiable {
    let id: String
    let title: String
    let summary: String
    let variants: [DemoVariant]

    var defaultVariantID: String? { variants.first?.id }
}

struct ComponentGroup: Identifiable {
    let id: String
    let title: String
    let demos: [ComponentDemo]
}
