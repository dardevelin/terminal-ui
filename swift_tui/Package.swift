// swift-tools-version: 6.2

import PackageDescription
import Foundation

// MARK: - Strict compiler settings (Swift 6+)

// `-warnings-as-errors` used to live in `strictSettings` via
// `.unsafeFlags`. That propagates the policy to downstream consumers'
// builds and is forbidden for libraries on the Swift Package Index.
// Now opt-in via the `TUI_WARNINGS_AS_ERRORS` env var so this repo's
// CI keeps the strict gate while consumers don't inherit it.
let warningsAsErrors: [SwiftSetting] = ProcessInfo.processInfo
    .environment["TUI_WARNINGS_AS_ERRORS"] == "1"
    ? [.unsafeFlags(["-warnings-as-errors"])]
    : []

let strictSettings: [SwiftSetting] = [
    // Strict concurrency — full actor isolation, Sendable enforcement
    .enableExperimentalFeature("StrictConcurrency"),

    // Upcoming Swift features — opt in early
    .enableUpcomingFeature("ExistentialAny"),           // require 'any' keyword for existentials
    // InternalImportsByDefault — disabled, too aggressive with @Observable macro re-exports
    // GlobalConcurrency — already enabled by default in Swift 6
] + warningsAsErrors

let package = Package(
    name: "swift_tui",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TerminalUI", targets: ["TerminalUI"]),
        // TerminalInk: zero-dep styled-output library for tooling /
        // CLIs / non-render contexts. Standalone target so consumers
        // can use it without pulling the full TUI runtime.
        .library(name: "TerminalInk", targets: ["TerminalInk"]),
        // TerminalLog: structured logging built on TerminalInk.
        // Levels with colored prefixes, console + file sinks, ANSI
        // auto-stripping for non-TTY targets.
        .library(name: "TerminalLog", targets: ["TerminalLog"]),
    ],
    dependencies: [
        // DocC — documentation generator. Only used at `swift package generate-documentation` time.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.3.0"),
    ],
    targets: [
        // Shared config module — used by TerminalUI (debug-only) and swtui CLI
        .target(
            name: "TerminalUIConfig",
            path: "Sources/TerminalUIConfig",
            swiftSettings: strictSettings
        ),
        // TerminalInk — styled output library (color model, capability
        // detection, ANSI SGR codes). Zero deps. Used by tooling that
        // needs styled stdout/stderr without a full render runtime.
        .target(
            name: "TerminalInk",
            path: "Sources/TerminalInk",
            swiftSettings: strictSettings
        ),
        // TerminalLog — structured logging built on TerminalInk.
        // Log("scope").info/.warn/.error/etc. with colored levels,
        // console + file sinks, env-var-driven min-level filtering.
        .target(
            name: "TerminalLog",
            dependencies: ["TerminalInk"],
            path: "Sources/TerminalLog",
            swiftSettings: strictSettings
        ),
        .target(
            name: "TerminalUI",
            dependencies: ["TerminalUIConfig", "TerminalInk", "TerminalLog"],
            path: "Sources/TerminalUI",
            swiftSettings: strictSettings
        ),
        // Developer CLI tool for managing .terminalui/ config
        .executableTarget(
            name: "swtui",
            dependencies: ["TerminalUIConfig", "TerminalInk", "TerminalLog"],
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
        .executableTarget(
            name: "Storybook",
            dependencies: ["TerminalUI"],
            path: "Examples/Storybook",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "GitClient",
            dependencies: ["TerminalUI"],
            path: "Examples/GitClient",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "TerminalUITests",
            dependencies: ["TerminalUI", "TerminalUIConfig"],
            path: "Tests/TerminalUITests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "TerminalInkTests",
            dependencies: ["TerminalInk"],
            path: "Tests/TerminalInkTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "TerminalLogTests",
            dependencies: ["TerminalLog", "TerminalInk"],
            path: "Tests/TerminalLogTests",
            swiftSettings: strictSettings
        ),
    ]
)
