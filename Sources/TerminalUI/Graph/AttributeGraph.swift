import Observation
import Synchronization

/// Persistent DAG of typed nodes — the core data structure.
///
/// First frame: builds the full tree from the view hierarchy.
/// Subsequent frames: reconciles in place — reuses existing nodes,
/// updates values, rebuilds only when structure changes.
public final class AttributeGraph: @unchecked Sendable {
    public var root: AttributeNode?

    /// Set during update() — tracks whether any primitive values actually changed.
    var changed = false

    /// Atomic<Bool> from the Synchronization module — a lock-free boolean
    /// safe to read/write from any thread or signal handler.
    /// Set by Observation onChange callbacks (which fire on the thread that
    /// mutated the @Observable property). Read/cleared on MainActor in update().
    private let _hasDirtyNodes = Atomic<Bool>(false)
    public var hasDirtyNodes: Bool {
        get { _hasDirtyNodes.load(ordering: .relaxed) }
        set { _hasDirtyNodes.store(newValue, ordering: .relaxed) }
    }

    public init() {}

    // MARK: - Dirty queue (in-place drain)
    //
    // SwiftUI parity per WWDC23 *Discover Observation in SwiftUI*:
    //   "If a property that is used changes, the view will update."
    //
    // The view updates — not its parents, not its siblings. The
    // `update(from:)` path always walks from root, paying parent-
    // emission cost on the unchanged path. The dirty queue is the
    // bypass: every per-node `withObservationTracking` `onChange`
    // enqueues the dirty node; `drain()` re-evaluates only those nodes
    // in place.
    //
    // Keyed by `ObjectIdentifier(node)` so two enqueues of the same
    // node within a frame collapse to one body evaluation.
    //
    // Closures that drive the body re-eval are stashed on the node
    // itself (`bodyReplay`) so `drain` can invoke them without naming
    // the generic view type.
    private var dirtyQueue: [ObjectIdentifier: AttributeNode] = [:]
    /// Re-entrancy guard: a markDirty fired *during* a drain (because a
    /// body re-evaluation read+wrote an observable) must enqueue for
    /// the next drain, not corrupt the current iteration.
    private var draining: Bool = false

    /// Called from the per-node `onChange` callback to register a
    /// dirty node for the next `drain()` cycle.
    func enqueueDirty(_ node: AttributeNode) {
        dirtyQueue[ObjectIdentifier(node)] = node
        hasDirtyNodes = true
    }

    /// Re-evaluate every node that became dirty since the last drain.
    /// Returns `true` if any work was done. Walks NO part of the tree
    /// outside the dirty nodes themselves — that's the parity claim.
    @discardableResult
    public func drain() -> Bool {
        guard !dirtyQueue.isEmpty else { return false }
        guard !draining else {
            // Re-entry from within an ongoing drain — let the outer
            // call pick up the new work on its next loop.
            return true
        }
        #if DEBUG
        dirtyDrainCount += 1
        #endif
        draining = true
        defer { draining = false }

        // Snapshot + clear so a body that re-arms its own observation
        // can enqueue itself for the *next* drain instead of looping.
        let pending = dirtyQueue
        dirtyQueue.removeAll(keepingCapacity: true)

        for (_, node) in pending {
            // Node may have been detached between markDirty and drain
            // (e.g. parent flipped an if/else branch). Skip silently.
            guard node.parent != nil || node === root else { continue }
            node.bodyReplay?(self, node)
        }

        // Re-stamp `_containsViewBody` — drained composites may have
        // grown or shrunk `.viewBody` descendants while their bodies
        // re-evaluated. Same rationale as `update(from:)`.
        if let r = root {
            _ = stampContainsViewBody(r)
        }

        hasDirtyNodes = !dirtyQueue.isEmpty
        return true
    }

    #if DEBUG
    // Frame-stat counters wired into the invalidation hot path.
    // Tests assert against these to pin parity claims; release builds
    // elide the entire #if DEBUG block so consumers pay nothing.
    //
    // bodyEvaluationCount — every composite body run inside a
    //   `withObservationTracking` scope (both `evaluateBody` and the
    //   first-build path in `constructComposite`).
    // rootWalkCount       — every call to `update(from:)`; the
    //   `drain()` path bypasses this.
    // dirtyDrainCount     — every `drain()` cycle that re-evaluated
    //   one or more dirty nodes in place.
    public private(set) var bodyEvaluationCount: Int = 0
    public private(set) var rootWalkCount: Int = 0
    public private(set) var dirtyDrainCount: Int = 0

    /// Reset every counter to zero. Tests call this between scenarios.
    public func resetFrameStats() {
        bodyEvaluationCount = 0
        rootWalkCount = 0
        dirtyDrainCount = 0
        lastFiredKeypath = nil
    }

    /// Snapshot of the current dirty-queue keys. Used by tests to
    /// assert that an observable mutation routed to exactly one
    /// composite node, not the entire ancestor chain. The queue is
    /// drained on `drain()`, so call this before draining to inspect
    /// what's pending.
    public var dirtyQueueNodeIDs: [NodeID] {
        dirtyQueue.values.map { $0.id }
    }

    /// The keypath that fired the most recent observation `willSet`,
    /// if AttributeGraph captured it. Today this is always `nil` —
    /// surfacing `ObservationTracking.changed` (currently
    /// `@_spi(SwiftUI)`) is the parity-completion work tracked
    /// separately. Reading this in tests pins the gap so it doesn't
    /// silently regress to "good enough" again.
    public private(set) var lastFiredKeypath: AnyKeyPath?
    #endif

    // MARK: - Public API

    /// Build or update the graph from a view tree.
    /// Returns true if any node values actually changed.
    @discardableResult
    public func update<V: TerminalView>(from view: V) -> Bool {
        #if DEBUG
        rootWalkCount += 1
        #endif
        let result: Bool
        if let existing = root {
            changed = false
            updateNode(existing, from: view)
            // Clear dirty AFTER update — Observation may set it again
            // for the next state change during re-evaluation
            hasDirtyNodes = false
            result = changed
        } else {
            root = constructNode(for: view, id: .root)
            hasDirtyNodes = false
            result = true
        }
        // Stamp `_containsViewBody` bottom-up so `GraphMeasurer.containsViewBody`
        // is O(1) on the measurement hot path. Reconciliation may have added
        // or removed `.viewBody` descendants — the structure is now settled
        // for the upcoming render walk, so this is the right moment to refresh.
        if let r = root {
            _ = stampContainsViewBody(r)
        }
        return result
    }

