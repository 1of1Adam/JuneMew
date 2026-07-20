// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KLineCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "KLineCore",
            targets: ["KLineCore"]
        )
    ],
    targets: [
        // 纯领域层：不 import AppKit / SwiftUI，不读系统时钟，不碰网络。
        // 所有时刻都由调用方作为参数传入 —— 这是全部可测性的基础。
        .target(
            name: "KLineCore",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "KLineCoreTests",
            dependencies: ["KLineCore"]
        )
    ]
)
