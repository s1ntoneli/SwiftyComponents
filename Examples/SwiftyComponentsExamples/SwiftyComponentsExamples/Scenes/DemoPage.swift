import SwiftUI

struct DemoPage: View {
    let demo: ComponentDemo
    @State var selectedVariantID: String?

    var body: some View {
        let current = demo.variants.first { $0.id == (selectedVariantID ?? demo.defaultVariantID) } ?? demo.variants.first!
        DemoHarness(title: demo.title) {
            current.makeView()
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Menu("变体") {
                    ForEach(demo.variants) { v in
                        Button(v.title) { selectedVariantID = v.id }
                            .accessibilityIdentifier("Harness.Variant.\(v.id)")
                    }
                }
                .accessibilityIdentifier("Harness.VariantsMenu")
            }
        }
        .onAppear {
            if selectedVariantID == nil { selectedVariantID = demo.defaultVariantID }
        }
        .accessibilityIdentifier("DemoPage.Root.\(demo.id)")
    }
}

