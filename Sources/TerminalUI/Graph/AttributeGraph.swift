#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Observation

/// Persistent DAG of typed nodes — the core data structure.
///
/// First frame: builds the full tree from the view hierarchy.
/// Subsequent frames: reconciles in place — reuses existing nodes,
/// updates values, rebuilds only when structure changes.
public final class AttributeGraph: @unchecked Sendable {
    /// The tree's root node; nil until the first ``update(from:)`` builds it.
    public var root: AttributeNode?

    /// Set during update() — tracks whether any primitive values actually changed.
    var changed = false

    /// Counts ``update(from:)`` calls. State only changes between updates,
    /// so a subtree built from the same inputs within one generation is the
    /// same subtree — what lets a `WidthReader` skip rebuilding at a width it
    /// already holds.
    public private(set) var updateGeneration = 0

    /// Whether any node awaits re-evaluation. The runtime reads it before
    /// doing any frame work — false means the frame is skipped entirely,
    /// which is what makes idle cost zero.
    public var hasDirtyNodes: Bool {
        invalidations.hasPending || !dirtyQueue.isEmpty
    }

    /// Creates an empty graph; the first ``update(from:)`` builds the tree.
    public convenience init() {
        self.init(wake: nil)
    }

    /// A graph whose observed-state changes raise `wake`, so the runtime's
    /// frame loop can sleep until one arrives.
    init(wake: WakeSignal?) {
        invalidations = InvalidationInbox(wake: wake)
    }

    // MARK: - Dirty queue (in-place drain)
    //
    // SwiftUI parity per WWDC23 *Discover Observation in SwiftUI*:
    //   "If a property that is used changes, the view will update."
    //
    // The view updates — not its parents, not its siblings. The
    // `update(from:)` path always walks from root, paying parent-
    // emission cost on the unchanged path. The dirty queue is the
    // bypass: every node a per-node `withObservationTracking` `onChange`
    // invalidated joins it; `drain()` re-evaluates only those nodes
    // in place.
    //
    // Keyed by `ObjectIdentifier(node)` so two enqueues of the same
    // node within a frame collapse to one body evaluation.
    //
    // Closures that drive the body re-eval are stashed on the node
    // itself (`bodyReplay`) so `drain` can invoke them without naming
    // the generic view type.
    private var dirtyQueue: [ObjectIdentifier: AttributeNode] = [:]
    /// The environment bound when the graph was last updated or drained —
    /// the root's environment, before any modifier in the tree applies.
    /// Recorded rather than read from `GraphContext` at use, because a reader
    /// rebuilt during measurement runs with the measurer's modifiers already
    /// applied to the bound environment, and applying the chain again on top
    /// would run a `transformEnvironment` edit twice.
    private(set) var baseEnvironment = EnvironmentValues()
    /// Re-entrancy guard: a `drain()` reached from inside a drain's body
    /// evaluation returns at once and leaves the work to the outer one.
    private var draining: Bool = false

    /// Nodes invalidated since the last update or drain, by `onChange` on
    /// any thread or by the main actor. The main actor moves them into the
    /// dirty queue at the start of its next ``update(from:)`` or ``drain()``.
    private let invalidations: InvalidationInbox

    /// Marks every invalidated node and queues it for ``drain()``.
    private func applyInvalidations() {
        for (_, posted) in invalidations.take() {
            // A ForEach posts itself for what its row closure read (see
            // `trackingRow`); the body holding it is what runs again.
            var node = posted
            while node.bodyReplay == nil, let parent = node.parent {
                node = parent
            }
            node.markDirty()
            dirtyQueue[ObjectIdentifier(node)] = node
        }
    }

    /// A node a reconciliation replaced no longer belongs to the tree, and
    /// re-evaluating it would only feed a subtree nothing renders.
    private func isAttached(_ node: AttributeNode) -> Bool {
        node.parent != nil || node === root
    }

