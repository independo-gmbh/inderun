// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IndeRun",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "IndeRunContracts",
            targets: ["IndeRunContracts"]
        ),
        .library(
            name: "IndeRun",
            targets: ["IndeRunSwift"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "IndeRunContracts",
            dependencies: []
        ),
        .target(
            name: "IndeRunSwift",
            dependencies: ["IndeRunCore", "IndeRunContracts"]
        ),
        .target(
            name: "IndeRunCore",
            dependencies: ["IndeRunContracts"]
        ),
        .testTarget(
            name: "IndeRunTests",
            dependencies: ["IndeRunSwift", "IndeRunContracts", "IndeRunCore"]
        )
    ]
)
