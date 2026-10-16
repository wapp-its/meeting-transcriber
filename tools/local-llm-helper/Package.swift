// swift-tools-version: 6.2
import PackageDescription

// The same gate the app package runs under, like tools/mt-cli. It applies to
// this package's own targets only, never to the MLX dependencies.
let strictSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=300",
        "-Xfrontend", "-warn-long-expression-type-checking=300",
    ]),
    .enableUpcomingFeature("ExistentialAny"),
]

// The helper is its own package so the app's package never depends on MLX:
// the App Store build, the app's tests and the app's CI never compile MLX or
// need Xcode's Metal Toolchain. The three pins are exact on purpose. The
// mlx-swift and swift-transformers versions are the ones mlx-swift-lm 3.32.3
// resolves to, pinned so an update is one deliberate edit (see README.md).
let package = Package(
    name: "local-llm-helper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "local-llm-helper", targets: ["LocalLLMHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),
    ],
    targets: [
        .executableTarget(
            name: "LocalLLMHelper",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/LocalLLMHelper",
            swiftSettings: strictSwiftSettings,
        ),
        .testTarget(
            name: "LocalLLMHelperTests",
            dependencies: [
                "LocalLLMHelper",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Tests/LocalLLMHelperTests",
            swiftSettings: strictSwiftSettings,
        ),
    ],
)