    /// Recompute and store `_containsViewBody` for `node` and every
    /// descendant. Bottom-up so a parent's value reflects freshly
    /// computed children. Called once per `update(from:)` after
    /// reconciliation completes; cheap because every descendant write
    /// is `Bool? = ...`. Returns the value stamped on `node` for the
    /// caller's convenience.
    @discardableResult
    private func stampContainsViewBody(_ node: AttributeNode) -> Bool {
        var result: Bool
        if case .viewBody = node.kind {
            result = true
        } else {
            result = false
        }
        for child in node.children {
            if stampContainsViewBody(child) {
                result = true
                // Don't break — every descendant still needs stamping.
            }
        }
        node._containsViewBody = result
        return result
    }

    // MARK: - Body Evaluation with Observation

    /// Evaluate a composite view's body with Observation tracking.
    ///
    /// `withObservationTracking` (from the Observation framework) records every
    /// @Observable property accessed during the `apply` closure. When any of
    /// those properties mutate later, the `onChange` closure fires — once, on
    /// whatever thread performed the mutation.
    ///
    /// The onChange closure must be thread-safe:
    /// - `hasDirtyNodes` is Atomic — safe from any thread.
    /// - `markDirty()` walks the mutable parent chain, so it dispatches
    ///   to @MainActor via Task.
    /// - `weak` captures prevent retain cycles when nodes are removed
    ///   from the graph between frames.
    /// - `AttributeNode` and `AttributeGraph` are `@unchecked Sendable`
    ///   so the weak captures travel through the closure freely. The
    ///   safety guarantee comes from runtime discipline — the closure
    ///   touches the captured nodes only via `markDirty` / `enqueueDirty`,
    ///   both of which only mutate atomic flags + cache fields.
    func evaluateBody<V: TerminalView>(node: AttributeNode, view: V) {
        weak let weakNode: AttributeNode? = node
        weak let weakGraph: AttributeGraph? = self
        #if DEBUG
        bodyEvaluationCount += 1
        #endif

        // Bind currentNode + currentGraph for the body-evaluation scope
        // via @TaskLocal. `withValue` restores the prior binding on
        // exit (regardless of throw) and isolates the binding to this
        // task — `Task.detached` callers cannot observe these values.
        let body: V.Body = GraphContext.$currentNode.withValue(node) {
            GraphContext.$currentGraph.withValue(self) {
                withObservationTracking {
                    view.body
                } onChange: {
                    weakGraph?.hasDirtyNodes = true
                    // Per-node dirty flag for the in-place drain path. Set
                    // synchronously so a subsequent `graph.update(from:)` on
                    // the same actor sees the dirtiness. Observation's
                    // onChange fires on the mutating thread; in a TUI app
                    // that's @MainActor for any state-driven update.
                    // `markDirty` itself only mutates a Bool + nil-able
                    // cache fields, safe under runtime discipline.
                    weakNode?.markDirty()
                    // Enqueue for in-place drain so the next frame doesn't
                    // have to walk from the root.
                    if let n = weakNode {
                        weakGraph?.enqueueDirty(n)
                    }
                }
            }
        }
        // Capture a replay closure so `drain()` can re-run the body
        // with the last-known view value without needing the generic
        // V in scope.
        node.bodyReplay = { graph, target in
            guard let storedAny = target.lastInputView, let stored = storedAny as? V else { return }
            graph.evaluateBody(node: target, view: stored)
        }

        // Update or create child from body result
        if let child = node.children.first {
            updateNode(child, from: body)
        } else {
            let childNode = constructNode(for: body, id: node.id.appending(.index(0)))
            childNode.parent = node
            node.children = [childNode]
        }

        // If the body produced different output, mark changed
        if node.isDirty {
            changed = true
            node.isDirty = false
        }
    }

    // MARK: - In-Place Update

