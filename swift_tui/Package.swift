// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swift_tui",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TerminalUI", targets: ["TerminalUI"]),
    ],
    targets: [
        .target(name: "TerminalUI", path: "Sources/TerminalUI"),
        .executableTarget(
            name: "Demo",
            dependencies: ["TerminalUI"],
            path: "Examples/Demo"
        ),
    ]
)
