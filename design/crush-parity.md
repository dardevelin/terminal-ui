# Crush parity — what makes Crush look like Crush, and what TerminalUI is missing

A study of `charmbracelet/crush` (Go, Bubble Tea v2 / Lip Gloss v2 / Bubbles v2)
against TerminalUI, aimed at one deliverable: **a demo app that reads as
Crush-grade, built on TerminalUI alone.**

Sources studied: `internal/ui/**` (36,652 lines of non-test Go across
`styles`, `common`, `list`, `dialog`, `chat`, `completions`, `diffview`,
`logo`, `anim`, `model`, `image`, `exitbanner`, `notification`), plus the
Charmtone palette from `charmbracelet/x/exp/charmtone`.

---

## 1. The headline finding

Crush's aesthetic is **not** a Bubble Tea capability. Bubble Tea is an Elm loop;
Lip Gloss is a string decorator. Neither is more capable than TerminalUI's
retained attribute graph and cell compositor — in render architecture we are
ahead, not behind.

What Crush actually has that we don't is **design infrastructure**, and it
decomposes into exactly three things:

1. **A ~30-role semantic palette** (`quickStyleOpts`) resolved from a
   ~60-color brand palette (Charmtone), with one builder function
   (`quickStyle()`) that expands it into every widget's styling.
2. **An exhaustively-specified style surface** — `styles.Styles` is a 704-line
   struct of named slots (`Tool.JobIconPending`, `Dialog.Sessions.RenamingPlaceholder`,
   `Messages.ShellBarFocused`). Nothing is styled ad hoc at a call site.
3. **A small vocabulary of signature devices**, reused everywhere: horizontal
   gradients, diagonal `╱` fields, left accent bars, section rules, pills,
   dim/bright focused/blurred pairs, and 40-odd single-glyph status icons.

Our `Theme` protocol has **six** roles: `accent`, `muted`, `success`, `warning`,
`error`, `border`. That is the gap in one sentence.

The good news: three of the hardest primitives are already ours —
`TextSpan`/`SpanBuilder` (per-run styling, better than Lip Gloss's
`StyleRanges` string surgery), truecolor `Color.rgb`, and sub-cell rendering
with alpha. The missing pieces are mostly small, well-scoped, and additive.

---

## 2. Component inventory

### 2.1 Already shipped — no work needed

Crush's list of *actually used* Bubbles/Lip Gloss widgets is shorter than its
reputation suggests. These we match or beat:

| Crush | TerminalUI | Note |
|---|---|---|
| `bubbles/textinput` | `TextInput` | ✅ |
| `bubbles/textarea` | `TextArea` | ✅ + undo stack |
| `bubbles/viewport` | `ScrollView` | ✅ + scroll indicators, boundary feedback |
| `lipgloss` Join/Align/Place | `VStack`/`HStack`/`ZStack`/`Spacer`/`Alignment` | ✅ |
| `lipgloss` Border | `.border(_:)` | ⚠️ 4 styles, see §3.4 |
| `diffview` (unified + split) | `DiffView`, `HunkDiffView` | ✅ |
| `ui/image` (kitty/sixel/halfblock) | `TerminalUIIO` | ✅ half-block + kitty |
| `ui/common/capabilities` | `TerminalCapabilities` | ✅ |
| `ui/common/scrollbar` | `ScrollbarGeometry` | ✅ |
| `ui/common/button` | `Button` | ✅ |
| `lipgloss.Compositor.Hit` | `Graph/HitTest` | ✅ retained + typed |
| Tabs (`question_form`) | `TabView` | ✅ |
| `ui/model/status` | `StatusBar` | ✅ |
| Charts (none in Crush) | `BarChart`, `Sparkline`, `HeatMap`, `BrailleCanvas` | ✅ we're ahead |
| Wordmark letterforms | `DotMatrixText` + `DotFont` | ⚠️ close, see §4.6 |

### 2.2 Missing — framework-level, blocks everything downstream