    /// Update an existing node with a new view value.
    /// If the structure matches, update values in place (zero allocation).
    /// If structure changed, rebuild the subtree.
    func updateNode<V: TerminalView>(_ node: AttributeNode, from view: V) {
        // Try to update primitives in place
        if updatePrimitive(node, from: view) {
            return
        }

        // Layout containers — update children in place
        if let vstack = view as? any _GraphVStack {
            if case .layout(let info) = node.kind, info.kind == .vstack {
                updateLayoutChildren(node, from: vstack.graphChildren())
                return
            }
        }
        if let hstack = view as? any _GraphHStack {
            if case .layout(let info) = node.kind, info.kind == .hstack {
                updateLayoutChildren(node, from: hstack.graphChildren())
                return
            }
        }

        if let zstack = view as? any _GraphZStack {
            if case .layout(let info) = node.kind, info.kind == .zstack {
                updateLayoutChildren(node, from: zstack.graphChildren())
                return
            }
        }

        // Modifiers — update effect + child + extra child
        if let modified = view as? any _GraphModified {
            if case .modifier = node.kind {
                let newEffect = modified.graphEffect()
                node.kind = .modifier(newEffect)

                // Keep focusable flag in sync
                if case .focusable = newEffect {
                    node.isFocusable = true
                }
                if case .focusScope(let scopeID) = newEffect {
                    stampScopeID(scopeID, on: node.children)
                }
                // same env-apply window as constructModifier so
                // descendant body re-evaluations during update see the
                // ancestor's environment value, not the default.
                withEnvironmentApplied(effect: newEffect) {
                    // Update base child
                    if let child = node.children.first {
                        modified.updateChild(child, graph: self)
                    }

                    // Handle extra child (overlay/background/modal)
                    let hadExtra = node.children.count > 1
                    let extraChild = modified.constructExtraChild(
                        id: node.id.appending(.index(1)), graph: self
                    )

                    if let extraChild {
                        if hadExtra {
                            // Update existing extra child
                            modified.updateExtraChild(node.children[1], graph: self)
                        } else {
                            // Add new extra child (e.g., modal just became presented)
                            extraChild.parent = node
                            node.children.append(extraChild)
                            changed = true
                        }
                    } else if hadExtra {
                        // Remove extra child (e.g., modal dismissed)
                        fireDisappear(on: node.children[1])
                        node.children.removeLast()
                        changed = true
                    }
                }

                // Containment is stamped after the extra child is
                // reconciled: on this path the modal's content subtree does
                // not exist (or is stale) until the block above has run.
                applyContainment(effect: newEffect, on: node)

                // Lifecycle dispatch on every update — onChange compares
                // current vs stored value here; onAppear is a no-op past
                // the first frame; onDisappear refreshes its captured action.
                modified.fireLifecycle(on: node)

                node.isDirty = false
                return
            }
        }

        // Conditional — check if branch changed
        if let cond = view as? any _GraphConditional {
            cond.updateConditionalNode(node, graph: self)
            return
        }

        // ForEach — update children from data
        if let forEach = view as? any _GraphForEach {
            forEach.updateForEachNode(node, graph: self)
            return
        }

        // ScrollView — update single child
        if let scroll = view as? any _GraphScrollView {
            if case .layout(let info) = node.kind, case .scroll = info.kind {
                if let child = node.children.first {
                    updateAnyView(child, from: scroll.graphChild())
                }
                node.isDirty = false
                return
            }
        }

        // SplitView — rebuild the layout tree from the SplitState's
        // current root. Slice 1 doesn't try to diff individual SplitNode
        // mutations; the @Observable hook will mark the SplitView's
        // ancestor dirty whenever `root` is reassigned, and update walks
        // the new tree. Tree shape changes (depth, children count) are
        // structurally invasive — rebuilding the children is correct
        // behaviour. Identity-preserving diff lands with Slice 2's
        // mutation API.
        if let split = view as? any _GraphSplitView {
            if case .layout(let info) = node.kind, case .split = info.kind {
                rebuildSplitChildren(node, from: split.state.root)
                node.isDirty = false
                return
            }
        }

        // GeometryReader — refresh the closure so captures (like an updated
        // `text` binding) stay in sync. The renderer invokes the rebuilder
        // each frame; post-it updates the existing child in place
        // rather than replacing it, so identity survives across renders.
        if let geom = view as? any _GraphGeometryReader {
            weak let weakSelf: AttributeGraph? = self
            let childID = node.id.appending(.index(0))
            node.geometryRebuilder = { size, parent in
                let view = geom.rebuild(with: size)
                guard let graph = weakSelf else { return }
                if let existing = parent.children.first {
                    graph.updateAnyView(existing, from: view)
                } else {
                    let fresh = graph.constructAnyTerminalView(view, id: childID)
                    fresh.parent = parent
                    parent.children = [fresh]
                }
            }
            node.isDirty = false
            return
        }

        // Composite view — re-evaluate body with observation tracking,
        // unless we can prove inputs and observed state are unchanged.
        //
        // Two invalidation gates (mirrors SwiftUI per WWDC21 + SE-0395):
        //
        // Value-equality gate: if the new view value compares equal to
        // the cached one AND no @Observable property this body read
        // has been mutated (`!isDirty`), skip body re-evaluation
        // entirely. Three paths into the compare, in order: the
        // user-supplied `==` from `.equatable()`, the user's own
        // `Equatable` conformance, and Mirror-based field-wise compare.
        //
        // Observation gate: per-node `withObservationTracking`
        // overrides the value-equality gate. If `node.isDirty`, the
        // body re-runs even for equal inputs — some property the body
        // depends on has changed and the rendered output may differ.
        //
        // Reflective-compare path — extends the skip-condition to ALL
        // composite views, not just `.equatable()`-wrapped ones.
        // SwiftUI does this automatically per WWDC21 *Demystify SwiftUI*:
        //   "SwiftUI will keep around a copy of the value to perform a
        //    comparison and know if the view has changed."
        //
        // Order:
        //   1. `_EquatableTerminalView` wrapper → existing `==` path
        //      (fast, exact).
        //   2. Else → Mirror-based field-wise compare via reflectiveEqual.
        //   3. Either way: !isDirty AND !subtreeIsDirty AND !children.isEmpty
        //      → skip body.
        if !(V.Body.self == Never.self) {
            var inputsEqual = false
            if let eq = view as? any _EquatableTerminalView {
                if let cached = node.lastEquatableInput as? any _EquatableTerminalView {
                    inputsEqual = eq._equatableContentEqual(to: cached)
                }
                node.lastEquatableInput = eq
            } else if let cached = node.lastInputView {
                inputsEqual = AttributeGraph.reflectiveEqual(view, cached)
            }
            node.lastInputView = view
            if inputsEqual && !node.isDirty && !subtreeIsDirty(node) && !node.children.isEmpty {
                return
            }
            evaluateBody(node: node, view: view)
            return
        }
    }

    /// Update primitive values in place — no allocation.
    /// Only sets `changed` if the value actually differs.
    /// Always clears isDirty after a successful match.
    func updatePrimitive<V: TerminalView>(_ node: AttributeNode, from view: V) -> Bool {
        if let text = view as? Text {
            if case .primitive(.text(let old)) = node.kind {
                if old != text.spans {
                    node.kind = .primitive(.text(text.spans))
                    // Invalidate cached measurements on this node and up the
                    // ancestor chain — text content drives height via
                    // wrapping, and parent stack heights depend on children.
                    // Without the walk, an enclosing VStack/HStack keeps its
                    // pre-change height cached. Surfaced as a PromptInput
                    // soft-wrap regression once made the node persist
                    // instead of being rebuilt each frame. We invalidate
                    // cache fields only — not `isDirty` — to avoid
                    // ricocheting back into reconciliation paths that read
                    // dirtiness as a structural-change signal.
                    invalidateMeasurementCache(from: node)
                    changed = true
                }
                node.isDirty = false
                return true
            }
        }
        if view is Spacer {
            if case .primitive(.spacer) = node.kind {
                node.isDirty = false
                return true
            }
        }
        if let bar = view as? ProgressBar {
            if case .primitive(.progressBar(let oldVal, _, _, _)) = node.kind {
                if oldVal != bar.value {
                    node.kind = .primitive(.progressBar(
                        value: bar.value, label: bar.label, filled: bar.filled, empty: bar.empty
                    ))
                    changed = true
                }
                node.isDirty = false
                return true
            }
        }
        if let spinner = view as? Spinner {
            if case .primitive(.spinner(let oldFrame, _)) = node.kind {
                if oldFrame != spinner.frame {
                    node.kind = .primitive(.spinner(frame: spinner.frame, style: spinner.style))
                    changed = true
                }
                node.isDirty = false
                return true
            }
        }
        if view is EmptyView {
            if case .primitive(.empty) = node.kind {
                node.isDirty = false
                return true
            }
        }
        return false
    }

