//
//  SwiftyComponentsExamplesApp.swift
//  SwiftyComponentsExamples
//
//  Created by lixindong on 2025/10/30.
//

import SwiftUI

@main
struct SwiftyComponentsExamplesApp: App {
    private let initialDemoID = UITestGate.argument("-demo")
    private let initialVariantID = UITestGate.argument("-variant")
    var body: some Scene {
        WindowGroup {
            CatalogView(initialDemoID: initialDemoID, initialVariantID: initialVariantID)
        }
    }
}
