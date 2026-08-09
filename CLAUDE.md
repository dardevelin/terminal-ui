# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

**TerminalUI** — a SwiftUI-paradigm TUI framework for Swift. The north star
(decided 2026-04-11, a deliberate pivot away from a multi-backend
render-to-anything design): *the best SwiftUI-for-terminal framework* — someone
who knows SwiftUI should build a complex TUI app without learning a new
paradigm. Modularity comes from good design, not premature backend abstraction.

The Swift package lives at the repo root: `Package.swift`, `Sources/`, `Tests/`,
`Examples/`, `tools/`. All commands run from the repo root.

The root also holds the FOSS shell: `README.md`, `CHANGELOG.md`, dual
`LICENSE-APACHE` + `LICENSE-MIT` (dual-licensed at the user's option), `NOTICE`,
`assets/` (logo), `logo-concepts/`, and `reference/` (studied prior art —
ratatui, SwiftTUI, asciinema, vhs).

## Commands

```bash
# Build & test
swift build                          # debug
swift build -c release               # release — all #if DEBUG machinery erased
swift test                           # full suite: 885 tests in 182 suites
swift test --filter InputParser      # run one suite by name substring
swift package clean && swift build   # full clean rebuild — must be 0 err / 0 warn

# Warnings-as-errors is opt-in via env (NOT baked into Package.swift, so
# downstream consumers don't inherit the strict gate). CI and local checks:
TUI_WARNINGS_AS_ERRORS=1 swift build

# Run the example apps
swift run Storybook          # every public API, one page each — the canonical showcase
swift run Demo               # 12-tab showcase; F1 overlay / F2 panel / F3 inspector (debug build)
swift run -c release Demo    # release build — debug tools gone
swift run ComponentsDemo     # component gallery with realistic data
swift run DotMatrixDemo      # dot-matrix display + Morse ticker
swift run GitClient          # example: git client TUI
swift run Chat               # example: chat TUI
swift run swtui help         # developer CLI for the .terminalui/ diagnostic system

# Linux verification (image tag MUST be swift:6.2 — Package.swift requires it;
# swift:6.0 rejects the manifest)
docker run --rm -v $(pwd):/app -w /app swift:6.2 swift build
docker run --rm -v $(pwd):/app -w /app swift:6.2 swift test

# PTY-driven visual harness against a Linux build — same coverage as macOS
tools/scripts/linux_harness.sh                      # walk all Storybook pages
tools/scripts/linux_harness.sh storybook_smoke.py   # full behavioural suite
```

The harness builds into `.build-linux/`, not `.build/`: a shared build dir leaves
Linux ELF binaries where a later macOS run expects Mach-O, and every case dies
with `Exec format error`. Both harness scripts take an optional build-dir
argument for this. The `swift:6.2` image ships no Python, which is the only
reason the harness cannot run inside the container — PTYs work fine there.

## Constraints (non-negotiable)

- **Swift 6.2+**, `.swiftLanguageMode(.v6)`, `StrictConcurrency` + `ExistentialAny`.
- **macOS 15+ / Linux** — cross-platform, Docker-verified. Platform-specific code
  uses `#if canImport(Glibc)` / `#if canImport(Darwin)`, never runtime checks.
  Verify Linux builds via Docker, not assumptions.
- **Zero dependencies** for consumers — not just at runtime: resolving this
  package clones nothing. `swift-docc-plugin` is opt-in behind
  `TUI_BUILD_DOCS=1`, because SwiftPM has no dev-only dependency and declaring
  it unconditionally made every consumer fetch it and swift-docc-symbolkit to
  build a package that references neither:

  ```bash
  TUI_BUILD_DOCS=1 swift package generate-documentation
  ```
- **0 errors, 0 warnings, always.** DX is paramount.
- All debug/diagnostic machinery is `#if DEBUG`-gated — zero release overhead.

## Package layout (5 library targets — a deliberate layering)

The package ships four public libraries so consumers pull only what they need.
This layering is the modularity strategy — not backend abstraction.

| Target | Depends on | Purpose |
|--------|-----------|---------|
| `TerminalInk` | — | Zero-dep styled output: color model, capability detection, ANSI SGR. For tooling that needs styled stdout/stderr without a render runtime. |
| `TerminalLog` | TerminalInk | Structured logging: leveled colored prefixes, console + file sinks, ANSI auto-stripping for non-TTY. |
| `TerminalUIConfig` | — | Shared diagnostic config (`DiagConfig`, `TOMLParser`, `DiagPaths`). Used by TerminalUI (debug-only) and the `swtui` CLI. |
| `TerminalUI` | Config, Ink, Log | The full TUI runtime — the main framework. |
| `TerminalUIIO` | TerminalUI | Opt-in image/media: `ImageBuffer`, decoders, half-block/kitty renderers, a pure-Swift PNG inflate. Apps without image needs don't pay for it. |

`swtui` is an executable target (the diagnostic CLI); `Examples/*` are executable
targets. Test targets exist per library (`TerminalUITests`, `TerminalInkTests`,
`TerminalLogTests`, `TerminalUIIOTests`).

## Core architecture

The render loop is a SwiftUI-style declarative pipeline over a terminal cell grid:

```
@Observable state mutation
    → atomic hasDirtyNodes flag (idle = zero work, unchanged state skips everything)
    → content() builds an immutable view value
    → AttributeGraph.update() reconciles it — persistent node identity across frames, cached layout
    → GraphRenderer.render() walks the graph via NodeKind ENUM DISPATCH (no as?) into a fresh CellBuffer
    → Compositor computes the delta vs previousBuffer, bridging gaps and tracking cursor
    → OutputBuffer.flush() — ONE POSIX write syscall per frame, raw [UInt8]
```

Why it matters: idle is free (~82k fps), ~700fps active in release, deltas keep
SSH cheap (~69–111 bytes/frame), and enum dispatch keeps the render hot path
allocation- and cast-free.

### Module map — `Sources/`

| Layer | Path | Core types |
|-------|------|-----------|
| **Core** | `TerminalUI/Core/` | `TerminalApp`, `TerminalView`, `InputParser` (ANSI, SGR 1006 mouse, kitty keyboard, UTF-8; drives off `ByteSource` — stdin or test array), `KeyEvent`, `MouseEvent`, `KeyBindings`, `FrameStats`, `Environment` |
| **Graph** | `TerminalUI/Graph/` | `AttributeGraph`, `AttributeNode`, `NodeKind` (enum dispatch), `NodeID`, `GraphRenderer`, `GraphMeasurer`, `GraphConformances`, `HitTest` |
| **Rendering** | `TerminalUI/Rendering/` | `CellBuffer`, `Compositor` (layers + delta), `OutputBuffer` (raw bytes), `Terminal` (raw mode, ANSI modes), `Rect` |
| **State** | `TerminalUI/State/` | `@TerminalState`, `Binding<Value>`, `StateStorage`, `GraphContext` (`@TaskLocal`), `EnvironmentValues` |
| **Focus** | `TerminalUI/Focus/` | `FocusEngine` (dual keyboard/mouse, scope-aware arrows, directional `move()`), `FocusModifiers` (`.focusable`, `.focusScope`), `FocusableContainer`, `FocusGraphIntegration` |
| **Actions** | `TerminalUI/Actions/` | Action-context stack, scoped key-bindings |
| **Views** | `TerminalUI/Views/` | Text, VStack, HStack, ZStack, Spacer, Divider, ForEach, List, ScrollView, Button, TextInput, Toggle, Table, GeometryReader, TabView, TreeView, TextArea, DiffView, HunkDiffView, PromptInput, StatusBar, ProgressBar, SplitView, Alert |
| **Charts** | `TerminalUI/Views/Charts/` | BarChart, Sparkline, HeatMap, BrailleCanvas, DotMatrixText, DotFont, MorseTicker |
| **Modifiers** | `TerminalUI/Modifiers/` | `ModifiedView`, overlay modifiers + protocols, lifecycle modifiers |
| **Style / Layout / Timeline** | `TerminalUI/{Style,Layout,Timeline}/` | `Color`, `BorderStyle`, `Theme`; `Coordinate`; timeline scheduling |
| **DevTools** | `TerminalUI/DevTools/` | DebugOverlay, DebugPanel, Inspector, DevTrace, DebugStream — all `#if DEBUG` |
| **Config / CLI** | `TerminalUIConfig/`, `swtui/` | `DiagConfig`, `TOMLParser`, `DiagPaths`; the diagnostic CLI |

Tests live in `Tests/<Target>Tests/`, Swift Testing (`import Testing`, `@Test`,
`#expect`) — 885 tests in 182 suites. Graph tests are `@MainActor`.

### Render modes

```swift
.uncapped              // benchmark: render every frame
.fps30 / .fps60 / .fps120   // presets, each a .capped(Duration)
.capped(.milliseconds(16))  // explicit frame budget
.onDemand              // zero CPU when idle, render only on events
```

### App entry point (a known footgun)

The public entry is `@main struct X: TerminalAppProtocol` with static
`content()` / `onEvent(_:)`. It is **NOT** `TerminalApp(view).run()` —
`TerminalApp` is an enum namespace whose `.print` etc. serve non-render contexts.
See `TerminalAppProtocol` in `Sources/TerminalUI/Core/TerminalApp.swift`.

### State in handler closures (a known footgun)

`@TerminalState` fails inside handler closures (`GraphContext.currentNode` is nil
there). Use an `@Observable` class + `Binding`; the `$binding` projected value
eagerly captures `currentNode` to fix this. Project `$state` in `body`, never
inside a `GeometryReader { … }` closure (it captures the wrong node).

## Diagnostics & remote control (`.terminalui/` + `swtui ctl`)

Config-driven, `#if DEBUG` only. Config in `.terminalui/terminalui.toml`;
ephemeral output in a **per-process PID-isolated** dir,
`/tmp/terminalui-{hash}-{pid}/`, with a `.terminalui/data` symlink to the most
recent. Every running app owns its own world — this isolation is load-bearing for
concurrent test runs. Features: `trace`, `capture`, `screenshots`, `events`,
`socket`.

```bash
swift run swtui init | status | config | clean
swift run swtui enable trace | disable trace | set frame_limit 50
swift run swtui bind toggle_inspector F5      # remap a debug keybinding

# Remote control of a running debug build, via its socket:
swift run swtui ctl ping | focus | tree | frame | screenshot | quit
swift run swtui ctl send-key <name> [mods...] | send-text "..."
swift run swtui ctl cells [x y w h] | probe <x> <y> | inspect
swift run swtui ctl inspector-move <x> <y> | inspector-toggle
swift run swtui ctl list | reap | kill --pid <N>
```

`ctl` targets `latest.sock` by default; `--pid`, `--socket`, `--dir` override.
`kill` requires an explicit PID (no dragnet); `reap` unlinks stale sockets whose
owning PID is dead; `list` is read-only.

A typed Python client + PTY runner live in `tools/terminalui/` (`client.py`,
`runner.py`); smoke/integration harnesses in `tools/scripts/`. Protocol: strict
one-request/one-response JSON lines over an AF_UNIX socket, pumped once per
frame. Spawn Storybook via PTY only.

## Code standards

- **Comments** explain research, protocol specs (RFC / ECMA-48 / xterm ctlseqs /
  kitty), undefined behavior, and ABI assumptions — never what the code does.
  No `// Parse X` / `// ESC` / `// Ctrl+key` narration.
- **No magic numbers** — extract into private enums with a spec reference.
  `InputParser.swift` (ASCII, SGRMouse, TildeCode, KittyEventType, UTF8) and
  `Terminal.swift` (ANSIMode) are the established pattern.
- **Naming** — no single-letter variables except loop counters (i, j) and x/y
  coordinates. `n` → `bytesRead`/`bytesWritten`, `cb` → `buttonCode`, `ws` →
  `windowSize`. Prefer full words: `paramString`, not `numStr`.
- **ExistentialAny** — protocol-as-type must use `any`: `[any DebugSink]`,
  `any AnyStateStorage`, `as? any _FocusGraphModifier`.
- **No tracker IDs in code.** Issue identifiers must never appear in filenames,
  code, comments, or commit messages — trackers rot, code outlives them.
- **Commits carry no AI/generated attribution and no human co-author trailers.**
- **Verify before committing framework changes** — run the relevant Example app
  (Storybook / Demo) interactively, not just `swift test`.

## Known performance hot spot

`[Any]` boxing in the graph protocol chain remains the largest active-frame cost:
`graphChildren() -> [Any]` on the stack/ForEach conformances
(`Graph/GraphConformances.swift`, `Views/TabView.swift`) and
`updateLayoutChildren(from:)` in `Graph/AttributeGraph.swift`. A prior
visitor-pattern attempt was reverted; the intended fix is parameter packs to
iterate tuple elements with concrete types, removing boxing, ARC, and most
remaining casts. See `Sources/TerminalUI/TerminalUI.docc/Articles/Performance.md`.

## Current direction

The active large effort is **i3-shaped tiling primitives**: the SplitNode model +
SplitView, the `FocusableContainer` protocol + directional `FocusEngine.move()`,
and an ActionContext stack with scoped key-bindings (i3 modes) have shipped;
work heads toward N-way/nested splits, workspaces, multi-output, and an
IPC/hotkey command vocabulary. A parallel SwiftUI API-parity effort is ongoing.

Prefer hardening the core over starting new epics.

## Orientation for new sessions

Don't explore the codebase from scratch: start with `git log --oneline -10`
for what changed recently and `git diff HEAD~N` for what's in flight, and
read the DocC articles under `Sources/TerminalUI/TerminalUI.docc/Articles/`
for architecture and performance history.