    /// Update layout container children in place.
    /// When counts match, verifies type compatibility before in-place update.
    /// If a child's type changed (e.g., conditional branch flip), that child
    /// is rebuilt rather than updated in place — prevents state leakage.
    func updateLayoutChildren(_ node: AttributeNode, from newChildren: [Any]) {
        if node.children.count == newChildren.count {
            for (i, newChild) in newChildren.enumerated() {
                let existing = node.children[i]
                if canUpdateInPlace(existing, from: newChild) {
                    updateAnyView(existing, from: newChild)
                } else {
                    // Type mismatch — rebuild this child. The outgoing
                    // subtree leaves the tree, so fire onDisappear before
                    // we forget about it.
                    fireDisappear(on: existing)
                    let childID = node.id.appending(.index(i))
                    let childNode = constructAnyView(newChild, id: childID)
                    childNode.parent = node
                    node.children[i] = childNode
                    changed = true
                }
            }
        } else {
            // Child count changed — rebuild all children. Fire disappear
            // on every detached subtree first so onDisappear closures
            // observe the removal.
            for old in node.children { fireDisappear(on: old) }
            node.children.removeAll(keepingCapacity: true)
            for (i, child) in newChildren.enumerated() {
                let childID = node.id.appending(.index(i))
                let childNode = constructAnyView(child, id: childID)
                childNode.parent = node
                node.children.append(childNode)
            }
            changed = true
        }
        node.isDirty = false
    }

    /// Invalidate cached width/height on `node` and any **layout** ancestors
    /// whose intrinsic size genuinely depends on this child's measurement.
    /// Stops at the first non-layout ancestor (modifier, viewBody) — those
    /// either pass through or rebuild from `geometryRebuilder`, so their
    /// caches don't need invalidation by a leaf Text edit.
    ///
    /// Originally walked all the way to the root. That over-invalidation
    /// re-measured the whole Storybook tree on every arrow-press in the
    /// sidebar — the user saw the Code panel width drift 41 → 27 across
    /// five keystrokes because some unrelated layout's cache was dropped
    /// and recomputed from a measurement context that had shifted.
    ///
    /// PromptInput soft-wrap (the original reason for any walk) still
    /// works because the GeometryReader's viewBody node bypasses cache
    /// in measureHeight AND measureWidth, so the GR's parent VStack
    /// re-derives child measurements every render — no stale path.
    func invalidateMeasurementCache(from node: AttributeNode) {
        var current: AttributeNode? = node
        while let n = current {
            n.cachedWidth = nil
            n.cachedHeight = nil
            n.cachedHeightWidth = nil
            if let parent = n.parent, case .layout = parent.kind {
                current = parent
            } else {
                current = nil
            }
        }
    }

    /// True iff any **composite** descendant of `node` has `isDirty
    /// == true`. Used by the skip-condition in `updateNode` to ensure
    /// we don't skip a body re-evaluation when an inner composite
    /// (wrapped in EquatableTerminalView, for example) has had
    /// observed state mutate.
    ///
    /// Only composite (`.viewBody`) nodes carry a meaningful "observed
    /// state changed" signal. Primitives and modifiers default to
    /// `isDirty = true` at construction (needs-first-render) and are
    /// only cleared on the update path. They must NOT count as dirty
    /// for the purposes of this check, or the short-circuit can never
    /// fire on a freshly-built subtree.
    private func subtreeIsDirty(_ node: AttributeNode) -> Bool {
        for child in node.children {
            if case .viewBody = child.kind, child.isDirty { return true }
            if subtreeIsDirty(child) { return true }
        }
        return false
    }

