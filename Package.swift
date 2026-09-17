// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleFM",
    // PackageDescription 6.0 does not yet expose .v26; API use is guarded in the library.
    platforms: [.macOS(.v15)],
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
