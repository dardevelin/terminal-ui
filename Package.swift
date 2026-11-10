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

// DocC is a documentation *tool*, not something the library builds against —
// but SwiftPM has no dev-only dependency, so declaring it unconditionally makes
// every consumer clone it and swift-docc-symbolkit to build a package that
// never references either. That contradicts the zero-dependencies promise, so
// it follows the same opt-in shape as the strict gate above: this repo's docs
// job sets the variable, and nobody else pays for it.
//
//     TUI_BUILD_DOCS=1 swift package generate-documentation
let docsDependency: [Package.Dependency] = ProcessInfo.processInfo
    .environment["TUI_BUILD_DOCS"] == "1"
    ? [.package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.3.0")]
    : []

// Location Services prompts only a process that has an Info.plist with a
// usage description, and names it by its bundle identifier. A SwiftPM
// executable is given one by the linker embedding the file as the
// `__TEXT,__info_plist` section (ld's `-sectcreate`), which `locationd`
// reads as the bundle's — design/maps.md, "Location". An unsafe flag, so
// opt-in like the strict gate: a consumer never builds the Maps example,
// and nobody else's build sees it.
//
//     TERMINALUI_MAPS_LOCATION_PLIST=1 swift run Maps --location corelocation
let mapsLocationPlist: [LinkerSetting] = ProcessInfo.processInfo
    .environment["TERMINALUI_MAPS_LOCATION_PLIST"] == "1"
    ? [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                     "-Xlinker", Context.packageDirectory + "/Examples/Maps/Support/Info.plist"])]
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
    name: "TerminalUI",
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
        // TerminalUIIO: image + media rendering. Opt-in module so apps
        // without image needs don't pay the cost. Hosts ImageBuffer,
        // ImageDecoder protocol, future Image view + renderers.
        .library(name: "TerminalUIIO", targets: ["TerminalUIIO"]),
        // TerminalUI3D: meshes, a scene, and a software rasterizer that
        // draws it in text through a Canvas. Opt-in, as TerminalUIIO is.
        .library(name: "TerminalUI3D", targets: ["TerminalUI3D"]),
        // TerminalUIMaps: maps drawn in text — vector and picture tiles,
        // search, routes, places, live location and navigation, behind
        // protocols an app fills with the backends it chooses. Opt-in.
        .library(name: "TerminalUIMaps", targets: ["TerminalUIMaps"]),
        // swtui: the diagnostic CLI. A product so an app's own package can
        // `swift run swtui ctl …` against the debug build it is running —
        // as a bare target it ran only from this checkout.
        .executable(name: "swtui", targets: ["swtui"]),
    ],
    dependencies: docsDependency,
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
        // TerminalUIIO — image + media rendering. Opt-in.
        .target(
            name: "TerminalUIIO",
            dependencies: ["TerminalUI"],
            path: "Sources/TerminalUIIO",
            swiftSettings: strictSettings
        ),
        // TerminalUI3D — vectors, matrices and quaternions; meshes and their
        // primitives, height fields and 3D lettering; a scene of models,
        // lights, a camera and labels; and the rasterizer that draws it into
        // a Canvas in one of several shading styles. Opt-in.
        .target(
            name: "TerminalUI3D",
            dependencies: ["TerminalUI"],
            path: "Sources/TerminalUI3D",
            swiftSettings: strictSettings
        ),
        // TerminalUIRaster — PNG and GIF encoders, the canvas the
        // recording renderer draws into, and a TrueType parser and
        // coverage rasterizer for its text. Pure Swift, integer only, so a
        // picture is the same bytes on every system. In no product: only
        // swtui's renderer uses it, and its API is `package`.
        .target(
            name: "TerminalUIRaster",
            path: "Sources/TerminalUIRaster",
            swiftSettings: strictSettings
        ),
        // TerminalUIRecording — turns a `.tuirec` recording into pictures:
        // its reader, the presentation clock, palettes and cell metrics, and
        // the encoders; its raster pictures are drawn with TerminalUIRaster. In no product: swtui is its only client, so a
        // consumer building TerminalUI compiles none of it.
        .target(
            name: "TerminalUIRecording",
            dependencies: ["TerminalUI", "TerminalUIConfig", "TerminalUIRaster"],
            path: "Sources/TerminalUIRecording",
            swiftSettings: strictSettings
        ),
        // TerminalUIMaps — geo and the Web Mercator camera, a Mapbox Vector
        // Tile decoder, the OpenMapTiles style roles, a renderer that draws
        // tiles into a Canvas, MapView, and the protocols the tile, search,
        // route, place, imagery and location backends meet. TerminalUIIO
        // for its Inflate and ImageBuffer, TerminalUIRaster for CRC-32 and
        // the deflate that gzips the sample town's tiles. Opt-in.
        .target(
            name: "TerminalUIMaps",
            dependencies: ["TerminalUI", "TerminalUIIO", "TerminalUIRaster"],
            path: "Sources/TerminalUIMaps",
            swiftSettings: strictSettings
        ),
        // Developer CLI tool for managing .terminalui/ config
        .executableTarget(
            name: "swtui",
            dependencies: ["TerminalUIConfig", "TerminalInk", "TerminalLog", "TerminalUI", "TerminalUIRecording",
                           "TerminalUIRaster"],
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
            dependencies: ["TerminalUI", "TerminalUI3D"],
            path: "Examples/Storybook",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "Navigation",
            dependencies: ["TerminalUI"],
            path: "Examples/Navigation",
            swiftSettings: strictSettings
        ),
