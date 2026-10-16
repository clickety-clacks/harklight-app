// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarklightNativeRelay",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "HarklightNativeRelay", targets: ["HarklightNativeRelay"])],
    dependencies: [.package(path: "../AttentionDomain")],
    targets: [
        .target(name: "HarklightNativeRelay", dependencies: [
            .product(name: "AttentionDomain", package: "AttentionDomain")
        ]),
        .testTarget(name: "HarklightNativeRelayTests", dependencies: ["HarklightNativeRelay", "AttentionDomain"])
    ]
)
