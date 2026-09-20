// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleFM",
    // FoundationModels is availability-guarded in the library; clients can use
    // AppleFM availability and the legacy JSON API on macOS 14 and later.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppleFM", targets: ["AppleFM"]),
        .executable(name: "apple-fm-helper", targets: ["apple-fm-helper"])
    ],
    targets: [
        .target(name: "AppleFM"),
        .executableTarget(name: "apple-fm-helper", dependencies: ["AppleFM"]),
        .testTarget(name: "AppleFMTests", dependencies: ["AppleFM"])
    ]
)