    /// Mirror-based field-wise compare — the automatic path into the
    /// composite-view skip-condition.
    ///
    /// SwiftUI parity contract (WWDC21 *Demystify SwiftUI*):
    ///   "SwiftUI will keep around a copy of the value to perform a
    ///    comparison and know if the view has changed. But after that,
    ///    the value is destroyed."
    ///
    /// This is automatic — `.equatable()` is the *fast path*, not the
    /// only path. Walks `Mirror.children` field by field; any field
    /// pair we cannot prove equal returns false (the body re-runs).
    ///
    /// Parity ceiling — closures (`() -> Void`) and reference types
    /// without `Equatable` defeat the compare. SwiftUI has the same
    /// limitation; mitigation is the `.equatable()` opt-in or hoisting
    /// closures to `@State` storage.
    static func reflectiveEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        // Different concrete types — never equal.
        guard type(of: lhs) == type(of: rhs) else { return false }
        return _reflectiveValueEqual(lhs, rhs)
    }

    private static func _reflectiveValueEqual(_ a: Any, _ b: Any) -> Bool {
        // Equatable fast path — value types AND classes that conform.
        // (`@Observable` classes do NOT auto-conform; storing one as a
        // view field defeats the compare here — falls through to the
        // class-reference branch below.)
        if let lhsEq = a as? any Equatable {
            return _isEqualByWitness(lhsEq, b)
        }

        // Reference type WITHOUT Equatable conformance — e.g. an
        // `@Observable` model class held by the view. We cannot prove
        // value equality without comparing every observed property,
        // and observed-state mutation already routes through the
        // per-node `onChange` tracker, not through this compare. To
        // stay correct, return false so the body re-runs and
        // `withObservationTracking` re-arms its tracker on the fresh
        // property reads. This is conservative but matches SwiftUI's
        // behaviour: reference semantics defeat the value-diff path;
        // mitigation is `.equatable()` with a user-supplied `==`
        // (the documented parity ceiling).
        if type(of: a) is AnyClass {
            return false
        }

        // Closures present no Equatable witness and Mirror exposes them
        // as zero-child leaves. We cannot decide equality → say no.
        let lm = Mirror(reflecting: a)
        let rm = Mirror(reflecting: b)
        let lhsKids = Array(lm.children)
        let rhsKids = Array(rm.children)
        guard lhsKids.count == rhsKids.count else { return false }

        // No children + no Equatable witness — two cases:
        //   (a) zero-field struct (e.g. `struct V: TerminalView { var
        //       body: ... }`) — no fields means no possible difference,
        //       always equal.
        //   (b) opaque value (closure, function reference) — Mirror
        //       reports zero children but Equatable witness was already
        //       absent. We can't tell (a) and (b) apart structurally,
        //       so we look at displayStyle: structs/classes report a
        //       displayStyle, primitives like closures don't.
        if lhsKids.isEmpty {
            switch lm.displayStyle {
            case .struct, .tuple:
                return true   // zero-field aggregate — guaranteed equal
            default:
                return false  // closure / opaque / class without == → parity ceiling
            }
        }

        for (lc, rc) in zip(lhsKids, rhsKids) {
            guard lc.label == rc.label else { return false }
            if !_reflectiveValueEqual(lc.value, rc.value) { return false }
        }
        return true
    }

    /// Open the existential to call `==` on a value whose static type
    /// is hidden behind `any Equatable`.
    private static func _isEqualByWitness<E: Equatable>(_ lhs: E, _ rhs: Any) -> Bool {
        guard let typed = rhs as? E else { return false }
        return lhs == typed
    }

    /// Walk a subtree about to be detached and invoke any captured
    /// `onDisappearAction` closures bottom-up. Mirrors SwiftUI's contract:
    /// inner views see disappear before their containers do.
    func fireDisappear(on node: AttributeNode) {
        for child in node.children {
            fireDisappear(on: child)
        }
        if let action = node.onDisappearAction {
            action()
            // Null out so a subsequent re-attach (e.g. modal toggled back
            // on) doesn't double-fire from the stale capture.
            node.onDisappearAction = nil
        }
    }

    /// Check if an existing node is structurally compatible with a new view.
    /// Returns false if the node kind doesn't match (e.g., text node receiving layout view).
    private func canUpdateInPlace(_ node: AttributeNode, from view: Any) -> Bool {
        guard let tv = view as? any TerminalView else { return false }
        return canUpdateInPlaceTyped(node, from: tv)
    }

    private func canUpdateInPlaceTyped<V: TerminalView>(_ node: AttributeNode, from view: V) -> Bool {
        // Primitives — check that the view type matches the stored primitive kind
        if view is Text { return node.kind.isPrimitive }
        if view is Spacer { return node.kind.isPrimitive }
        if view is ProgressBar { return node.kind.isPrimitive }
        if view is Spinner { return node.kind.isPrimitive }
        if view is EmptyView { return node.kind.isPrimitive }
        if view is Divider { return node.kind.isPrimitive }
        // Layouts — check kind matches
        if view is any _GraphVStack { return node.kind.isLayout(.vstack) }
        if view is any _GraphHStack { return node.kind.isLayout(.hstack) }
        if view is any _GraphZStack { return node.kind.isLayout(.zstack) }
        if let scroll = view as? any _GraphScrollView {
            return node.kind.isLayout(.scroll(scroll.scrollAxis))
        }
        // SplitView's kind match is on the axis at the *root* of the
        // current SplitState tree. If the consumer reassigns root from
        // a `.split(.horizontal, ...)` to a `.leaf(...)` or to a
        // different axis, the node kind no longer matches and the
        // graph will rebuild — same shape rule that other layout
        // containers follow.
        if let split = view as? any _GraphSplitView {
            switch split.state.root {
            case .split(let axis, _, _):
                return node.kind.isLayout(.split(axis))
            case .leaf:
                // A bare-leaf root has no split layout shell of its own;
                // no kind to match. Returning false forces a rebuild,
                // which then constructs a single-leaf tree without a
                // split node. Acceptable for Slice 1 — degenerate case.
                return false
            }
        }
        // Modifiers, conditionals, forEach — check structural kind
        if view is any _GraphModified { return node.kind.isModifier }
        if view is any _GraphConditional { return node.kind.isViewBody } // conditionals are viewBody("Conditional") nodes
        if view is any _GraphForEach { return node.kind.isLayout(.vstack) } // ForEach builds as vstack
        if view is any _TupleViewProtocol { return node.kind.isLayout(.vstack) } // TupleView builds as vstack
        // Composite views — must match BOTH viewBody kind AND the
        // exact composite type. Without the type check, swapping one
        // composite for another (e.g. TabView's `_TabContentRelay`
        // changing tab) reuses the previous composite's child subtree
        // because both are "viewBody" — leaving stale rows from the
        // outgoing tab in the incoming tab's render.
        if !(V.Body.self == Never.self) {
            guard node.kind.isViewBody else { return false }
            // First-time construction (no cached input) — types match
            // by definition because the node was just built.
            guard let cached = node.lastInputView else { return true }
            return type(of: cached) == V.self
        }
        return true // default: allow update
    }

    /// Type-erased update — opens the existential to call the generic version.
    func updateAnyView(_ node: AttributeNode, from view: Any) {
        if let tv = view as? any TerminalView {
            updateAnyTerminalView(node, from: tv)
        }
    }

    func updateAnyTerminalView<V: TerminalView>(_ node: AttributeNode, from view: V) {
        updateNode(node, from: view)
    }

    // MARK: - Initial Construction (first frame only)

    func constructNode<V: TerminalView>(for view: V, id: NodeID) -> AttributeNode {
        if let node = constructPrimitive(for: view, id: id) {
            return node
        }
        if let vstack = view as? any _GraphVStack {
            return constructVStack(vstack, id: id)
        }
        if let hstack = view as? any _GraphHStack {
            return constructHStack(hstack, id: id)
        }
        if let zstack = view as? any _GraphZStack {
            return constructZStack(zstack, id: id)
        }
        if let modified = view as? any _GraphModified {
            return constructModifier(modified, id: id)
        }
        if let cond = view as? any _GraphConditional {
            return cond.constructConditionalNode(id: id, graph: self)
        }
        if let forEach = view as? any _GraphForEach {
            return forEach.constructForEachNode(id: id, graph: self)
        }
        if let scroll = view as? any _GraphScrollView {
            return constructScrollView(scroll, id: id)
        }
        if let split = view as? any _GraphSplitView {
            return constructSplitView(split, id: id)
        }
        if let geom = view as? any _GraphGeometryReader {
            return constructGeometryReader(geom, id: id)
        }
        return constructComposite(view, id: id)
    }

    /// GeometryReader is built as a bare `viewBody` node carrying the
    /// content rebuilder closure. At graph-build time we construct a
    /// placeholder subtree with the root proposed size so measurements can
    /// proceed; the renderer calls `geometryRebuilder` each frame with the
    /// real rect and rebuilds children from scratch. This keeps descendants'
    /// view of `Size` in sync with the actual allocated region rather than
    /// the root terminal size.
    func constructGeometryReader(_ geom: any _GraphGeometryReader, id: NodeID) -> AttributeNode {
        let info = ViewBodyInfo(viewTypeName: "GeometryReader")
        let node = AttributeNode(id: id, kind: .viewBody(info))

        // Capture graph + id so the renderer can rebuild without going
        // through `GraphContext.currentGraph` (which is only scoped during
        // `graph.update`, not during render).
        weak let weakSelf: AttributeGraph? = self
        let childID = id.appending(.index(0))
        node.geometryRebuilder = { size, parent in
            let view = geom.rebuild(with: size)
            guard let graph = weakSelf else { return }
            // update existing child in place. Identity (NodeID,
            // state slots, focus registrations, lifecycle bookkeeping)
            // survives across renders. Falls back to construction only
            // when the child is missing (defensive — the seed path
            // populates children.first during construction).
            if let existing = parent.children.first {
                graph.updateAnyView(existing, from: view)
            } else {
                let fresh = graph.constructAnyTerminalView(view, id: childID)
                fresh.parent = parent
                parent.children = [fresh]
            }
        }

        // Seed with an initial subtree using whatever proposed size is
        // current — allows first-pass measurement without a render. The
        // subtree is replaced on every render via `geometryRebuilder`.
        let termSize = GraphContext.currentEnvironment?.terminalSize ?? .default
        let seedSize = GraphContext.currentProposedSize
            ?? Size(width: termSize.cols, height: termSize.rows)
        let seed = geom.rebuild(with: seedSize)
        let childNode = constructAnyView(seed, id: childID)
        childNode.parent = node
        node.children.append(childNode)
        return node
    }

    func constructPrimitive<V: TerminalView>(for view: V, id: NodeID) -> AttributeNode? {
        if let text = view as? Text {
            return AttributeNode(id: id, kind: .primitive(.text(text.spans)))
        }
        if view is Spacer {
            return AttributeNode(id: id, kind: .primitive(.spacer))
        }
        if let bar = view as? ProgressBar {
            return AttributeNode(id: id, kind: .primitive(
                .progressBar(value: bar.value, label: bar.label, filled: bar.filled, empty: bar.empty)
            ))
        }
        if let spinner = view as? Spinner {
            return AttributeNode(id: id, kind: .primitive(.spinner(frame: spinner.frame, style: spinner.style)))
        }
        if view is Divider {
            return AttributeNode(id: id, kind: .primitive(.divider))
        }
        if view is EmptyView {
            return AttributeNode(id: id, kind: .primitive(.empty))
        }
        if let bufferView = view as? BufferView {
            return AttributeNode(id: id, kind: .primitive(.cellBuffer(bufferView.buffer)))
        }
        return nil
    }

    func constructVStack(_ vstack: any _GraphVStack, id: NodeID) -> AttributeNode {
        let node = AttributeNode(id: id, kind: .layout(LayoutInfo(
            kind: .vstack,
            isStructural: vstack.isStructuralVStack
        )))
        let children = vstack.graphChildren()
        for (i, child) in children.enumerated() {
            let childID = id.appending(.index(i))
            let childNode = constructAnyView(child, id: childID)
            childNode.parent = node
            node.children.append(childNode)
        }
        return node
    }

    func constructHStack(_ hstack: any _GraphHStack, id: NodeID) -> AttributeNode {
        let node = AttributeNode(id: id, kind: .layout(LayoutInfo(kind: .hstack)))
        let children = hstack.graphChildren()
        for (i, child) in children.enumerated() {
            let childID = id.appending(.index(i))
            let childNode = constructAnyView(child, id: childID)
            childNode.parent = node
            node.children.append(childNode)
        }
        return node
    }

    func constructZStack(_ zstack: any _GraphZStack, id: NodeID) -> AttributeNode {
        let node = AttributeNode(id: id, kind: .layout(LayoutInfo(kind: .zstack)))
        let children = zstack.graphChildren()
        for (i, child) in children.enumerated() {
            let childID = id.appending(.index(i))
            let childNode = constructAnyView(child, id: childID)
            childNode.parent = node
            node.children.append(childNode)
        }
        return node
    }

    /// Build the AttributeNode subtree for a `SplitView`'s current
    /// `SplitState.root`. Recursively walks the value-typed `SplitNode`
    /// tree, mapping each `.split(axis:, children:, ratios:)` to a
    /// `LayoutKind.split(axis)` node carrying the per-child ratios on
    /// `node.splitRatios`. Leaves construct as their underlying view.
    ///
    /// Slice 1 ships fixed ratios at construction time. Slice 2 (mutation
    /// API) will re-enter via `rebuildSplitChildren` when `root` changes.
    func constructSplitView(_ split: any _GraphSplitView, id: NodeID) -> AttributeNode {
        constructSplitNode(split.state.root, id: id)
    }

    private func constructSplitNode(_ tree: SplitNode, id: NodeID) -> AttributeNode {
        switch tree {
        case .leaf(let view, _):
            // The marker is for serialisation only; the graph identifies nodes
            // by their NodeID path.
            return constructAnyView(view, id: id)

        case .split(let axis, let children, let ratios):
            let node = AttributeNode(id: id, kind: .layout(LayoutInfo(kind: .split(axis))))
            node.splitRatios = ratios
            for (i, child) in children.enumerated() {
                let childID = id.appending(.index(i))
                let childNode = constructSplitNode(child, id: childID)
                childNode.parent = node
                node.children.append(childNode)
            }
            return node
        }
    }

    /// Rebuild a SplitView's children from a (possibly mutated)
    /// `SplitNode` root. Used by `updateNode` when the consumer
    /// reassigns `state.root`. Replaces the existing subtree rather
    /// than diffing — Slice 2 will introduce identity-preserving diff
    /// once the mutation API has stable identifiers.
    private func rebuildSplitChildren(_ node: AttributeNode, from tree: SplitNode) {
        guard case .split(let axis, let children, let ratios) = tree else {
            // Defensive: kindMatches() rejects a leaf root before we
            // get here (the calling updateNode falls through to the
            // structural rebuild path). Bail out without mutating so
            // the caller's rebuild fires cleanly.
            return
        }
        // Sync node kind in case the axis flipped.
        node.kind = .layout(LayoutInfo(kind: .split(axis)))
        node.splitRatios = ratios

        // Rebuild children — Slice 1's "good enough" strategy. Mark
        // the tree dirty so downstream consumers re-render. Identity-
        // preserving diff is Slice 2 work.
        for old in node.children {
            fireDisappear(on: old)
        }
        node.children.removeAll()
        for (i, child) in children.enumerated() {
            let childID = node.id.appending(.index(i))
            let childNode = constructSplitNode(child, id: childID)
            childNode.parent = node
            node.children.append(childNode)
        }
        changed = true
    }

    func constructScrollView(_ scroll: any _GraphScrollView, id: NodeID) -> AttributeNode {
        let node = AttributeNode(id: id, kind: .layout(LayoutInfo(kind: .scroll(scroll.scrollAxis))))
        let childID = id.appending(.index(0))
        let childNode = constructAnyView(scroll.graphChild(), id: childID)
        childNode.parent = node
        node.children.append(childNode)
        // Implicit ScrollView focus from the first attempt was
        // reverted: the "focusable descendant?" check only looked at the
        // ScrollView's own subtree, so a sibling focusable (e.g. Storybook's
        // sidebar hint line BELOW the ScrollView) didn't prevent the
        // ScrollView from claiming Tab. That broke sidebar navigation.
        // Proper keyboard scroll affordance will ship as an explicit
        // modifier in a follow-up — see `scripts/storybook_walk.py` for
        // the harness that caught the regression.
        return node
    }

    func constructModifier(_ modified: any _GraphModified, id: NodeID) -> AttributeNode {
        let effect = modified.graphEffect()
        let node = AttributeNode(id: id, kind: .modifier(effect))

        // Mark focusable during construction so it's available before first render
        if case .focusable = effect {
            node.isFocusable = true
        }

        // environment modifier must apply BEFORE child construction
        // so descendants observe the new value when their bodies evaluate.
        // Previously this apply only ran at render time, by which point any
        // `@TerminalEnvironment(\.x)` reads in child bodies had already
        // resolved against the parent / default value (read-before-apply).
        // Push the mutation, build, then restore — descendants of any
        // sibling subtree are unaffected.
        let previousEnvironment = withEnvironmentApplied(effect: effect) {
            // Base view child (child[0])
            let childID = id.appending(.index(0))
            let childNode = modified.constructChildNode(id: childID, graph: self)
            childNode.parent = node
            node.children.append(childNode)

            // Extra child for overlay/background/modal (child[1])
            if let extraNode = modified.constructExtraChild(id: id.appending(.index(1)), graph: self) {
                extraNode.parent = node
                node.children.append(extraNode)
            }
        }
        _ = previousEnvironment

        // stamp scope onto focusable descendants after children exist.
        if case .focusScope(let scopeID) = effect {
            stampScopeID(scopeID, on: node.children)
        }
        applyContainment(effect: effect, on: node)

        // Fire lifecycle on the modifier node itself (onAppear, onChange's
        // first probe, onDisappear's closure capture). Without this, an
        // onAppear attached at the root never fires until the *second*
        // frame because the construction path doesn't loop back through
        // updateChild.
        modified.fireLifecycle(on: node)

        return node
    }

    /// Run `body` with `GraphContext.currentEnvironment` mutated by `effect`
    /// when `effect == .environment(apply)`. Restores the previous env on
    /// return (regardless of throw). Other effects pass through unchanged.
    /// Returns the prior env so callers can pair it with a manual restore
    /// in non-scoped paths.
    @discardableResult
    func withEnvironmentApplied<T>(effect: ModifierEffect, _ body: () -> T) -> EnvironmentValues? {
        guard case .environment(let apply) = effect else {
            _ = body()
            return nil
        }
        let previous = GraphContext.currentEnvironment ?? EnvironmentValues()
        var mutated = previous
        apply(&mutated)
        GraphContext.$currentEnvironment.withValue(mutated) {
            _ = body()
        }
        return previous
    }

    /// Walk the subtree and record scopeID on every focusable descendant.
    /// Called during construction and reconciliation of a .focusScope modifier.
    /// Stops descending into nested scopes — inner .focusScope wins for its subtree.
    func stampScopeID(_ id: String, on nodes: [AttributeNode]) {
        for node in nodes {
            if case .modifier(.focusScope) = node.kind { continue }
            if node.isFocusable { node.scopeID = id }
            stampScopeID(id, on: node.children)
        }
    }

    /// Stamp (or clear) focus containment for a modal effect. Shared by the
    /// construction and reconciliation paths, both of which call this only
    /// once the modal's content child exists.
    ///
    /// Content lives at `child[1]`; `child[0]` is the base view the modal is
    /// presented over and must stay reachable-free of the containment.
    func applyContainment(effect: ModifierEffect, on node: AttributeNode) {
        guard case .modal(let isPresented) = effect else { return }
        guard node.children.count > 1 else { return }
        // Depth 0 means "not contained", so dismissing is the same walk with
        // a different starting depth — a dismissed modal's content must be
        // reset, since reconciliation reuses these nodes and they would
        // otherwise keep trapping focus after `isPresented` flips false.
        stampContainment(depth: isPresented ? 1 : 0, on: [node.children[1]])
    }

    /// Walk a modal's content subtree recording how many presented modals
    /// enclose each focusable descendant.
    ///
    /// Depth is carried *down* from this walk rather than derived by walking
    /// up from a node's ancestors: graph construction is bottom-up, so an
    /// inner modal is stamped before its parent links exist and could not see
    /// the enclosing presentation. Descending through nested presentations
    /// here makes the result a function of tree shape alone — hence writing
    /// every visited focusable unconditionally is enough to stay idempotent
    /// under the per-frame reconciliation that re-runs this on live nodes,
    /// with no separate clearing pass.
    func stampContainment(depth: Int, on nodes: [AttributeNode]) {
        for node in nodes {
            if case .modifier(.modal(let isPresented)) = node.kind,
               node.children.count > 1 {
                // Base content stays at this level; the nested modal's own
                // content sits one level deeper when it is presented.
                stampContainment(depth: depth, on: [node.children[0]])
                stampContainment(depth: isPresented ? depth + 1 : 0,
                                 on: [node.children[1]])
                continue
            }
            // Stamped on every node, not only the explicitly focusable ones:
            // a container that is focusable as a *unit* — a split pane holding
            // nothing focusable — is decided later, at focus-collection time,
            // and would otherwise be left at depth 0 and filtered out of a
            // presented modal's traversal.
            node.containmentDepth = depth
            stampContainment(depth: depth, on: node.children)
        }
    }

    func constructComposite<V: TerminalView>(_ view: V, id: NodeID) -> AttributeNode {
        guard !(V.Body.self == Never.self) else {
            return AttributeNode(id: id, kind: .primitive(.empty))
        }
        let info = ViewBodyInfo(viewTypeName: String(describing: V.self))
        let node = AttributeNode(id: id, kind: .viewBody(info))

        weak let weakNode2: AttributeNode? = node
        weak let weakGraph2: AttributeGraph? = self
        #if DEBUG
        bodyEvaluationCount += 1
        #endif
        // Bind currentNode + currentGraph for the body-evaluation scope
        // via @TaskLocal. See `evaluateBody` for the contract.
        let body: V.Body = GraphContext.$currentNode.withValue(node) {
            GraphContext.$currentGraph.withValue(self) {
                withObservationTracking {
                    view.body
                } onChange: {
                    weakGraph2?.hasDirtyNodes = true
                    // Per-node dirty flag — synchronous so the next
                    // graph.update sees it. See `evaluateBody` for the
                    // longer note on isolation.
                    weakNode2?.markDirty()
                    // Same enqueue dance as evaluateBody.
                    if let n = weakNode2 {
                        weakGraph2?.enqueueDirty(n)
                    }
                }
            }
        }
        // Replay closure for drain(); see evaluateBody site.
        node.bodyReplay = { graph, target in
            guard let storedAny = target.lastInputView, let stored = storedAny as? V else { return }
            graph.evaluateBody(node: target, view: stored)
        }

        let childID = id.appending(.index(0))
        let childNode = constructNode(for: body, id: childID)
        childNode.parent = node
        node.children.append(childNode)
        node.isDirty = false
        // Prime the user-Equatable wrapper cache on first build so the
        // second update can short-circuit when the wrapped value
        // hasn't changed.
        if let eq = view as? any _EquatableTerminalView {
            node.lastEquatableInput = eq
        }
        // Prime the reflective-compare cache for every composite,
        // mirroring SwiftUI's automatic value-diff.
        node.lastInputView = view
        return node
    }

    func constructAnyView(_ view: Any, id: NodeID) -> AttributeNode {
        if let tv = view as? any TerminalView {
            return constructAnyTerminalView(tv, id: id)
        }
        return AttributeNode(id: id, kind: .primitive(.empty))
    }

    func constructAnyTerminalView<V: TerminalView>(_ view: V, id: NodeID) -> AttributeNode {
        constructNode(for: view, id: id)
    }
}

