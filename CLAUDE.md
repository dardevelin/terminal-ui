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

The root also holds the FOSS shell: `README.md`, `CHANGELOG.md`, `NOTICE`,
`assets/` (logo), `logo-concepts/`, and the licence files. Licensing is
**tri-licensed at the user's option**: `LICENSE-APACHE` (Apache-2.0),
`LICENSE-MIT`, `LICENSE-EUPL` (EUPL-1.2) — keep `NOTICE` and the README licence
section in sync when any of them change.

`reference/` (studied prior art — ratatui, SwiftTUI, asciinema, vhs) is
gitignored: separately-cloned repos kept locally, not part of the project. So
is `.claude/` (machine-specific hooks) and `CLAUDE.local.md`.

## Commands

```bash
# Build & test
swift build                          # debug
swift build -c release               # release — all #if DEBUG machinery erased
swift test                           # full suite (Swift Testing)
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
swift run Coder              # agent-chat TUI — the Crush-parity forcing function
swift run swtui help         # developer CLI for the .terminalui/ diagnostic system

# Single-purpose examples. These double as fixtures for the behavioural
# harness (storybook_smoke.py drives them) — keep them runnable.
swift run Navigation ; swift run AsyncState ; swift run Settings

# Work tracking — board is gitignored working state, the script is tracked
tools/scripts/kanban.py board
tools/scripts/kanban.py lessons

# Linux verification (image tag MUST be swift:6.2 — Package.swift requires it;
# swift:6.0 rejects the manifest). --scratch-path is NOT optional: without it
# the container writes Linux artifacts into the same .build/ the host uses, and
# the next command in either direction dies on a module-cache collision
# ("module 'SwiftShims' is defined in both …", "missing required module
# 'SwiftOverlayShims'"). Same reason linux_harness.sh uses .build-linux/.
# The same error can ALSO appear intermittently with an isolated scratch path
# (seen once in six runs, cold build → test, never reproduced on demand). It
# is not a code defect: re-run and it passes. Don't pipe these through `tail`
# when judging success — the pipeline reports tail's exit code, not swift's.
docker run --rm -v $(pwd):/app -w /app swift:6.2 swift build --scratch-path .build-linux
docker run --rm -v $(pwd):/app -w /app swift:6.2 swift test  --scratch-path .build-linux

# PTY-driven visual harness against a Linux build — same coverage as macOS
tools/scripts/linux_harness.sh                      # walk all Storybook pages
tools/scripts/linux_harness.sh storybook_smoke.py   # full behavioural suite

# What CI actually gates on, runnable locally (see .github/workflows/ci.yml)
python3 tools/scripts/storybook_walk.py    # every Storybook page, via PTY
python3 tools/scripts/storybook_smoke.py   # behavioural suite vs every example app
                                           # cases run side by side, half the cores; --jobs N
python3 tools/scripts/integration_suite.py # every test_* script, in turn
python3 tools/scripts/tool_tests.py        # tests of the checks and the harness verdict
python3 tools/scripts/check_api_compat.py  # public API vs the last release (own .build-api/)

# The whole local gate in one command: tooling tests and repository checks →
# build (tests included, warnings as errors) → public API → test → walk →
# integration scripts → smoke. Skips itself when the turn touched no .swift /
# .py file. Builds into .build-automation/.
python3 tools/scripts/verify.py

# Automation (verify.py, an agent at work) builds apart from .build/. SwiftPM
# locks a build directory for the length of a build or test, so sharing .build
# left the developer's `swift run Coder` waiting on "Another instance of
# SwiftPM is already running". TERMINALUI_BUILD_DIR points every harness
# script, and the swtui they call, at the automation build. verify.py builds
# it with warnings as errors; a build there without the variable changes a
# build setting and recompiles everything, so set it by hand too.
TUI_WARNINGS_AS_ERRORS=1 swift build --scratch-path .build-automation
TUI_WARNINGS_AS_ERRORS=1 swift test  --scratch-path .build-automation
TERMINALUI_BUILD_DIR=.build-automation/debug python3 tools/scripts/storybook_smoke.py

# Thread Sanitizer: run before merging anything that touches a lock, a
# Sendable conformance, a signal handler or a task. Its own scratch path.
swift test --sanitize=thread --scratch-path .build-tsan
swift build --sanitize=thread --scratch-path .build-tsan
python3 tools/scripts/storybook_smoke.py .build-tsan/debug
```