| # | Gap | Crush equivalent | Impact |
|---|---|---|---|
| G1 | **Theme has 6 roles, needs ~30** | `quickStyleOpts` | Blocks all of it |
| G2 | **No color blending / gradient API** | `lipgloss.Blend1D`, `styles.ForegroundGrad` | The single most "Crush-looking" feature |
| G3 | **`padding` is a uniform `Int`** | `Padding(0,2)`, `PaddingLeft(2)` | Every dense layout needs asymmetric padding |
| G4 | **Border colour is inherited from foreground; no per-side borders** | `BorderForeground`, `BorderLeft` | Left accent bars are Crush's core message device |
| G5 | **No markdown renderer** | `glamour` + `ansi.StyleConfig` | No chat pane without it |
| G6 | **Syntax highlighting is Swift-only** | `chroma` (300+ lexers) | Code blocks in chat/diffs |
| G7 | **No fuzzy filter + match highlighting** | `sahilm/fuzzy`, `list/filterable.go` | Every picker/palette in Crush |
| G8 | **No layered dialog/overlay stack** | `dialog.Overlay` | We have single-level `.modal` only |
| G9 | **No help/keybinding legend view** | `bubbles/help` | Crush shows it on every screen |
| G10 | **No spinner / activity indicator** | `ui/anim` | Signature "thinking" animation |
| G11 | **No ANSI-16 remap for embedded raw output** | `Styles.ANSI [16]color.Color` | Shell output legibility |
| G12 | **No anchored popup positioning** | Completions above the prompt | Autocomplete |
| G13 | **No text selection + OSC 52 copy** | `list/highlight.go`, selection drag | Mouse-select in chat |
| G14 | **No OSC 9/99 desktop notifications** | `ui/notification/osc.go` | Background-task alerts |

### 2.3 Missing — component-level, buildable on top

| Component | Crush file | Notes |
|---|---|---|
| Virtualised, height-cached list | `list/list.go` (961 lines) | Ours lacks per-item render caching + `Prewarm`, needed for long chats |
| Completions popup | `completions/` | Fuzzy + name-priority tiers + anchored |
| File picker | `bubbles/filepicker` | — |
| Pills / badges | `model/pills.go` | Bordered chip with gradient icon run |
| Section rule | `common.Section` | `Title ─────────────` — trivial, high impact |
| Dialog title rule | `common.DialogTitle` | `Title ╱╱╱╱╱╱` gradient — trivial, high impact |
| Status row | `common.Status` | icon + title + truncated desc + extra |
| Sidebar composition | `model/sidebar.go` | — |
| Exit banner | `exitbanner/` | Prints after TUI teardown |
| Chat message items | `chat/*.go` (~6k lines) | App-level, but the *shapes* are reusable |

---

## 3. The primitive gaps in detail

### 3.1 (G1) Theme: 6 roles → ~30

Crush's `quickStyleOpts` is the whole design system's input. Transcribed and
mapped to a proposed TerminalUI `Theme`:

```
Brand         primary, secondary, accent, keyword
Foreground    fgBase, fgSubtle, fgMoreSubtle, fgMostSubtle
Background    bgBase, bgLeastVisible, bgLessVisible, bgMostVisible
Contrast      onPrimary
Structure     separator
Status        destructive, error, warning, warningSubtle, attention, busy,
              info, infoMoreSubtle, infoMostSubtle,
              success, successMoreSubtle, successMostSubtle
Raw output    ansi[16]
```

The two structural ideas worth stealing:

- **Ramps, not single values.** Three levels of subtlety for foregrounds, three
  for backgrounds, three for info/success. This is what lets Crush layer six
  things in one pane and keep them legible.
- **Contrast pairings.** `onPrimary` exists so "text on a primary-coloured
  background" is a *theme decision*, not a call-site guess.

What we should **not** copy: the 704-line `Styles` struct. It is Crush's
technical debt (it already carries `// Deprecated - kept for backward
compatibility` fields). SwiftUI's answer to the same problem is the environment
plus per-component style protocols — and we already have the shape of it
(`PickerStyle`, `FocusIndicatorStyle`, `EnvironmentValues`). Expand the palette;
resolve it through the environment; add `ButtonStyle`/`ListStyle`-shaped
protocols where a component genuinely needs multiple looks.

### 3.2 (G2) Gradients — the highest-leverage single feature

Every visually distinctive element in Crush is a horizontal colour ramp over a
run of glyphs:

- the `CRUSH` wordmark and the compact header logo
- the `╱╱╱╱╱╱` diagonal fields beside the logo and dialog titles
- the queue pill's `▶▶▶▶▶` triangles, truncated to the queue count
- the "thinking" spinner's cycling character band

The mechanism is one function — blend N colours across N grapheme clusters,
in HCL to stay in gamut (`anim.makeGradientRamp` uses `BlendHcl`; Lip Gloss's
`Blend1D` does the same). We have `TextSpan`, so the API is natural:

```swift
Text.gradient("CRUSH", from: .charple, to: .dolly)   // -> [TextSpan]
```

