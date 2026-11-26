// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CallCapture",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.14.7")),
        // Hummingbird 2.29 declares swift-tools-version 6.2, so building needs Xcode 26+.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.29.0"),
        // swift-log 1.17+ uses the `@nonexhaustive` attribute, which Swift 6.2.x (Xcode 26.1) rejects.
        // Hummingbird only needs 1.14+, so cap it until the toolchain moves to 6.3.
        .package(url: "https://github.com/apple/swift-log.git", "1.14.0"..<"1.17.0")
    ],
    targets: [
        .executableTarget(
            name: "CallCapture",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Hummingbird", package: "hummingbird")
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "CallCaptureTests",
            dependencies: [
                "CallCapture",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird")
            ],
            path: "Tests/CallCaptureTests"
        )
    ]
)