The harness builds into `.build-linux/`, not `.build/`: a shared build dir leaves
Linux ELF binaries where a later macOS run expects Mach-O, and every case dies
with `Exec format error`. Both harness scripts take an optional build-dir
argument for this. The `swift:6.2` image ships no Python, which is the only
reason the harness cannot run inside the container — PTYs work fine there.

**CI runs the same matrix twice, Linux (`swift:6.2` container) and macOS 15**,
and each leg is: `swift build` → `swift test` → warnings-as-errors debug →
warnings-as-errors release (the debug one builds the tests too: plain
`swift build` never compiles a test target) → `storybook_walk.py` → `integration_suite.py`,
which finds and runs every `test_*` script in `tools/scripts/`
(name a new one that way and it gates) → `storybook_smoke.py`. What one app
driven by one client shows is a smoke case, its terminal, environment and
project files set on the `SmokeCase`; only what takes several apps, `swtui`
or verify.py itself is an integration script. Ahead of
the build, the macOS leg runs `tool_tests.py` — every `tools/tests/test_*.py`,
the tests of the checks and of the runner's exit verdict
(`tools/terminalui/verdict.py`) — then the escape-hatch, colour-literal and
tracker-id checks, and after the release build `check_api_compat.py`: Swift's
API digester against the release `tools/api-breakage-allowlist.txt` names as
its baseline, failing on any break the list does not accept with why, and on
any listed break that no longer occurs. After a major release is tagged, the
baseline becomes the new tag and the list empties. The PTY
harness is a merge gate, not a local nicety — a change that renders differently
fails CI even with a green `swift test`. The Linux leg `apt-get install`s
python3 first; the macOS leg selects the newest Xcode on the image, because the
runner default ships Swift 6.1 and the manifest requires 6.2.

A third CI job runs `swift test`, the smoke suite and the integration scripts
against a **Thread Sanitizer** build. It catches what a crash-based test only sometimes does: the
trace recorder's race crashed one smoke run in three, and TSan reports it on
every run. Signal handlers must be installed with `sigaction` (see
`installSignalDisposition` in Terminal.swift), never `signal()`: TSan
intercepts only `sigaction`, and a handler it does not know about runs inside
whatever the thread was doing — in `free`, it aborted on TSan's own lock.
TSan also runs a signal's handler only once the thread the signal reached
calls into its runtime, and an idle app's threads sleep in the kernel: a
sanitized app sent SIGTERM while idle does not act on it until something
wakes it. The runner's stop works because closing its socket wakes the app;
a case that signals an idle app on purpose raises `CaseSkipped` when
`client.sanitizer == "thread"`.

