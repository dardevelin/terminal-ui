# The framework records its own pictures

Every picture the docs and README show was recorded with vhs (ttyd, headless
Chrome, ffmpeg) and ImageMagick, from tapes that guess timings. This plan
replaces that with a recorder inside the framework and a renderer in `swtui`,
so a picture is made from the frames the app drew, driven by the same code
that checks the tutorial, on macOS and Linux, with nothing to install.

Decided with the project owner (2026-11-09):

- Every format is producible from every recording: SVG (still and
  CSS-animated), PNG (stills), GIF (animations), and an asciinema v2 `.cast`.
- Raster text is drawn with the system font by default (CoreText on macOS,
  FreeType on Linux), and a setting points the renderer at a font file.
  JetBrains Mono is bundled as the reproducible choice the docs use.

The steps are numbered below; the board tracks them, and this document is the
design they implement.

## Formats per surface

| Surface | Default | Files |
|---|---|---|
| README demo and debug tour | GIF, 1× | `assets/demo.gif`, `assets/debug.gif` (names unchanged) |
| Pages landing | animated SVG | `demo.svg` (one-line switch back to the GIF) |
| DocC step previews | PNG, plus `@2x` | `preview-<step>.png`, `preview-<step>@2x.png` |
| DocC chapter cards | RGBA PNG, plus `@2x` | `card-chN.png`, `card-chN@2x.png` |
| DocC chapter intros | GIF, 1× | `demo-chN.gif` |
| `.cast` | every recording, not committed | Pages may link `demo.cast` |

Research behind it: DocC's `@Image` takes png, jpg, jpeg, svg and gif, with
`~dark` and `@2x` variants; `@Video` takes only mov/mp4 and needs a poster, so
it is not used. A README image is an `<img>` served from the repository: a GIF
animates everywhere, including GitHub's mobile app and package indexes; a
CSS-animated SVG animates in browsers (termtosvg, svg-term-cli rely on it).
asciicast v2: header `version, width, height` plus optional `env, title,
idle_time_limit, theme`; events `[t, "o"|"i"|"m"|"r", data]`.

## Targets

| Target | Product | Holds |
|---|---|---|
| `TerminalUIConfig` | existing | `Recording/RecordingLog.swift` (`package`): the `.tuirec` line types, a hand-rolled writer and reader; `[record]` keys on `DiagConfig` (public, documented, memberwise init unchanged) |
| `TerminalUI` | existing | `DevTools/FrameRecorder.swift` (`#if DEBUG`, `@MainActor`, owned by the runtime); the hook; socket verbs; public DEBUG `RecordingInfo`; `OutputBuffer.contents` and `Terminal.windowBackgroundSequence` raised to `package` |
| `TerminalUIRecording` | no | `RecordingReader`, `PresentationClock`, `RecordingPalette`, `CellMetrics`, `GlyphGeometry`, `SVGFrameRenderer`, `SVGAnimationRenderer`, `CastEncoder`, `CardLayout`, `RasterFrameComposer`, `RasterAnimator` |
| `TerminalUIRaster` | no | Pure Swift, integer only: `PixelCanvas`, `CoverageRasterizer`, `TrueTypeFont`, `BuiltinGlyphSource`, `CRC32`, `Adler32`, `Deflate`, `PNGWriter`, `LZW`, `GIFWriter`, `IndexedPaletteBuilder` |
| `TerminalUISystemFonts` | no | `SystemGlyphSource`: CoreText under `canImport(CoreText)`; FreeType and fontconfig through `dlopen` under `canImport(Glibc)` |
| `swtui` | existing | `swtui record start/mark/stop/status/dump/render`; reads a `[render]` section itself |

`TerminalUIRecording` depends on TerminalUI, TerminalUIConfig and
TerminalUIRaster; `swtui` on all three new targets; `TerminalUIRaster` on
nothing (its tests use `TerminalUIIO.Inflate` as a round-trip check). The three
new targets are `package`-only and in no product: a consumer building
TerminalUI compiles none of them, and nobody needs libfreetype to build.
FreeType is reached with `dlopen("libfreetype.so.6")` because the `swift:6.2`
image ships the library but no headers, so a `systemLibrary` target would make
every Linux build of the package install `libfreetype-dev`. CLAUDE.md's
layering table names them "internal, swtui-only; not products".

## The recording log, `.tuirec` (version 1, JSON lines)