`Color` needs an Oklab or HCL blend to do this without banding. Pure Swift, no
dependency, ~80 lines.

### 3.3 (G3) Edge-aware padding

`PaddingModifier` currently carries a single `Int` applied to all four sides.
Crush uses asymmetric padding constantly (`Padding(0, 2)` for pills,
`PaddingLeft(2)` for tool-call bodies, `Padding(0, 1, 0, 1)` for the header).
Proposal:

```swift
.padding(2)                       // existing, unchanged
.padding(.horizontal, 2)
.padding(.leading, 2)
.padding(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 1))
```

This is SwiftUI's exact API, so it costs no new concepts.

### 3.4 (G4) Borders

Three separate shortfalls:

- **Colour** — `.border(.rounded)` inherits the foreground, so you cannot draw
  a dim box around bright text. Crush's focused/blurred distinction is almost
  entirely "same glyph, different border colour". Need `.border(.rounded, color:)`.
- **Per-side** — Crush's single most-used message device is a *left bar only*
  (`BorderThick = "▌"`, `BorderThin = "│"`), colour-coded by focus and role.
  Need `.border(.rounded, edges: .leading)`.
- **Glyph sets** — we ship 4 styles; Crush composes custom `uv.Border` values
  per tab state. A `BorderStyle.custom(...)` case covers it.

### 3.5 (G5/G6) Markdown and syntax highlighting

The chat pane is 60% of what a Crush-like demo *is*, and it is markdown with
fenced code. Two pieces:

- **`MarkdownView`** — a parser for the CommonMark subset that matters
  (headings, emphasis, lists, block quotes, fenced code, inline code, links,
  rules, tables) rendering to `TextSpan` runs. Crush leans on Glamour's
  `ansi.StyleConfig`, which is a per-element style table; ours should be a
  `MarkdownTheme` resolved from the semantic palette.
- **More lexers.** `SwiftSyntaxHighlighter` is the only one. The `SyntaxHighlighter`
  protocol and `SyntaxTheme` are already right — this is additive work
  (JSON, Bash, Go, Python, JS/TS, Markdown, diff cover most of what a coding
  agent shows).

Note Crush's `CodespanPadding` trick (`"\u{00a0}\u{fe0e}"`) — a non-breaking
space tagged with the text-presentation selector, used as inline-code padding
that survives word wrap and round-trips back to backticks on copy. The comment
also records a real bug: `U+FE0F` measures 2 cells in `ansi.StringWidth` but
renders as 1, causing per-frame repaint flicker. Worth knowing before we build
selection.

---

## 4. Signature devices worth stealing verbatim

These are small, and they carry most of the visual identity.

### 4.1 The section rule
`common.Section` — title, space, then `─` repeated to fill the remaining width,
with optional right-aligned info. Two lines of layout, used on every panel.

### 4.2 The dialog title rule
`common.DialogTitle` — title, space, then `╱` repeated to fill, **gradient-ramped**.
Same idea, different glyph, and the gradient is what sells it.

### 4.3 The diagonal field
The logo sits between a 6-column left field of `╱` and a right field that
*steps down by one column per row*, producing a slanted edge. Pure `╱` repetition,
no special rendering.

### 4.4 The left accent bar
Every chat message, shell block and tool call is framed by a single-column left
border, coloured by role and focus state. `BorderThick "▌"` for emphasis,
`BorderThin "│"` for quiet. This is the workhorse.

### 4.5 The icon vocabulary
~40 single-glyph constants with fixed semantics — `✓ ⋯ ⟳ ◇ ◆ → ● × ◉ ○ │ ▌ ─
• ■ ≡ ▲ ✕ ┃ E W I H`. Cheap to adopt, and consistency here reads as polish.

### 4.6 The wordmark
Crush hand-codes letterforms as functions (`LetterC`, `LetterR`, …, 419 lines),
each stretchable horizontally, and stretches **one randomly chosen letter per
session** so the logo has character without jittering on resize. We have
`DotMatrixText` + `DotFont`, which is the same idea with a different texture —
close enough that the demo can use ours and look intentional rather than derivative.

### 4.7 The spinner
`ui/anim` is more considered than it looks and worth reading before we build ours:
- a band of random hex-ish glyphs under a colour ramp, cycling at 20fps
- a **staggered birth schedule** — each column fades in at a deterministic step
  derived from `hash(id + settingsHash)`, so two spinners on screen don't march
  in lock-step, but the same spinner is byte-identical across runs
