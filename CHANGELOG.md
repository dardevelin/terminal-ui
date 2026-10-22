# Changelog

All notable changes to TerminalUI are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **`CursorFlash`, as `@TerminalEnvironment(\.cursorFlash)`** — the focused
  cursor's flash at a wall, which a running app supplies. An input that draws
  a cursor of its own reads `isLit` while it holds focus, as the framework's
  inputs do.
- **Users can keep their own editing keys, if the app lets them.** An app
  opts in with `TerminalAppProtocol.userKeymap` — `.configFile(named:)` for
  `keys.toml` in the user's config directory (`$XDG_CONFIG_HOME`, or
  `~/.config`), `.file(at:)` for any other — and the file's bindings lie over
  the app's keymap. The file is TOML, keys written as `ctrl+k` or
  `shift+enter`; a line that cannot be read is printed with its number and
  the rest still applies. `.allowsUserKeymap(false)` keeps a subtree's keys
  the app's. Coder reads `~/.config/coder/keys.toml`. `swtui keys` lists the
  commands and their keys, and `swtui keys --check <file>` checks a file.
  An app reads the file's problems from `@TerminalEnvironment(\.userKeymap)`
  to show them, as stderr is hidden once it has the screen.
  `InputBinding(keySpec:)` reads a chord as a person writes it, and
  `TOMLParser.document(_:)` reads quoted keys, string arrays and comments
  after a value, with the line of each.
- **One keymap for text editing, the same in every input.** TextInput,
  TextArea and PromptInput perform one set of named `TextEditCommand`s —
  Ctrl+A/E and Home/End to the line's ends, Alt+B/F and Alt+←/→ by word,
  Ctrl+K and Ctrl+U to kill to either end of the line, Ctrl+W back to
  whitespace, Alt+Backspace and Alt+D a word, Ctrl+Y to yank the last kill,
  Ctrl+Z / Ctrl+Shift+Z to undo and redo — through one engine. These are
  readline's keys, which Claude Code, Codex and Crush follow, and which macOS
  terminals send for Command and Option chords: Cmd+← arrives as Ctrl+A.
  `TextKeymap.standard` holds them, and `.textKeymap(_:)` rebinds keys for
  a subtree. A key binds an ordered list of commands, and the focused input
  performs the first that means something to it, as a key goes up Cocoa's
  responder chain: Enter is `[.submit, .insertNewline]`, so a prompt sends,
  an editor starts a line, and a single-line field leaves Enter to the app;
  Up and Ctrl+P are `[.moveUp, .previousHistory]`; Enter with any modifier
  is a new line. A prompt that takes Enter as a new line and sends on
  Shift+Enter is two bindings. `merging(_:)` replaces a key's list, and an
  empty list unbinds it. `TextEditCommand` is an open name, as `ActionID`
  is, so a keymap can bind a command the framework does not declare. One
  `KillBuffer` serves the app, so a kill in one input yanks into another;
  `\.killBuffer` gives a subtree its own. A key whose commands have nothing
  to do passes on to the app, as Ctrl+D on an empty line does in readline.
- **A `crash` remote command** (debug builds) — the app raises SIGSEGV on its
  own main thread, as a fault in its code would; the Python client's `crash()`
  sends it. Crash tests that sent the signal with `kill` passed or failed by
  chance under Thread Sanitizer.
- **`.scrollPosition(id:anchor:)` with a binding** — SwiftUI's two-way scroll
  position. Set the binding and the view with that `.id(_:)` scrolls into
  sight, at the anchor; scroll, and the binding is set to the view now at the
  anchor. The view is moved only when the bound id changes, so a reader can
  scroll away from it.
- **`.defaultScrollAnchor(_:)`** — where enclosed `ScrollView`s open, and what
  they keep in view as their content changes size. `.bottom` is a transcript's
  tail: it opens on the latest entry and follows new ones in; scroll away and it
  stays where it was left, scroll back to the end and it follows again. SwiftUI's
  name and meaning, with `Alignment` in place of `UnitPoint`.

- **`PromptPrefix` and `.promptPrefix(_:)`** — replace a `PromptInput`'s prompt
  glyph with a column drawn per row and for focus, such as Crush's composer:
  `>` on the first row while focused, `:::` on the rest. Every row's prefix is
  the stated width, and the text wraps in what is left.
- **`PromptInput(placeholder:)` and `PromptInput(minimumHeight:)`** — a faint
  placeholder while the buffer is empty, with the cursor on its first
  character; and a floor on the prompt's height, the rows past the text
  carrying the prefix's continuation.