```
{"tuirec":1,"cols":94,"rows":26,"cursor":"hidden","app":"tasks20201","env":{"TERM":"xterm-256color","COLORTERM":"truecolor"}}
{"style":0,"fg":null,"bg":null}
{"style":1,"fg":"rgb:cba6f7","bg":null,"bold":true}
{"t":0,"frame":1,"windowBg":"rgb:1e1e2e","rows":[[0,[[1,"Tasks"],[0,"   …"]]]]}
{"t":0,"mark":"start","hold":2500}
{"t":41233,"frame":7,"rows":[[3,[[2,"▸ ☐ Build a task list"]]]]}
{"t":51200,"resize":[100,30]}
{"t":90000,"end":true,"frames":12,"marks":5}
```

- Styles are declared once, on first use. Colours keep their encoding: `null`
  (terminal default), the 16 `Color` names, `idx:N`, `rgb:rrggbb`; resolving
  them is the renderer's choice of palette.
- A frame holds only the rows that changed; the first holds all. A row is
  `[styleId, text]` runs, one `Character` per cell; a run whose cells would
  merge into one grapheme cluster falls back to a per-cell array.
- `windowBg` is written when it changes. `frame` is the runtime's counter.
  Identical consecutive buffers are not recorded.
- Times are integer µs from `ContinuousClock`, taken after `flush()`. Fixed key
  order and no floats, so the bytes are identical on macOS and Linux.

## Recorder, socket, CLI

- `FrameRecorder` is `@MainActor` and owned by the runtime: the hook and the
  socket both run there, so it needs no lock and no escape hatch. Its hook
  follows `tracer.endFrame` in the diff-frame draw; `finish()` runs in the quit
  path, which SIGTERM reaches. Idle, it costs one bool check.
- Deltas are buffered and written on mark, stop or finish, or past 256 KB.
  Files open `O_CREAT|O_EXCL|O_NOFOLLOW`, mode 0600; a non-regular file is
  refused. The per-process data dir is removed at exit, so a recording is
  written elsewhere: by default `.terminalui/recordings/<app>-<pid>.tuirec`.
- `[record] enabled/path` records from launch to quit.
- Socket verbs `record_start {path, label?}`, `record_mark {label, hold_ms?}`,
  `record_stop`, `record_status`, routed through an internal
  `RecordingRuntime` protocol reached by `as?` (no new requirement on the
  public `RemoteControlRuntime`). `RemoteRequest` gains `path`, `label`,
  `holdMs`; `RemoteResult` gains `recording` (stored, set after init). Every
  request is served before the next drain, so a mark is answered after all
  earlier input is drawn: the frame at a mark is the screen after the actions
  before it.
- `swtui record start <path> | mark <label> [--hold 400ms] | stop | status`
  (resolving the app as `ctl` does) and `swtui record dump <log> [--at LABEL |
  --frame N]`.

## Timing

The app runs on real time (apps sleep and read `ContinuousClock`), so the log
keeps real µs and `PresentationClock` derives the picture's timeline.

