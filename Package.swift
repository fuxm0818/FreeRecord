// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FreeRecord",
    platforms: [.macOS("12.3")],
    products: [
        .executable(name: "FreeRecord", targets: ["FreeRecordApp"]),
        .executable(name: "FreeRecordPOC", targets: ["FreeRecordPOC"]),
    ],
    targets: [
        .target(
            name: "FreeRecordCore",
            path: "Sources/FreeRecordCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "FreeRecordApp",
            dependencies: ["FreeRecordCore"],
            path: "Sources/FreeRecordApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "FreeRecordPOC",
            dependencies: ["FreeRecordCore"],
            path: "Sources/FreeRecordPOC",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