- prerendered frames cached by settings hash; `Render()` is pure string assembly
- generation counters so re-arming supersedes an in-flight tick chain instead of
  double-driving the animation

That determinism discipline maps directly onto our `Timeline` + PTY harness:
a spinner built this way is **golden-testable**, which ours should also be.

---

## 5. How we work: the demo is the forcing function

**We do not port the inventory in §2.** We build the demo app, and every time it
hits a wall we build the framework feature that wall demands — properly, as a
first-class TerminalUI feature with a Storybook page and tests — then carry on.

Rationale: a checklist port builds things the demo never needs, in whatever
shape Crush happened to choose, and it defers the only proof that matters —
that TerminalUI can *express* this look. Hitting the wall while building tells
us the real requirement and its natural API shape.

So §2 and §3 are a **gap ledger**, not a work queue. Items get pulled from it
when the demo demands them, and an item the demo never demands doesn't get built.

### The demo

`Examples/Coder` — an agent-chat TUI, the shape Crush is:

- header: wordmark + diagonal field + session/context metadata
- sidebar: session title, cwd, model info, modified files, LSP/MCP/skills status
- transcript: markdown messages, tool-call cards, left accent bars, diffs
- prompt: multiline input, mode prompts, completions popup, attachments
- overlays: command palette, sessions dialog, model picker, permission dialog
- chrome: pills (todo/queue), status bar, help legend

Built with fixture data — no agent, no network. It is a *look and interaction*
demo, and it doubles as a PTY-harness fixture like every other example.

### Build order

Driven by what the demo needs to show something on screen at each step, roughly:

1. **Shell** — window, header band, sidebar/transcript split, status bar.
   *Expect to hit:* theme roles (G1), edge padding (G3), border colour (G4).
2. **Transcript** — messages with left accent bars, then markdown, then code.
   *Expect to hit:* markdown (G5), lexers (G6), list caching.
3. **Prompt + overlays** — input, completions, command palette.
   *Expect to hit:* fuzzy (G7), dialog stack (G8), anchored popups (G12).
4. **Identity pass** — gradients, wordmark, pills, section rules, icon set.
   *Expect to hit:* gradients (G2) — deliberately last, so the structure is
   sound before the flourish goes on.
5. **Polish** — help legend (G9), spinner (G10), selection (G13), notifications (G14).

The "expect to hit" column is a prediction, not a commitment. What the demo
actually demands wins.

### Ledger — closed

**L1. `HStack` height measured children at the wrong width.** *(framework bug)*

The first screen of the demo lost a word. A chat message read "…find out why
and fix" and its final "it." was simply absent, while the node's rect claimed
the two rows the wrap needed.

`GraphMeasurer.computeHeight` proposed the stack's *full* width to every child
of an `HStack`, but a child is placed at that width minus its siblings minus the
gaps. A body that fit the former and not the latter measured one row short, the
enclosing `VStack` reserved a row too few, and the parent's rect clipped the
wrap's last line. It only showed up at the boundary — a 103-column body in a
104-column stack — which is why nothing in the suite had caught it.

Fixed by giving the measurer the same per-child width allocation the render walk
uses, extracted as `GraphRenderer.hstackChildWidths` so the two passes cannot
drift apart again. `.zstack` was split out of the shared case: its children
genuinely do overlay at full width.

One trap worth recording: `measureFocusedPosition` asks for heights at
`proposedWidth: 0`, meaning "unconstrained". Apportioning zero columns across
the children measured every one at nothing, reported height 0, and silently
disabled keyboard scrolling in `Form`. Both behaviours are now pinned by tests.

**L2. `Text` could not truncate.** *(gap — built)*

The sidebar wrapped `Rendering/Compositor.swift  +14 −6` onto two rows, and the
second row held nothing but `−6`. In a fixed-height rail the line has to give
way instead of reflowing the panel.

`LineBreakMode` already had display-width-aware `.byTruncatingHead/Middle/Tail`
and an `.lineBreakMode(_:)` modifier — but only `TextInput` consumed it. `Text`
answered to `TextWrapMode`, which offered wrap or silent clip and nothing else.

Added `TextWrapMode.truncate(TextTruncationEdge)` — truncation is a third answer
to the question that enum already asks. The string path delegates to
`LineBreakMode` rather than restating its cell arithmetic. The styled path needed
new work: a status row is three colors on one line, so
`TextLayout.truncate(spans:width:edge:)` cuts the *run list*, keeps each
surviving run's style, and gives the ellipsis the style of the run it
interrupts. Wide graphemes are dropped whole.

