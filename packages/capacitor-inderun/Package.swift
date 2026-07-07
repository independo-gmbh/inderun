// swift-tools-version: 5.9
import PackageDescription

// The IndeRun Swift SDK now lives at the monorepo root (../..). This manifest
// is used for local development/testing of the Capacitor bridge. The bridge is
// distributed to Capacitor apps via npm; iOS integration is handled by
// Capacitor's SwiftPM support. Capacitor publishing is tracked separately.

let package = Package(
    name: "IndeRunCapacitor",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "IndeRunCapacitor",
            targets: ["IndeRunCapacitorPlugin"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0"),
        .package(path: "../..") // IndeRun Swift SDK (repo-root Package.swift)
    ],
    targets: [
        .target(
            name: "IndeRunCapacitorPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm", condition: .when(platforms: [.iOS])),
                .product(name: "IndeRun", package: "IndeRun"),
                .product(name: "IndeRunCore", package: "IndeRun"),
                .product(name: "IndeRunAppleProviders", package: "IndeRun"),
                .product(name: "IndeRunOpenAIProviders", package: "IndeRun")
            ],
            path: "ios/Sources/IndeRunCapacitorPlugin"
        ),
        .testTarget(
            name: "IndeRunCapacitorTests",
            dependencies: [
                .target(name: "IndeRunCapacitorPlugin"),
                .product(name: "IndeRun", package: "IndeRun"),
                .product(name: "IndeRunCore", package: "IndeRun"),
                .product(name: "IndeRunContracts", package: "IndeRun")
            ],
            path: "ios/Tests/IndeRunCapacitorTests"
        )
    ]
)
