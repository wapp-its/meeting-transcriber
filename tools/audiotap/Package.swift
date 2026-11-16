// swift-tools-version: 6.2
import PackageDescription

// The same gate the app package runs under. `treatAllWarnings(as:)` is what
// pins the manifest to tools-version 6.2; it does not exist in 6.0.
//
// One caveat, because the failure is not obvious from the error text: Xcode
// passes `-suppress-warnings` to any package it builds as a dependency, and
// that conflicts outright with the `-warnings-as-errors` below, so an
// `xcodebuild` of the app fails on this target before compiling anything.
// Build it with `SWIFT_SUPPRESS_WARNINGS=NO`, as CI's analyze job does.
// `swift build` and `swift test` are unaffected, which is every other path
// the repo uses, the release build included.
let strictSwiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    // `unsafeFlags` is legal only because the app consumes this library by
    // path; SwiftPM rejects it in a package resolved from a URL.
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=300",
        "-Xfrontend", "-warn-long-expression-type-checking=300",
    ]),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "AudioTapLib",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AudioTapLib", targets: ["AudioTapLib"]),
    ],
    targets: [
        // Objective-C shim that bridges NSExceptions (e.g. from
        // installTapOnBus) into Swift-catchable NSErrors. See header.
        .target(
            name: "CExceptionCatcher",
            path: "Sources/CExceptionCatcher"
        ),
        // Lock-free level cell the device meters' real-time callbacks write
        // (`DeviceLevelMeter`). C11 atomics, because `Synchronization.Atomic`
        // needs macOS 15. The flag turns a blocking call inside a function
        // marked nonblocking into a build error. See header.
        .target(
            name: "CLevelCell",
            path: "Sources/CLevelCell",
            cSettings: [.unsafeFlags(["-Werror=function-effects"])]
        ),
        .target(
            name: "AudioTapLib",
            dependencies: ["CExceptionCatcher", "CLevelCell"],
            path: "Sources",
            exclude: ["CExceptionCatcher", "CLevelCell"],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "AudioTapLibTests",
            dependencies: ["AudioTapLib", "CExceptionCatcher"],
            path: "Tests",
            swiftSettings: strictSwiftSettings
        ),
    ]
)
