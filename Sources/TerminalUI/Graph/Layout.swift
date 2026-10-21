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
/// dependency that bit an earlier attempt). Layer 3 lands when its
/// own slice ships.
///
/// Isolation: Layout is non-isolated to match `GraphRenderer`. Both run
/// on the thread that owns the graph they are given — the main actor for
/// the runtime's, the caller's for `TerminalApp.print` — and keep no state
/// of their own between calls.
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

        case .split(let axis):
            // SplitView is Layer-2 native: ratios are first-class, so
            // layout owns child rect arithmetic end-to-end (renderer
            // becomes a pure walk). Distribute width/height across
            // children by node.splitRatios, accounting for one
            // divider cell per sibling boundary.
            placeSplit(node, axis: axis, in: rect)
        }
    }

    /// Distribute `rect` across split children along `axis`, weighted
    /// by `node.splitRatios`. Reserves one cell per sibling boundary
    /// for the divider; the remainder goes to children.
    ///
    /// Rounding rule lives in the inner per-child loop — declared
    /// ratios are honoured to the cell with the trailing child
    /// absorbing rounding error. See the comment block on the loop
    /// for why this beats `round` or Hamilton apportionment.
    private static func placeSplit(_ node: AttributeNode, axis: SplitAxis, in rect: Rect) {
        let n = node.children.count
        guard n > 0 else { return }
        if n == 1 {
            measureAndPlace(graph: node.children[0], in: rect)
            return
        }

        // Normalize ratios — the public API allows any non-negative
        // doubles; we treat them as proportional weights. Empty or
        // all-zero arrays fall back to uniform distribution so a
        // misconfigured caller still renders cleanly.
        let rawRatios = node.splitRatios.count == n ? node.splitRatios : Array(repeating: 1.0, count: n)
        let total = rawRatios.reduce(0, +)
        let weights: [Double] = total > 0
            ? rawRatios.map { $0 / total }
            : Array(repeating: 1.0 / Double(n), count: n)

        let dividers = n - 1
        let totalLength: Int
        let crossLength: Int
        switch axis {
        case .horizontal:
            totalLength = rect.width
            crossLength = rect.height
        case .vertical:
            totalLength = rect.height
            crossLength = rect.width
        }
        let availableForChildren = max(0, totalLength - dividers)

        // Per-child distribution rule:
        //
        // Non-last children take `ceil(weight × availableForChildren)`.
        // The last child absorbs the remainder so children + dividers
        // sum to `totalLength` exactly.
        //
        // Why ceil-and-trail rather than round-and-trail:
        //
        // 1. Stable visual share. Declaring `[0.6, 0.4]` of a 100-cell
        //    rect produces `[60, 39]` (with 1-cell divider) — the
        //    declared 60% pane is visibly 60 cells, not 59 because of
        //    a `round(0.6 × 99)=59` rounding-down accident. Ratios are
        //    a statement of intent; the first-listed child is the
        //    "anchor" pane and gets at least its declared share.
        //
        // 2. Trailing-error placement is consistent. The last child
        //    always carries any accumulated remainder, matching
        //    i3wm's con_resize behaviour where the last sibling mops
        //    up cell drift. No leftover drifts into a middle pane.
        //
        // 3. No starvation. The clamp in the inner branch caps each
        //    child's size at `available - assigned - dividersAfter`
        //    so a misconfigured ratio set (e.g. `[10, 0.1]` against
        //    20 cells) can't push the last pane below zero.
        var sizes: [Int] = []
        sizes.reserveCapacity(n)
        var assigned = 0
        for (i, weight) in weights.enumerated() {
            let dividersAfter = n - 1 - i
            if i == n - 1 {
                sizes.append(availableForChildren - assigned)
            } else {
                let exact = Double(availableForChildren) * weight
                // ceil(): for non-negative reals, this is "round up
                // unless already an integer". `Int(exact)` floors;
                // adding 1 only when there's a fractional part gives
                // ceil without importing Foundation.
                let floored = Int(exact)
                let size = (Double(floored) == exact) ? floored : floored + 1
                let maxAllowed = max(0, availableForChildren - assigned - dividersAfter)
                let clamped = min(size, maxAllowed)
                sizes.append(clamped)
                assigned += clamped
            }
        }

        var cursor: Int
        switch axis {
        case .horizontal:
            cursor = rect.x
            for (i, child) in node.children.enumerated() {
                let childRect = Rect(x: cursor, y: rect.y, width: sizes[i], height: crossLength)
                measureAndPlace(graph: child, in: childRect)
                cursor += sizes[i]
                if i < n - 1 { cursor += 1 }  // divider cell
            }
        case .vertical:
            cursor = rect.y
            for (i, child) in node.children.enumerated() {
                let childRect = Rect(x: rect.x, y: cursor, width: crossLength, height: sizes[i])
                measureAndPlace(graph: child, in: childRect)
                cursor += sizes[i]
                if i < n - 1 { cursor += 1 }  // divider cell
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
        var childRect = transformedRect(for: effect, parentRect: rect)
        childRect = aligned(childRect, of: child, for: effect)
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

    /// Place the content inside a frame that is bigger than it is.
    ///
    /// A `.frame` states a size; alignment states where the content sits in
    /// it. Without this the content simply drew from the top-left corner and
    /// `.frame(width: 20, alignment: .center)` said nothing. Only a
    /// non-default alignment measures — a frame under `.topLeading` hands its
    /// child the whole rect exactly as before, which is what keeps every view
    /// already written against a frame rendering unchanged.
    private static func aligned(_ rect: Rect, of child: AttributeNode,
                                for effect: ModifierEffect) -> Rect {
        guard case .frame(_, _, _, _, _, _, let alignment) = effect,
              alignment != .topLeading else { return rect }

        let width = min(rect.width, GraphMeasurer.measureWidth(child))
        let height = min(rect.height,
                         GraphMeasurer.measureHeight(child, proposedWidth: max(1, width)))
        return Rect(
            x: rect.x + alignment.horizontal.offset(for: width, in: rect.width),
            y: rect.y + alignment.vertical.offset(for: height, in: rect.height),
            width: max(1, width), height: max(1, height)
        )
    }

    /// Compute the child rect for a modifier effect.
    ///
    /// SW-TYPE-ENUM-STATE: explicit switch over `ModifierEffect` so
    /// adding a new effect produces a compile error here, not a
    /// silent layout regression.
    /// The width a modifier lays its child out at, given its own — the rule
    /// `transformedRect` applies, so measurement asks a child about the width
    /// layout will actually hand it. Width never depends on height here.
    static func childWidth(for effect: ModifierEffect, outerWidth: Int) -> Int {
        transformedRect(for: effect, parentRect: Rect(x: 0, y: 0, width: outerWidth, height: 0)).width
    }

    private static func transformedRect(for effect: ModifierEffect, parentRect rect: Rect) -> Rect {
        switch effect {
        case .padding(let insets):
            return Rect(x: rect.x + insets.leading,
                        y: rect.y + insets.top,
                        width: max(0, rect.width - insets.horizontal),
                        height: max(0, rect.height - insets.vertical))

        case .border(_, _, let edges):
            // Each drawn edge occupies one cell of the outer rect, so the
            // child shrinks only on the sides that are actually drawn — a
            // leading-only rail costs one column and no rows. Style-agnostic:
            // every BorderStyle draws a 1-cell line.
            return Rect(
                x: rect.x + (edges.contains(.leading) ? 1 : 0),
                y: rect.y + (edges.contains(.top) ? 1 : 0),
                width: max(0, rect.width - edges.horizontalInset),
                height: max(0, rect.height - edges.verticalInset))

        case .frame(let width, let height, let minWidth, let maxWidth, let minHeight, let maxHeight, _):
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
             .actions, .environment, .task,
             .overlay, .backgroundView, .modal:
            // Pass-through and Layer-3 modifiers: child gets the
            // parent rect unchanged. Layer 3 will replace .overlay /
            // .backgroundView / .modal with their own rect math.
            return rect
        }
    }
}