    /// Re-evaluate every node that became dirty since the last drain.
    /// Returns `true` if any work was done. Walks NO part of the tree
    /// outside the dirty nodes themselves — that's the parity claim.
    @discardableResult
    public func drain() -> Bool {
        applyInvalidations()
        guard !dirtyQueue.isEmpty else { return false }
        guard !draining else {
            // Re-entry from within an ongoing drain — let the outer
            // call pick up the new work on its next loop.
            return true
        }
        #if DEBUG
        dirtyDrainCount += 1
        #endif
        baseEnvironment = GraphContext.currentEnvironment ?? EnvironmentValues()
        draining = true
        defer { draining = false }

        // Snapshot + clear so a body that re-arms its own observation
        // can enqueue itself for the *next* drain instead of looping.
        let pending = dirtyQueue
        dirtyQueue.removeAll(keepingCapacity: true)

        for (_, node) in pending {
            // Node may have been detached between markDirty and drain
            // (e.g. parent flipped an if/else branch). Skip silently.
            guard isAttached(node) else { continue }
            GraphContext.$currentEnvironment.withValue(environment(at: node)) {
                node.bodyReplay?(self, node)
            }
        }

        // Re-stamp — drained composites may have grown or shrunk
        // `.viewBody` descendants, and changed what they read, while their
        // bodies re-evaluated. Same rationale as `update(from:)`.
        if let r = root {
            stampSubtree(r)
        }
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
    /// Composite bodies run inside an observation scope since the last
    /// ``resetFrameStats()`` — both first builds and re-evaluations. Debug
    /// builds only.
    public private(set) var bodyEvaluationCount: Int = 0
    /// Full root reconciliations (``update(from:)`` calls) since the last
    /// reset; the in-place ``drain()`` path never increments it. Debug
    /// builds only.
    public private(set) var rootWalkCount: Int = 0
    /// ``drain()`` cycles that re-evaluated at least one dirty node in place
    /// since the last reset. Debug builds only.
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
        dirtyQueue.merging(invalidations.posted) { queued, _ in queued }.values.map { $0.id }
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
        applyInvalidations()
        updateGeneration += 1
        baseEnvironment = GraphContext.currentEnvironment ?? EnvironmentValues()
        #if DEBUG
        rootWalkCount += 1
        #endif
        let result: Bool
        if let existing = root {
            changed = false
            updateNode(existing, from: view)
            result = changed
        } else {
            root = constructNode(for: view, id: .root)
            result = true
        }
        // The walk re-evaluated what it reached; anything it left dirty
        // still belongs to the next drain.
        let stillDue = { (node: AttributeNode) in node.isDirty && self.isAttached(node) }
        if dirtyQueue.values.contains(where: stillDue) {
            dirtyQueue = dirtyQueue.filter { stillDue($0.value) }
        } else {
            dirtyQueue.removeAll(keepingCapacity: true)
        }
        // Stamp `_containsViewBody` bottom-up so `GraphMeasurer.containsViewBody`
        // is O(1) on the measurement hot path. Reconciliation may have added
        // or removed `.viewBody` descendants — the structure is now settled
        // for the upcoming render walk, so this is the right moment to refresh.
        if let r = root {
            stampSubtree(r)
        }
        return result
    }

    /// Recompute and store `_containsViewBody` and `_readsEnvironmentBelow`
    /// for `node` and every descendant. Bottom-up so a parent's value
    /// reflects freshly computed children. Called once per `update(from:)`
    /// and `drain()` after reconciliation completes; cheap because every
    /// descendant write is `Bool? = ...`.
    @discardableResult
    private func stampSubtree(_ node: AttributeNode) -> (containsViewBody: Bool, readsEnvironment: Bool) {
        var containsViewBody = false
        var readsEnvironment = !node.environmentReads.isEmpty || node.geometryRebuilder != nil
        if case .viewBody = node.kind {
            containsViewBody = true
        }
        for child in node.children {
            // Don't stop early — every descendant still needs stamping.
            let below = stampSubtree(child)
            containsViewBody = containsViewBody || below.containsViewBody
            readsEnvironment = readsEnvironment || below.readsEnvironment
        }
        node._containsViewBody = containsViewBody
        node._readsEnvironmentBelow = readsEnvironment
        return (containsViewBody, readsEnvironment)
    }

    // MARK: - Body Evaluation with Observation

