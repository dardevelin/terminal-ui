
# Known Issues — 2026-04-11

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
