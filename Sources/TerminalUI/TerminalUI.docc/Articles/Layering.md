# Layering and Z-Order

How views overlap, which one is on top, and which one the pointer reaches.

SwiftUI has no numeric z-index, and neither does TerminalUI. Layering is
structural: what is drawn later is on top, and you can tell which view that
is by reading the code. There are three ways to put one view over another:

- A ``ZStack``, for peers that share one region.
- ``TerminalView/overlay(alignment:content:)`` and
  ``TerminalView/backgroundView(alignment:content:)``, for decorating one
  view.
- A presentation (a modal, an alert, an inspector, a menu or a pushed
  screen), which is drawn over the whole screen after everything else.

One rule runs through all three. Overlap is resolved per cell, not per
pixel: a view on top replaces the character and the style of every cell it
writes, and leaves every other cell as it was.

## ZStack

Each child is offered the stack's size and placed at the size it claims,
where the stack's alignment puts it. A child claims all of an axis when it
fills it, as a ``GeometryReader``, a ``ScrollView``, a ``Divider`` across or
`.frame(maxWidth: .infinity)` does. On an axis it does not claim, it gets its
measured size. Code order is draw order, so the last child is on top.

```swift
ZStack {
    Text("░░░░░░░░░░░░\n░░░░░░░░░░░░\n░░░░░░░░░░░░")
    Text(" 3 new ")
}
```

The label covers the first seven cells of the top row. The block still shows
after it and on the rows below, and the pointer reaches the block beside the
label. To cover the whole
stack, a child says so with `.frame(maxWidth: .infinity, maxHeight: .infinity)`.

The default alignment is `.topLeading`, as it is for every stack and frame
here. SwiftUI's is `.center`.

## Overlay and background

`.overlay` and `.backgroundView` follow the ZStack rule, measured against
the frame of the view they modify (its *base*). The content is offered the
base's frame and sits at the size it claims, placed by `alignment`. A mark in
the corner covers only its own cells.

```swift
Text("Inbox")
    .frame(width: 12)
    .overlay(alignment: .topTrailing) { Text("3") }
```

An overlay is drawn after its base. A background is drawn first and the base
over it, so the background shows only in the cells the base leaves unwritten.

```swift
Text("Saved")
    .frame(width: 12, height: 3)
    .backgroundView(alignment: .bottomTrailing) { Text("●") }
```

The dot shows in the bottom-right corner, a cell the text leaves unwritten.
A background that should fill the cells around its base, such as the cells
added by `.padding`, says so with `.frame(maxWidth: .infinity, maxHeight: .infinity)`.

The pointer agrees with the drawing. Inside the base's frame the pointer
reaches the base, even in a cell where only the background shows. A
background's `.onClick` or `.onHover` never wins over the view drawn on top
of it, so put the handler on the base.

SwiftUI calls this modifier `background(alignment:content:)`. Here
``TerminalView/background(_:)`` is a different modifier: it takes a colour,
not a view, and fills every cell of the view's rect with that colour. A base
with a colour background writes all of its cells, so a `.backgroundView`
under it never shows.

## Presentations

A presentation is not drawn where it is declared. Once the rest of the tree
has been drawn, each presentation is drawn on its own layer over the whole
screen. A modal declared inside a scrolled pane still covers the app, not
just the pane.

| Modifier | Placement | Dimmed | Dismissed by |
|----------|-----------|--------|--------------|
| ``TerminalView/modal(isPresented:content:)`` | Centred on the screen | Yes | Its `Bool` only |
| ``TerminalView/alert(_:isPresented:message:actions:)`` | Centred, actions side by side | Yes | Escape, or any action |
| ``TerminalView/confirmationDialog(_:isPresented:message:actions:)`` | Centred, actions stacked | Yes | Escape, or any action |
| ``TerminalView/inspector(isPresented:content:)`` | Along the trailing edge of the view it is declared on | No | Its binding only |
| ``TerminalView/contextMenu(menuItems:)`` | At the cell clicked with the secondary button | No | Escape, a choice, or a press outside |
| ``NavigationStack`` push | Centred, over a blank base | Nothing to dim | Escape pops |

