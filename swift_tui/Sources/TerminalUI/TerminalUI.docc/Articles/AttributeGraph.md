
# Apple's Attribute Graph — How SwiftUI Actually Works

SwiftUI is closed source. What follows is assembled from WWDC sessions, reverse engineering, and observable behavior.

## The Three Layers

```
Layer 1: View structs (developer code, value types, cheap to create)
         ↓ body is called by framework
Layer 2: Attribute Graph (framework-owned, persistent, dependency tracking)
         ↓ invalidation flows through edges
Layer 3: Render Tree (backing objects, minimal updates to screen)
```

The developer only touches Layer 1. The framework owns Layers 2 and 3.

## The Attribute Graph

Not a tree of views. A **directed acyclic graph of dependencies between values.**

Every piece of data is a node:
- A `@State` property → node
- A `body` computation → node
- A layout result → node
- A rendered frame → node

Edges represent "this node reads from that node."

```
@State count ──→ body of CounterView ──→ Text node ──→ rendered glyphs
                                      ──→ layout size ──→ parent layout

@State name  ──→ body of NameView ──→ TextField node ──→ rendered glyphs
```

Changing `count` touches nothing related to `name`. Not because we diffed and found `name` unchanged — because **there's no edge connecting them.**

## Key Properties

### Dependency Tracking, Not Diffing

- React: "something changed, diff everything to find what's different"
- SwiftUI: "this specific thing changed, I already know who cares"

When `body` has `let _ = print("called")` inside it, only that view's body is called when its dependencies change. Parent views are NOT re-evaluated.

### Structural Identity

Apple distinguishes:
- **Structural identity** — position in the result builder determines identity
- **Explicit identity** — `.id()` modifier or `ForEach` with identifiable data

The first `Text` in a `VStack` is always node \#1. No ambiguity. No diffing needed to determine "which Text is which."

### Surgical Invalidation

1. State changes
2. Framework knows which view bodies depend on that state (via Observation tracking)
3. Only those bodies are re-invoked
4. Result is compared against previous result for that specific view — not the whole tree

## The Layout Protocol (Public Since iOS 16)

```swift
protocol Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    )
}
```

Two methods. Parent proposes size, child responds, parent places. Three traversals, all O(n). No constraint solver. No iteration.

## Why This Avoids Fiber

| Concern | Apple's approach |
|---|---|
| What to re-evaluate | Dependency graph tracks it — no scanning |
| Diffing old vs new | Structural identity = positions are stable |
| Expensive layout | Single pass propose-respond-place |
| Blocking main thread | body calls are small, layout is one pass |
| Deep component trees | Depth irrelevant — only dependency fan-out matters |

## Layout as Graph Nodes

Layout results are also nodes in the attribute graph. A `Text` node's size depends on its content. A `VStack`'s size depends on children's sizes. These are graph edges.

When `Text` content changes → size node invalidated → parent layout invalidated → render position updated. Invalidation follows the graph. No full layout pass.

## Analogs in Other Systems

The attribute graph is closer to:
- MobX (JavaScript reactive state)
- Solid.js signals
- Rust's Leptos signals
- Reactive spreadsheet cells

Than to React's virtual DOM or Elm's model-view-update.

See [[10_chosen_architecture]] for how we adopt this approach.
