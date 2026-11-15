// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleFM",
    // FoundationModels is availability-guarded in the library; clients can use
    // AppleFM availability and the legacy JSON API on macOS 14 and later.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppleFM", targets: ["AppleFM"]),
        .executable(name: "apple-fm-helper", targets: ["apple-fm-helper"]),
        .executable(name: "apple-fm-acp", targets: ["apple-fm-acp"])
    ],
    targets: [
        .target(name: "AppleFM"),
        .executableTarget(name: "apple-fm-helper", dependencies: ["AppleFM"]),
        .testTarget(name: "AppleFMTests", dependencies: ["AppleFM"]),
        // ACP protocol handling, with no Apple SDK imports so it can be tested without the model.
        .target(name: "ACPAgent"),
        .executableTarget(name: "apple-fm-acp", dependencies: ["AppleFM", "ACPAgent"]),
        .testTarget(name: "ACPAgentTests", dependencies: ["ACPAgent"])
    ]
)