- **`VStack(alignment:spacing:)`, `HStack(alignment:spacing:)`,
  `ZStack(alignment:)`** — with `HorizontalAlignment`, `VerticalAlignment` and
  `Alignment` value types. The defaults are `.leading` / `.top` rather than
  SwiftUI's `.center`: every layout written against this framework assumed
  top-left placement, and a centring default would silently move all of them.
  Spacing defaults to none, the unit being a whole cell.
- **`alignment:` on `frame`, `overlay` and `backgroundView`.** A view smaller
  than its frame now has a stated placement rule, and an overlay can be pinned
  to a corner — `.overlay(alignment: .topTrailing) { … }` for badges, close
  buttons and corner indicators. An overlay aligns within the *base view's*
  frame, not the rect its parent handed down, so a badge pins to the thing it
  belongs to rather than to the screen edge.
- **`.task { }` and `.task(id:)`** — async work owned by a view: started when it
  appears, cancelled when it leaves, restarted when the id changes. The action
  is `@MainActor`, so an app touches its `@Observable` model inside it the same
  way it does in `onAppear`, with no hop and no wrapper.
- **`.padding(_ edges:_ length:)`, `.padding(EdgeInsets)`, `Edge` and `Edge.Set`**
  — padding on the sides you name, in SwiftUI's words. A message keeps a column
  of room beside its rail without blank rows above and below it.
  `BorderEdges` is now `Edge.Set`, so borders and padding name their sides
  alike; existing `.border(edges:)` calls are unchanged.
- **`WidthReader`** — hands its content the width it is given and is as tall as
  that content is at that width: the container for text that wraps, rows that
  truncate, and a prompt that grows. The content receives the width only, so it
  cannot read back the height it decides.
- **`@Binding`, `$value.property` and `Binding.constant(_:)`** — `Binding` has
  SwiftUI's shape. A child view that edits a value it does not own declares it
  `@Binding var value`; `$value.field` derives a binding to one property, writing
  the whole value back; `.constant(x)` reads `x` and ignores writes. Hand-built
  `Binding(get:set:)` still works.
- **`MarkdownStyle` and `.markdownStyle(_:)`** — restyle any markdown element
  per subtree: colour, background, weight, and a prefix and suffix, so headings
  can keep their `##` markers and inline code can be a padded chip. Every field
  starts unset and an unset field keeps the theme default, so a style states only
  what it changes. A heading level beats every heading, which beats the whole
  document (`text`), which beats the default; `text.background` fills the whole
  document, blank rows included.
- **`CodeView`** — read-only source, highlighted by language and numbered from
  any line, so an excerpt keeps the numbering of the file it came from. Long
  lines follow `.wrap(_:)`; a wrapped line continues under its code, not under
  the gutter. It takes no focus.
- **`Theme.syntax`** — code colours are a theme role, like `border`. `CodeView`,
  `MarkdownView`'s fenced blocks and a highlighting `TextArea` all follow it;
  the stock value is `SyntaxTheme.defaultDark`, the palette they drew before.
- **`.syntaxHighlighter(_:for:)` and `SyntaxHighlighters`** — register a lexer
  for a language, and every view handed that language uses it. Registration
  adds to what a subtree inherits rather than replacing it. Swift is standard.
- **`transformEnvironment(_:transform:)`** — edit an inherited environment value
  for a subtree instead of replacing it. SwiftUI parity.
- **`SyntaxHighlighter.highlight(lines:theme:)`** — colour a document line by
  line with tokenizer state carried across lines; stretches a lexer leaves
  unclassified are drawn plain rather than dropped.
- **`ScrollbarStyle` and `.scrollbarStyle(_:)`** — the glyphs a scroll view's bar
  is drawn with, per subtree: `.thin`, `.block`, `.hairline`, or your own. The
  edge arrows are their own optional `ScrollEdgeMarkers`, so they can go while
  the bar stays.

### Changed

- **One spelling for keys.** The debug keybindings, `swtui bind`, a user's
  `keys.toml` and the remote control's `send-key` read keys through one
  grammar, `KeyCombo`, where each had its own and they disagreed: `meta` is
  Alt everywhere now, `space` and `F13`–`F24` are keys everywhere, and an
  unknown modifier in `send-key` is an error where it was dropped.
- **`terminalui.toml` is read as TOML.** A comment after a value is no
  longer part of it, and quoted keys and escapes are read; a value TOML
  cannot read — an unquoted word — is skipped where it used to be taken as
  text.
