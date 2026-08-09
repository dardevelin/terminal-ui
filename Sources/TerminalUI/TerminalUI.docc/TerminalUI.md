# ``TerminalUI``

SwiftUI for the terminal. macOS, Linux, over SSH.

## Overview

TerminalUI brings the SwiftUI paradigm to the terminal: declarative views,
`@Observable` state, modifiers, view composition. The framework renders into a
cell buffer, composites a delta against the previous frame, and emits only the
cells that changed through a single POSIX write per frame.

> Tip: New to the framework? Start with the tutorial — <doc:BuildATaskList>
> builds a working app step by step, and every reference page here is one
> click away from its steps.

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
- <doc:BuildATaskList>

### Getting started

- <doc:GettingStarted>

### Architecture

In-depth: how the framework works, for when you need to reason about it.

- <doc:ArchitecturalModels>
- <doc:AttributeGraph>
- <doc:Layering>
- <doc:Performance>

### Layout

- ``VStack``
- ``HStack``
- ``ZStack``
- ``Spacer``
- ``Divider``
- ``ScrollView``
- ``GeometryReader``

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

### Display

- ``List``
- ``Table``
- ``TabView``
- ``TreeView``
- ``DiffView``
- ``HunkDiffView``
- ``ProgressBar``
- ``StatusBar``

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
