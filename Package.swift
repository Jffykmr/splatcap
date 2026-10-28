// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SplatcapCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "SplatcapCore", targets: ["SplatcapCore"])],
    targets: [
        .target(name: "SplatcapCore"),
        .testTarget(name: "SplatcapCoreTests", dependencies: ["SplatcapCore"]),
    ]
)