    /// Runs `view.body` for `node` with Observation tracking.
    ///
    /// `withObservationTracking` records every `@Observable` property the
    /// body reads. When one of them changes, `onChange` fires — once, on
    /// whatever thread made the change — and all it can reach is the inbox.
    /// `weak` captures keep a node the graph has since dropped, and a graph
    /// that is gone, from being kept alive by state they once read.
    private func trackedBody<V: TerminalView>(of view: V, for node: AttributeNode) -> V.Body {
        #if DEBUG
        bodyEvaluationCount += 1
        #endif
        weak let weakNode: AttributeNode? = node
        weak let inbox: InvalidationInbox? = invalidations

        // `withValue` restores the prior binding on exit (regardless of
        // throw) and isolates it to this task — `Task.detached` callers
        // cannot observe these values.
        node.environmentReads.removeAll(keepingCapacity: true)
        let body: V.Body = GraphContext.$currentNode.withValue(node) {
            GraphContext.$currentGraph.withValue(self) {
                withObservationTracking {
                    view.body
                } onChange: {
                    if let node = weakNode {
                        inbox?.post(node)
                    }
                }
            }
        }
        // `drain()` re-runs the body from the last view value, without the
        // generic `V` in scope.
        node.bodyReplay = { graph, target in
            guard let storedAny = target.lastInputView, let stored = storedAny as? V else { return }
            graph.evaluateBody(node: target, view: stored)
        }
        return body
    }

    /// Builds one of a ForEach's rows from its closure, tracking what the
    /// closure reads. The closure runs while the graph reconciles, after the
    /// body holding the ForEach returned, so its reads belonged to no body's
    /// tracking: a row that read the selection kept its old mark when only
    /// the selection changed. A change posts `node`, the ForEach, and
    /// `applyInvalidations` runs the body holding it. Only the closure is
    /// tracked here, not the bodies of the row views it returns, which
    /// track their own.
    func trackingRow<Row>(of node: AttributeNode, _ build: () -> Row) -> Row {
        weak let weakNode: AttributeNode? = node
        weak let inbox: InvalidationInbox? = invalidations
        return withObservationTracking(build) {
            if let node = weakNode {
                inbox?.post(node)
            }
        }
    }

