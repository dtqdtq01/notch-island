// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NotchIsland",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotchIsland", targets: ["NotchIsland"]),
        .executable(name: "notch-bridge", targets: ["notch-bridge"]),
    ],
    targets: [
        .target(name: "NotchShared"),
        .executableTarget(name: "notch-bridge", dependencies: ["NotchShared"]),
        .executableTarget(name: "NotchIsland", dependencies: ["NotchShared"]),
        .testTarget(name: "NotchIslandTests", dependencies: ["NotchIsland", "NotchShared"]),
    ]
)
