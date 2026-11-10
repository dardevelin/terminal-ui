# Drawing on a canvas

Paths stroked and filled, and text placed, at a finer grain than the cell —
SwiftUI's `Canvas`, on a terminal.

## Overview

A ``Canvas`` hands its renderer a ``GraphicsContext`` and its size in cells.
The renderer draws ``Path``s and text into the context, and no views are
built for what it draws, so a canvas of thousands of segments costs only the
drawing:

```swift
struct RouteMap: TerminalView {
    let route: [CanvasPoint]
    @TerminalEnvironment(\.theme) var theme

    var body: some TerminalView {
        let theme = theme
        return Canvas { context, size in
            context.fill(Path(CanvasRect(x: 0, y: size.height / 2,
                                         width: size.width, height: size.height / 2)),
                         with: .color(theme.successSubtle))
            var path = Path()
            path.addLines(route)
            context.stroke(path, with: .color(theme.accent))
            if let summit = route.last {
                context.draw(Text("summit"), at: summit, anchor: .bottomLeading)
            }
        }
        .frame(height: 8)
    }
}
```

Coordinates are in cells from the canvas's top-left corner, and fractions
reach inside a cell: `CanvasPoint(x: 2.5, y: 1.25)` is a quarter of the way
down the third cell across.

### Three planes

A terminal cell shows one character in two colours, so the context keeps
three planes, each at the resolution a cell can show it at, and composites
them into cells when the renderer returns:

- **Fills** land on half cells, two to a cell. Where a cell's halves differ
  and nothing else covers it, the canvas draws `▀` in its two colours. A
  half is filled when its centre is inside the path, as ``FillStyle``
  decides: the non-zero rule, or the even-odd one, under which a lake in a
  field is a hole.
- **Strokes** land on braille dots, two across and four down a cell. A cell
  has one foreground, so it holds one stroke colour: a later stroke of
  another colour clears what an earlier one left in the cells it passes
  through, and a road over a river reads as a bridge rather than a blend.
  ``GraphicsContext/resolution`` — or ``TerminalView/canvasResolution(_:)``
  around the canvas — draws strokes on half cells or whole cells instead,
  into the fill plane, solid where braille is dotted.
- **Text** lands on whole cells over both, and takes the fill beneath it as
  its background unless it states one.

### Context state

A context is a value. ``GraphicsContext/translateBy(x:y:)`` and
``GraphicsContext/scaleBy(x:y:)`` move and scale what is drawn next,
``GraphicsContext/clip(to:style:)`` limits it to a path, and
``GraphicsContext/opacity`` mixes it, in Oklab, toward what lies beneath in
the canvas. Set them on a copy to have them gone after a few calls:

```swift
var inset = context
inset.translateBy(x: size.width / 2, y: size.height / 2)
inset.clip(to: Path(ellipseIn: CanvasRect(x: -6, y: -3, width: 12, height: 6)))
inset.opacity = 0.5
inset.fill(Path(CanvasRect(x: -6, y: -3, width: 12, height: 6)), with: .color(theme.accent))
```

Over the terminal's own background, which no program can know, a colour at
least half opaque draws as it is and a fainter one not at all.

### Pictures worked out sample by sample

A picture the app computes itself — a decoded image, a heat map, a software
renderer's frame — goes in without a path or a `Text` per sample.
``GraphicsContext/fillHalfCells(columns:halfRows:at:colour:)`` asks for each
half cell's colour, and
``GraphicsContext/drawCells(columns:rows:at:cell:)`` for each cell's
``CanvasCell``; ``GraphicsContext/fill(_:with:)-(CanvasRect,_)`` fills the
half cells of a rectangle without scanning a path. None of them builds
anything per sample, so once the canvas's palette has seen a picture's
colours, drawing it allocates nothing.

### When a canvas draws

Like ``GeometryReader``, a canvas is greedy: it takes what its container
offers and claims nothing from one that sizes itself to its content, so give
it a flexible slot or a `.frame`. Gestures and `.onClick` attach to it as to
any view, with locations in its own cells.

The renderer runs when the canvas has something new to show — the view
holding it builds it again, what the renderer read from an `@Observable`
model changes, the environment around it may have changed, or its size does.
A frame drawn for anything else shows what it last drew, without running the
renderer. Draw from state, then, not from the clock: to animate a canvas,
build it in a ``TimelineView``, as in <doc:DrawingOnASchedule>.

Where the renderer draws nothing the canvas is transparent, and in a
``ZStack`` the layers under it show. Pass `opaque: true` to blank those cells
instead.

## Topics

### The canvas

- ``Canvas``
- ``GraphicsContext``
- ``CanvasResolution``

### Shapes and places

- ``Path``
- ``FillStyle``
- ``CanvasPoint``
- ``CanvasSize``
- ``CanvasRect``
- ``UnitPoint``

### Block transfers

- ``CanvasCell``
