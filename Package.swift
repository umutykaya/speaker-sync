// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "speaker-sync",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.28.1"),
    ],
    targets: [
        .target(
            name: "AudioEngine",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        .executableTarget(name: "ssync-poc", dependencies: ["AudioEngine"]),
        .executableTarget(
            name: "ssyncd",
            dependencies: [
                "AudioEngine",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .testTarget(name: "ssyncdTests", dependencies: ["ssyncd"]),
    ],
    swiftLanguageModes: [.v5]
)
