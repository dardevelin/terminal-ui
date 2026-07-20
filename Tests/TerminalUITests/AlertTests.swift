import Foundation
import Testing
@testable import TerminalUI

// Apple HIG, Alerts: an alert "conveys important information related to the
// state of your app" and requires an explicit choice to dismiss. Two rules
// from that guidance drive the behaviour pinned here:
//
//   * Escape must always leave. A dialog the user cannot dismiss is the
//     worst failure mode in a terminal, where there is no window chrome to
//     fall back on. Escape dismisses whether or not a `.cancel` action was
//     declared.
//   * A destructive action is never the default. HIG: "make sure the button
//     that performs the destructive action isn't the one people are most
//     likely to choose accidentally."
//
// Dismissal rides the existing action system rather than a bespoke registry.
// `ActionDispatch.scopeChain` walks focused-node→root innermost-first and
// appends the framework defaults last, and focus containment guarantees the
// focused node sits inside the topmost presented modal. So an alert-scoped
// Escape binding shadows the framework's `dismissOrQuit` exactly while the
// alert is up, and nests correctly for alert-over-alert.

@MainActor
private func focusables(_ engine: FocusEngine, _ root: AttributeNode) -> [AttributeNode] {
    engine.collectFocusables(root)
}

/// Render once so `_resolvedEnv` is populated — it is assigned during
/// `GraphRenderer.render`, not by `graph.update`, and action dispatch reads
/// the resolved action context from it.
@discardableResult
@MainActor
private func render(_ graph: AttributeGraph, width: Int = 80, height: Int = 24) -> CellBuffer {
    var buffer = CellBuffer(width: width, height: height)
    guard let root = graph.root else { return buffer }
    GraphRenderer.render(
        root,
        into: &buffer,
        context: RenderContext(rect: Rect(x: 0, y: 0, width: width, height: height))
    )
    return buffer
}

/// Build a graph with a focus engine installed, the way the runtime does.
///
/// `.onKeyPress` handlers register through `GraphContext.currentFocusEngine`
/// during graph construction, so an engine created after `graph.update` has an
/// empty handler table and Return reaches nothing. Tests that press keys must
/// bind the engine first.
@MainActor
private func buildWithEngine(
    _ engine: FocusEngine,
    _ graph: AttributeGraph,
    _ view: some TerminalView,
    width: Int = 80,
    height: Int = 24
) {
    GraphContext.$currentFocusEngine.withValue(engine) {
        graph.update(from: view)
        render(graph, width: width, height: height)
        engine.rebuildIndex(root: graph.root!)
    }
}

/// Flatten a rendered buffer to text so assertions can look for labels
/// without caring where the dialog was centred.
private func renderedText(_ buffer: CellBuffer) -> String {
    var out = ""
    for y in 0..<buffer.height {
        for x in 0..<buffer.width {
            out.append(buffer[x, y].character)
        }
        out.append("\n")
    }
    return out
}

// MARK: - Presentation

@Suite("Alert — presentation")
@MainActor
struct AlertPresentationTests {

    @Test("alert renders its title and actions when the binding is true")
    func alertPresentsWhenBindingTrue() {
        let flag = Box(true)
        let graph = AttributeGraph()
        graph.update(from: Text("bg").focusable()
            .alert("Delete file?", isPresented: flag.binding) {
                AlertAction("Delete", role: .destructive) {}
                AlertAction("Cancel", role: .cancel) {}
            })

        let text = renderedText(render(graph))
        #expect(text.contains("Delete file?"))
        #expect(text.contains("Delete"))
        #expect(text.contains("Cancel"))
    }

    @Test("alert renders nothing when the binding is false")
    func alertHiddenWhenBindingFalse() {
        let flag = Box(false)
        let graph = AttributeGraph()
        graph.update(from: Text("bg").focusable()
            .alert("Delete file?", isPresented: flag.binding) {
                AlertAction("Delete", role: .destructive) {}
            })

        #expect(!renderedText(render(graph)).contains("Delete file?"))
    }