- **Ctrl+Y yanks in TextArea; redo is Ctrl+Shift+Z.** Ctrl+Y was a redo
  alias there, and nowhere else. To keep it,
  `.textKeymap(.standard.merging([.keyboard(.character("y"), .ctrl): [.redo]]))`.
- **Word movement in TextArea goes by letters and digits**, as Alt+B/F do in
  readline and Emacs: Ctrl+←/→ stopped only at whitespace, so `path/to/file`
  was one word. Ctrl+W still deletes back to whitespace.
- **`TextArea` draws in theme colours.** Its literal cyan cursor, blue
  selection, grey gutter and disabled text are now the theme's `accent` (with
  `foregroundEmphasis` under the cursor), `backgroundSelected`,
  `foregroundMuted`, and `foregroundFaint` for the `~` rows past the end. The
  stock theme reproduces the old colours, except the `~` rows: they were a
  darker 256-colour grey and are now `foregroundFaint`.
- **`TextInput` and `TextArea` draw their cursor only while they hold focus**,
  as `PromptInput` now does. Two fields both showing a cursor left the user to
  guess which one keys would reach.
- **`PromptInput` draws its cursor only while it holds focus, in theme
  colours.** The cursor was drawn whether or not keys would reach the prompt.
  Its literal cyan, white and greys are now the theme's `accent` (prompt glyph,
  cursor), `foregroundEmphasis` (the character under the cursor),
  `foreground` (text), `foregroundMuted` (collapsed pastes, the paste hint,
  the badge on `backgroundRaised`) and `foregroundFaint` (placeholder).
- **Resolving TerminalUI now clones nothing.** `swift-docc-plugin` was declared
  unconditionally, so every consumer fetched it and `swift-docc-symbolkit` to
  build a package that references neither — SwiftPM has no dev-only dependency.
  It is opt-in behind `TUI_BUILD_DOCS=1`, the same shape the strict-warnings
  gate already used. Building documentation is unchanged:
  `TUI_BUILD_DOCS=1 swift package generate-documentation`.
- **Framework-drawn affordances take theme roles.** The scrollbar thumb and edge
  arrows use `borderActive`, its track `separator`, the focus bar `accent`, and
  the read-only and hover bars `foregroundMuted`. The stock theme's values are
  the colours drawn before. The default scrollbar thumb is now a heavy line
  (`┃`) rather than a full block; `.scrollbarStyle(.block)` keeps the old one.
- **`GeometryReader` is greedy, as in SwiftUI.** It fills what it is offered, and
  when a container that sizes to its content measures it, it claims nothing.
  It used to report the height of whatever its content had last been built at,
  and three passes built it at three sizes, so a parent's measurement depended
  on which ran last. Content whose height follows from its width belongs in
  `WidthReader`; `TextInput`, `PromptInput` (`.fixed`/`.unbounded`), `TabView`,
  `StatusBar` and `BarChart` moved there.
- **Markdown rows paint only the fills something stated.** Prose no longer
  paints the theme's ground behind its text, so markdown inside a panel of
  another colour shows that panel; a code block's fill now reaches the edge of
  its column instead of stopping where its text does.
- **A markdown quote keeps a column of room beside its rail** (`┃ quoted`),
  on every row it wraps to, instead of the rail touching the text.
- **`PaddingModifier` carries `insets: EdgeInsets`** instead of `amount: Int`.
  Code that read `amount` reads `insets`; `.padding(n)` itself is unchanged.
- **`TextArea(theme:)` is optional and follows `Theme.syntax` when omitted.** The
  stored `theme` property is now `SyntaxTheme?`; passing a theme still wins.
- **`DiffView` takes focus only when it has rows below its viewport,** and draws
  in theme roles (`success`, `error`, `foregroundMuted`, `foregroundEmphasis`,
  `separator`). A diff that fits is content: it no longer becomes a Tab stop
  that swallows the arrows meant for its container.

### Deprecated

- **`BoundaryFeedbackEmitter.emit(reason:env:callback:)` and `bellSink`.** No
  input calls them any more: they read the environment's `boundaryHit`
  instead, and the bell is the environment's `\.bell`. `bounceSink` stays the
  `.bounce` hook. Both keep working until the next major version.
- **`.scrollPosition(id:)` with a value.** It re-applies its target every
  frame, so a reader cannot scroll away from the view it names — the Storybook
  sidebar snapped back to the selected page under the wheel. Bind the position
  with `.scrollPosition(id:anchor:)`, or follow a tail with
  `.defaultScrollAnchor(.bottom)`. It keeps working until the next major
  version.

