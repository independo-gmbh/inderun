// swift-tools-version: 5.9
import PackageDescription

// This manifest lives at the repository root so the IndeRun Swift SDK is
// consumable via Swift Package Manager by URL + git tag, e.g.:
//   .package(url: "https://github.com/independo-gmbh/inderun.git", from: "0.1.0")
// The sources remain under ios/IndeRun/, referenced explicitly via `path:`.
let package = Package(
    name: "IndeRun",
    platforms: [
        .iOS(.v16),
        .macOS(.v14)
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
        ),
        .library(
            name: "IndeRunOnnxProviders",
            targets: ["IndeRunOnnxProviders"]
        )
    ],
    dependencies: [
        // ONNX Runtime C/Objective-C bindings for the Apple ONNX Runtime provider family member.
        // macOS 14 / iOS 16 (this package's platform minimums) are required by this dependency.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.24.2"),
        // Hugging Face tokenizer parsing, used by the default ONNX runtime to tokenize model input
        // without hand-rolling a tokenizer implementation.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3")
    ],
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
        .target(
            name: "IndeRunOnnxProviders",
            dependencies: [
                "IndeRunCore",
                "IndeRunContracts",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            path: "ios/IndeRun/Sources/IndeRunOnnxProviders"
        ),
        .testTarget(
            name: "IndeRunTests",
            dependencies: [
                "IndeRunSwift",
                "IndeRunContracts",
                "IndeRunCore",
                "IndeRunAppleProviders",
                "IndeRunOpenAIProviders",
                "IndeRunOnnxProviders"
            ],
            path: "ios/IndeRun/Tests/IndeRunTests"
        )
    ]
)