// MARK: - Protocols for graph construction

protocol _GraphVStack {
    func graphChildren() -> [Any]
    /// True for TupleView-style synthetic vstacks (result builder output).
    /// User-written `VStack` returns false — it's a real layout boundary.
    /// Defaulted so existing conformances (user VStack) don't need updates.
    var isStructuralVStack: Bool { get }
}

extension _GraphVStack {
    var isStructuralVStack: Bool { false }
}

protocol _GraphHStack {
    func graphChildren() -> [Any]
}

protocol _GraphModified {
    func graphEffect() -> ModifierEffect
    func constructChildNode(id: NodeID, graph: AttributeGraph) -> AttributeNode
    func updateChild(_ child: AttributeNode, graph: AttributeGraph)
    /// For overlay/background/modal: construct the extra child node
    func constructExtraChild(id: NodeID, graph: AttributeGraph) -> AttributeNode?
    func updateExtraChild(_ child: AttributeNode, graph: AttributeGraph)
    /// Lifecycle hook fired against the modifier *node itself* (not its
    /// child). Called during initial construction and on each update so
    /// onAppear/onChange/onDisappear can read/write per-node lifecycle
    /// state (didAppear, lastObservedValue, onDisappearAction).
    func fireLifecycle(on node: AttributeNode)
}

