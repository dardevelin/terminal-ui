# ``TerminalUI``

SwiftUI for the terminal. macOS, Linux, over SSH.

## Overview

TerminalUI brings the SwiftUI paradigm to the terminal: declarative views,
`@Observable` state, modifiers, view composition. The framework renders into a
cell buffer, composites a delta against the previous frame, and emits only the
cells that changed through a single POSIX write per frame.

## Two ways to read this documentation

- **Learn by doing.** The <doc:TerminalUITutorials> build a real app step by
  step — every step is a complete program with a rendered preview of what it
  draws. Start there if the framework is new to you.
- **Read in depth.** The Topics below cover every view, modifier, and
  protocol, and the Architecture articles explain the machine underneath:
  the attribute graph, the layout model, the render pipeline, and the
  performance history. Start there if you want to understand before you
  build.

The two paths stay connected: tutorial steps link into the reference as
symbols come up, and links between the two open in a side panel so you
never lose your place in either.

## Hello world

```swift
import TerminalUI

@main
struct Hello: TerminalAppProtocol {
    static func content() -> some TerminalView {
        VStack {
            Text("Hello from TerminalUI").bold()
            Divider()
            Text("Press q to quit.").foreground(.gray)
        }
    }
}
```

Run with `swift run`. Press `q` to exit.

## Topics

### Tutorials

Step-by-step, building a real app — start here if you learn by doing.

- <doc:TerminalUITutorials>

### Getting started

- <doc:GettingStarted>

### Architecture

In-depth: how the framework works, for when you need to reason about it.

- <doc:ArchitecturalModels>
- <doc:UnderstandingTheAttributeGraph>
- <doc:Layering>
- <doc:Performance>

### Layout

- ``VStack``
- ``HStack``
- ``ZStack``
- ``Spacer``
- ``Divider``
- ``ScrollView``
- ``ScrollbarStyle``
- ``GeometryReader``
- ``WidthReader``
- ``DisclosureGroup``
- ``Edge``
- ``EdgeInsets``

### Primitives

- ``Text``
- ``ForEach``
- ``ForEachWithID``

### Input

- ``Button``
- ``TextInput``
- ``TextArea``
- ``Toggle``
- ``PromptInput``
- <doc:EditingKeys>

### Gestures

A press carries its button, its click count and the modifiers held; a
gesture waits for the one it describes. A right click opens a view's
`contextMenu(menuItems:)`.

- ``TapGesture``
- ``DragGesture``

### Display

- ``List``
- ``Table``
- ``TabView``
- ``TreeView``
- ``DiffView``
- ``HunkDiffView``
- ``MarkdownView``
- ``MarkdownStyle``
- ``ProgressBar``
- ``StatusBar``

### Code

- ``CodeView``
- ``SyntaxHighlighter``
- ``SyntaxHighlighters``
- ``SyntaxTheme``

### Charts

- ``BarChart``
- ``Sparkline``
- ``HeatMap``
- ``BrailleCanvas``
- ``DotMatrixText``
- ``MorseTicker``

### App lifecycle

- ``TerminalAppProtocol``
- ``TerminalRuntime``
- ``TerminalEvent``
- ``KeyEvent``
- ``MouseEvent``
- ``RenderMode``

### Known issues

- <doc:KnownIssues>