Note what did **not** get built: a `.truncationMode(_:)` alias. SwiftUI needs one
because truncation there is a separate axis from `lineLimit`; here `.truncate`
already implies one row, so a second spelling would be two ways to say one thing.

**L3. A border could not have its own colour or draw one side.** *(G4 — built)*

The transcript needs two frames: a dim box around bright text, and a coloured
rail down the left of a message marking its author. The demo had been faking
the rail with a glyph, which only ever marked a message's first line.

`.border` now takes `color:` and `edges:` (SwiftUI's `Edge.Set` naming, so
`.horizontal` is leading + trailing). A drawn edge costs one cell and an undrawn
one costs nothing in all three passes — measurement, layout inset, render — and
that agreement is what the tests pin, because content lands a cell out if any
pass disagrees. Corners resolve from what meets there, so a lone top edge is an
unbroken rule rather than a rule with corner pieces stuck on.

Not built: `BorderStyle.custom(...)`. The demo hasn't needed a glyph set beyond
the shipped four.

Surfaced but deferred: modifiers measure their child at the outer width instead
of inside their own frame. Correcting it broke `PromptInput`'s soft-wrap, whose
height is a measure/layout feedback cycle through its own `GeometryReader`. That
cycle is the real defect, and it now blocks G3 — see Ledger — open.

**L4. Theme roles existed and nothing read them.** *(G1 — built)*

The theme carried six roles and exactly one view consulted any of them; every
other component drew `.gray` / `.cyan` literals. The demo's own palette was
thirty properties living outside the framework's theming entirely, because
that theming was useless to it.

Roles went from six to twenty-six, as **ramps** — five foreground weights, four
background steps, a `…Subtle` partner per status — plus `onPrimary` as a
contrast pairing. Body-based components were wired to them. The role defaults
reproduce the literals components already drew, so it was a refactor, not a
restyle: suite and smoke passed unchanged. (One near miss: `Picker`'s selected
row would have silently lost its highlight to a role that resolved to nothing.)

Not built: Crush's 704-line `Styles` struct shape. The environment plus roles
did the job. Also not done: `TabView`, `TreeView`, `DiffView`, `HunkDiffView`,
`StatusBar` and `PromptInput` still draw literals — their colours live in static
helpers or literal-defaulted style structs, and theming them changes signatures
or public API. Left for when the demo puts one on screen.

**L5. Colour had no arithmetic, so nothing could sweep.** *(G2 — built)*

The wordmark and the diagonal header field are colour ramps over a run of
glyphs, and `Color` was a closed set of values with nothing between them.

`Color.blended(with:amount:)` interpolates in **Oklab**, not sRGB (sRGB's
blue→yellow dies grey in the middle) and not the HCL Lip Gloss uses (no hue
channel, so no choosing which way round the wheel to go). `Text.gradient` steps
per grapheme cluster, so an emoji is one step however many cells it fills.
TerminalInk gained `nominalRGB`, xterm's default values for the named slots — a
blend leaves the user's palette behind deliberately, and `Color.default`
resolves to nothing, so blending from it returns the nearer end instead of
inventing black.

Pulled earlier than the build order planned (it said identity pass, last),
because L6 needed it.

**L6. A theme author had to state twenty-six colours.** *(G1 follow-on — built)*

Nominating every role one at a time drifts: nothing holds the quiet steps in
relation to the loud ones, and the defaults *aliased* (`foregroundFaint` was a
second name for `foregroundMuted`).

Unstated roles now **derive** by mixing toward the ground they sit on — Textual's
token shape. Every step travels less than half way, which is load-bearing: an
unresolvable end (`Color.default`) returns the nearer end, so a theme on terminal
defaults keeps exactly the contrast it had. `ThemeDerivation.off` lets a brand
palette decline computed shades and borrow the nearest stated colour instead;
every derived role reads the switch through one helper. Every role is a declared
protocol requirement, pinned by a test through `any Theme` — an extension-only
member would dispatch statically and ignore the conformer's override.

The demo's theme became a real conformance: fourteen stated colours, the rest
derived, published to the environment so a framework component dropped into
the transcript resolves the same palette.

**L7. Messages were one long grey line.** *(G5 — built)*

A transcript is markdown and rendered as plain text — heading indistinguishable
from body, fences shown as backticks, lists run on.

