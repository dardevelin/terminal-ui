# Changelog

All notable changes to TerminalUI are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

Work in progress toward v1.0.0 — the first public FOSS release. No API changes
planned; all work is documentation, discoverability, and packaging polish.

## [0.8.0] — 2026-04-17 — Hardened core

Closed core debt before expanding the framework's surface.

- **Test target** stood up: `Tests/TerminalUITests/` — 146 assertions across
  20 suites with Swift Testing (`@Test`, `#expect`). Runs on macOS and Docker
  `swift:6.2` Linux.
- **InputParser → ByteSource** refactor. The state machine now takes
  `inout some ByteSource`, with `StdinByteSource` for runtime and
  `ArrayByteSource` for tests. Behavior unchanged, parser testable without a TTY.
- **HYP-41 quit hang fixed** via POSIX self-pipe: pressing `q` now exits in
  ~2.4ms (previously ≥100ms because `read(STDIN_FILENO)` blocks cancellation).
- **HYP-40 focus scopes**: `.focusScope(_ id: String)` groups focusables.
  Arrow keys clamp inside the scope; Tab still crosses (SwiftUI convention).
- Demo grew a "Scopes" tab (12th) demonstrating focus scopes.

## [0.7.2] — 2026-04-12

- FocusEngine API simplification and event routing documentation.

## [0.7.1] — 2026-04-12

- Unified VStack/HStack spacer distribution in a shared helper.

## [0.7.0] — 2026-04-11

- `DotMatrix` components, `MorseStream` demo, `PromptInput`.
- Text wrapping via `writeSpans` at container width; `countWrappedLines` for height.

## [0.6.2] — 2026-04-11

- Myers diff backtrack bug fixed; algorithm selector (Myers + LCS) added to DiffEngine.

## [0.6.1] — 2026-04-11

- DiffView crash fix (replaced buggy Myers with LCS on the hot path).
- TreeView interaction polish.

## [0.6.0] — 2026-04-11

- Six new components: `DiffView`, `HunkDiffView`, `TreeView`, `TextArea`,
  `TabView`, `StatusBar`.
- `ProjectedValue` fix for `@TerminalState` — bindings eagerly capture
  `currentNode`, making them usable in handler closures.

## [0.5.1] — 2026-04-11

- Cross-platform Linux support via `#if canImport(Glibc)` / `#if canImport(Darwin)`.
  Docker `swift:6.2` verified.

## [0.5.0] — 2026-04-11

- AAA-quality hardening pass: concurrency safety (Swift 6 `StrictConcurrency`),
  performance, architecture. `-warnings-as-errors` — 0 errors / 0 warnings policy.

## [0.4] — 2026-04-11

- `TextSpan` per-character styling.
- Render mode fixes (`.uncapped`, `.capped`, `.onDemand`).
- Flicker-free resize.

## [0.3]

- Chart library: `BarChart`, `Sparkline`, `HeatMap`, `BrailleCanvas`.
- Focus system: dual keyboard + mouse focus, `.focusable()`, `.onKeyPress`.
- Mouse support: SGR 1006 — click, drag, move, scroll.
- Interactive controls.

## [0.2]

- Compositor with layer-based rendering for modals and overlays.
- Delta compositor — only recomposite changed regions.
- Hit testing: spatial node lookup from screen coordinates.
- Inspector: in-app node debugger with crosshair.

## [0.1]

- Initial prototype: SwiftUI-paradigm TUI framework for Swift.
- Attribute graph with `@Observable` state, `@TerminalState`, `Binding<Value>`.
- Dev tools: debug overlay, panel, stream protocol.
- Observation-driven frame skip: ~82,000 fps idle, ~700 fps active.

[Unreleased]: https://github.com/dardevelin/terminal-ui/compare/v0.8.0...HEAD
[0.8.0]: https://github.com/dardevelin/terminal-ui/releases/tag/v0.8.0
[0.7.2]: https://github.com/dardevelin/terminal-ui/releases/tag/v0.7.2
[0.7.1]: https://github.com/dardevelin/terminal-ui/releases/tag/v0.7.1
[0.7.0]: https://github.com/dardevelin/terminal-ui/releases/tag/v0.7.0
[0.6.2]: https://github.com/dardevelin/terminal-ui/releases/tag/v0.6.2
[0.6.1]: https://github.com/dardevelin/terminal-ui/releases/tag/v0.6.1
[0.6.0]: https://github.com/dardevelin/terminal-ui/releases/tag/v0.6.0
[0.5.1]: https://github.com/dardevelin/terminal-ui/releases/tag/v0.5.1
[0.5.0]: https://github.com/dardevelin/terminal-ui/releases/tag/v0.5.0
[0.4]: https://github.com/dardevelin/terminal-ui/releases/tag/v0.4