.executableTarget(
            name: "AsyncState",
            dependencies: ["TerminalUI"],
            path: "Examples/AsyncState",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "Settings",
            dependencies: ["TerminalUI"],
            path: "Examples/Settings",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "GitClient",
            dependencies: ["TerminalUI"],
            path: "Examples/GitClient",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "Chat",
            dependencies: ["TerminalUI"],
            path: "Examples/Chat",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "Coder",
            dependencies: ["TerminalUI"],
            path: "Examples/Coder",
            swiftSettings: strictSettings
        ),
        // What a TerminalUI3D frame costs: `swift run -c release SceneBenchmark`.
        .executableTarget(
            name: "SceneBenchmark",
            dependencies: ["TerminalUI", "TerminalUI3D"],
            path: "Examples/SceneBenchmark",
            swiftSettings: strictSettings
        ),
        // TerminalUIMaps on a full-screen map. Opens on the sample town, so
        // a first launch and the smoke harness need no network.
        .executableTarget(
            name: "Maps",
            dependencies: ["TerminalUI", "TerminalUIMaps"],
            path: "Examples/Maps",
            // The demo's GPX tracks, and the Info.plist a Location Services
            // build embeds: data, not sources or resources.
            exclude: ["Tracks", "Support"],
            swiftSettings: strictSettings,
            linkerSettings: mapsLocationPlist
        ),
        // Full-screen chapters that play on their own, recorded for the
        // README: `swift run Showcase [3d|canvas]`.
        .executableTarget(
            name: "Showcase",
            dependencies: ["TerminalUI", "TerminalUI3D"],
            path: "Examples/Showcase",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "TerminalUITests",
            dependencies: ["TerminalUI", "TerminalUIConfig"],
            path: "Tests/TerminalUITests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "TerminalUIIOTests",
            dependencies: ["TerminalUIIO", "TerminalUI"],
            path: "Tests/TerminalUIIOTests",
            // InflateTests resolves these via `#filePath` against the
            // source tree — not Bundle.module — so they must be excluded
            // from the target's resource processing. Without this SwiftPM
            // emits an "unhandled files" warning on every build.
            exclude: ["Fixtures"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "TerminalUIRasterTests",
            // TerminalUIIO only for its Inflate, the round trip the encoder
            // is checked against.
            dependencies: ["TerminalUIRaster", "TerminalUIIO"],
            path: "Tests/TerminalUIRasterTests",
            // Goldens read through `#filePath`, as TerminalUIIOTests' are,
            // and so is the bundled font under tools/fonts/.
            exclude: ["Fixtures"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "TerminalUIRecordingTests",
            dependencies: ["TerminalUIRecording", "TerminalUI", "TerminalUIConfig", "TerminalUIRaster"],
            path: "Tests/TerminalUIRecordingTests",
            // Hand-written logs and their SVG goldens, read through `#filePath`.
            exclude: ["Fixtures"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "TerminalUIMapsTests",
            // TerminalUI to draw a map into a canvas's planes and read the
            // cells, as its own canvas tests do.
            dependencies: ["TerminalUIMaps", "TerminalUI", "TerminalUIIO", "TerminalUIRaster"],
            path: "Tests/TerminalUIMapsTests",
            // Real tiles and responses, read through `#filePath`.
            exclude: ["Fixtures"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "TerminalUI3DTests",
            // TerminalUI to draw a scene into a canvas's planes and read the
            // cells, as its own canvas tests do.
            dependencies: ["TerminalUI3D", "TerminalUI"],
            path: "Tests/TerminalUI3DTests",
            swiftSettings: strictSettings
        ),
        // The Showcase's choreography, which a recording plays once and a
        // frame cut short would spoil: what can be checked without a screen.
        .testTarget(
            name: "ShowcaseTests",
            dependencies: ["Showcase", "TerminalUI3D"],
            path: "Tests/ShowcaseTests",
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
