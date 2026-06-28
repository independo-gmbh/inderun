// swift-tools-version: 5.9
import PackageDescription

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
        .package(path: "../../ios/IndeRun")
    ],
    targets: [
        .target(
            name: "IndeRunCapacitorPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "IndeRun", package: "IndeRun"),
                .product(name: "IndeRunCore", package: "IndeRun"),
                .product(name: "IndeRunAppleProviders", package: "IndeRun"),
                .product(name: "IndeRunOpenAIProviders", package: "IndeRun")
            ],
            path: "ios/Sources/IndeRunCapacitorPlugin"
        )
    ]
)
