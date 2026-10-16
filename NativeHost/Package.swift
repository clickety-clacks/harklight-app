// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AttentionNativeHost",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AttentionHostBoundary", targets: ["AttentionHostBoundary"]),
        .executable(name: "AttentionForegroundHost", targets: ["AttentionForegroundHost"])
    ],
    dependencies: [.package(path: "../AttentionDomain")],
    targets: [
        .target(name: "AttentionHostBoundary", dependencies: [
            .product(name: "AttentionDomain", package: "AttentionDomain")
        ], resources: [.process("Assets")]),
        .executableTarget(name: "AttentionForegroundHost", dependencies: ["AttentionHostBoundary", "AttentionDomain"]),
        .testTarget(name: "AttentionHostBoundaryTests", dependencies: ["AttentionHostBoundary", "AttentionDomain"],
                    resources: [.copy("Fixtures")])
    ]
)
