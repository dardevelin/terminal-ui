<p align="center">
  <img src="assets/logo.svg" width="240" alt="TerminalUI — Ember Fox mascot"/>
</p>

<h1 align="center">TerminalUI</h1>

<p align="center">SwiftUI for the terminal. macOS, Linux, over SSH. Zero runtime dependencies.</p>

---

```swift
import TerminalUI

@main
struct Hello: TerminalAppProtocol {
    static func content() -> some TerminalView {
        VStack {
            Text("Hello from TerminalUI").bold()
            Divider()
            Text("Press q to quit.").foreground(.gray)
        }
    }
}
```

That's a working TUI. `swift run` and it's on your screen — keyboard input, mouse
support, resize handling, 60 fps capped rendering, debug tools, all live.

## Why it exists

Every terminal UI framework asks you to learn a new paradigm. TerminalUI doesn't.
If you know SwiftUI, you already know it: `VStack`, `HStack`, `Text`, `Button`,
`@Observable` state, `Binding`, modifiers. The twist is that the "pixels" are
terminal cells, and the framework pushes only the ones that changed.

- **~82,000 fps idle / ~700 fps active** thanks to Observation-driven frame
  skipping and delta compositing.
- **~69–111 bytes per frame over SSH** — deltas + gap bridging mean remote
  rendering is production-practical, not a demo trick.
- **22 view types** — VStack, HStack, ZStack, Text, Button, TextInput,
  TextArea, Toggle, Table, List, ForEach, ScrollView, GeometryReader, TabView,
  TreeView, DiffView, HunkDiffView, PromptInput, StatusBar, ProgressBar, Spacer,
  Divider.
- **7 chart components** — BarChart, Sparkline, HeatMap, BrailleCanvas,
  DotMatrixText, DotFont, MorseTicker.
- **Dual keyboard + mouse focus**, scope-aware arrow navigation, SGR 1006 mouse
  protocol, kitty keyboard protocol (Alt+Enter, Shift+Enter, modifier arrows).
- **Debug tools** built in (F1 overlay, F2 panel, F3 inspector) — `#if DEBUG`
  gated, zero release overhead.

## Install

Swift 6.2+. macOS 15+ or Linux.

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/dardevelin/terminal-ui", from: "1.0.0"),
],
targets: [
    .executableTarget(
        name: "YourApp",
        dependencies: [
            .product(name: "TerminalUI", package: "terminal-ui"),
        ]
    ),
]
```

## Your first TUI (3 minutes)

Create a package, add the dependency above, put this in `Sources/YourApp/main.swift`:

```swift
import Observation
import TerminalUI

@Observable
final class Counter {
    var value = 0
}

@main
struct CounterApp: TerminalAppProtocol {
    static let state = Counter()

    static func onEvent(_ event: TerminalEvent) -> Bool {
        if case .key(let k) = event {
            switch k.key {
            case .character("+"): state.value += 1
            case .character("-"): state.value -= 1
            case .character("q"), .escape: return false  // quit
            default: break
            }
        }
        return true
    }

    static func content() -> some TerminalView {
        VStack {
            Text("Counter").bold()
            Divider()
            Text("value = \(state.value)")
            Text("  +/-: change   q: quit").foreground(.gray)
        }
    }
}
```

Run it:

```bash
swift run YourApp
```

Press `+`, `-`, `q`. That's the full programming model.

## See what's possible

The repo ships three example apps. Clone and run:

```bash
git clone https://github.com/dardevelin/terminal-ui
cd terminal-ui

swift run Storybook         # every public API, one page each (start here)
swift run Demo              # 12-tab showcase — charts, diff, tree, focus scopes
swift run ComponentsDemo    # component gallery with realistic data
swift run DotMatrixDemo     # dot-matrix display + Morse ticker
swift run swtui help        # diagnostic config CLI
```

The `Demo` app is the fastest way to see the framework do something real —
keyboard navigation, mouse, live charts, modals, focus scopes, an in-app
inspector (F3). Resize your terminal while it's running.

## How it works (one paragraph)

A user-written `body: some TerminalView` builds an immutable view value. The
framework reconciles it into an attribute graph — persistent identity across
frames, cached layout. A renderer walks the graph with enum dispatch (no `as?`)
into a fresh cell buffer. A compositor computes the delta against the previous
frame's buffer and emits cursor-position + character writes only where cells
changed. One POSIX `write` syscall per frame. `@Observable` integration means
unchanged state skips the whole pipeline — idle is free.

Deeper architecture docs live at the DocC site (once published):
`https://dardevelin.github.io/terminal-ui/documentation/terminalui/`

## Requirements & compatibility

- **Swift 6.2+** with `.swiftLanguageMode(.v6)` and `StrictConcurrency`
- **macOS 15+** or **Linux** (Docker `swift:6.2` verified)
- **Any terminal that speaks VT100/ANSI** — tested on iTerm2, Terminal.app,
  Alacritty, kitty, wezterm, tmux, ssh
- **Truecolor** preferred; 256-color and 16-color fallback is planned

## Status

v0.8.0 tagged 2026-04-17. 885 tests across 182 suites, on macOS and Linux.
0 errors, 0 warnings under `-warnings-as-errors`. v1.0.0 is the first public
release — this repo is being published with that version.

## License

TerminalUI is dual-licensed under either of:

- Apache License, Version 2.0 ([`LICENSE-APACHE`](LICENSE-APACHE) or
  <http://www.apache.org/licenses/LICENSE-2.0>)
- MIT License ([`LICENSE-MIT`](LICENSE-MIT) or
  <http://opensource.org/licenses/MIT>)

at your option. Unless you explicitly state otherwise, any contribution you
submit for inclusion will be dual-licensed as above without additional terms
or conditions.