- `.script` (record_media's default): a mark shows the screen as it is for
  `hold`; segment *i* starts at `P_i = Σ D_j` and lasts `hold_i`, or the
  quantised real span when no hold was given (a live segment, for what
  animates). A held segment shows the mark's screen for its whole hold, and
  what was drawn during it appears when it ends, at `P_i + D_i`: a driver's
  dwell does not sleep, so the next key's frame comes milliseconds after the
  mark and would otherwise replace its screen at once. In a live segment a
  frame shows at `P_i + min(q(t − m_i), D_i)`. The last of frames at one
  instant wins; frames before the first mark collapse into it; `q` rounds to
  the quantum, at least 20 ms, default 40 ms. A duration on the command line
  always states its unit (`400ms`, `1.5s`) and is a whole number of
  milliseconds.
- `.draw`: real times with gaps capped at 2 s, for ad-hoc recordings.
- A driver's dwell does not sleep for real (`client.send_key("down");
  rec.hold(0.4)`), so a 45-second walk records in seconds; `rec.live(2.0)`
  does sleep, between two marks.
- GIF delays are cumulative-rounded centiseconds, so drift never builds up; a
  frame under 2 cs is merged into the next, because browsers play such delays
  at about 10 cs.

## Cells, shapes, palette

- `CellMetrics(fontSize, lineHeight = 1.2, advance, scale)`: `cellW =
  round(advance·fontSize·scale)`, `cellH = round(lineHeight·fontSize·scale)`;
  `advance` is the font's (0.6 for JetBrains Mono). SVG and raster share it.
- `GlyphGeometry` draws these as primitives in cell units, on every engine and
  in every format, never from a font: box drawing U+2500–257F (light, heavy,
  double, rounded corners, dashes, reaching the cell edges so borders join),
  block elements U+2580–259F (shades as 0.25/0.5/0.75 opacity), braille
  U+2800–28FF (2×4 dots), and the framework's chrome ▸ ▾ ▲ ▼ ● ❯ ☐ ☑. In a
  raster, strokes snap to whole pixels and are at least 1 px; dots and arcs are
  anti-aliased. `tools/font-glyphs.txt` lists every non-ASCII literal in
  `Sources/TerminalUI` and the tutorial steps, and a test holds each to being a
  shape or in the bundled font's cmap.
- `RecordingPalette { name, foreground, background, ansi[16] }`: the default
  foreground is the palette's; the default background is the recorded
  `windowBg`, else the palette's; the 16 names and `ansi256(0…15)` index the
  palette; `ansi256(16…255)` uses the xterm cube and grey ramp; `rgb` is as
  is. `.catppuccinMocha` (the docs) is pinned by a golden against the official
  scheme; `.xterm` comes from the existing nominal table.

## SVG

Background runs as rects (`crispEdges`); text runs pinned to cells with
`textLength`, every glyph outside printable ASCII/Latin-1 in its own `<text>`
at its cell and wide glyphs over two cells, so a fallback font can never shift
the grid; the font stack `"JetBrains Mono","SF Mono",Menlo,Consolas,"DejaVu
Sans Mono","Liberation Mono",monospace`; shapes as `<symbol>`/`<use>`.
Animation paints delta groups shown by `step-end` keyframes; without animation
support or under reduced motion the SVG shows its last frame; recurring rows
are deduplicated. `--svg-embed-font` embeds the configured font as a `data:`
`@font-face` (about 730 KB, off by default).

## Raster

- `GlyphSource` gives a glyph as 8-bit coverage or premultiplied RGBA
  (colour emoji), with its offsets and advance in device pixels.
- `BuiltinGlyphSource`: a TrueType parser (`head hhea maxp hmtx OS/2`, cmap
  4 and 12, `loca/glyf` simple and composite, TTC) and a signed-area coverage
  rasterizer in integer fixed point (24.8), no hinting. No floating point, so
  output is bit-identical across CPUs and systems. Bold and italic come from
  their files, else a deterministic embolden and a 12° shear. CFF/OTF go to the
  system engine.
- `SystemGlyphSource`: CoreText on macOS (the user's fixed-pitch font, or a
  file; grayscale anti-aliasing; the system cascade for fallback). On Linux,
  FreeType through `dlopen` with the few `FT_*` entry points bound by `dlsym`
  and the public prefixes of `FT_FaceRec`/`FT_GlyphSlotRec` mirrored (soname
  6), checked by a start-up self-test; fontconfig through `dlopen` for
  discovery, else a scan of standard directories. Without libfreetype the error
  says: "system font rendering on Linux needs FreeType (libfreetype.so.6):
  install libfreetype6, or render with --font bundled".
- Glyph fallback: a shape first; then the configured font; then each
  `fallback_fonts` file; then the system cascade (default with `--font
  system`, else only under `--missing-glyph system`); then the policy —
  `system` (cascade, then tofu), `box` (a hollow rect, warned with code points
  and frames), `fail` (exit non-zero). Docs renders use `fail`. A glyph wider
  than its cells is scaled to fit.
- Compositing: backgrounds, then shapes, then coverage, blended in sRGB with
  integer maths `(fg·a + bg·(255−a) + 127) / 255`.
- PNG: RGB for stills, RGBA for cards (transparent canvas, rounded clip, the
  fox rasterised from `assets/logo.svg`), indexed automatically when the
  palette is exact; `IHDR sRGB PLTE tRNS IDAT IEND`, no `tIME`; adaptive row
  filters for truecolor, none for indexed. `@2x` is rendered at scale 2.
- Deflate: LZ77 with a 32 KiB window, hash chains (max 128, deterministic),
  one-step lazy matching; each block the smallest of stored, fixed and dynamic
  Huffman by exact bit count; code lengths limited to 15 by package-merge;
  zlib wrapper and Adler-32; CRC-32 with the reflected `0xEDB88320` table.
- GIF89a: NETSCAPE2.0 loop; per frame a graphic control extension (disposal 1,
  a transparent index, the delay); each frame the dirty rectangle, unchanged
  pixels transparent; LZW up to 12-bit codes with a clear code exactly at 4096
  entries.
- Colour (`IndexedPaletteBuilder`): pixels are keyed `(fg, bg, level)` with 16
  coverage levels, so the ends of every ramp are the exact terminal colours.
  If the exact colours fit 255 entries, one global table, dropping ramp levels
  from the least-used pairs until they fit; else a local table per frame's
  dirty rectangle; past that, the least-used colours map to their nearest in
  Oklab, with a warning. Emoji get up to 32 median-cut slots per frame. No
  dithering.
- Budgets, enforced by record_media: `demo.gif` ≤ 2.0 MB (3.0 MB today),
  `debug.gif` ≤ 0.8 MB, each `demo-chN.gif` ≤ 150 KB, each `@2x` preview ≤ 60
  KB, `demo.svg` ≤ 2 MB. An over-budget walk is split in two.

## Rendering settings

`swtui record render <log> --format svg|png|gif|cast [--at LABEL] [--from L
--to L] [--scale 1|2] [--font system|bundled|PATH] [--font-bold PATH
--font-italic PATH --font-bold-italic PATH] [--fallback-font PATH]... [--engine
auto|builtin|system] [--missing-glyph system|box|fail] [--palette
catppuccin-mocha|xterm] [--font-size 15] [--line-height 1.2] [--padding 12]
[--quantum 40ms] [--loop-pause 1.5s] [--card --logo assets/logo.svg]
[--svg-embed-font] -o OUT`

`--engine auto` picks the platform engine for `system` and for CFF/OTF files,
and the builtin engine for `bundled` and TrueType files. `swtui` reads the same
keys from a `[render]` section of `.terminalui/terminalui.toml` itself (not
`DiagConfig`, so no public API); flags win. `bundled` resolves to
`tools/fonts/JetBrainsMono/` in the checkout, found from the source file's own
path; if missing, the error names the path and suggests `--font PATH`.

## The bundled font

`tools/fonts/JetBrainsMono/`: JetBrains Mono v2.304, Regular, Bold, Italic and
BoldItalic TTFs (about 1.1 MB), `OFL.txt`, and a README with the version,
source and each file's SHA-256, which a tool test checks. Under `tools/`, so in
no target and no product. SIL OFL 1.1 allows redistribution with software when
the notice and licence go with it and the font is not sold alone; it is not
modified; pictures drawn with it carry no obligation. NOTICE gains a
third-party section naming it; the README licence section gains one sentence
and "except where a file says otherwise"; CLAUDE.md's licence-sync rule covers
it.

## Driving

- `run_step(step, build_dir, env, on_stage)` moves into
  `tools/terminalui/tutorial.py`, and `check_tutorial_steps.py` becomes a thin
  caller. `record_media.py` records each preview after its stage's checks pass,
  then renders the PNG and its `@2x`. Previews may now click. Both build the
  same debug package; each step gets its own temporary HOME.
- `tools/terminalui/scenes.py`: `CHAPTER_SCENES` (each chapter tape, as
  actions with holds and live spans), `README_WALK` (pages with dwells,
  asserting each landmark's title while recording, which retires
  `test_demo_tape.py`), `README_DEBUG` (F1, F2, F3 through the socket).
- `spawn_and_connect(inherit_terminal=False)` builds the environment from
  `record_media.recording_environment`, with `TERM=xterm-256color` and
  `COLORTERM=truecolor`.
- The logs are committed under `assets/recordings/`. `record_media.py render
  [--formats …]` re-renders every picture from them without running an app,
  which is all a renderer, palette or font change needs; formats that are not
  a surface's default go to `.build-recordings/media/`. `record_media.py all`
  drives, logs and renders, always with `--font bundled --missing-glyph fail
  --palette catppuccin-mocha --font-size 15`.

## Tests

- Byte-exact on macOS and Linux (CI runs both): CRC-32/Adler-32 vectors;
  deflate round-trips through `Inflate` and goldens; PNG goldens (RGB, RGBA,
  indexed); LZW at the 4096 reset; GIF goldens (deltas, transparency, local
  tables, loop, centiseconds); TrueType parsing of the bundled files;
  rasterizer coverage on synthetic shapes (a half-pixel edge is exactly 128);
  shapes-only raster fixtures at scale 1 and 2; bundled-font text fixtures to
  PNG and GIF; SVG and cast goldens; `.tuirec` round trips; clock and palette.
- Independent oracles in Python: `zlib.decompress` on our IDAT, and a small GIF
  decoder in the test.
- System engines are tested by property, not bytes: ink within its cell, a
  consistent baseline, IoU ≥ 0.85 against the builtin engine over ASCII with
  the bundled font, the ABI self-test; CI sets `TUI_REQUIRE_FREETYPE=1` on
  Linux so a missing library fails rather than skips.
- `FrameRecorderTests`; `test_record_cli.py`; smoke cases "a recording of a
  page is the page" (one log rendered to all four formats, each checked) and
  "record from launch"; the byte-replay case from step 1.

## Steps

| # | Step | Depends on | Done when |
|---|---|---|---|
| 1 | The byte-replay check (`vt.py`, a smoke case on every page) and wide and zero-width characters written to the terminal correctly | — | in progress separately |
| 2 | `.tuirec` log, `FrameRecorder`, `[record]` from launch, `swtui record dump` | — | a session dumps as text; no recorder symbols in release; API, docs and TSan gates green |
| 3 | Socket verbs, `swtui record start/mark/stop/status`, `recording.py`, `inherit_terminal=False`, `test_record_cli.py` | 2 | a mark is answered after earlier input is drawn (by frame number) |
| 4 | `TerminalUIRecording` base: reader, clock, palette, `CellMetrics`, `CastEncoder`, `--format cast` | 2 | cast goldens byte-exact on both systems; plays in asciinema; replays through `vt.py` to the final cells |
| 5 | `GlyphGeometry`, the glyph coverage list, the SVG still renderer | 4 | SVG goldens; shapes not text; borders join at 1× and 2× in Safari, Chrome, Firefox |
| 6 | Animated SVG, starting with a Pages/DocC spike; dedupe; `--svg-embed-font` | 5 | animates on Pages; same bytes on re-render; `demo.svg` ≤ 2 MB |
| 7 | `TerminalUIRaster` encoders: CRC-32, Adler-32, deflate, PNG, LZW, GIF | — | goldens byte-exact on both systems; Python oracles; round trip through `Inflate` |
| 8 | Builtin TrueType parser and rasterizer; JetBrains Mono bundled with licence and hashes; NOTICE, README, CLAUDE.md | 7 | all four files parse; exact coverage tests; hashes checked; licence notices in place |
| 9 | Raster composer: PNG stills, GIF animation, palette builder, render flags and `[render]` | 4, 5, 7, 8 | raster goldens byte-identical on both systems; the README walk GIF within budget; four-format smoke case |
| 10 | `TerminalUISystemFonts`: CoreText; FreeType and fontconfig via `dlopen`; `--font system` the default | 9 | property tests on both systems; the stated error without libfreetype; no new packages to build on `swift:6.2` |
| 11 | Tutorial previews and cards from the shared driver; logs committed; `record_media.py render` | 3, 9 | tutorial check unchanged; previews written only after their stages pass; same files rendered on Linux and macOS; a second run leaves git clean |
| 12 | Chapter intro GIFs from `CHAPTER_SCENES` | 9, 11 | seven GIFs ≤ 150 KB; input-only chapters re-record with no diff |
| 13 | README GIFs and the Pages SVG; vhs retired (`check_vhs_compat.py`, its test, `test_demo_tape.py`, the tapes, the vhs and ImageMagick code) | 1, 6, 9 | `record_media.py all` runs with no vhs, ffmpeg or ImageMagick on macOS and in Linux Docker; README and Pages animate; budgets met; CI green |

Steps 7 and 8 run beside 2–6; 9 onward need both. Step 10 is off the docs path
and can land any time after 9. Until step 13, the vhs pipeline keeps working.

## Risks

1. FreeType's struct prefixes are mirrored without headers: only long-stable
   public fields of soname 6, behind a self-test, and only on the
   `--font system` path, which the docs never take.
2. Minimal Linux images without libfreetype or fontconfig: a clear error, a
   directory scan, and the bundled font always works.
3. The builtin rasterizer has no hinting, so 1× text is a little softer than
   CoreText's; stills ship `@2x`; judged by eye in step 9. About 1,000 lines
   to maintain, and the price of byte-identical output.
4. Byte identity holds only for the builtin engine: FreeType's version varies
   by distribution.
5. GIF colour limits on gradient-heavy pages: local tables, then nearest in
   Oklab with a warning; PNG and SVG stay exact.
6. Browser delay clamping: short frames merged, quantum ≥ 20 ms.
7. Repository size: about 1.1 MB of font plus logs; budgets enforced.
8. Licence notices must stay in sync with the font (hash-pinned).
9. SVG on Pages and DocC: settled by the step 6 spike; the fallback is the last
   frame, and Pages can return to the GIF.
10. The recorder shows what the framework meant to draw; step 1's byte replay
    checks what reached the terminal, on every page, in CI.
11. Timer-driven segments vary by one quantum; the debug overlay's live numbers
    differ on every run; goldens use synthetic logs.
12. Recorder overhead (buffered writes, a bool when idle), debug versus release
    appearance (compare a step's first frame once), path safety, the API gates,
    and three non-product targets that must stay so.
