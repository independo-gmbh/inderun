// swift-tools-version: 5.9
import PackageDescription

// MARK: - Pre-publish requirement
// The IndeRun iOS SDK (ios/IndeRun/) must be extracted to a dedicated git
// repository before this package is distributable via SPM.
// Replace the local path dependency below with:
//   .package(url: "https://github.com/independo-gmbh/inderun-ios.git", from: "1.0.0"),
// and update the .product(name:package:) references to use that package name.
// Tracking: issue #23

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
        .package(path: "../../ios/IndeRun") // TODO: replace with URL before publishing (see above)
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