    @Test("confirmationDialog stacks its actions vertically")
    func confirmationDialogStacksActionsVertically() {
        let flag = Box(true)
        let graph = AttributeGraph()
        graph.update(from: Text("bg").focusable()
            .confirmationDialog("Discard changes?", isPresented: flag.binding) {
                AlertAction("Discard", role: .destructive) {}
                AlertAction("Keep", role: .cancel) {}
            })
        render(graph)

        let engine = FocusEngine()
        let buttons = focusables(engine, graph.root!).filter { $0.containmentDepth > 0 }
        #expect(buttons.count == 2)
        // Stacked: the two actions share a column and differ in row. The
        // horizontal `.alert` form is asserted by its complement below.
        let rects = buttons.map(\.rect)
        #expect(rects[0].y != rects[1].y, "confirmationDialog actions must stack vertically; got \(rects)")
    }

    @Test("alert lays its actions out side by side")
    func alertRowsActionsHorizontally() {
        let flag = Box(true)
        let graph = AttributeGraph()
        graph.update(from: Text("bg").focusable()
            .alert("Delete file?", isPresented: flag.binding) {
                AlertAction("Delete", role: .destructive) {}
                AlertAction("Cancel", role: .cancel) {}
            })
        render(graph)

        let engine = FocusEngine()
        let buttons = focusables(engine, graph.root!).filter { $0.containmentDepth > 0 }
        #expect(buttons.count == 2)
        let rects = buttons.map(\.rect)
        #expect(rects[0].y == rects[1].y, "alert actions must share a row; got \(rects)")
    }
}

// MARK: - Dismissal

@Suite("Alert — dismissal")
@MainActor
struct AlertDismissalTests {

    @Test("escape dismisses and fires the cancel action")
    func escapeDismissesAndFiresCancel() {
        let flag = Box(true)
        let cancelled = Box(false)
        let graph = AttributeGraph()
        graph.update(from: Text("bg").focusable()
            .alert("Delete file?", isPresented: flag.binding) {
                AlertAction("Delete", role: .destructive) {}
                AlertAction("Cancel", role: .cancel) { cancelled.value = true }
            })
        render(graph)

        let engine = FocusEngine()
        let inAlert = focusables(engine, graph.root!).first { $0.containmentDepth > 0 }
        #expect(inAlert != nil)

        ActionDispatch.dispatch(binding: .keyboard(.escape, []), from: inAlert!)
        #expect(cancelled.value, "escape must fire the .cancel action")
        #expect(!flag.value, "escape must clear the presentation binding")
    }

    @Test("escape still dismisses when no cancel action was declared")
    func escapeDismissesWhenNoCancelAction() {
        let flag = Box(true)
        let graph = AttributeGraph()
        graph.update(from: Text("bg").focusable()
            .alert("Heads up", isPresented: flag.binding) {
                AlertAction("OK") {}
            })
        render(graph)

        let engine = FocusEngine()
        let inAlert = focusables(engine, graph.root!).first { $0.containmentDepth > 0 }
        #expect(inAlert != nil)

        ActionDispatch.dispatch(binding: .keyboard(.escape, []), from: inAlert!)
        #expect(!flag.value, "escape must dismiss even with no .cancel action")
    }

    @Test("escape inside an alert does not reach the framework quit default")
    func escapeDoesNotQuitWhilePresented() {
        let flag = Box(true)
        let quit = Box(false)
        let graph = AttributeGraph()
        graph.update(from: Text("bg").focusable()
            .alert("Delete file?", isPresented: flag.binding) {
                AlertAction("Cancel", role: .cancel) {}
            })
        render(graph)

        let defaults = ActionScope.frameworkDefaults(
            quit: {},
            dismissOrQuit: { quit.value = true }
        )
        let engine = FocusEngine()
        let inAlert = focusables(engine, graph.root!).first { $0.containmentDepth > 0 }

        ActionDispatch.dispatch(
            binding: .keyboard(.escape, []),
            from: inAlert!,
            frameworkDefaults: defaults
        )
        #expect(!quit.value, "the alert's Escape binding must shadow app.dismissOrQuit")
        #expect(!flag.value)
    }