### Fixed

- **`.boundaryFeedback(.bounce)`, the default, shows something.** It called
  a hook nothing filled, so a wall hit in any input was silent. Now the
  focused cursor lights in the theme's warning colour for a tenth of a
  second, and an app's own `bounceSink` is still called. `.bell` and `.none`
  remain a modifier away.
- **Text inputs no longer re-run on every frame.** Since the bell came
  through the environment, the editing context every input reads compared
  as changed from one frame to the next — a closure made afresh on each
  read, and padding bytes after a one-byte field — so each TextInput,
  TextArea and PromptInput rebuilt its body on every active frame.
- **An app quits when its terminal goes away.** The kernel sends SIGHUP only
  to a terminal's controlling process; an app without one — started by a
  harness, or in a detached multiplexer pane — learned of the hang-up from
  stdin alone. macOS reports a hung-up terminal readable and empty, so the
  input thread spun a core for as long as nobody killed the app; on Linux the
  input stopped and the app ran on with no terminal. A hang-up is now handled
  as SIGHUP, through the app's teardown, and a key the hang-up cut short is
  not delivered.
- **On Linux, an app stopped by a signal dies by it.** After teardown the
  runtime re-raised the signal on a thread that blocked it, so it stayed
  pending and the app exited 0 — its parent could not tell it was stopped.
  The signal is unblocked first, and the test harness now fails an app that
  exits 0 on SIGTERM.
- **`.boundaryFeedback(.bell)` rings.** It called a bell sink nothing had
  installed, so a wall hit was silent. The bell now comes from the running app,
  through the environment, and BEL goes out with the next frame — on its own
  when that frame changed no cell.
- **A trackpad does not leave the app behind.** A trackpad reports a scroll,
  or a hover sweep, as hundreds of events a second, and each one found what was
  under the cursor afresh — the wheel three times over. A debug build under
  Thread Sanitizer fell seconds behind and stopped answering its control
  socket. Now a run of wheel notches at one cell is routed once and moves its
  target by the whole run, stopping at the first step nothing takes, and of a
  run of moves only the last is routed, as AppKit coalesces mouse-moved events.
  `FocusEngine.routeWheel` takes a `steps` count; `onEvent` still sees every
  event.
- **Each app is addressed by its own id.** `swtui ctl` without `--pid`
  followed `latest.sock`, the most recently started app's socket, so an app a
  test harness launched took over a developer's `swift run Coder` session,
  and when it exited left `ctl` with nothing to reach. Now `ctl` reaches the
  one app running from the checkout and, when several are, refuses and lists
  them by pid and name; `swtui ctl list` and `swtui status` show each app,
  including those writing inline with `use_tmp = false`. Apps no longer
  publish `latest.sock`, nor point `.terminalui/data` at themselves — the
  same "newest wins" choice, which every app a harness started claimed; `swtui
  status` lists each app's dir instead, and `DiagPaths.updateDataSymlink()`
  is deprecated. The Python client requires a `pid`. New in `DiagPaths`:
  `runningApps()`, `debugApps()`, `removeDeadApps()`,
  `socket(inRemoteDir:pid:)`, `isAlive(_:)` and the app-name record.
- **SIGINT, SIGTERM and SIGHUP quit through the app's teardown.** The handler
  restored the terminal and died on the spot, since little else is safe in a
  signal handler, so every app ended that way — each one a test harness
  stops, each closed terminal tab — left its socket and output in `/tmp` and
  never wrote its trace summary. The first such signal now asks the running
  app to quit, as a key would, and it dies of the signal after tearing down,
  so the parent still sees it; a second signal ends it at once. `swtui ctl
  reap` removes the whole output of an app that crashed or was killed, not
  just its socket, and the harness flags an app that stopped normally but
  left its output behind.
- **`swtui clean` leaves running apps alone.** It deleted every per-process
  dir of the checkout, the sockets of live apps among them, breaking a
  running session; it now skips live processes and says which.
- **`swtui status` shows the running apps.** It reported the CLI's own data
  dir, which no app writes, as "not yet created".
- **An idle app costs nothing.** An `.onDemand` app — documented as zero CPU
  when idle — polled for work every millisecond, every app polled for a
  resize every 16ms, and the input thread woke ten times a second. Now an
  event, a change to observed state, a resize and a remote command each wake
  the frame loop, which otherwise sleeps; the input thread blocks in one
  `poll()` between events, and SIGWINCH writes to a pipe it watches. A capped
  mode such as the default `.fps60` sleeps the same way and still draws at
  most one frame per interval. An idle `.onDemand` app went from about 2% of
  a core to nothing measurable. `TerminalRuntimeError.wakePipeUnavailable` is
  new: the runtime throws it when it cannot open those pipes, and
  `Terminal.checkResize()` is deprecated, since nothing needs to poll.
