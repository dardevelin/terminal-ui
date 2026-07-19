
# Layering Model — Z-Ordering and Floating Views

## How SwiftUI Does It

SwiftUI has no numeric z-index. Layering is structural:

- **ZStack** — children overlap. Code order = render order. Last child on top.
- **`.overlay { }`** — attached view renders on top of parent's frame.
- **`.background { }`** — attached view renders behind parent in same frame.
- **`.sheet { }`** — floating modal over everything, own coordinate space.
- **`.popover { }`** — floating, anchored to a view.

Layering is always predictable from reading the code.

## Our Model

### Tiled (current: VStack, HStack)
Children divide parent space. No overlap.

### Stacked (current: ZStack)
Children overlap in same rect. Code order = render order.
Needs: proper background handling so later children obscure earlier ones.

### Overlay/Background (planned)
```swift
Text("Hello")
    .overlay {
        Text("!").foreground(.red)  // on top, same frame
    }
    .background {
        Text("░░░")  // behind, same frame
    }
```

### Modal/Sheet (planned)
```swift
App()
    .modal(isPresented: $showHelp) {
        HelpPanel()
    }
```

Modals:
- Render over entire screen, above all other content
- Optional dim/clear background
- Centered by default, or positioned
- Capture input focus
- Dismiss with escape or binding

## Relationship to i3wm

The [[05_i3wm_layout_model|i3 model]] has tiling + floating. We follow the same split:
- Tiled = VStack/HStack (divide space)
- Stacked = ZStack (overlap)
- Floating = modal/sheet (above everything, own coordinate space)

## Implementation Priority

1. Fix ZStack to properly handle background/transparency
2. Add `.overlay { }` and `.background { }` modifiers
3. Add `.modal(isPresented:)` for floating panels