**Every app the harness spawns is checked on the way out**, by
`tools/terminalui/verdict.py`, which `runner.py` consults as each app ends: a
case fails, even with every assertion green, if the app crashed, ignored SIGTERM, left a DEC mode it set (alternate screen,
mouse tracking, bracketed paste, hidden cursor), left its data dir after
stopping, or a sanitizer reported on it. A case that kills its app on purpose
sets `client.expected_exit_signal`; one that tests a crash calls
`client.crash()`, which raises SIGSEGV on the app's main thread — never
`kill -SEGV`, whose signal any thread may take.
The runner turns Swift's backtracer off (`SWIFT_BACKTRACE=enable=no`): on a
PTY it holds a crashed process open for 30s offering a debugger.

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
| `TerminalUIConfig` | — | Config file formats: `TOMLParser`, `KeyCombo` (the one key spelling), and the diagnostic config (`DiagConfig`, `DiagPaths`, debug-only), with `UnixSocket`, the package-only helper the debug sockets and `swtui ctl` open them with. Used by TerminalUI and the `swtui` CLI. |
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
| **Rendering** | `TerminalUI/Rendering/` | `CellBuffer`, `Compositor` (layers + delta), `OutputBuffer` (raw bytes), `Terminal` (raw mode, ANSI modes), `Rect`, `UnicodeWidth`; `SubCell/` — `AlphaCell`, `SubCellGlyph`, `SubCellRenderer`, `Compositor+Alpha` (half-block/quadrant sub-cell resolution + alpha compositing) |
| **State** | `TerminalUI/State/` | `@TerminalState`, `Binding<Value>`, `StateStorage`, `GraphContext` (`@TaskLocal`), `EnvironmentValues` |
| **Focus** | `TerminalUI/Focus/` | `FocusEngine` (dual keyboard/mouse, scope-aware arrows, directional `move()`), `FocusModifiers` (`.focusable`, `.focusScope`), `FocusableContainer`, `FocusGraphIntegration` |
| **Actions** | `TerminalUI/Actions/` | Action-context stack, scoped key-bindings |
| **Views** | `TerminalUI/Views/` | Text, VStack, HStack, ZStack, Spacer, Divider, ForEach, List, ScrollView, Button, TextInput, Toggle, Table, GeometryReader, TabView, TreeView, TextArea, DiffView, HunkDiffView, PromptInput, StatusBar, ProgressBar, Alert, Form, Picker, Navigation, BufferView, SyntaxHighlighter, UndoStack, BoundedValue(+Controls); `Split/` — SplitNode, SplitState, SplitView, SplitTreeCoding |
| **Charts** | `TerminalUI/Views/Charts/` | BarChart, Sparkline, HeatMap, BrailleCanvas, DotMatrixText, DotFont, MorseTicker |
| **Markdown** | `TerminalUI/Markdown/` | CommonMark *subset* parsed to a style-free value tree (`MarkdownBlock`, `MarkdownInline`); `MarkdownView` renders it. Scope is what agent output contains — no HTML, images, reference links, setext headings |
| **Modifiers** | `TerminalUI/Modifiers/` | `ModifiedView`, overlay modifiers + protocols, lifecycle modifiers |
| **Style / Layout / Timeline** | `TerminalUI/{Style,Layout,Timeline}/` | `Color`, `ColorBlending` (sRGB↔Oklab), `BorderStyle`, `Theme`; `Coordinate`, text layout; timeline scheduling |
| **DevTools** | `TerminalUI/DevTools/` | DebugOverlay, DebugPanel, Inspector, DevTrace, DebugStream — all `#if DEBUG` |
| **Config / CLI** | `TerminalUIConfig/`, `swtui/` | `DiagConfig`, `TOMLParser`, `KeyCombo`, `DiagPaths`; the diagnostic CLI (links TerminalUI for `swtui keys`) |

Tests live in `Tests/<Target>Tests/`, Swift Testing (`import Testing`, `@Test`,
`#expect`). Graph tests are `@MainActor`.

### Render modes

```swift
.uncapped              // benchmark: render every frame
.fps30 / .fps60 / .fps120   // presets, each a .capped(Duration)
.capped(.milliseconds(16))  // explicit frame budget
.onDemand              // zero CPU when idle, render only on events
```

### Theming

Components never hardcode colours: they read `@TerminalEnvironment(\.theme)`
and ask for a semantic *role* (`accent`, `foregroundMuted`, `errorSubtle`, …).
`check_colour_literals.py` (CI, verify.py) holds them to it: a colour named in
drawing code fails unless `tools/colour-literals.txt` lists it with why. Read
the theme once in `body` — `let theme = theme` — and pass `any Theme` down:
each read of the wrapper copies the environment, and a read inside a
`WidthReader` or `GeometryReader` closure runs against the wrong node.
`Theme` (`Style/Theme.swift`) is a protocol of ~26 roles organised as ramps
(foreground, background, status + `…Subtle`), each with a default in a protocol
extension, so a conforming theme states only what it changes.

