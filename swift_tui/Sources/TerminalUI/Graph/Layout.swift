/// Layout phase — measures the graph and places it within an
/// allocated rect. Runs between reconcile (`AttributeGraph.update`)
/// and render (`GraphRenderer.render`), and owns the *mutating* parts
/// of the per-frame pipeline:
///
/// 1. Walks the graph applying layout primitives (VStack distributes
///    height, HStack distributes width, etc.) and stamps each node's
///    `rect` for the upcoming render.
/// 2. Invokes every `GeometryReader` rebuilder with the resolved
///    rect's size. The rebuilder reconciles its child subtree
///    against the live size.
///
/// After `measureAndPlace` returns, `GraphRenderer.render` can run as
/// a pure draw — read rects, write cells, no graph mutation. The
/// reviewer flagged the old design (`render` invoking the rebuilder
/// directly) as a phase-separation violation; this layer fixes that.
///
/// Layer 2 (this file) owns rect-arithmetic primitives:
///
///   - Modifier rect transforms — padding (inset by amount), border
///     (inset by 1), frame (clamp dimensions).
///   - ZStack — every child inherits the parent's rect.
///
/// Layer 3 (still on `GraphRenderer.renderLayout` until extracted)
/// owns flex distribution:
///
///   - VStack / HStack — flex weighting + per-child rect along the
///     stack axis.
///   - ScrollView — content-buffer sizing + scroll-offset blit.
///   - Modal / overlay / background-view — content centering and
///     z-order rect computation.
///
/// The split lines up with risk: Layer 2 is pure rect arithmetic
/// (easy to verify per-primitive at the layout level). Layer 3 needs
/// flex measurement + env stacking + scroll content sizing (the
/// dependency that bit the HYP-5 attempt). Layer 3 lands when its
/// own slice ships.
///
/// Isolation: Layout is non-isolated to match `GraphRenderer`. Both
/// run on the main thread by convention (the framework's 5
/// `nonisolated(unsafe)` statics in `GraphContext` document the same
/// convention) and `AttributeNode` is `@unchecked Sendable`. Tests
/// run inside `@MainActor` suites; the runtime invokes Layout from
/// main-thread render code.
public enum Layout {

    /// Measure and place the graph rooted at `node` within `rect`.
    /// Recursively walks the tree, applying layout to children
    /// according to each node's kind, and firing GeometryReader
    /// rebuilders with the size each one was placed at.
    ///
    /// This is the runtime path; tests use it directly via the same
    /// public surface to pin the phase contract.
    public static func measureAndPlace(graph node: AttributeNode, in rect: Rect) {
        node.rect = rect

        switch node.kind {
        case .primitive:
            return  // primitives have no descendants requiring layout

        case .layout(let info):
            placeLayout(node, info: info, in: rect)

        case .modifier(let effect):
            placeModifier(node, effect: effect, in: rect)

        case .viewBody:
            // GeometryReader is a viewBody node carrying a
            // `geometryRebuilder` closure. Fire it with the allocated
            // rect's size so the child subtree is reconciled now,
            // outside the render phase. Non-GR viewBody nodes have
            // a nil rebuilder; the recursion still descends so any
            // nested GR finds its rect.
            if let rebuild = node.geometryRebuilder {
                let size = Size(width: rect.width, height: rect.height)
                rebuild(size, node)
                node._lastLaidOutSize = size
            }
            for child in node.children {
                measureAndPlace(graph: child, in: rect)
            }
        }
    }

    // MARK: - Layout primitives (Layer 2: ZStack only)

    /// Place a layout container's children in `rect`.
    ///
    /// **Layer 2** (here): ZStack — every child gets the parent's rect.
    ///
    /// **Layer 3** (still in `GraphRenderer.renderLayout`): VStack,
    /// HStack, ScrollView. Layout falls back to "recurse with same
    /// rect" for those, then render does its own per-child rect math.
    /// When Layer 3 ships, the per-child rects produced by render
    /// will be moved here, and `GraphRenderer.renderLayout` will
    /// become a pure walk that reads pre-stamped child rects.
    private static func placeLayout(_ node: AttributeNode, info: LayoutInfo, in rect: Rect) {
        switch info.kind {
        case .zstack:
            // ZStack semantics: every child draws over the parent's
            // full rect, last child wins on overlapping cells. The
            // render walk treats children identically; layout matches
            // by stamping each child with the parent's rect.
            for child in node.children {
                measureAndPlace(graph: child, in: rect)
            }

        case .vstack, .hstack, .scroll:
            // Layer 3 — render still owns child rect computation for
            // these. Recurse with the parent's rect so any descendant
            // GR / modifier still fires its layout-phase contract;
            // render will overwrite the child rects when its own walk
            // distributes flex.
            for child in node.children {
                measureAndPlace(graph: child, in: rect)
            }
        }
    }

