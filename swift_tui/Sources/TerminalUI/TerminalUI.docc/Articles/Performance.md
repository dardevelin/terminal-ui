
# Profiling Progression

Three iterations measured via `sample` tool, 3 seconds at 1000Hz, release builds.

## Summary

| Version | FPS (uncapped) | swift_dynamicCast | _conformsToProtocols | swift_allocObject | _swift_release_dealloc |
|---|---|---|---|---|---|
| v1: Old Renderer (Any + as?) | ~514 | 191 | 162 | 45 | 108 |
| v2: Graph (rebuild every frame) | ~534 | 77 | 64 | 49 | 104 |
| v3: Graph (in-place update) | ~537 | 58 | 43 | 35 | 68 |

## What Changed at Each Step

### v1 → v2: Graph + enum dispatch renderer
- Render path switched from `as?` cascade (9 casts per node) to `NodeKind` enum switch (jump table)
- Dynamic casts: **-60%** (191→77)
- But graph was rebuilt from scratch every frame — allocation stayed same
- Net FPS gain: minimal (~4%) because graph construction replaced renderer casting

### v2 → v3: In-place update
- On subsequent frames, update values inside existing nodes instead of allocating new ones
- `swift_allocObject`: **-29%** (49→35)
- `_swift_release_dealloc`: **-35%** (104→68)
- Dynamic casts: **-25%** further (77→58) — update path does fewer checks

### Overall v1 → v3
- `swift_dynamicCast`: **-70%**
- `_conformsToProtocols`: **-73%**
- `swift_allocObject`: **-22%**
- `_swift_release_dealloc`: **-37%**

## Remaining Hotspots (v3)

1. **`swift_dynamicCast` (58)** — still in `updatePrimitive` and `updateNode` which use `as?` to match view types. The render path is clean; the update path still casts.
2. **`tuple_initializeWithCopy` (39) + `tuple_destroy` (37)** — from view struct value-type copying during `buildView()` and body evaluation.
3. **`_swift_release_dealloc` (68)** — ARC on `[Any]` from `graphChildren()`. The `Any` boxing of tuple children creates heap allocations.
4. **`_xzm_free` (42)** — deallocation of the `Any`-boxed children arrays.

## Next Optimization Targets

1. **Eliminate `[Any]` from `graphChildren()`** — use parameter packs to iterate tuple elements with concrete types. Removes boxing, ARC, and most remaining casts.
2. **Skip `buildView()` when state unchanged** — with Observation integration, only rebuild view bodies that depend on changed state.
3. **Dirty-region rendering** — only walk and render the graph subtree that changed, skip unchanged nodes entirely.

## v4: Optimized Diff Output

| Change | Detail |
|---|---|
| Coalesced adjacent changes | One cursor position + N characters instead of N positions + N characters |
| Bridge small gaps | Overwrite 2-3 unchanged cells rather than emit new cursor position |
| Track cursor position | Skip cursor move when already at correct position |

**Result: 537fps → 730fps (+36%)**

The terminal emulator was the bottleneck — sending fewer bytes means it has less work to parse and render. The optimization that helps SSH also helps local performance.

| Version | FPS | Improvement |
|---|---|---|
| v1: Old Renderer | ~514 | baseline |
| v2: Graph rebuild | ~534 | +4% |
| v3: In-place update | ~537 | +4% |
| v4: Optimized diff | ~730 | **+42%** |

## v5: Debug Overlay Removed from View Tree

| Change | Detail |
|---|---|
| DebugOverlay → direct buffer render | Eliminated 16 graph nodes per frame |
| Fixed Duration unit display | attoseconds/10^12 (μs) → attoseconds/10^15 (ms) |

**Corrected measurements:**
- build: 1.40ms (not 1419ms — was a display bug, 1000x off)
- io: 0.00ms (69 bytes, rounds to zero)
- 0% dirty — only spinner/progress cells change
- 69 bytes per frame — excellent for SSH

**Result: ~700fps** (debug build, uncapped)

| Version | FPS | Key change |
|---|---|---|
| v1: Old Renderer | ~514 | baseline |
| v2: Graph rebuild | ~534 | enum dispatch |
| v3: In-place update | ~537 | reuse nodes |
| v4: Optimized diff | ~730 | coalesced writes |
| v5: Overlay fix | ~700 | debug build, overlay active |

## v6: Skip Render on Unchanged Frames

`graph.update()` now returns whether any primitive values actually changed. When nothing changed, the runtime skips buffer rebuild, GraphRenderer, diff, and flush entirely.

**Result: idle frames at 17,900fps (0.05ms), active frames at ~700fps (1.4ms)**

| Frame type | FPS | Build time | Bytes | Work done |
|---|---|---|---|---|
| Idle (nothing changed) | ~17,900 | 0.05ms | 0 | buildView + graph.update (values identical) |
| Active (timer fired) | ~700 | 1.40ms | ~69 | full rebuild + render + diff + flush |

The debug overlay now shows `active/total` FPS split (e.g. `21/17927fps`) and displays stats from the last active frame so developers see real render costs, not idle frame zeros.

| Version | FPS | Key change |
|---|---|---|
| v1: Old Renderer | ~514 | baseline |
| v2: Graph rebuild | ~534 | enum dispatch |
| v3: In-place update | ~537 | reuse nodes |
| v4: Optimized diff | ~730 | coalesced writes |
| v5: Overlay fix | ~700 | debug build, overlay active |
| v6: Skip unchanged | ~17,900 idle / ~700 active | dirty tracking |

## v7: Observation-Driven Frame Skip

Runtime checks `graph.hasDirtyNodes` (set by Observation onChange callbacks) before calling `buildView()`. When no `@Observable` state has changed, zero work is done.

Demo uses `@Observable AppState` instead of global vars. The Observation framework tracks property access during body evaluation and fires callbacks on mutation.

**Result: idle frames at 82,058fps (0.01ms)**

| Frame type | FPS | Build time | Bytes | Work done |
|---|---|---|---|---|
| Idle | ~82,000 | ~0.01ms | 0 | check hasDirtyNodes (false) → skip |
| Active | ~21 | 1.45ms | 111 | buildView + graph update + render + diff + flush |

| Version | Idle FPS | Active FPS | Key change |
|---|---|---|---|
| v1: Old Renderer | ~514 | ~514 | baseline (always rebuild) |
| v4: Optimized diff | ~730 | ~730 | coalesced writes |
| v6: Skip unchanged | ~17,900 | ~700 | graph dirty tracking |
| v7: Observation skip | **~82,000** | ~21 | skip buildView() entirely |
