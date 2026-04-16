# TerminalUI

SwiftUI-paradigm TUI framework for Swift. North star: can someone who knows SwiftUI build a complex TUI app without learning a new paradigm?

## Quickstart

```bash
swift run Demo              # debug build — F1 overlay, F2 panel, F3 inspector
swift run -c release Demo   # release build — debug tools erased
swift run ComponentsDemo    # component showcase
swift run DotMatrixDemo     # dot matrix / morse demo
swift run swtui help        # diagnostic config CLI
swift test                  # 146 tests across parsers, compositor, graph, focus
```

## Constraints

- **Swift 6+ only** (swift-tools-version: 6.2, `.swiftLanguageMode(.v6)`)
- **macOS 15+ / Linux** — cross-platform, Docker-verified
- **Zero external dependencies**
- **Strict compiler flags**: StrictConcurrency, ExistentialAny, -warnings-as-errors
- **0 errors, 0 warnings** — always. DX is paramount.

## Architecture

### Core Pipeline

```
@Observable state mutation
    → Atomic hasDirtyNodes flag
    → buildView() + graph.update() (reconciliation)
    → GraphRenderer.render() into CellBuffer (enum dispatch, zero as?)
    → Delta composite against previousBuffer
    → OutputBuffer.flush() — single POSIX write syscall, raw [UInt8]
```

### Key Types

| Layer | Files | Core Types |
|-------|-------|------------|
| **Graph** | `Graph/` | `AttributeGraph`, `AttributeNode`, `NodeKind` (enum dispatch), `NodeID`, `GraphRenderer`, `GraphMeasurer`, `GraphConformances`, `HitTest` |
| **State** | `State/` | `@TerminalState`, `Binding<Value>`, `StateStorage`, `GraphContext` (5 `nonisolated(unsafe)` statics), `EnvironmentValues` |
| **Rendering** | `Rendering/` | `CellBuffer`, `Compositor` (layers + delta), `OutputBuffer` (raw bytes), `Terminal` (raw mode, ANSI modes) |
| **Focus** | `Focus/` | `FocusEngine` (dual keyboard/mouse, scope-aware arrows), `FocusModifiers` (`.focusable`, `.focusScope`), `FocusGraphIntegration` |
| **Input** | `Core/` | `InputParser` (ANSI, SGR 1006 mouse, kitty keyboard, UTF-8) — drives off `ByteSource` (stdin or test array), `KeyEvent`, `MouseEvent`, `KeyBindings` |
| **Views** | `Views/` | Text, VStack, HStack, ZStack, Spacer, Divider, ForEach, List, ScrollView, Button, TextInput, Toggle, Table, GeometryReader, TabView, TreeView, TextArea, DiffView, HunkDiffView, PromptInput, StatusBar, ProgressBar |
| **Charts** | `Views/Charts/` | BarChart, Sparkline, HeatMap, BrailleCanvas, DotMatrixText, DotFont, MorseTicker |
| **DevTools** | `DevTools/` | DebugOverlay, DebugPanel, Inspector, DevTrace, DebugStream — all `#if DEBUG` erased |
| **Config** | `TerminalUIConfig/` | `DiagConfig`, `TOMLParser`, `DiagPaths` — shared with `swtui` CLI |
| **Modifiers** | `Modifiers/` | ModifiedView, OverlayModifiers, OverlayProtocols, LifecycleModifiers |

### Tests

`Tests/TerminalUITests/` — 146 assertions across 20 suites, Swift Testing
(`import Testing`, `@Test`, `#expect`). Covers TOMLParser, KeyCombo, CellBuffer,
InputParser (ASCII + CSI + SS3 + tilde + kitty + SGR mouse + UTF-8),
Compositor delta, AttributeGraph reconciliation/identity, GraphRenderer/Measurer,
FocusEngine baseline + scope-aware navigation. Run with `swift test`. Graph tests
are `@MainActor` with a `resetGraphContext()` helper that clears the five
`nonisolated(unsafe)` statics between cases.

### Dead Code (delete pending — HYP-7)

`Rendering/Renderer.swift` and `Rendering/ViewConformances.swift` are the old pre-graph `Any`-based renderer. Fully replaced by `GraphRenderer`. Do not reference or extend these files.

### Performance

- ~82,000fps idle (Observation skip — zero work when no state changed)
- ~700fps active (release build, full rebuild + render + diff + flush)
- ~69-111 bytes/frame over SSH
- Delta compositing with gap bridging and cursor tracking

### Render Modes

```swift
.uncapped           // benchmark: render every frame
.capped(.fps60)     // sleep remaining budget per frame
.onDemand           // zero CPU when idle, render only on events
```

### Diagnostics (.terminalui/)

Config-driven diagnostic system. All debug machinery is `#if DEBUG` — zero release overhead.

```bash
swift run swtui init              # create .terminalui/terminalui.toml
swift run swtui enable trace      # enable frame tracing
swift run swtui disable trace     # disable
swift run swtui set frame_limit 50
swift run swtui status            # show config + running app status
swift run swtui clean             # wipe ephemeral output
```

Layout: config in `.terminalui/terminalui.toml`, ephemeral output in `/tmp/terminalui-{hash}/` with symlink at `.terminalui/data`. Features: `trace`, `capture`, `screenshots`, `events`, `socket`.

## Code Standards

### Comments
Comments explain research, protocol specs, undefined behavior, and ABI assumptions — never what code does. Every named constant group has a spec reference (RFC, ECMA-48, xterm ctlseqs). Remove `// ESC`, `// Parse X`, `// Ctrl+key` style narration.

### Magic Numbers
Extract into private enums with doc comments. See `InputParser.swift` (ASCII, SGRMouse, TildeCode, KittyEventType, UTF8) and `Terminal.swift` (ANSIMode) as the established pattern.

