// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PortaCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "PortaCore", targets: ["PortaCore"]),
    ],
    targets: [
        .target(name: "PortaCore"),
        .testTarget(name: "PortaCoreTests", dependencies: ["PortaCore"]),
    ]
)