    @Test("a presented alert reports that it is containing focus")
    func presentedAlertContainsFocus() {
        let flag = Box(true)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, Text("bg").focusable()
            .alert("Delete file?", isPresented: flag.binding) {
                AlertAction("Cancel", role: .cancel) {}
            })

        // The runtime reads this to keep an app's global Escape-to-quit from
        // firing while a dialog is up. Apps that bind Escape at the top level
        // would otherwise quit instead of closing the dialog.
        #expect(engine.isContainingFocus, "a presented alert must contain focus")

        flag.value = false
        buildWithEngine(engine, graph, Text("bg").focusable()
            .alert("Delete file?", isPresented: flag.binding) {
                AlertAction("Cancel", role: .cancel) {}
            })
        #expect(!engine.isContainingFocus, "a dismissed alert must release containment")
    }

    @Test("enter fires the default action")
    func enterFiresDefaultAction() {
        let flag = Box(true)
        let confirmed = Box(false)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, Text("bg").focusable()
            .alert("Save?", isPresented: flag.binding) {
                AlertAction("Save") { confirmed.value = true }
                AlertAction("Cancel", role: .cancel) {}
            })

        // Return is consumed by the focused Button itself — initial focus
        // lands on the `.default` action, so activation follows from focus
        // rather than from a separate key binding.
        #expect(engine.keyboardFocusID != nil, "an action must hold focus while presented")
        #expect(engine.routeKeyEvent(KeyEvent(key: .enter), root: graph.root!))
        #expect(confirmed.value, "Return must fire the .default action")
        #expect(!flag.value, "firing an action must dismiss the alert")
    }

    @Test("dismissing restores focus to the view that presented the alert")
    func dismissRestoresPreviousFocus() {
        let flag = Box(true)
        let graph = AttributeGraph()
        let build = {
            Text("trigger").focusable()
                .alert("Delete file?", isPresented: flag.binding) {
                    AlertAction("Cancel", role: .cancel) {}
                }
        }
        graph.update(from: build())
        render(graph)

        let engine = FocusEngine()
        engine.rebuildIndex(root: graph.root!)
        let whilePresented = engine.keyboardFocusID
        #expect(whilePresented != nil)

        flag.value = false
        graph.update(from: build())
        render(graph)
        engine.rebuildIndex(root: graph.root!)

        let afterDismiss = engine.keyboardFocusID
        #expect(afterDismiss != whilePresented,
                "focus must leave the dismissed alert's content")
        let survivors = focusables(engine, graph.root!)
        #expect(survivors.allSatisfy { $0.containmentDepth == 0 },
                "no contained focusables should remain after dismissal")
    }
}

// MARK: - Focus policy

@Suite("Alert — initial focus and traversal")
@MainActor
struct AlertFocusTests {

