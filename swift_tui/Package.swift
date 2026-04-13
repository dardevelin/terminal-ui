// swift-tools-version: 6.2

import PackageDescription

// MARK: - Strict compiler settings (Swift 6+)

let strictSettings: [SwiftSetting] = [
    // Strict concurrency — full actor isolation, Sendable enforcement
    .enableExperimentalFeature("StrictConcurrency"),

    // Upcoming Swift features — opt in early
    .enableUpcomingFeature("ExistentialAny"),           // require 'any' keyword for existentials
    // InternalImportsByDefault — disabled, too aggressive with @Observable macro re-exports
    // GlobalConcurrency — already enabled by default in Swift 6

    // Treat all warnings as errors
    .unsafeFlags(["-warnings-as-errors"]),
]

let package = Package(
    name: "swift_tui",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TerminalUI", targets: ["TerminalUI"]),
    ],
    targets: [
        // Shared config module — used by TerminalUI (debug-only) and swtui CLI
        .target(
            name: "TerminalUIConfig",
            path: "Sources/TerminalUIConfig",
            swiftSettings: strictSettings
        ),
        .target(
            name: "TerminalUI",
            dependencies: ["TerminalUIConfig"],
            path: "Sources/TerminalUI",
            swiftSettings: strictSettings
        ),
        // Developer CLI tool for managing .terminalui/ config
        .executableTarget(
            name: "swtui",
            dependencies: ["TerminalUIConfig"],
            path: "Sources/swtui",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "Demo",
            dependencies: ["TerminalUI"],
            path: "Examples/Demo",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "ComponentsDemo",
            dependencies: ["TerminalUI"],
            path: "Examples/ComponentsDemo",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "DotMatrixDemo",
            dependencies: ["TerminalUI"],
            path: "Examples/DotMatrixDemo",
            swiftSettings: strictSettings
        ),
    ]
)