A CommonMark subset parses to a style-free value tree (`MarkdownBlock`,
`MarkdownInline`); `MarkdownView` flattens it to rows, deciding indentation once
so a wrapped bullet sits under its text. Streaming shaped the parser more than
the grammar did: an unterminated fence runs to end of input, an unmatched
delimiter stays literal, and `_` inside a word never opens emphasis so
`snake_case` survives. Quotes use L3's leading edge rather than a gutter glyph.
Every colour is a theme role.

Not built: tables, HTML, images, reference links, setext headings — §3.5
listed tables, but no agent message in the demo has one. Code fences use the
existing `SwiftSyntaxHighlighter` and fall back to plain for other languages;
G6 stays open until the demo shows a non-Swift fence.

Fixed on the way: styled text wrapped per character while plain text wrapped
per word, and the measurer counted word-wrapped rows for both, so a styled
paragraph could measure one height and render another. Wrapping is now decided
on the run list.

**L8. A diff inside a card behaved like a control.** *(G1 remainder, partly — built)*

The Edit tool card wanted the change itself, not `+14 −6`. `DiffView` already
diffs two strings, which is exactly what an edit carries — but dropped into the
transcript it was the only focusable node on screen: it took focus at boot, the
transcript auto-scrolled to it so the conversation opened mid-way, Down
scrolled the edit's first line out of the card, and its focus indicator painted
over the card's rail. Its green and red were also ANSI literals, so a themed
transcript showed the terminal's palette in the middle of the app's.

`DiffView` is now focusable **only when it has rows below its viewport**. A diff
that fits has nothing to scroll, so it is content, not a Tab stop — no new API,
and the threshold counts rendered rows, so side-by-side's paired rows are
measured as rows. Colours come from roles: gutters `foregroundMuted`, additions
`success`, removals `error`, the header path `foregroundEmphasis`, the
side-by-side divider `separator`. `DefaultTheme`'s values for those roles are
the literals it drew, so nothing changes for an unthemed app.

`HunkDiffView` was the other candidate and the wrong one: it is a review
surface whose cursor and selection are the point, so it stays a control.

Not built: line numbers anchored to the file. `DiffEngine` numbers from 1, so
the card says line 4 for code the Grep card above it placed at 311. Crush shows
real numbers. Worth a `DiffEngine` starting offset when the demo's next edit
makes the mismatch matter; not worth an API before then.

**L9. The scrollbar ate the last column.** *(framework bug — fixed)*

The Bash card shows a command's output the way Crush does (`tools.go`,
`toolOutputPlainContent`): at most ten lines, one over the cap shown whole, a
`… (N lines hidden)` note, each line cut to the card with `…` on a raised
block. Everything it needed already existed — `.wrap(.truncate(.tail))` cuts
per logical line, `.frame(maxWidth: .infinity)` plus `.background` gives the
full-width block — so the card is app code.

But the one line long enough to truncate read as cut off mid-word: no `…`. The
truncation was right; the ellipsis sat in the transcript's last column, and a
vertical `ScrollView` laid content across its full width and then painted the
scrollbar over that column. Any content there was lost whenever the content
overflowed — a truncation mark, or the last letter of a line that wrapped to
the full width. The horizontal axis documents the same trade for a row; the
vertical one had never decided it.

Overflowing content is now laid out one column narrower, the way a classic
scrollbar reserves its gutter; content that fits keeps the full width, and
`.scrollIndicators(.hidden)` gives the column back. Narrowing only ever wraps
more, so content that overflowed still overflows and the decision cannot
oscillate. Scroll clamping's first-frame fallback measures at the same width
the render lays out at, so the two passes cannot disagree about the range.

Seen but not built, each waiting for the demo to need it:

- **Bash highlighting of the command** (G6). Crush lexes the header's command
  as bash. Plain text reads fine; this is the first place a non-Swift lexer
  would show.
- **Expanding a capped result.** Crush's note says "click or space to expand".
  The transcript has no per-entry interaction yet, so the note only counts.
- **The body's two-column indent** (G3). Crush pads tool bodies left by 2; the
  card's rail gives the separation instead until edge padding lands.
- **Scroll indicator colours.** The thumb and track are cyan and gray literals,
  so the transcript's scrollbar ignores the theme. One more for G1's remainder.

**L10. What the framework drew for an app ignored the app.** *(G1 remainder — built)*

The transcript's scrollbar was a cyan full block whatever the theme; the demo
had declared the glyphs it wanted and had nowhere to put them, and the only
control was hiding the bar. The reference look — a hairline track, a coloured
thumb, no arrows — was not expressible.

