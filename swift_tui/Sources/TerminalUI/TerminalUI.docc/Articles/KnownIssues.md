
# Known Issues — 2026-04-11

## Inspector z-order
The inspector's hit test walks the graph tree depth-first but doesn't account for compositor layering. When a modal is open, hitting a cell in the modal's rendered area should find modal nodes, but may find base app nodes instead because the graph tree has both as children of the modal modifier node.

**Fix needed:** Hit test should use resolved rects (which are correct from the render pass) AND respect compositor layer order. Cells within a modal's rendered bounds should only hit-test against modal children.

## Input parsing limitations
- ctrl+i = tab (byte 9) — can't distinguish them
- Some terminal emulators intercept certain ctrl combos
- No mouse support yet
- No detection of terminal capabilities (which escape sequences are supported)
- Need a proper input abstraction layer that handles terminal differences

## Crosshair rendering
- The crosshair horizontal/vertical lines modify cell backgrounds, which may fight with the app's own styling
- The node bounds highlight (blue tint) applies to the entire rect including border characters

## Debug always-render performance
- When debug tools are active, frame skipping is disabled, which means the framework does full rebuilds at the uncapped rate
- Should have a separate debug frame rate cap (e.g. 30fps) to avoid burning CPU while debugging

## Modal modifier chain
- The graph shows `modal → border` in the chain even when the modal is dismissed
- The modal modifier node persists in the graph; only its extra child (modal content) is added/removed
