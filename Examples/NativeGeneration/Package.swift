// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NativeGenerationExample",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "AppleFM", path: "../..")],
    targets: [
        .executableTarget(name: "NativeGenerationExample", dependencies: [
            .product(name: "AppleFM", package: "AppleFM")
        ])
    ]
)