Framework-drawn affordances take roles now: the bar's thumb and edge markers
`borderActive` (the bar stands where a border would; the thumb is its active
part), the track `separator`, the focus bar `accent`, read-only and hover bars
`foregroundMuted`. Shape is a `ScrollbarStyle` set per subtree, the way
`.focusIndicator(_:)` sets the focus bar, with the edge arrows as their own
optional set: `.thin` (default), `.block` (the old look), `.hairline`. All of
it is read from the scroll view's own environment, so one pane can differ.

**L11. Code colours and languages were fixed in place.** *(G6 groundwork + a missing view — built)*

The Read card wanted the file text itself — highlighted, numbered from where the
read began — as Crush's View card shows it. Nothing could draw that: there was
no read-only code view; `MarkdownView` hard-wired one palette whatever the
theme; `SyntaxTheme`'s documentation promised a `.syntaxTheme(_:)` that never
existed; and the language lookup was internal and Swift-only, so a lexer an app
wrote could not reach a markdown fence.

Code colours are `Theme.syntax`, a declared role like `border`. Lexers register
through the environment (`.syntaxHighlighter(_:for:)`), built on a new
`transformEnvironment` so registering one adds to what is inherited. A public
`highlight(lines:theme:)` carries tokenizer state across lines and draws
unclassified stretches plain — the protocol's promise, which the markdown path
had not kept. `CodeView` uses it and so does `MarkdownView`; `TextArea`'s
syntax theme now follows the theme when not given.

Not built: lexers beyond Swift. The registry is the seam; the demo's excerpts
are Swift. Bash for the Bash card's command is the likely first.

**L12. Markdown could only look one way.** *(G5 follow-on — built)*

Side by side with Crush, a reply read differently for reasons none of which
were the demo's to fix: Crush keeps `##` markers so structure reads in a column
of prose, draws inline code as a padded chip, and mutes its thinking on a block
of its own. Every element here was one fixed role.

`MarkdownStyle` states a look per element — colour, background, weight, prefix,
suffix — with every field unset by default and an unset field keeping the theme
default, so an empty style changes nothing. Glamour's precedence (level over
heading over document over default) and its meaning of background (a chip
behind a run, a fill under the document) came across unchanged; it is the
shape Crush's three configurations are written in.

Two framework defects surfaced getting the fills right, both fixed on their
own: styled `Text` wrote only its glyphs while plain `Text` padded its frame, so
a background behind coloured text stopped at the text; and markdown rows
painted the theme's ground behind all prose, which showed as patches inside
any panel of another colour.

The demo's replies now use a Crush-shaped style built from its own roles. Not
built: a quiet thinking block — the demo has no thinking content yet.

**L13. Side by side, the layout was the difference.** *(demo — built)*

