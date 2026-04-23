// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AlchemyKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "AlchemyKit",
            targets: ["AlchemyKit"]
        ),
    ],
    targets: [
        .target(
            name: "AlchemyKit"
        ),
        .testTarget(
            name: "AlchemyKitTests",
            dependencies: ["AlchemyKit"]
        ),
    ]
)

