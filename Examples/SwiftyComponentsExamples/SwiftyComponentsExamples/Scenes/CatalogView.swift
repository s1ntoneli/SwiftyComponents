import SwiftUI

struct CatalogView: View {
    struct DemoRoute: Hashable { let demoID: String }
    @State private var search: String = ""
    @State private var path: [DemoRoute] = []
    let initialDemoID: String?
    let initialVariantID: String?

    init(initialDemoID: String? = nil, initialVariantID: String? = nil) {
        self.initialDemoID = initialDemoID
        self.initialVariantID = initialVariantID
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Catalog.Title")
                .searchable(text: $search)
                .onAppear(perform: navigateIfNeeded)
        }
        .accessibilityIdentifier("Catalog.Root")
    }

    private var filteredGroups: [ComponentGroup] {
        guard !search.isEmpty else { return ComponentRegistry.groups }
        let text = search.lowercased()
        return ComponentRegistry.groups.compactMap { group in
            let demos = group.demos.filter { d in
                d.title.lowercased().contains(text) || d.summary.lowercased().contains(text)
            }
            return demos.isEmpty ? nil : ComponentGroup(id: group.id, title: group.title, demos: demos)
        }
    }

    @ViewBuilder
    private var content: some View {
        List {
            ForEach(filteredGroups) { group in
                Section(group.title) {
                    ForEach(group.demos) { demo in
                        NavigationLink(value: CatalogView.DemoRoute(demoID: demo.id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(demo.title)
                                    .font(.headline)
                                Text(demo.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("Catalog.Row.\(demo.id)")
                    }
                }
            }
        }
        .navigationDestination(for: DemoRoute.self) { route in
            if let demo = ComponentRegistry.groups.flatMap({ $0.demos }).first(where: { $0.id == route.demoID }) {
                DemoPage(demo: demo, selectedVariantID: initialVariantID)
            } else {
                Text("Demo 不存在")
            }
        }
    }

    private func navigateIfNeeded() {
        guard let id = initialDemoID else { return }
        // 找到对应 Demo 并推入导航栈，便于 UI 测试直接进入组件页
        if let demo = ComponentRegistry.groups.flatMap({ $0.demos }).first(where: { $0.id == id }) {
            // 避免重复推入
            if path.isEmpty { path = [DemoRoute(demoID: demo.id)] }
        }
    }
}