Compared against a Crush screenshot with the text ignored, most of what read as
"not Crush" was the demo's own choices, now changed to Crush's numbers from
`generateLayout`: one flat ground with no raised panels; no header band — the
name lives in the sidebar; a margin of one all round, which the uniform
`.padding(1)` already expresses exactly; a 32-column sidebar after a two-column
gap, listing title, directory, model, then Modified Files, LSPs and MCPs as
quiet sections; messages capped at 120 columns with the scroll bar at the
column's edge; a borderless three-row `:::` composer; a `key action · key
action` help line.

Nothing in the framework had to change for any of that. Two things the
comparison showed did need it, and are recorded rather than faked: Crush's
three-row block wordmark (no block letterform with a gradient exists), and the
leading-only padding every message frame uses (G3, below).

**L14. Messages framed the way Crush frames them.** *(G3 — built, by way of three fixes)*

Crush pads every message on its leading side only: a user message one column
past a thin rail, an agent reply or tool call two columns with no rail, so all
text starts in one column and the rail marks the turns that came from outside.
That needed edge-aware padding, which needed a modifier's child measured at its
inner width, which needed the GeometryReader measure/layout cycle gone.

So, in order: `GeometryReader` became greedy and `WidthReader` took the
content-sized case (the cycle cannot exist when content cannot read the
dimension it decides); two stale measurement caches that readers had been
hiding were fixed; children of padding, borders and frames are measured at the
width they are laid out at; and `.padding(_:_:)` / `.padding(EdgeInsets)`
arrived, with `BorderEdges` becoming SwiftUI's `Edge.Set`. Markdown quotes got
their column of room in the same stroke.

Not built: per-message focus, which in Crush thickens the focused entry's rail
to `▌`. The demo has no message selection yet.

**L15. The composer became a control.** *(demo — built, by way of four fixes)*

Run interactively, the demo closed under the user's hands: its composer was a
drawing, `q` and Escape were quit chords, and the first word with a `q` in it
ended the session and ran the rest of the line in the shell. Making the
composer a `PromptInput` that looks like Crush's — `>` on the first row while
focused, `:::` on the rest, dimmed when focus is elsewhere, three rows when
empty, a placeholder — took four framework fixes, each on its own:

- With nothing focused, action dispatch started at the graph root and walked up
  past none of the app's scopes, so an app could not override Escape or Ctrl+C
  at all. A key with no focused view is now addressed to the window.
- A body re-run in place after a state change, and a `GeometryReader`'s content
  rebuilt during layout, saw the frame's bare environment — under
  `.environment(\.theme, …)` they drew with the default theme. Both now resolve
  the environment from the modifiers above them.
- `isFocused` and `focusedID` were documented and never set. A focusable's
  content now reads whether it holds focus, as in SwiftUI; `@TerminalEnvironment`
  records what each body read, and a focus change re-runs only the readers.
- `PromptInput` draws its cursor only while focused, takes its colours from the
  theme, and gained `placeholder:`, `minimumHeight:` and `PromptPrefix` /
  `.promptPrefix(_:)` for a per-row column.

Escape is the framework's dismiss-or-quit; in Crush it cancels the request in
flight, so the demo binds it to a Cancel that has nothing to cancel yet.

**L16. An environment change reaches every reader.** *(bug, found while
building L15)*

The update walk skips a view whose inputs compare equal, and with it everything
below — so a theme switched above an unchanged view never reached it.
`@TerminalEnvironment` now records, with each key a body reads, the value it
read; a skipped view still re-runs its own body if one of those changed, and
re-runs in place the bodies below it whose values changed, and no others. What
a reader sees is worked out at the reader, through the modifiers between, so a
`transformEnvironment` below the skip still applies. A copy of an unchanged
value is its bytes, so most checks are a `memcmp` of the concrete value; only a
real change pays the field-by-field compare. Storybook's
`.environment(\.theme)` page switches themes live under a view that takes no
inputs.

### Ledger — open

- **The transcript does not follow its tail.** Crush opens on the latest
  message and keeps it in view as entries arrive, until the reader scrolls
  away. `.scrollPosition(id:)` re-applies its target on every render, which
  pins rather than follows; SwiftUI's is a two-way binding. A sent message
  lands below the fold.
- **`TextInput` and `TextArea` draw their cursor without focus** — the defect
  `PromptInput` had; the fix is the same, and nothing in the demo uses them yet.
- **G1 remainder — the literal-drawing components** listed in L4, less
  `DiffView` (L8) and `PromptInput` (L15): `TabView`, `TreeView`,
  `HunkDiffView`, `StatusBar`. (`ScrollView`'s indicators done in L10.)
- **G6 — lexers beyond Swift.** The registry exists (L11); the first lexer
  demanded will be bash, for the Bash card's command.

Everything else in §2.2 waits for the demo to reach it.

### Ledger discipline

Each gap closed gets: the framework feature, a Storybook page, tests, a
`storybook_walk` pass, and a line in this doc recording what the demo needed and
what shape we gave it. That record is the point — it's the difference between a
framework that grew from real use and one that grew from a competitor's file
listing.

---

## 6. Constraints this must respect

Non-negotiables from `CLAUDE.md` that shape all of the above:

- **Zero dependencies.** No Glamour, no Chroma, no colour library. Markdown,
  lexers and Oklab blending are all pure-Swift work.
- **Swift 6.2, `.v6` language mode, `StrictConcurrency` + `ExistentialAny`.**
- **0 errors, 0 warnings**, `TUI_WARNINGS_AS_ERRORS=1`.
- **macOS 15+ / Linux**, Docker-verified.
- **Enum dispatch on the render hot path** — new modifiers mean new `NodeKind`
  cases, not `as?` casts.
- **No magic numbers** — glyph sets and ramp steps go in private enums with a
  spec or design reference.
- **CI gates on the PTY harness**, so every new component needs a Storybook page
  and a `storybook_walk` pass.

Two design cautions:

- Don't port `styles.Styles`. It is a 704-line struct with deprecated fields;
  the SwiftUI-shaped answer is environment + style protocols.
- Don't port Lip Gloss's string-surgery model (`StyleRanges`, re-measuring
  rendered ANSI). `TextSpan` is strictly better and already ours.