    @Test("the default action is initially focused")
    func defaultActionInitiallyFocused() {
        let flag = Box(true)
        let fired = Box<String?>(nil)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        // Declaration order puts Cancel first; the .default action must still
        // be the one Return reaches.
        buildWithEngine(engine, graph, Text("bg").focusable()
            .alert("Save?", isPresented: flag.binding) {
                AlertAction("Cancel", role: .cancel) { fired.value = "Cancel" }
                AlertAction("Save") { fired.value = "Save" }
            })

        _ = engine.routeKeyEvent(KeyEvent(key: .enter), root: graph.root!)
        #expect(fired.value == "Save",
                "initial focus must land on the .default action, not declaration order")
    }

    @Test("a destructive action is never initially focused")
    func destructiveActionNotInitiallyFocused() {
        let flag = Box(true)
        let fired = Box<String?>(nil)
        let engine = FocusEngine()
        let graph = AttributeGraph()
        buildWithEngine(engine, graph, Text("bg").focusable()
            .alert("Delete file?", isPresented: flag.binding) {
                AlertAction("Delete", role: .destructive) { fired.value = "Delete" }
                AlertAction("Cancel", role: .cancel) { fired.value = "Cancel" }
            })

        _ = engine.routeKeyEvent(KeyEvent(key: .enter), root: graph.root!)
        #expect(fired.value != "Delete",
                "a .destructive action must never take initial focus")
    }

    @Test("tab cycles between actions and stays inside the alert")
    func tabCyclesBetweenActionsWithinAlert() {
        let flag = Box(true)
        let graph = AttributeGraph()
        graph.update(from: VStack {
            Text("bg1").focusable()
            Text("bg2").focusable()
        }.alert("Delete file?", isPresented: flag.binding) {
            AlertAction("Delete", role: .destructive) {}
            AlertAction("Cancel", role: .cancel) {}
        })
        render(graph)

        let engine = FocusEngine()
        engine.rebuildIndex(root: graph.root!)

        var visited: Set<NodeID> = []
        for _ in 0..<6 {
            if let id = engine.keyboardFocusID { visited.insert(id) }
            engine.focusNext()
        }
        let contained = Set(
            focusables(engine, graph.root!)
                .filter { $0.containmentDepth > 0 }
                .map(\.id)
        )
        #expect(visited.count == 2, "Tab must cycle only the two alert actions; visited \(visited.count)")
        #expect(visited.isSubset(of: contained), "Tab escaped the alert's containment")
    }
}

// MARK: - Programmer-error warnings

#if DEBUG

/// Counts framework warnings by code. Mirrors the probe in
/// DebugStreamWarningTests — sinks are not `@MainActor` because
/// DebugStream is `@unchecked Sendable`.
private final class AlertWarningProbe: DebugSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _counts: [FrameworkWarningCode: Int] = [:]

    func receive(_ event: DebugEvent) {
        guard case .frameworkWarning(let info) = event else { return }
        lock.lock()
        _counts[info.code, default: 0] += 1
        lock.unlock()
    }

    func count(of code: FrameworkWarningCode) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return _counts[code, default: 0]
    }
}

@MainActor
private func withProbe(_ body: (AlertWarningProbe) -> Void) {
    let probe = AlertWarningProbe()
    DebugStream.shared.addSink(probe)
    DebugStream.shared.unsuppressAllWarnings()
    DebugStream.shared.resetWarningDedup()
    defer {
        DebugStream.shared.removeAllSinks()
        DebugStream.shared.unsuppressAllWarnings()
        DebugStream.shared.resetWarningDedup()
    }
    body(probe)
}

// Framework convention is runtime warnings over phantom types: the
// composition is legal Swift and only wrong at runtime, so the compiler
// has nothing to reject without contorting the call-site API.
@Suite("Alert — programmer-error warnings", .serialized)
@MainActor
struct AlertWarningTests {

    @Test("declaring more than one default action warns")
    func multipleDefaultActionsEmitsWarning() {
        withProbe { probe in
            let flag = Box(true)
            let graph = AttributeGraph()
            graph.update(from: Text("bg").focusable()
                .alert("Pick one", isPresented: flag.binding) {
                    AlertAction("First") {}
                    AlertAction("Second") {}
                })
            render(graph)
            #expect(probe.count(of: .alertMultipleDefaultActions) >= 1)
        }
    }

    @Test("an alert with no actions warns and renders a dismiss button")
    func zeroActionsRendersFallbackDismissButton() {
        withProbe { probe in
            let flag = Box(true)
            let graph = AttributeGraph()
            graph.update(from: Text("bg").focusable()
                .alert("Something happened", isPresented: flag.binding) {})

            let text = renderedText(render(graph))
            #expect(probe.count(of: .alertHasNoActions) >= 1)
            #expect(text.contains("OK"),
                    "a zero-action alert must still render a way out")
        }
    }
}

#endif

// MARK: - Test support

/// Minimal reference cell so tests can hand a `Binding` to the view under
/// test and then observe writes. `@TerminalState` is unavailable outside a
/// graph node, which is exactly the situation these tests construct.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) { _value = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }

    var binding: Binding<Value> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }
}
