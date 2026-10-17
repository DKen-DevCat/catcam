// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "catcam",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CatCore"),
        .executableTarget(name: "CatCam", dependencies: ["CatCore"]),
        .executableTarget(name: "catlib-builder", dependencies: ["CatCore"]),
        .testTarget(name: "CatCoreTests", dependencies: ["CatCore"]),
    ]
)