**Modal.** The content is drawn at its measured size, centred, and limited
to the screen less one cell on each side. If it is larger, it is clipped,
and a debug build warns, because controls that were clipped away can still
take focus. The whole screen behind it is dimmed: colours shift toward their
dark counterparts and bold is turned off. Nothing closes a modal except its
`Bool`, so give the content a way out:

```swift
MainView()
    .modal(isPresented: model.showHelp) {
        HelpPanel()
            .onKeyPress { event in
                guard event.key == .escape else { return .ignored }
                model.showHelp = false
                return .handled
            }
    }
```

While any presentation is up, Escape cannot quit the app, even when the
app's own handler would quit on it.

**Alert and confirmation dialog.** These are modals whose content is a
bordered dialog of ``AlertAction`` buttons. Focus starts on the `.default`
action, so Return activates it. Escape dismisses and runs the `.cancel`
action, if there is one. Any action dismisses after it runs, and the
framework clears the binding.

**Inspector.** The panel is as wide as its content, so give the content a
`.frame(width:)`. It is as tall as the view it is declared on. That view is
laid out narrower to make room, so the panel sits beside the content instead
of over it. Nothing is dimmed. Declare it on the area it should take: on the
whole app it takes every row, and on the area above a footer the footer
stays in view.

**Context menu.** The menu opens with its top-left corner on the clicked
cell, moved left or up only as far as it must to stay on the screen. Nothing
is dimmed. Focus moves to its first item. Choosing an item (Enter, Space or a
click) runs it and closes the menu. Escape, or a press anywhere outside the
menu, closes it without choosing.

**Navigation.** A ``NavigationStack`` presents the pushed screen as a modal
over a blank base, so the level it covers never shows through. Escape pops
the screen, and focus returns to the link that pushed it.

### Focus and the pointer

Every presentation traps focus. When one appears, focus moves into it, Tab
stays inside it, and a key its content ignores does not reach the view that
declared it. When it closes, focus returns to where it was.

Every presentation also owns the pointer. A click, hover or wheel inside
its content reaches only that content. A press outside it reaches nothing:
the dim around a dialog, or the screen beside an inspector. There is one
exception: the wheel beside an inspector still scrolls the view there, so
the content it presents over can still be read. A press outside a context
menu closes the menu.

### Nested presentations

A presentation can be declared inside another, such as an alert raised
from an inspector. Presentations are drawn level by level: first those
declared in the main tree, then those declared inside them. Within a level
they are drawn in tree order. The one drawn last is the *topmost*, and only
the topmost owns focus and the pointer.

## Hit-testing and z-order

``HitTest`` and the focus engine find what is under the pointer in the
same order the renderer draws:

1. If a presentation is up, the topmost one owns the screen. A point inside
   its content is searched only in that content. A point outside it belongs
   to the modal and goes no further.
2. Otherwise, or inside the topmost presentation, the search goes depth
   first through each node's children in reverse draw order, so the child
   drawn last is tried first. For a `.backgroundView` the draw order is the
   background content and then its base, so the base is tried first.
3. The deepest node whose rect contains the point wins.

Placement follows the same rule. A ZStack child's rect, and an overlay's or
background's, is the size the child claims, not the size of its container.
A small label on top holds the pointer only in its own cells, and the view
beside it can still be clicked. The renderer and the hit test read the same
draw order, so the view you see on top is the one the pointer reaches.

## Relationship to i3wm

The i3 window manager separates *tiling* windows, which divide the screen
between them, from *floating* windows, which sit above it. TerminalUI does
the same, and adds a stacking layer in between:

- **Tiled:** ``VStack``, ``HStack`` and ``SplitView`` divide their space,
  and no child overlaps another.
- **Stacked:** ``ZStack``, `.overlay` and `.backgroundView` overlap within
  one view's frame.
- **Floating:** presentations are drawn above everything, in screen
  coordinates, wherever they were declared.
