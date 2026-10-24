# Architectural Models Compared

How each TUI framework solves the core problems: state management, layout,
rendering, and updates.

## React/Ink — Virtual DOM + Reconciler

```
JSX Components → Virtual DOM → Diff → ANSI Output
```

- Developer declares UI with JSX.
- React builds a virtual tree.
- On state change, builds new virtual tree.
- Diffs old vs new (reconciliation).
- Applies minimal changes to terminal output.
- **Fiber** breaks diffing into interruptible units.

Strength: familiar model, handles dynamic UIs well.
Weakness: runtime overhead of diffing, Fiber complexity, Node.js dependency.

## Bubbletea — Elm Architecture

```
Model → Update(Msg) → New Model → View(Model) → String
```

- Pure functional loop.
- Messages in, model updated, view re-rendered.
- Full re-render on every message — no diffing.
- Developer manages all state in the model.

Strength: simple, predictable, easy to reason about.
Weakness: full re-render every time, no partial updates.

## Ratatui — Immediate Mode

```
Loop { read input → update state → draw entire frame }
```

- No retained framework state.
- Every frame describes the entire UI.
- Framework draws what you tell it.
- Developer owns all state.

Strength: zero framework magic, maximum control.
Weakness: developer does everything, no compositional abstraction.

## Textual — Widget Tree + CSS

```
Widget Tree → CSS Layout → Render → Message System
```

- DOM-like widget tree with parent/child relationships.
- CSS-inspired styling and layout.
- Message passing between widgets.
- Reactive attributes for targeted updates.

Strength: most capable, closest to web development.
Weakness: most complex, heavy runtime.

## SwiftUI — Attribute Graph

```
View Structs → Attribute Graph → Surgical Invalidation → Render
```

- Value-type views declare structure.
- Framework maintains persistent dependency graph.
- State changes propagate through graph edges.
- Only affected nodes re-evaluate — no scanning, no diffing.

Strength: surgical precision, zero wasted work, type-safe.
Weakness: attribute graph is complex to build.

See <doc:UnderstandingTheAttributeGraph> for the details of how TerminalUI implements this.

## TerminalUI's approach

TerminalUI adopts SwiftUI's attribute graph model. Views are value types, the
framework maintains a persistent attribute graph, and state mutations through
`@Observable` propagate via graph edges — only the affected subtree
re-evaluates. Idle frames skip the whole pipeline (no state change → no work).

This gives TerminalUI ~82,000 fps idle and ~700 fps active in release builds,
with ~69–111 bytes emitted per frame over SSH thanks to delta compositing.