### Naming
- No single-letter variables except standard loop counters (i, j) and x/y coordinates
- `n` → `bytesRead`/`bytesWritten`, `s` → descriptive name, `cb` → `buttonCode`, `ws` → `windowSize`
- Prefer full words: `paramString` not `numStr`, `mutableString` not `s`

### ExistentialAny
Protocol-as-type must use `any` keyword: `[any DebugSink]`, `any AnyStateStorage`, `as? any _FocusGraphModifier`

### Platform Code
`#if canImport(Glibc)` / `#if canImport(Darwin)` — never runtime checks. Verify Linux builds via Docker, not assumptions.

### State in Handlers
`@TerminalState` fails in handler closures (GraphContext.currentNode is nil). Use `@Observable` class + `Binding`. The `$binding` projected value eagerly captures `currentNode` to fix this.

## Module Layout

```
Sources/TerminalUI/
├── Core/           TerminalApp, TerminalView, InputParser, KeyEvent, MouseEvent, KeyBindings, FrameStats, Environment
├── Graph/          AttributeGraph, AttributeNode, GraphRenderer, GraphMeasurer, HitTest, GraphConformances, NodeID
├── Rendering/      CellBuffer, Compositor, OutputBuffer, Terminal, Rect, [Renderer.swift, ViewConformances.swift — DEAD]
├── State/          State, StateStorage, GraphContext, EnvironmentValues
├── Focus/          FocusEngine, FocusModifiers, FocusGraphIntegration
├── Modifiers/      ModifiedView, OverlayModifiers, OverlayProtocols, LifecycleModifiers
├── Style/          Color, BorderStyle, Theme
├── Layout/         Coordinate
├── Views/          22 view types
├── Views/Charts/   7 chart components
└── DevTools/       DebugOverlay, DebugPanel, Inspector, DevTrace, DebugStream
Sources/TerminalUIConfig/   DiagConfig, TOMLParser, DiagPaths (shared with swtui CLI)
Sources/swtui/              Developer CLI for .terminalui/ config management
Tests/TerminalUITests/      146 assertions / 20 suites — Swift Testing
Examples/
├── Demo/           12-tab showcase including Scopes (focus scope demo)
├── ComponentsDemo/ Component gallery
└── DotMatrixDemo/  Dot matrix + morse
```

## Orientation for New Sessions

Don't explore the codebase from scratch. Use these tools to get current state:

1. **git log --oneline -10** — what changed recently
2. **git diff HEAD~N** — what's in flight
3. **MemPalace**: `mempalace_search query="<topic>" wing="swift_tui"` — architectural decisions, past bugs, design rationale
4. **MemPalace KG**: `mempalace_kg_query entity="TerminalUI"` — implemented features, milestones, capabilities
5. **Linear**: team Hyperlocalwave, project "Developer Experience Tooling" — all tracked issues (HYP-5 through HYP-23)
6. **Obsidian**: vault `swift_tui_framework/` (27 docs) — `obsidian search query="<topic>"` then `obsidian read path="swift_tui_framework/<doc>.md"`
7. **Claude memory**: `~/.claude/projects/-Users-dbrasdasilva-workspace-swift-workspace/memory/MEMORY.md`

### Key Obsidian Docs
- `00_index.md` — full knowledge graph
- `17_profiling_progression.md` — v1-v7 optimization history with measurements
- `23_known_issues.md` — current bugs
- `25_session_continuation.md` — full context handoff
- `27_session_continuation_2.md` — competitive analysis, strategic direction

## Known Issues & Top Priorities

Check Linear (`list_issues team="Hyperlocalwave" project="Developer Experience Tooling"`) for current state.

**Closed in v0.8 hardening pass:** HYP-6 (test coverage — 146 assertions), HYP-40 (focus scopes — `.focusScope(_:)`), HYP-41 (quit hang — self-pipe wakes blocked stdin read).

| Priority | Key Issues |
|----------|------------|
| **Urgent** | HYP-5: [Any] boxing (44% active frame cost) — 7 live instances in graph protocol chain (deferred from v0.8: prior visitor-pattern attempt reverted, needs parameter packs) |
| **High** | HYP-7: Dead renderer to delete, HYP-22: Complex demos, HYP-23: SPM packaging |
| **Medium** | HYP-8: GraphContext thread safety, HYP-10: ForEach virtualization, HYP-12: .disabled(), HYP-13: Color downgrade, HYP-14: NavigationStack, HYP-20/21: Standardized debug output + remote debugger, HYP-37: DiffView stale cells |

### GraphContext Thread Safety
5 `nonisolated(unsafe)` static properties in `GraphContext.swift`. Safety depends on runtime discipline that body evaluation only happens on `@MainActor`. No compiler enforcement. Consider `@TaskLocal` migration.

### [Any] Boxing Hotspots (7 live instances after dead code deleted)
- `GraphConformances.swift` — VStack/HStack/ForEach `graphChildren() -> [Any]`
- `AttributeGraph.swift` — `updateLayoutChildren(from newChildren: [Any])`, protocol requirement
- `TabView.swift` — `graphChildren() -> [Any]`

## Build & Verify

```bash
swift build                          # debug build
swift build -c release               # release build (debug tools erased)
swift test                           # 146 tests / 20 suites — must pass
swift package clean && swift build   # full clean rebuild (must pass 0err/0warn)
```

### Linux verification
```bash
docker run --rm -v $(pwd):/app -w /app swift:6.2 swift build
docker run --rm -v $(pwd):/app -w /app swift:6.2 swift test
```
Note: image tag must be `swift:6.2` (Package.swift requires Swift 6.2). Older `swift:6.0` will reject the manifest.
