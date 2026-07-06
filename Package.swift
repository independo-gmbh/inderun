// swift-tools-version: 5.9
import PackageDescription

// This manifest lives at the repository root so the IndeRun Swift SDK is
// consumable via Swift Package Manager by URL + git tag, e.g.:
//   .package(url: "https://github.com/independo-gmbh/inderun.git", from: "0.1.0")
// The sources remain under ios/IndeRun/, referenced explicitly via `path:`.
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
            dependencies: [],
            path: "ios/IndeRun/Sources/IndeRunContracts"
        ),
        .target(
            name: "IndeRunSwift",
            dependencies: ["IndeRunCore", "IndeRunContracts"],
            path: "ios/IndeRun/Sources/IndeRunSwift"
        ),
        .target(
            name: "IndeRunCore",
            dependencies: ["IndeRunContracts"],
            path: "ios/IndeRun/Sources/IndeRunCore"
        ),
        .target(
            name: "IndeRunAppleProviders",
            dependencies: ["IndeRunCore", "IndeRunContracts"],
            path: "ios/IndeRun/Sources/IndeRunAppleProviders"
        ),
        .target(
            name: "IndeRunOpenAIProviders",
            dependencies: ["IndeRunCore", "IndeRunContracts"],
            path: "ios/IndeRun/Sources/IndeRunOpenAIProviders"
        ),
        .testTarget(
            name: "IndeRunTests",
            dependencies: ["IndeRunSwift", "IndeRunContracts", "IndeRunCore", "IndeRunAppleProviders", "IndeRunOpenAIProviders"],
            path: "ios/IndeRun/Tests/IndeRunTests"
        )
    ]
)