- **A remote command reaches an idle app.** `swtui ctl inspector-toggle`, a
  focus set and a screenshot changed what is drawn but asked for no frame,
  and `invoke_action app.quit` fired a quit only a key's handling looked for,
  so an idle `.onDemand` app did neither until the next keypress.
- **A modal presented from inside a modal is drawn.** A presentation is drawn
  after the tree, over the whole screen; one declared while drawing another
  was added to a list that had already been read, so an alert raised from a
  sheet never appeared. Presentations are now drawn level by level, each over
  the one before.
- **A dialog owns the keyboard and the pointer.** Focus contained itself to
  the first dialog at the deepest level while a later one at that level was
  drawn over it, so Tab walked a dialog the user could not see. A key or an
  action binding the dialog did not take climbed out into the view that
  declared it, and a click on a `.onClick` row, a hover, or the wheel reached
  the content under the dim; only focusable controls had been fenced off. Hit
  testing pruned by the rect of the declaring view, so the inspector and
  `swtui ctl probe` missed any dialog declared below the root. The renderer,
  focus, key routing, hit testing and every pointer path now agree on one
  order of presentations — level by level, then tree order — and on the one
  drawn on top.
- **`containmentDepth` is right after a partial update.** A dialog whose view
  re-evaluated on its own restamped its content at depth 1 whatever enclosed
  it, and a node a reader rebuilt during layout read 0. The depth is now read
  from the tree.
- **`TerminalApp.print` may run on several threads at once.** What a render
  had left to draw was kept in statics every render shared, so two at once
  drew each other's dialogs or crashed. The renderer now keeps no state
  between calls.
- **An `@Observable` model may change on any thread.** Observation reports a
  change on the thread that made it, and the graph marked the node and wrote
  its drain queue right there, racing the frame that was reading both; under
  load the queue's dictionary was corrupted and the app crashed. The changing
  thread now only records the node under a lock, and the main actor marks it
  at the start of the next frame, as SwiftUI does for `@Observable` models.
  `AttributeGraph.hasDirtyNodes` is read-only.
- **A change that lands while the graph updates is no longer dropped.** The
  update cleared the dirty flag when it finished, discarding a change made
  meanwhile, so an `.onDemand` app showed the old value until something else
  changed. The flag is now cleared only when no change is pending.
- **Quitting waits for the input task before closing its wake pipe.** The
  runtime cleared and closed the pipe while the input task, cancelled but
  still running, could be reading it: it could poll a closed descriptor, one a
  later cleanup had reopened, or fall back to a blocking read of the shell's
  stdin. The task is now awaited first; the wake byte stays in the pipe so a
  half-parsed escape sequence gives up at once; and `StdinByteSource.shutdownReadFD`
  is held atomically, with the same API.
- **A control client that hangs up no longer kills the app.** `swtui ctl kill`
  sends its quit and disconnects without reading the reply; the reply then went
  to a closed socket, SIGPIPE ended the app inside the write, and nothing
  restored the terminal, which was left in raw mode with mouse tracking on.
  Socket writes now pass `MSG_NOSIGNAL`, so a gone peer is an `EPIPE` the
  server handles, and SIGPIPE stays the app's to decide.
- **Scrolling no longer crashes debug builds.** The input task records each
  event's bytes in the dev trace while the render loop opens and closes frames
  on another thread, and both wrote one unguarded array — a burst of wheel
  events crashed it, and debug builds trace their first hundred frames by
  default. The recording is now behind a lock. Input traced between frames
  goes into the next frame instead of being cleared away, and nothing is
  recorded past the frame limit.
- **A crash restores the terminal.** Only SIGINT, SIGTERM and SIGHUP put it
  back; a crash left raw mode, the alternate screen and mouse reporting on, so
  the backtrace printed as a staircase over the last frame and the shell went
  on receiving mouse coordinates as typed text. SIGSEGV, SIGBUS, SIGILL,
  SIGFPE, SIGTRAP and SIGABRT now restore it first, then go to the handler they
  had before — the Swift backtracer still prints, on the restored screen.
