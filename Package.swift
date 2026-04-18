// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftyComponents",
    platforms: [
        .iOS(.v15),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SwiftyComponents",
            targets: ["SwiftyComponents"]
        ),
        .executable(
            name: "RecordingSyncCaptureTool",
            targets: ["RecordingSyncCaptureTool"]
        ),
        .executable(
            name: "RecordingSyncTargetApp",
            targets: ["RecordingSyncTargetApp"]
        ),
        .executable(
            name: "RecordingSyncInspectionTool",
            targets: ["RecordingSyncInspectionTool"]
        ),
    ],
    targets: [
        .target(
            name: "SwiftyComponents"
        ),
        .executableTarget(
            name: "RecordingSyncCaptureTool",
            dependencies: ["SwiftyComponents"]
        ),
        .executableTarget(
            name: "RecordingSyncTargetApp",
            dependencies: ["SwiftyComponents"]
        ),
        .executableTarget(
            name: "RecordingSyncInspectionTool",
            dependencies: ["SwiftyComponents"]
        ),
        .testTarget(
            name: "SwiftyComponentsTests",
            dependencies: ["SwiftyComponents"]
        ),
    ]
)