protocol _GraphConditional {
    func constructConditionalNode(id: NodeID, graph: AttributeGraph) -> AttributeNode
    func updateConditionalNode(_ node: AttributeNode, graph: AttributeGraph)
}

/// ForEach constructs children from identifiable data
protocol _GraphZStack {
    func graphChildren() -> [Any]
}

protocol _GraphForEach {
    func constructForEachNode(id: NodeID, graph: AttributeGraph) -> AttributeNode
    func updateForEachNode(_ node: AttributeNode, graph: AttributeGraph)
}

protocol _GraphScrollView {
    var scrollAxis: ScrollAxis { get }
    func graphChild() -> Any
}

/// SplitView's graph hook. The view exposes its `SplitState` so the
/// graph can walk the recursive `SplitNode` tree at construct/update
/// time and build a matching tree of `LayoutKind.split(...)` nodes —
/// each carrying the per-child ratios that drive `Layout.placeSplit`.
protocol _GraphSplitView {
    var state: SplitState { get }
}

/// Marks `GeometryReader` so the graph can detect it and install its lazy
/// rebuilder on the constructed node. `rebuild(with:)` is called during
/// render with the node's actual rect size, NOT at graph-build time.
protocol _GraphGeometryReader {
    func rebuild(with size: Size) -> any TerminalView
}

