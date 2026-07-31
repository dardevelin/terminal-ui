# Changelog

All notable changes to TerminalUI are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **`.task { }` and `.task(id:)`** — async work owned by a view: started when it
  appears, cancelled when it leaves, restarted when the id changes. The action
  is `@MainActor`, so an app touches its `@Observable` model inside it the same
  way it does in `onAppear`, with no hop and no wrapper.

### Fixed

- **State mutated outside an input event now reaches the screen.** The run
  loop's render gate consulted only `needsRender`, which the event paths set —
  so `Task { model.x = await fetch() }` marked the graph dirty and the frame was
  dropped until the user happened to press a key. `.onDemand` was worse: its
  idle loop had no way to be woken by state at all. Both arms now consult
  `hasDirtyNodes`, the atomic observation tracking already maintains. Idle cost
  is unchanged — one atomic read on a loop that was already polling.

- **Down walks every row of a `Form`.** Arrow navigation stepped over rows and
  stopped partway: the stacks a result builder introduces were dropped from the
  focus walk along with their children, so a `Section` of any size presented one
  destination — and a stack holding arrows at its last child ended the walk at
  the first section boundary.
- **The focus bar draws inside a scroll container.** It was skipped for any node
  with a scroll ancestor, which since `Form` composes a `ScrollView` meant every
  control in every form went unmarked. The bar is now clipped to the viewport
  instead of dropped, so a row scrolled out of view still leaves nothing behind.
- **The arrow cursor visits read-only rows.** `LabeledContent` and `Gauge` are
  rows, so a settings screen's closing section is somewhere the cursor goes;
  Tab still skips them, because a stop where Enter does nothing is worse than
  no stop. They are marked by their own cursor — a lighter `┆` in grey rather
  than the solid cyan `▎` — so "you can read this, not operate it" is stated by
  shape as well as by colour.
- **A list on its last row stops promising more.** The ▼ and the scrollbar
  thumb were derived from the content's *measured* height, which counts rows
  that draw nothing, so a pane padded out by a fixed frame or a trailing spacer
  sat on its last row still advertising content below — and still scrolled,
  into blank space. Both now follow what the content actually drew.
- **Arrows read past the last control.** A form's final rows are routinely the
  ones with nothing to focus — a version string, a gauge, a footer — and
  scroll-to-focused only ever follows focus, so they were laid out, drawn, and
  unreachable from the keyboard. When focus has nowhere left to go, the region
  holding it scrolls instead; a key that changes nothing stays unclaimed.
- **The mouse wheel scrolls past a focusable that ignores it.** A focusable
  under the cursor still gets first refusal — a `List` or `TextArea` scrolls its
  own contents — but refusing now falls through to the deepest scroll region
  rather than ending the search.
- **`Stepper`'s ◂ ▸ take clicks**, like every other affordance the framework
  draws. The label is measured as drawn, so a stepper inside a `Form` reads its
  own padded column correctly.
- **A scrollbar takes clicks.** Its ends step the viewport and the track jumps
  it; the cells belong to the scroll view, so a press does not also activate the
  row painted underneath.

- **`Form` scrolls when its content outgrows the space it is given.** An
  overflowing form was clipped while its off-screen rows stayed focusable, so
  Tab landed on controls the user could not see. `Form` now composes the
  shipped `ScrollView`; the label column is still measured across every row,
  on screen or not, so it does not shift as rows scroll past.
- **A `ScrollView` inside a container that sizes itself to its content —
  `.border()`, `.padding()` — no longer collapses to an empty box.** It now
  reports the size of its content and accepts less, while a stack still hands
  it whatever its siblings leave.

## [1.0.0] — 2026-07-20 — First public release

The package now lives at the repository root, so the documented
`.package(url:)` install resolves, and it is named `TerminalUI` rather than
after the directory it used to sit in.

### Added

- **`TerminalInk`** — zero-dependency styled output: colour model, capability
  detection, ANSI SGR, `StyledString`. Usable for tooling that wants styled
  stdout without a render runtime.
- **`TerminalLog`** — structured logging on top of Ink: levelled coloured
  prefixes, console and file sinks, ANSI stripping for non-TTY targets.
- **`TerminalUIIO`** — opt-in image and media: `ImageBuffer`, decoder seam,
  half-block renderer, sub-cell glyph atlas, and a pure-Swift RFC 1951 inflate.
- **Action graph** — `Action`, `ActionScope`, `.actions { }`, and input
  bindings dispatched by walking the focus chain. Ctrl+C and Escape are
  framework defaults an app can shadow. Exposed over the remote-control socket
  so external tools can enumerate and invoke actions.
- **`ActionContext`** — a mode stack for scoped key bindings, i3-shaped.
- **`SplitView`** — split-pane primitive whose tree is the state, plus the
  `FocusableContainer` protocol that drives directional focus for every
  container kind. Panes are focusable units, so a pane holding nothing
  focusable is still somewhere the user can go.
- **`.alert` / `.confirmationDialog`** — SwiftUI-shaped dialogs with role-tagged
  actions. Escape dismisses and fires the cancel action; Return activates the
  default, which also takes initial focus; a destructive action is never
  focused first.
- **Modal focus containment** — Tab cannot leave a presented dialog.
- **Boundary feedback** — `.onBoundaryHit` fires at a component's edges, with
  `TextInput`, `TextArea` and `PromptInput` emitting.
- **`PromptInput`** — Claude Code-shaped prompt with soft wrap, paste markers,
  and buffer references.
- **`Timeline`** — animation primitive: frame stepper and eased progress.
- Views and modifiers: `.disabled()` with visual dimming, `.flexible()`,
  `.scrollPosition(id:)`, `.onPaste`, `.onHover`, `.focusGranularity(_:)`,
  `.focusBoundaryPolicy(_:)`, scrollbars, syntax highlighting, TextArea
  undo/redo.
- **Diagnostics** — per-process data directories, the `swtui ctl` remote-control
  protocol, and a PTY-driven harness that drives the real apps.
- **CI** — build, test, the warnings-as-errors gate, release build, and the
  visual harness on macOS and Linux.

### Fixed

- **Control characters in user-supplied text reached the terminal.** Cell bytes
  are copied verbatim to the file descriptor, so an escape sequence in any
  string the program did not control — a filename, a chat message, a branch
  name — was executed rather than drawn. Cells now refuse C0, DEL and C1.
- Terminal escape state no longer leaks to the parent shell on signal or abort,
  and mouse tracking no longer survives exit.
- Arrow navigation had two parallel implementations, only one of them reachable;
  they are now one path dispatched through `FocusableContainer`.
- Paste neutralises line terminators per scalar, so a CRLF pair can no longer
  smuggle a newline into a single-line field.
- Wrapping and truncation measure display cells rather than grapheme count.

### Changed

- `GraphContext` moved from `nonisolated(unsafe)` statics to `@TaskLocal`.
- Layout is its own phase: it owns `GeometryReader` rebuilds, and render is
  pure.
- **885 tests across 182 suites**, on macOS and Linux.

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

[Unreleased]: https://github.com/dardevelin/terminal-ui/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/dardevelin/terminal-ui/compare/v0.8.0...v1.0.0
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