    // MARK: - Modifier primitives (Layer 2: padding / border / frame)

    /// Place a modifier node's child in `rect`, applying any modifier-
    /// specific rect transform before recursing.
    ///
    /// **Layer 2** (here): padding (inset by amount), border (inset
    /// by 1), frame (clamp dimensions). These are pure rect arithmetic;
    /// they don't depend on env, sibling sizes, or content
    /// measurement.
    ///
    /// **Layer 3** (still in `GraphRenderer.renderModifier`): overlay,
    /// backgroundView, modal — all of which compute z-order rect
    /// math that depends on content measurement (modal centering)
    /// or sibling rects. Move with the rest of Layer 3.
    ///
    /// **Pass-through modifiers** (no rect transform): foreground,
    /// background, bold, italic, underline, flexible, explicitID,
    /// focusable, focusScope, onKeyPress, onAppear, onChange,
    /// onDisappear, onClick, onHover, onPaste, actions, environment.
    /// Child inherits the parent rect unchanged.
    private static func placeModifier(_ node: AttributeNode, effect: ModifierEffect, in rect: Rect) {
        guard let child = node.children.first else { return }
        let childRect = transformedRect(for: effect, parentRect: rect)
        measureAndPlace(graph: child, in: childRect)

        // Overlay / backgroundView / modal carry a SECOND child
        // (`children[1]`). Layer 3 owns their layout (modal centering,
        // overlay z-stacking). Layer 2 places it in the parent rect
        // as a safe pre-stamp; render's existing rect math still wins
        // for those cases until Layer 3 lands.
        if node.children.count > 1 {
            measureAndPlace(graph: node.children[1], in: rect)
        }
    }

    /// Compute the child rect for a modifier effect.
    ///
    /// SW-TYPE-ENUM-STATE: explicit switch over `ModifierEffect` so
    /// adding a new effect produces a compile error here, not a
    /// silent layout regression.
    private static func transformedRect(for effect: ModifierEffect, parentRect rect: Rect) -> Rect {
        switch effect {
        case .padding(let amount):
            return rect.inset(by: amount)

        case .border:
            // Border occupies the outer ring; child gets the rect
            // shrunk by 1 on every side. Style-agnostic — every
            // BorderStyle uses the same 1-cell ring.
            return rect.inset(by: 1)

        case .frame(let width, let height, let minWidth, let maxWidth, let minHeight, let maxHeight):
            var clamped = rect
            if let w = width { clamped.width = min(w, clamped.width) }
            // .infinity skips the min() clamp — the rect already
            // carries the proposed width from the parent stack's flex
            // distribution. Only finite caps narrow the rect further.
            if let maxW = maxWidth?.fixedValue { clamped.width = min(maxW, clamped.width) }
            if let minW = minWidth?.fixedValue { clamped.width = max(minW, clamped.width) }
            if let h = height { clamped.height = min(h, clamped.height) }
            if let maxH = maxHeight?.fixedValue { clamped.height = min(maxH, clamped.height) }
            if let minH = minHeight?.fixedValue { clamped.height = max(minH, clamped.height) }
            return clamped

        case .foreground, .background, .bold, .italic, .underline,
             .flexible, .explicitID,
             .focusable, .focusScope,
             .onKeyPress, .onAppear, .onChange, .onDisappear,
             .onClick, .onHover, .onPaste,
             .actions, .environment,
             .overlay, .backgroundView, .modal:
            // Pass-through and Layer-3 modifiers: child gets the
            // parent rect unchanged. Layer 3 will replace .overlay /
            // .backgroundView / .modal with their own rect math.
            return rect
        }
    }
}