- Unstated roles are **derived** by mixing toward the ground they sit on, in
  Oklab (`Style/ColorBlending.swift`). `ThemeDerivation.off` makes them borrow
  the nearest stated colour instead — for brand palettes where computed shades
  aren't acceptable. Every derived default must route through the one helper
  that reads that switch.
- **Every role must be a declared protocol requirement**, not just an extension
  member — the environment holds `any Theme`, and a non-requirement would
  dispatch statically and silently ignore the conforming type's override.
  `ThemeRolesTests` checks this through the existential.
- Ramp steps stay below 0.5 so a theme on terminal defaults (`Color.default`,
  unresolvable) falls back to the colour it stated.

### App entry point (a known footgun)

The public entry is `@main struct X: TerminalAppProtocol` with static
`content()` / `onEvent(_:)`. It is **NOT** `TerminalApp(view).run()` —
`TerminalApp` is an enum namespace whose `.print` etc. serve non-render contexts.
See `TerminalAppProtocol` in `Sources/TerminalUI/Core/TerminalApp.swift`.

### State in handler closures (a known footgun)

`@TerminalState` fails inside handler closures (`GraphContext.currentNode` is nil
there). Use an `@Observable` class + `Binding`; the `$binding` projected value
eagerly captures `currentNode` to fix this. Project `$state` in `body`, never
inside a `GeometryReader { … }` or `WidthReader { … }` closure (it captures the
wrong node).

### GeometryReader vs WidthReader

`GeometryReader` is greedy, as in SwiftUI: it fills what it is offered and
claims nothing when a content-sized parent measures it — give it a flexible
slot or a `.frame`. When content's height should follow from its width
(wrapping text, truncating rows, a growing prompt), use `WidthReader`: it is
handed the width only and measured by building its content for that width.
Never read a dimension the content itself decides — that was the measure/layout
cycle the split removed.

## Diagnostics & remote control (`.terminalui/` + `swtui ctl`)

Config-driven, `#if DEBUG` only. Config in `.terminalui/terminalui.toml`;
ephemeral output in a **per-process PID-isolated** dir,
`/tmp/terminalui-{hash}-{pid}/`, which `swtui status` lists and the app removes
when it quits — SIGTERM included, which it turns into a quit. Every running app
owns its own world, and nothing names "the" app — this isolation is load-bearing
for concurrent test runs. Features: `trace`, `capture`, `screenshots`, `events`,
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

With no `--pid`, `ctl` reaches the one app running from this checkout and
refuses, listing them, when several are; `--pid`, `--socket`, `--dir` choose.
`kill` requires an explicit PID (no dragnet); `reap` unlinks stale sockets whose
owning PID is dead; `list` is read-only.

A typed Python client + PTY runner live in `tools/terminalui/` (`client.py`,
`runner.py`); smoke/integration harnesses in `tools/scripts/`. Protocol: strict
one-request/one-response JSON lines over an AF_UNIX socket, served before each
frame's event drain; an idle app wakes for it. So a reply comes after every key
sent before it is drawn, and the client's `paste`/`write_raw`/`resize_terminal`
return only once the app has taken their input, and the app draws its first
frame before it answers anything: assert straight after input or spawn, never
sleep. Wait only for what lands in its own time, a `Task` or a timer, with
`wait_until(predicate)`. Spawn Storybook via PTY only.

## Documentation (DocC → GitHub Pages)

Everything user-facing lives in `Sources/TerminalUI/TerminalUI.docc/`:

| Path | What it holds |
|------|---------------|
| `Articles/` | Architecture + history prose — `UnderstandingTheAttributeGraph` (not `AttributeGraph`: an article named like a symbol replaces the symbol's page), `Layering`, `ArchitecturalModels`, `Performance`, `GettingStarted`, `KnownIssues` |
| `Tutorials/` | The guided course: `TerminalUITutorials` (the table of contents) plus per-chapter `.tutorial` files — BuildATaskList, GiveItStructure, AddInputAndTheMouse, NavigateToDetail, ShowTheNumbers, ArchitectForGrowth, MakeItProduction |
| `Resources/` | Tutorial code steps (`tasks-SS-NN.swift` for chapter 1, `tasks<chapter>-SS-NN.swift` after), chapter cards, and demo GIFs |

```bash
TUI_BUILD_DOCS=1 swift package generate-documentation   # one-shot build
tools/scripts/preview_docs.sh                           # local preview, live reload
tools/scripts/preview_docs.sh 9000 TerminalUIIO         # explicit port / target
```

Use the wrapper, not the bare plugin: SwiftPM detaches `docc` into its own
process group, so a plain `kill`/`pkill` (SIGTERM) reaps only the wrapper and
leaves `docc` squatting the port. The script probes upward for a free port and
translates INT/TERM/HUP into the SIGINT that actually takes the tree down.

`.github/workflows/docs.yml` deploys to Pages on every push to `main`. It does
four things beyond `generate-documentation`, all of which break silently if a
path moves: swaps DocC's 404ing root for `.github/pages/index.html`, injects
`reference-pane.{js,css}` + `docc-fixes.css` into every SPA bootstrap copy (so
reference links inside tutorials open in a slide-over instead of navigating
away), and zips the tutorial's final step — `Resources/tasks-04-01.swift`, the
single source of truth — into the downloadable sample project. The
`--hosting-base-path` is derived from the repo name; don't hardcode it.

**The tutorial code steps are real, compiled-by-the-reader code.** Changing a
public API means updating the affected `Resources/tasks-*.swift` steps and the
`.tutorial` files that narrate them, or the course teaches an API that no longer
exists.

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
- **Concurrency escape hatches are listed.** `@unchecked Sendable` and
  `nonisolated(unsafe)` switch the compiler's checking off, and every data race
  this framework shipped sat behind one. Prefer what the compiler checks:
  `Mutex` / `Atomic` (Synchronization) with a plain `Sendable`, or `@MainActor`.
  Where that is impossible, add the declaration to `tools/escape-hatches.txt`
  with what actually guards it; `check_escape_hatches.py` (CI, verify.py) fails
  on any hatch the list does not name, and on any entry whose hatch is gone.
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

## Work tracking (`design/`)

`design/` holds planning that outlives a session but isn't user documentation:

- **`design/crush-parity.md`** — a study of `charmbracelet/crush` against this
  framework, and the gap ledger driving current work. Read §5 first: the rule is
  that **the demo is the forcing function**. `Examples/Coder` gets built, and
  each framework feature is built at the moment the demo actually needs it. The
  ledger is not a work queue — an item the demo never demands never gets built.
- **`tools/scripts/kanban.py`** — the board. Cards carry a type (`bug`, `gap`,
  `feature`, `chore`), a lane, blockers, and a `lessons` list.

  ```bash
  tools/scripts/kanban.py board            # columns
  tools/scripts/kanban.py show <card>      # one card in full
  tools/scripts/kanban.py lessons          # every lesson, with the card that earned it
  tools/scripts/kanban.py move <card> doing
  ```

The board file (`design/board.jsonl`) is **gitignored** — it is working state,
not project truth, and its ids must never appear in code, comments, or commit
messages (see Code standards). Anything the repo should remember permanently
gets promoted out of the board into code, tests, or a document here; a card is
done when its lesson has a home that is not the board.

## Orientation for new sessions

Don't explore the codebase from scratch: start with `git log --oneline -10`
for what changed recently and `git diff HEAD~N` for what's in flight, and
read the DocC articles under `Sources/TerminalUI/TerminalUI.docc/Articles/`
for architecture and performance history.

Commit subjects here are written as prose lines, not `type(scope):` prefixes —
match the existing style rather than introducing conventional commits.
