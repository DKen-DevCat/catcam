// swift-tools-version:5.10
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "catcam",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CatCore"),
        .executableTarget(
            name: "CatCam",
            dependencies: ["CatCore"],
            // .app に包まずに Info.plist を効かせる。リアクションのジェスチャー検出（CPU を大きく食う）を既定でオフにするため
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "\(root)/Support/Info.plist"])]
        ),
        .executableTarget(name: "catlib-builder", dependencies: ["CatCore"]),
        .testTarget(name: "CatCoreTests", dependencies: ["CatCore"]),
    ]
)
