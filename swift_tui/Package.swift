// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swift_tui",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TerminalUI", targets: ["TerminalUI"]),
    ],
    targets: [
        .target(
            name: "TerminalUI",
            path: "Sources/TerminalUI",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "Demo",
            dependencies: ["TerminalUI"],
            path: "Examples/Demo"
        ),
        .executableTarget(
            name: "ComponentsDemo",
            dependencies: ["TerminalUI"],
            path: "Examples/ComponentsDemo"
        ),
    ]
)