- **Content that gains children is measured again.** A `ForEach` that gained
  elements — and a stack whose children were rebuilt, a split re-laid, an
  overlay or modal added or removed — left the cached sizes above it in place.
  A scroll view sizes its content by measuring it, so a line appended to a log
  was built and never drawn.
- **An environment change reaches views whose inputs did not change.** The
  update walk skips a view whose inputs compare equal, and everything under it —
  so a theme switched by `.environment(\.theme, …)` above an unchanged view never
  reached the views below. `@TerminalEnvironment` now records the value each
  body read, and the bodies whose values changed run again, wherever they sit
  under the skipped view; the others still do not.
- **A view can read whether it holds focus.** `isFocused` and `focusedID` were
  documented environment values that nothing ever set, so no view could tell
  whether keys would reach it. A `.focusable()` view's content now reads
  `@TerminalEnvironment(\.isFocused)` as in SwiftUI — true while the nearest
  focusable above it holds focus — and the runtime binds `focusedID` every
  frame. When focus moves, only the bodies that read either value run again:
  `@TerminalEnvironment` records what each body read.
- **A body rebuilt outside the update walk sees the environment above it.** The
  walk applies each environment modifier on its way down; the two paths that
  evaluate a body without it did not. A body re-run in place after an
  observable changed, and a `GeometryReader`'s content rebuilt during layout,
  saw the frame's bare environment — under `.environment(\.theme, …)` they drew
  with the default theme. Both now resolve the environment from the modifiers
  above them, once.
- **An app's `.actions` answer keys while nothing is focused.** With no focused
  view, dispatch started from the graph root and walked up — past none of the
  scopes an app declares, which all sit below it — so Escape and Ctrl+C always
  reached the framework defaults and an app could not override them. A key with
  no focused view is now addressed to the window: dispatch starts at the
  innermost node wrapping all of it, and meets every scope applied to the app
  as a whole, and none applied to one part.
- **A modifier's child is measured at the width it is laid out at.** Padding, a
  border's drawn edges and a frame's width all narrow the space a child gets,
  but its height was measured at the outer width — so wrapped text inside a
  border reserved too few rows and the box clipped its last line. Measurement
  now asks the same rule layout uses.
- **Measurements follow what they measured.** A changed `Text` invalidated
  cached sizes up through layout containers but stopped at the first modifier,
  whose cached size is its child's — so `Text(…).foreground(…)` kept its old
  width. And width, unlike height, reused cached answers for containers whose
  composite-view content can change without marking them dirty. Both now
  re-measure; a view's width follows its content when it changes.
- **Styled text fills its frame the way plain text does.** A `Text` with any
  styled run wrote only its glyphs, while plain text padded each line to its
  frame — so `.background` behind coloured text stopped where the text did.
  Both now own the rows they write, edge to edge.
- **A vertical scrollbar no longer covers the content's last column.** Content
  that overflows is laid out one column narrower so the bar has its own; the
  last character of a full-width line, or the `…` a truncated line ends on, was
  being painted over.
- **A `Divider` still spans a stack that is centred or trailing-aligned.**
  Alignment measures a child so it can place it, and a `Divider` measures one
  cell while drawing across whatever it is given — so it collapsed to a single
  dash floating mid-stack. Anything that fills its cross axis, including
  `.frame(maxWidth: .infinity)`, keeps the whole width under any alignment.
- **A stack's spacing counts toward its measured size.** The measurer summed
  its children and ignored the gaps, so any parent sizing a spaced stack — a
  centred stack, a border, a frame — under-measured it and clipped the last
  child by exactly the total gap.
- **`swtui ctl` commands reach an app that already has a client attached.** The
  remote-control server accepted a connection only while none was open, so a
  second client's request sat unread in the kernel's backlog — its write
  succeeded, so `swtui ctl kill --pid <N>` reported `status=quit-sent` against
  an app that never heard the command and never exited. Every connection is
  served now, still one request at a time.
- **A stack honours an explicit `.frame` on the axis it does not stack along.**
  A stack handed every child the whole of its cross axis, so
  `.frame(width: 8).border()` in a `VStack` drew its box at the stack's width
  and only the text inside reflowed — the box never resized. A child that asks
  for a size now gets it; a child that asks for nothing still fills the axis,
  which is what `Divider` and every background-filling row rely on.
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
- **Quit hang fixed** via POSIX self-pipe: pressing `q` now exits in
  ~2.4ms (previously ≥100ms because `read(STDIN_FILENO)` blocks cancellation).
- **Focus scopes**: `.focusScope(_ id: String)` groups focusables.
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
