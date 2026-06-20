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
        ),
        .library(
            name: "IndeRunCore",
            targets: ["IndeRunCore"]
        ),
        .library(
            name: "IndeRunAppleProviders",
            targets: ["IndeRunAppleProviders"]
        ),
        .library(
            name: "IndeRunOpenAIProviders",
            targets: ["IndeRunOpenAIProviders"]
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
        .target(
            name: "IndeRunAppleProviders",
            dependencies: ["IndeRunCore", "IndeRunContracts"]
        ),
        .target(
            name: "IndeRunOpenAIProviders",
            dependencies: ["IndeRunCore", "IndeRunContracts"]
        ),
        .testTarget(
            name: "IndeRunTests",
            dependencies: ["IndeRunSwift", "IndeRunContracts", "IndeRunCore", "IndeRunAppleProviders", "IndeRunOpenAIProviders"]
        )
    ]
)
