// swift-tools-version: 5.7
// 说明：macOS 12 + Command Line Tools（Swift 5.7）也能直接构建；
// tools-version 5.7 在 Xcode 16 / Swift 6 下同样默认使用 Swift 5 语言模式，
// 与 CI 的行为保持一致（原先依赖 6.0 才有的 swiftLanguageMode(.v5) 显式声明）。
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
            path: "Sources/FreeRecordCore"
        ),
        .executableTarget(
            name: "FreeRecordApp",
            dependencies: ["FreeRecordCore"],
            path: "Sources/FreeRecordApp"
        ),
        .executableTarget(
            name: "FreeRecordPOC",
            dependencies: ["FreeRecordCore"],
            path: "Sources/FreeRecordPOC"
        ),
    ]
)