    /// Re-evaluates a composite's body and reconciles its child against it.
    func evaluateBody<V: TerminalView>(node: AttributeNode, view: V) {
        let body = trackedBody(of: view, for: node)

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
                let graphModifier = modified.graphEffect()
                let newEffect = graphModifier.effect
                node.apply(graphModifier)

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
                withEnvironmentApplied(of: node) {
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
                            invalidateMeasurementCache(from: node)
                            changed = true
                        }
                    } else if hadExtra {
                        // Remove extra child (e.g., modal dismissed)
                        fireDisappear(on: node.children[1])
                        node.children.removeLast()
                        invalidateMeasurementCache(from: node)
                        changed = true
                    }
                }

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

        // SplitView — reconcile the layout tree with the SplitState's
        // current root, pane by pane; see `updateSplitChildren`.
        if let split = view as? any _GraphSplitView {
            if case .layout(let info) = node.kind, case .split = info.kind {
                updateSplitChildren(node, from: split.state.root, state: split.state, path: [])
                node.isDirty = false
                return
            }
        }

        // GeometryReader — refresh the closure so captures (like an updated
        // `text` binding) stay in sync. The renderer invokes the rebuilder
        // each frame; post-it updates the existing child in place
        // rather than replacing it, so identity survives across renders.
        if let geom = view as? any _GraphGeometryReader {
            node.readerSizing = geom.sizing
            node.geometryRebuilder = makeGeometryRebuilder(geom, childID: node.id.appending(.index(0)))
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
        //
        // Equal inputs say nothing about the environment, which reaches a
        // body without passing through them. A skipped body whose own reads
        // changed runs anyway, and the bodies below it whose reads changed
        // run in place (`refreshEnvironmentReaders`).
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
                let environment = GraphContext.currentEnvironment ?? EnvironmentValues()
                if !node.environmentReadsDiffer(from: environment) {
                    refreshEnvironmentReaders(below: node, in: environment)
                    return
                }
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
                    invalidateMeasurementCache(from: node)
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
            invalidateMeasurementCache(from: node)
            changed = true
        }
        node.isDirty = false
    }

    /// Invalidate cached width/height on `node` and every ancestor, since
    /// each one's measured size is built from this one's.
    ///
    /// Owed by every change to what a node measures: its text, and the
    /// children it holds. A `ForEach` that gained an element without this
    /// kept its old height, and a scroll view, which sizes its content by
    /// measuring it, drew the log without the line appended to it.
    ///
    /// The walk used to stop at the first non-layout ancestor, on the grounds
    /// that modifiers pass through. Passing through is exactly why they must
    /// be invalidated: a modifier's cached size is its child's size. A
    /// `Text(…).foreground(…)` whose text changed left the foreground node
    /// answering with the old width, and Storybook's detail column kept the
    /// width of the page before.
    ///
    /// The early stop was itself a workaround. Walking to the root once made
    /// the Code panel's width drift 41 → 27 across keystrokes — but the drift
    /// came from GeometryReader content measured at whatever size its last
    /// rebuild had left, not from invalidating too much. With readers no
    /// longer measured that way, re-measuring an ancestor gives the same
    /// answer every time.
    func invalidateMeasurementCache(from node: AttributeNode) {
        var current: AttributeNode? = node
        while let n = current {
            n.cachedWidth = nil
            n.cachedHeight = nil
            n.cachedHeightWidth = nil
            current = n.parent
        }
    }

    /// Re-run the bodies under `node` whose environment reads no longer match
    /// the environment they now sit in, and none of the others.
    ///
    /// `environment` is the one `node` sits in; what each descendant sits in
    /// is worked out going down, through the same modifiers the walk would
    /// have applied. Those are unchanged — a skipped body's subtree is what
    /// it built last time — but they are applied rather than assumed, since a
    /// `transformEnvironment` makes the value a reader sees differ from the
    /// value at the skipped view. A re-run body updates its own subtree, so
    /// the search stops there.
    private func refreshEnvironmentReaders(below node: AttributeNode, in environment: EnvironmentValues) {
        guard node._readsEnvironmentBelow != false else { return }
        var inner = environment
        node.applyEnvironment(to: &inner)
        for child in node.children {
            if case .viewBody = child.kind, let replay = child.bodyReplay,
               child.environmentReadsDiffer(from: inner) {
                GraphContext.$currentEnvironment.withValue(inner) {
                    replay(self, child)
                }
                continue
            }
            refreshEnvironmentReaders(below: child, in: inner)
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

    /// Whether an environment value is the one a body read.
    ///
    /// Nearly always it is the very value, copied: the environment is
    /// rebuilt each frame from the same stored values, and a copy of a value
    /// is its bytes — inline fields, and the references to whatever it keeps
    /// out of line. Identical bytes settle it in a fraction of a microsecond,
    /// where comparing a theme field by field costs tens of microseconds —
    /// more than re-running the body it would spare, and it is asked once
    /// per reader. Bytes that differ prove nothing (a string rebuilt with the
    /// same characters, a padding byte), so those go to the compare inputs
    /// get, ``reflectiveEqual(_:_:)``.
    ///
    /// One consequence: a reference is the same value while it points at the
    /// same object, as in SwiftUI. What an observable object holds is tracked
    /// by observation, not here.
    static func sameEnvironmentValue<Value>(_ current: Value, _ read: Value) -> Bool {
        identicalBytes(current, read) || reflectiveEqual(current, read)
    }

    /// Compares the concrete values, not their containers: a value held as
    /// `any Theme` too large for the existential's inline buffer lives in a
    /// box, and the buffer words the box pointer leaves unused are not
    /// copied, so two containers for one value differ in bytes. Opening the
    /// value itself is not enough when `Value` is that existential — erasing
    /// it to `Any` wraps the container rather than what is in it — so the
    /// dynamic type is opened and both values are cast out to it.
    private static func identicalBytes<Value>(_ lhs: Value, _ rhs: Value) -> Bool {
        func compare<Concrete>(_: Concrete.Type) -> Bool {
            guard var lhs = lhs as? Concrete, var rhs = rhs as? Concrete else { return false }
            return withUnsafeBytes(of: &lhs) { lhsBytes in
                withUnsafeBytes(of: &rhs) { rhsBytes in
                    guard let lhsBase = lhsBytes.baseAddress, let rhsBase = rhsBytes.baseAddress else {
                        return true
                    }
                    return memcmp(lhsBase, rhsBase, lhsBytes.count) == 0
                }
            }
        }
        return _openExistential(type(of: lhs as Any), do: compare)
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
        // Work a view started belongs to that view: when it leaves the tree
        // the task goes with it, or a screen the user navigated away from
        // keeps polling and keeps waking the render loop.
        if let running = node.lifecycleTask {
            running.cancel()
            node.lifecycleTask = nil
            node.lifecycleTaskID = nil
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
                // split node — a degenerate case, rebuilt in full.
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
        let info = ViewBodyInfo(viewTypeName: geom.sizing == .width ? "WidthReader" : "GeometryReader")
        let node = AttributeNode(id: id, kind: .viewBody(info))
        node.readerSizing = geom.sizing
        let childID = id.appending(.index(0))
        node.geometryRebuilder = makeGeometryRebuilder(geom, childID: childID)

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
        node._readerBuild = (width: seedSize.width, generation: updateGeneration)
        return node
    }

    /// The closure a reader node rebuilds its content with, for whichever
    /// size a pass settles on.
    ///
    /// It captures the graph so the renderer can rebuild without going
    /// through `GraphContext.currentGraph`, which is only scoped during
    /// `graph.update`, not during render. The existing child is updated in
    /// place, so identity — NodeID, state slots, focus registrations,
    /// lifecycle bookkeeping — survives across rebuilds; construction is the
    /// fallback for a node with no child yet.
    ///
    /// A `WidthReader` skips the rebuild when it already holds a build for
    /// this width from this update: its content is a function of width and
    /// state alone, and state does not change within an update. That is what
    /// lets measurement build it for the width it asks about without paying
    /// again in layout and render. A `GeometryReader` rebuilds every time, as
    /// it always has.
    func makeGeometryRebuilder(_ geom: any _GraphGeometryReader,
                               childID: NodeID) -> (Size, AttributeNode) -> Void {
        weak let weakSelf: AttributeGraph? = self
        let sizing = geom.sizing
        return { size, parent in
            guard let graph = weakSelf else { return }
            if sizing == .width, let built = parent._readerBuild,
               built.width == size.width, built.generation == graph.updateGeneration {
                return
            }
            // Measurement and layout rebuild a reader outside the walk that
            // applied the modifiers above it, so its content is built in the
            // environment those modifiers resolve to, not whatever the caller
            // happens to have bound.
            GraphContext.$currentEnvironment.withValue(graph.environment(at: parent)) {
                let view = geom.rebuild(with: size)
                if let existing = parent.children.first {
                    graph.updateAnyView(existing, from: view)
                } else {
                    let fresh = graph.constructAnyTerminalView(view, id: childID)
                    fresh.parent = parent
                    parent.children = [fresh]
                }
            }
            parent._readerBuild = (width: size.width, generation: graph.updateGeneration)
        }
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
            isStructural: vstack.isStructuralVStack,
            spacing: vstack.layoutSpacing,
            alignment: vstack.layoutAlignment
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
        let node = AttributeNode(id: id, kind: .layout(LayoutInfo(
            kind: .hstack,
            spacing: hstack.layoutSpacing,
            alignment: hstack.layoutAlignment
        )))
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
        let node = AttributeNode(id: id, kind: .layout(LayoutInfo(
            kind: .zstack,
            alignment: zstack.layoutAlignment
        )))
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
    /// Reassigning `root` re-enters via `rebuildSplitChildren`.
    func constructSplitView(_ split: any _GraphSplitView, id: NodeID) -> AttributeNode {
        constructSplitNode(split.state.root, id: id, state: split.state, path: [])
    }

    /// `path` is the child indices from the state's root to `tree`.
    private func constructSplitNode(_ tree: SplitNode, id: NodeID, state: SplitState,
                                    path: [Int]) -> AttributeNode {
        switch tree {
        case .leaf(let view, _):
            // The marker is for serialisation only; the graph identifies nodes
            // by their NodeID path.
            return constructAnyView(view, id: id)

        case .split(let axis, let children, let ratios):
            let node = AttributeNode(id: id, kind: .layout(LayoutInfo(kind: .split(axis))))
            node.splitRatios = ratios
            Self.stampResize(node, state: state, path: path)
            for (i, child) in children.enumerated() {
                let childID = id.appending(.index(i))
                let childNode = constructSplitNode(child, id: childID, state: state, path: path + [i])
                childNode.parent = node
                node.children.append(childNode)
            }
            return node
        }
    }

    /// Lets a dragged divider write the split's new ratios into `state`.
    private static func stampResize(_ node: AttributeNode, state: SplitState, path: [Int]) {
        node._resizeSplit = { [weak state] ratios in
            guard let state else { return }
            state.root = state.root.settingRatios(ratios, at: path[...])
        }
    }

    /// Reconcile a SplitView's nodes with a (possibly mutated) `SplitNode`
    /// tree, by position, as `updateLayoutChildren` does a stack's: a pane
    /// whose view can update in place keeps its node, and with it its
    /// `@TerminalState` and focus; a nested split of the same axis is
    /// reconciled in turn. Rebuilt from nothing on every update, a pane's
    /// state reset whenever anything above the split drew again, and
    /// resizing — which assigns new ratios — reset every pane. A split
    /// whose child count changed is rebuilt: SplitNode carries no stable
    /// identifiers to diff by.
    private func updateSplitChildren(_ node: AttributeNode, from tree: SplitNode, state: SplitState,
                                     path: [Int]) {
        guard case .split(let axis, let children, let ratios) = tree else {
            // Defensive: kindMatches() rejects a leaf root before we
            // get here (the calling updateNode falls through to the
            // structural rebuild path). Bail out without mutating so
            // the caller's rebuild fires cleanly.
            return
        }
        // Sync node kind in case the axis flipped.
        node.kind = .layout(LayoutInfo(kind: .split(axis)))
        Self.stampResize(node, state: state, path: path)
        if node.splitRatios != ratios {
            node.splitRatios = ratios
            invalidateMeasurementCache(from: node)
            changed = true
        }
        guard node.children.count == children.count else {
            for old in node.children {
                fireDisappear(on: old)
            }
            node.children.removeAll()
            for (i, child) in children.enumerated() {
                let childNode = constructSplitNode(child, id: node.id.appending(.index(i)), state: state,
                                                   path: path + [i])
                childNode.parent = node
                node.children.append(childNode)
            }
            invalidateMeasurementCache(from: node)
            changed = true
            return
        }
        for (i, child) in children.enumerated() {
            let existing = node.children[i]
            switch child {
            case .split(let childAxis, _, _) where existing.kind.isLayout(.split(childAxis)):
                updateSplitChildren(existing, from: child, state: state, path: path + [i])
            case .leaf(let view, _) where canUpdateInPlace(existing, from: view):
                updateAnyView(existing, from: view)
            default:
                fireDisappear(on: existing)
                let childNode = constructSplitNode(child, id: existing.id, state: state, path: path + [i])
                childNode.parent = node
                node.children[i] = childNode
                invalidateMeasurementCache(from: node)
                changed = true
            }
        }
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
        let graphModifier = modified.graphEffect()
        let effect = graphModifier.effect
        let node = AttributeNode(id: id, kind: .modifier(effect))
        node.apply(graphModifier)

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
        let previousEnvironment = withEnvironmentApplied(of: node) {
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

        // Fire lifecycle on the modifier node itself (onAppear, onChange's
        // first probe, onDisappear's closure capture). Without this, an
        // onAppear attached at the root never fires until the *second*
        // frame because the construction path doesn't loop back through
        // updateChild.
        modified.fireLifecycle(on: node)

        return node
    }

    /// Run `body` with `GraphContext.currentEnvironment` carrying what `node`
    /// sets for its descendants (see ``AttributeNode/applyEnvironment(to:)``).
    /// Restores the previous env on return. Nodes that set nothing pass
    /// through unchanged. Returns the prior env so callers can pair it with a
    /// manual restore in non-scoped paths.
    @discardableResult
    func withEnvironmentApplied<T>(of node: AttributeNode, _ body: () -> T) -> EnvironmentValues? {
        guard node.setsEnvironment else {
            _ = body()
            return nil
        }
        let previous = GraphContext.currentEnvironment ?? EnvironmentValues()
        var mutated = previous
        node.applyEnvironment(to: &mutated)
        GraphContext.$currentEnvironment.withValue(mutated) {
            _ = body()
        }
        return previous
    }

    /// The environment `node`'s body is evaluated in: ``baseEnvironment`` with
    /// every environment modifier above `node` applied, outermost first.
    ///
    /// The root walk builds this as it descends. A body evaluated outside that
    /// walk — a drained body re-running after an observable changed, a reader
    /// rebuilt during layout — must ask for it, or it sees the frame's bare
    /// environment and draws with the default theme under an app that set one.
    func environment(at node: AttributeNode) -> EnvironmentValues {
        var env = baseEnvironment
        for ancestor in node.ancestors {
            ancestor.applyEnvironment(to: &env)
        }
        return env
    }

    /// The node keyboard focus was on when the graph was last told.
    private(set) var focusedID: NodeID?

    /// Tell the graph keyboard focus is now on `id`, so the bodies that read
    /// it — `isFocused` under the node that lost or gained it, `focusedID`
    /// anywhere — run again. Nothing else re-runs: a body that never asked
    /// cannot draw differently. Returns whether any body was invalidated.
    @discardableResult
    func focusMoved(to id: NodeID?) -> Bool {
        guard id != focusedID else { return false }
        let previous = focusedID
        focusedID = id
        guard let root else { return false }
        var invalidated = false
        invalidateFocusReaders(in: root, focusable: nil,
                               moved: [previous, id].compactMap { $0 },
                               invalidated: &invalidated)
        return invalidated
    }

    /// `focusable` is the nearest focusable node above `node` — the one whose
    /// focus `isFocused` reports to `node`'s body.
    private func invalidateFocusReaders(in node: AttributeNode, focusable: NodeID?,
                                        moved: [NodeID], invalidated: inout Bool) {
        if case .viewBody = node.kind, !node.environmentReads.isEmpty {
            let readsOwnFocus = node.environmentReads[\EnvironmentValues.isFocused] != nil
                && focusable.map(moved.contains) == true
            if readsOwnFocus || node.environmentReads[\EnvironmentValues.focusedID] != nil {
                invalidations.post(node)
                invalidated = true
            }
        }
        let below: NodeID?
        if case .modifier(.focusable) = node.kind { below = node.id } else { below = focusable }
        for child in node.children {
            invalidateFocusReaders(in: child, focusable: below, moved: moved, invalidated: &invalidated)
        }
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

    func constructComposite<V: TerminalView>(_ view: V, id: NodeID) -> AttributeNode {
        guard !(V.Body.self == Never.self) else {
            return AttributeNode(id: id, kind: .primitive(.empty))
        }
        let info = ViewBodyInfo(viewTypeName: String(describing: V.self))
        let node = AttributeNode(id: id, kind: .viewBody(info))

        let body = trackedBody(of: view, for: node)

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
    /// The author's `spacing:` and `alignment:`. Defaulted so a synthetic
    /// stack — which nobody wrote and therefore asked nothing of — reports
    /// the neutral values.
    var layoutSpacing: Int { get }
    var layoutAlignment: Alignment { get }
}

extension _GraphVStack {
    var isStructuralVStack: Bool { false }
    var layoutSpacing: Int { 0 }
    var layoutAlignment: Alignment { .topLeading }
}

protocol _GraphHStack {
    func graphChildren() -> [Any]
    var layoutSpacing: Int { get }
    var layoutAlignment: Alignment { get }
}

extension _GraphHStack {
    var layoutSpacing: Int { 0 }
    var layoutAlignment: Alignment { .topLeading }
}

/// What a modifier makes of its node: the effect, and what the effect's
/// public payload has no room for.
struct GraphModifier {
    let effect: ModifierEffect
    /// Whether a `.foreground` gives way to a colour stated above it (see
    /// `ForegroundModifier.yieldsToStated`).
    var foregroundYieldsToStated = false
    /// Where a presented modal's content is drawn.
    var placement = PresentationPlacement.centered
    /// Closes the presentation: what a press outside a menu does, or
    /// choosing an item in it.
    var dismissal: (() -> Void)?
}

/// Where a presentation is drawn: a dialog centred over the dimmed screen,
/// an inspector along the trailing edge beside what it presents over, or a
/// menu at the cell it was opened from.
enum PresentationPlacement: Equatable {
    case centered
    case trailing
    case anchored(Point)
}

protocol _GraphModified {
    func graphEffect() -> GraphModifier
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
    var layoutAlignment: Alignment { get }
}

extension _GraphZStack {
    var layoutAlignment: Alignment { .topLeading }
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

/// Marks the size-reading views so the graph can detect them and install
/// their lazy rebuilder on the constructed node. `rebuild(with:)` is called
/// with the size a pass has settled on, NOT at graph-build time.
protocol _GraphGeometryReader {
    func rebuild(with size: Size) -> any TerminalView
    /// Which dimensions the content is built from.
    var sizing: ReaderSizing { get }
}

/// How a reader is sized — the contract that keeps every pass building the
/// same subtree for the same question.
public enum ReaderSizing: Sendable, Equatable {
    /// `GeometryReader`: told its size by its container on both axes, and
    /// claims nothing when measured. Its content may read either dimension,
    /// because neither is derived from the content.
    case proposal
    /// `WidthReader`: told its width, and as tall as its content is at that
    /// width. Its content reads the width only, so building it for a width
    /// always yields the same subtree whichever pass asks.
    case width
}

