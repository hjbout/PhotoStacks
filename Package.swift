// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PhotoStacks",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PhotoStacks", targets: ["PhotoStacks"]),
    ],
    targets: [
        .target(name: "StackCore"),
        .executableTarget(name: "PhotoStacks", dependencies: ["StackCore"]),
        .testTarget(name: "StackCoreTests", dependencies: ["StackCore"]),
    ],
    swiftLanguageModes: [.v5]
)
