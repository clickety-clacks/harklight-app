// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AttentionDomain",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "AttentionDomain", targets: ["AttentionDomain"])],
    targets: [.target(name: "AttentionDomain")]
)
