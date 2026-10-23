import Testing
@testable import TerminalUI

// Modality per Apple HIG: a modal presentation "prevents interaction with
// the parent view and requires an explicit action to dismiss". Keyboard
// containment is the terminal expression of that rule — Tab must not walk
// out of a presented modal into the content it dims.
//
// Distinct from `.focusScope(id)`, which GROUPS focusables so arrows stay
// local while Tab deliberately crosses scopes (SwiftUI's FocusScope
// convention). Grouping and containment are separate concepts and compose.

@MainActor
private func focusables(_ engine: FocusEngine, _ root: AttributeNode) -> [AttributeNode] {
    engine.collectFocusables(root)
}

@Suite("Focus containment — graph stamping")
@MainActor
struct FocusContainmentStampingTests {

    @Test("presented modal stamps containment depth on its content focusables")
    func stampsWhenPresented() {
        let graph = AttributeGraph()
        graph.update(from: VStack {
            Text("bg").focusable()
        }.modal(isPresented: true) {
            Text("ok").focusable()
        })

        let engine = FocusEngine()
        let all = focusables(engine, graph.root!)
        #expect(all.count == 2)
        #expect(all.filter { $0.containmentDepth > 0 }.count == 1)
    }

    @Test("dismissed modal stamps nothing")
    func noStampWhenDismissed() {
        let graph = AttributeGraph()
        graph.update(from: VStack {
            Text("bg").focusable()
        }.modal(isPresented: false) {
            Text("ok").focusable()
        })

        let engine = FocusEngine()
        #expect(focusables(engine, graph.root!).allSatisfy { $0.containmentDepth == 0 })
    }

    @Test("containment and focusScope compose — a scope inside a modal keeps both")
    func composesWithScope() {
        let graph = AttributeGraph()
        graph.update(from: Text("bg").focusable()
            .modal(isPresented: true) {
                HStack {
                    Text("a").focusable()
                    Text("b").focusable()
                }.focusScope("row")
            })

        let engine = FocusEngine()
        let scoped = focusables(engine, graph.root!).filter { $0.scopeID == "row" }
        #expect(scoped.count == 2)
        #expect(scoped.allSatisfy { $0.containmentDepth > 0 })
    }
}

@Suite("Focus containment — Tab traversal")
@MainActor
struct FocusContainmentTraversalTests {

    /// VStack { bg1, bg2 }.modal(presented) { ok, cancel }
    /// Returns (engine, background ids, modal ids).
    private func presentedModal() -> (FocusEngine, [NodeID], [NodeID]) {
        let graph = AttributeGraph()
        graph.update(from: VStack {
            Text("bg1").focusable()
            Text("bg2").focusable()
        }.modal(isPresented: true) {
            VStack {
                Text("ok").focusable()
                Text("cancel").focusable()
            }
        })
        let engine = FocusEngine()
        engine.rebuildIndex(root: graph.root!)
        let all = focusables(engine, graph.root!)
        let contained = all.filter { $0.containmentDepth > 0 }.map { $0.id }
        let background = all.filter { $0.containmentDepth == 0 }.map { $0.id }
        return (engine, background, contained)
    }

    @Test("tab within an active containment wraps inside it")
    func tabWrapsInsideContainment() {
        let (engine, _, modal) = presentedModal()
        engine.keyboardFocusID = modal[0]
        engine.focusNext()
        #expect(engine.keyboardFocusID == modal[1])
        engine.focusNext()
        #expect(engine.keyboardFocusID == modal[0], "must wrap to first contained node")
    }

    @Test("shift-tab within an active containment wraps backward inside it")
    func shiftTabWrapsInsideContainment() {
        let (engine, _, modal) = presentedModal()
        engine.keyboardFocusID = modal[0]
        engine.focusPrevious()
        #expect(engine.keyboardFocusID == modal[1], "must wrap to last contained node")
        engine.focusPrevious()
        #expect(engine.keyboardFocusID == modal[0])
    }

    @Test("background nodes are unreachable while a containment is active")
    func backgroundUnreachable() {
        let (engine, background, modal) = presentedModal()
        engine.keyboardFocusID = modal[0]
        for _ in 0..<12 {
            engine.focusNext()
            #expect(!background.contains(engine.keyboardFocusID!), "Tab escaped into the dimmed background")
        }
    }

    @Test("focus starting outside an active containment is pulled into it")
    func focusPulledIntoContainment() {
        let (engine, background, modal) = presentedModal()
        engine.keyboardFocusID = background[0]
        engine.focusNext()
        #expect(modal.contains(engine.keyboardFocusID!), "presenting must capture focus")
    }

    @Test("no containment leaves global Tab order intact")
    func noContainmentGlobalOrder() {
        let graph = AttributeGraph()
        graph.update(from: VStack {
            Text("a").focusable()
            Text("b").focusable()
            Text("c").focusable()
        })
        let engine = FocusEngine()
        engine.rebuildIndex(root: graph.root!)
        let all = focusables(engine, graph.root!)
        engine.keyboardFocusID = all[0].id
        engine.focusNext()
        #expect(engine.keyboardFocusID == all[1].id)
        engine.focusNext()
        #expect(engine.keyboardFocusID == all[2].id)
        engine.focusNext()
        #expect(engine.keyboardFocusID == all[0].id, "global order still wraps")
    }

    // Earlier behaviour let Tab fall back to the covered base so an empty
    // dialog could not "freeze" Tab — but that reaches controls the user
    // cannot see, and it left `isContainingFocus` false, so the Esc quit
    // default fired under a presented screen. Modality "prevents interaction
    // with the parent view" (Apple HIG, Patterns → Modality): the
    // presentation owns the keyboard even when nothing inside it is
    // focusable. The user is never stranded — keys route to the presented
    // subtree's own handlers, and Ctrl+C stays unconditional.
    @Test("a presentation with no focusables owns the keyboard, not the base")
    func emptyContainmentOwnsKeyboard() {
        let graph = AttributeGraph()
        graph.update(from: VStack {
            Text("a").focusable()
            Text("b").focusable()
        }.modal(isPresented: true) {
            Text("no focusables here")
        })
        let engine = FocusEngine()
        engine.rebuildIndex(root: graph.root!)
        let all = focusables(engine, graph.root!)

        #expect(engine.isContainingFocus, "presented is a tree fact, not a focusables fact")
        #expect(engine.keyboardFocusID != nil, "adoption moves focus into the presentation")
        #expect(!all.contains { $0.id == engine.keyboardFocusID })

        engine.focusNext()
        #expect(
            !all.contains { $0.id == engine.keyboardFocusID },
            "Tab must not reach controls under the modal"
        )
    }

    @Test("disabled nodes inside a containment are still skipped")
    func disabledSkippedInsideContainment() {
        let graph = AttributeGraph()
        graph.update(from: Text("bg").focusable()
            .modal(isPresented: true) {
                VStack {
                    Text("ok").focusable()
                    Text("nope").focusable().disabled(true)
                    Text("cancel").focusable()
                }
            })

        // `.disabled()` resolves into `_resolvedEnv` during render, and
        // `rebuildIndex` reads it from there — so the containment filter has
        // to be exercised after a render pass, not straight off update().
        var buffer = CellBuffer(width: 40, height: 10)
        GraphRenderer.render(
            graph.root!,
            into: &buffer,
            context: RenderContext(rect: Rect(x: 0, y: 0, width: 40, height: 10))
        )

        let engine = FocusEngine()
        engine.rebuildIndex(root: graph.root!)

        let reachable = engine.collectFocusables(graph.root!)
            .filter { $0.containmentDepth > 0 && ($0._resolvedEnv?.isEnabled ?? true) }
        #expect(reachable.count == 2, "disabled node must stay out of the Tab cycle")
    }
}

// Presenting and dismissing are the moments containment starts and ends.
// The runtime's auto-focus only fires when nothing is focused at all, so
// without adoption a dialog would appear un-focused and the user would have
// to press Tab before it responded. Found by driving the live Demo app —
// the graph-level traversal tests all passed while this was broken.
@Suite("Focus containment — adoption on present/dismiss")
@MainActor
struct FocusContainmentAdoptionTests {

    @Test("presenting pulls focus into the dialog")
    func presentingAdoptsFocus() {
        let graph = AttributeGraph()
        let engine = FocusEngine()

        graph.update(from: VStack {
            Text("bg1").focusable()
            Text("bg2").focusable()
        }.modal(isPresented: false) {
            Text("ok").focusable()
        })
        engine.rebuildIndex(root: graph.root!)
        engine.focusNext()
        let background = engine.keyboardFocusID
        #expect(background != nil)

        graph.update(from: VStack {
            Text("bg1").focusable()
            Text("bg2").focusable()
        }.modal(isPresented: true) {
            Text("ok").focusable()
        })
        engine.rebuildIndex(root: graph.root!)

        let contained = engine.collectFocusables(graph.root!)
            .filter { $0.containmentDepth > 0 }
            .map { $0.id }
        #expect(contained.contains(engine.keyboardFocusID!),
                "presenting must move focus into the dialog")
    }

    @Test("dismissing restores focus to the node the dialog interrupted")
    func dismissRestoresPreviousFocus() {
        let graph = AttributeGraph()
        let engine = FocusEngine()

        func build(_ presented: Bool) -> some TerminalView {
            VStack {
                Text("bg1").focusable()
                Text("bg2").focusable()
            }.modal(isPresented: presented) {
                Text("ok").focusable()
            }
        }

        graph.update(from: build(false))
        engine.rebuildIndex(root: graph.root!)
        // Park focus on the SECOND background node, not the first, so
        // restoring to "the previous node" is distinguishable from
        // restoring to "the top of the page".
        let all = engine.collectFocusables(graph.root!).map { $0.id }
        engine.keyboardFocusID = all[1]
        let parked = engine.keyboardFocusID

        graph.update(from: build(true))
        engine.rebuildIndex(root: graph.root!)
        #expect(engine.keyboardFocusID != parked, "dialog should hold focus")

        graph.update(from: build(false))
        engine.rebuildIndex(root: graph.root!)
        #expect(engine.keyboardFocusID == parked,
                "dismissal must restore the interrupted node, not jump to the first")
    }
}

@Suite("Focus containment — nesting")
@MainActor
struct FocusContainmentNestingTests {

    @Test("innermost containment wins when modals nest")
    func innermostWins() {
        let graph = AttributeGraph()
        graph.update(from: Text("bg").focusable()
            .modal(isPresented: true) {
                Text("outer").focusable()
                    .modal(isPresented: true) {
                        Text("inner").focusable()
                    }
            })
        let engine = FocusEngine()
        engine.rebuildIndex(root: graph.root!)

        let all = focusables(engine, graph.root!)
        let outer = all.first { $0.containmentDepth > 0 && $0.containmentDepth == 1 }
        let inner = all.first { $0.containmentDepth == 2 }
        #expect(outer != nil)
        #expect(inner != nil)

        // Tab anywhere must land on the innermost modal's single focusable.
        engine.keyboardFocusID = all[0].id
        engine.focusNext()
        #expect(engine.keyboardFocusID == inner!.id, "the topmost containment owns focus")
        engine.focusNext()
        #expect(engine.keyboardFocusID == inner!.id, "single contained node re-selects itself")
    }

    @Test("dismissing the inner modal returns traversal to the outer one")
    func poppingRestoresOuter() {
        // Inner dismissed → outer becomes topmost.
        let graph = AttributeGraph()
        graph.update(from: Text("bg").focusable()
            .modal(isPresented: true) {
                VStack {
                    Text("outerA").focusable()
                    Text("outerB").focusable()
                }
                .modal(isPresented: false) {
                    Text("inner").focusable()
                }
            })
        let engine = FocusEngine()
        engine.rebuildIndex(root: graph.root!)

        let all = focusables(engine, graph.root!)
        let outerIDs = all.filter { $0.containmentDepth == 1 }.map { $0.id }
        #expect(outerIDs.count == 2)

        engine.keyboardFocusID = outerIDs[0]
        engine.focusNext()
        #expect(engine.keyboardFocusID == outerIDs[1])
        engine.focusNext()
        #expect(engine.keyboardFocusID == outerIDs[0], "traversal confined to the outer modal")
    }
}

@Suite("Focus containment — mouse")
@MainActor
struct FocusContainmentMouseTests {

    @Test("click outside an active containment does not steal focus")
    func clickOutsideDoesNotStealFocus() {
        let graph = AttributeGraph()
        graph.update(from: VStack {
            Text("bg1").focusable()
            Text("bg2").focusable()
        }.modal(isPresented: true) {
            Text("ok").focusable()
        })
        let root = graph.root!
        let engine = FocusEngine()
        let all = focusables(engine, root)
        let modalNode = all.first { $0.containmentDepth > 0 }!
        let backgroundNode = all.first { $0.containmentDepth == 0 }!

        // Disjoint rects — the click lands squarely on the background node.
        backgroundNode.rect = Rect(x: 0, y: 0, width: 5, height: 1)
        modalNode.rect = Rect(x: 0, y: 5, width: 5, height: 1)
        engine.rebuildIndex(root: root)

        engine.keyboardFocusID = modalNode.id
        let r = backgroundNode.rect
        engine.handleMouseClick(x: r.x, y: r.y, root: root)
        #expect(engine.keyboardFocusID == modalNode.id, "clicking the dimmed background must not move focus")
    }
}

// A modal that does not fit is clipped by `min(mh, buffer.height - 2)` in
// the renderer. Silent truncation is dangerous rather than merely ugly:
// controls scrolled out of view stay focusable, so Tab reaches buttons the
// user cannot see. Terminal size is a runtime value — the same dialog fits
// one window and not another — so this cannot be a compile-time error, and
// the framework's runtime-warning channel is the correct reporting path.

private final class ContainmentWarningSink: DebugSink, @unchecked Sendable {
    nonisolated(unsafe) var events: [DebugEvent] = []
    func receive(_ event: DebugEvent) {
        events.append(event)
    }
}

@Suite("Focus containment — oversized modal reporting")
@MainActor
struct ModalDoesNotFitWarningTests {

    private func emittedWarnings(_ sink: ContainmentWarningSink) -> [FrameworkWarningInfo] {
        sink.events.compactMap { event in
            if case .frameworkWarning(let info) = event { return info }
            return nil
        }
    }

    @Test("a modal taller than the terminal reports .modalDoesNotFit")
    func oversizedModalWarns() {
        DebugStream.shared.resetWarningDedup()
        DebugStream.shared.removeAllSinks()
        let sink = ContainmentWarningSink()
        DebugStream.shared.addSink(sink)
        defer {
            DebugStream.shared.removeAllSinks()
            DebugStream.shared.resetWarningDedup()
        }

        let graph = AttributeGraph()
        graph.update(from: Text("bg").focusable()
            .modal(isPresented: true) {
                Text(Array(repeating: "row", count: 40).joined(separator: "\n"))
            })

        var buffer = CellBuffer(width: 20, height: 6)
        GraphRenderer.render(
            graph.root!,
            into: &buffer,
            context: RenderContext(rect: Rect(x: 0, y: 0, width: 20, height: 6))
        )

        let codes = emittedWarnings(sink).map { $0.code }
        #expect(codes.contains(.modalDoesNotFit),
                "a 40-row dialog in a 6-row terminal must report the clip; got \(codes)")
    }

    @Test("a modal that fits reports nothing")
    func fittingModalStaysQuiet() {
        DebugStream.shared.resetWarningDedup()
        DebugStream.shared.removeAllSinks()
        let sink = ContainmentWarningSink()
        DebugStream.shared.addSink(sink)
        defer {
            DebugStream.shared.removeAllSinks()
            DebugStream.shared.resetWarningDedup()
        }

        let graph = AttributeGraph()
        graph.update(from: Text("bg").focusable()
            .modal(isPresented: true) {
                Text("ok")
            })

        var buffer = CellBuffer(width: 40, height: 20)
        GraphRenderer.render(
            graph.root!,
            into: &buffer,
            context: RenderContext(rect: Rect(x: 0, y: 0, width: 40, height: 20))
        )

        let codes = emittedWarnings(sink).map { $0.code }
        #expect(!codes.contains(.modalDoesNotFit),
                "a dialog with room to render must not warn; got \(codes)")
    }
}

// A modal must OCCLUDE what it covers. "Prevents interaction with the parent
// view" (Apple HIG, Patterns → Modality) has a visual half: background text
// showing through the dialog's padding and between its glyphs makes the panel
// unreadable and makes it ambiguous which control a row belongs to.
//
// `.transparent` compositing skips empty cells, so a dialog's spaces let the
// content behind bleed through — correct for `.overlay` decoration, wrong for
// a presentation that must cover.

@Suite("Modal rendering — the panel occludes its background")
@MainActor
struct ModalOcclusionTests {

    /// Render a full-screen background of 'X', then the same tree with a
    /// presented modal over it, and return the row the dialog's body lands on.
    /// The dialog carries padding — that interior whitespace is where a
    /// `.transparent` layer lets the background through.
    private func rowUnderModal(width: Int, height: Int) -> String {
        let graph = AttributeGraph()
        let background = Array(repeating: String(repeating: "X", count: width),
                               count: height).joined(separator: "\n")
        graph.update(from: Text(background)
            .modal(isPresented: true) {
                Text("ok").padding()
            })
        var buffer = CellBuffer(width: width, height: height)
        GraphRenderer.render(
            graph.root!,
            into: &buffer,
            context: RenderContext(rect: Rect(x: 0, y: 0, width: width, height: height))
        )
        let midY = height / 2
        var row = ""
        for x in 0..<width {
            row.append(buffer[x, midY].character)
        }
        return row
    }

    @Test("background does not bleed through the dialog's padding")
    func backgroundDoesNotBleedThrough() {
        let row = rowUnderModal(width: 24, height: 9)
        #expect(row.contains("ok"), "dialog content must be drawn; got \(row.debugDescription)")
        guard let r = row.range(of: "ok") else { return }
        let idx = row.distance(from: row.startIndex, to: r.lowerBound)
        // The padded cells flanking "ok" belong to the dialog and must not
        // show the background beneath.
        let left = row[row.index(row.startIndex, offsetBy: max(0, idx - 1))]
        let rightIdx = min(24 - 1, idx + 2)
        let right = row[row.index(row.startIndex, offsetBy: rightIdx)]
        #expect(left != "X" && right != "X",
                "background bled into the dialog's padding: \(row.debugDescription)")
    }
}

// A modal is a screen-level presentation: it dims everything and centres on
// the terminal. `ScrollView` renders its content into a local buffer that is
// blitted into the viewport, so a modal declared inside one used to centre on
// that sub-buffer and get clipped by the blit — the dialog landed inside the
// scrolled pane instead of over the app, with its lower rows cut off while
// still focusable.

@Suite("Modal presentation is screen-level, not subtree-level")
@MainActor
struct ModalPresentationScopeTests {

    private func screen(width: Int, height: Int, _ view: some TerminalView) -> [String] {
        let buffer = renderedBuffer(view, width: width, height: height)
        return (0..<height).map { y in
            var row = ""
            for x in 0..<width { row.append(buffer[x, y].character) }
            return row
        }
    }

    @Test("a modal declared inside a ScrollView still centres on the screen")
    func modalInsideScrollViewReachesScreen() {
        let rows = screen(width: 40, height: 20,
            ScrollView(.vertical) {
                VStack {
                    Text("row a")
                    Text("row b")
                }
                .modal(isPresented: true) {
                    Text("DIALOG")
                }
            }
            .frame(height: 4)
        )

        let hit = rows.enumerated().first { $0.element.contains("DIALOG") }
        #expect(hit != nil, "dialog must be drawn: \(rows.joined(separator: "|"))")
        guard let hit else { return }
        // Centred on a 20-row screen, not trapped in the 4-row scroll pane.
        #expect(hit.offset > 4,
                "dialog landed at row \(hit.offset), inside the scroll viewport rather than centred on screen")
    }

    @Test("a modal's full content survives — no rows lost to a sub-buffer clip")
    func modalContentNotClippedBySubBuffer() {
        let rows = screen(width: 40, height: 20,
            ScrollView(.vertical) {
                Text("bg")
                    .modal(isPresented: true) {
                        VStack {
                            Text("Delete this file?")
                            Text("[ Cancel ]")
                            Text("[ Delete ]")
                        }
                    }
            }
            .frame(height: 3)
        )
        let joined = rows.joined(separator: "\n")
        #expect(joined.contains("Delete this file?"), "title missing:\n\(joined)")
        #expect(joined.contains("[ Cancel ]"), "Cancel missing:\n\(joined)")
        #expect(joined.contains("[ Delete ]"),
                "Delete was clipped away while remaining focusable:\n\(joined)")
    }
}


// The `.overlay` focus indicator draws at `rect.x - 1` — deliberately OUTSIDE
// the focused view, where a parent's padding usually sits. Inside a modal that
// cell is the dialog's own border, so the bar punches a hole in the frame.
// `.overlay` already declines to draw inside scroll viewports for the same
// reason; a presented modal is the same kind of bounded region.

@Suite("Focus indicator respects a modal's frame")
@MainActor
struct ModalFocusIndicatorTests {

    @Test("indicator stays inside the dialog instead of overwriting its border")
    func indicatorDoesNotPunchBorder() {
        let graph = AttributeGraph()
        graph.update(from: Text("background").focusable()
            .modal(isPresented: true) {
                VStack {
                    Text("Delete this file?")
                    Text("[ Cancel ]").focusable()
                }
                .border()
            })

        let width = 40, height = 12
        var buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))

        let engine = FocusEngine()
        engine.rebuildIndex(root: graph.root!)
        // Focus the contained control, as presenting would.
        let contained = engine.collectFocusables(graph.root!).filter { $0.containmentDepth > 0 }
        #expect(!contained.isEmpty, "modal must contain a focusable")
        engine.keyboardFocusID = contained.first?.id
        GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: engine, root: graph.root!)

        let target = contained.first!.rect
        // The cell left of the focused control belongs to the dialog frame.
        guard target.x - 1 >= 0, target.y < height else { return }
        let leftOfControl = buffer[target.x - 1, target.y].character
        #expect(leftOfControl != "▎",
                "indicator overwrote the dialog's border cell at x=\(target.x - 1)")
    }

    @Test("a focused Button inside a modal keeps its opening bracket")
    func indicatorDoesNotEatButtonBracket() {
        // The complement of the border case: when the cell left of the
        // control is interior padding rather than the frame, the indicator
        // belongs there. Drawing inside the rect instead would land on
        // `Button`'s own `[`, rendering the focused action as `▎ Cancel ]`
        // — which affected every Button placed in any modal, not just alerts.
        let graph = AttributeGraph()
        graph.update(from: Text("background").focusable()
            .modal(isPresented: true) {
                VStack {
                    Text("Delete this file?")
                    Button("Cancel") {}
                }
                .padding()
                .border()
            })

        let width = 40, height = 12
        var buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        Layout.measureAndPlace(graph: graph.root!, in: rect)
        GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))

        let engine = FocusEngine()
        engine.rebuildIndex(root: graph.root!)
        let contained = engine.collectFocusables(graph.root!).filter { $0.containmentDepth > 0 }
        #expect(!contained.isEmpty, "modal must contain a focusable")
        engine.keyboardFocusID = contained.first?.id
        GraphRenderer.renderFocusIndicators(into: &buffer, focusEngine: engine, root: graph.root!)

        let target = contained.first!.rect
        guard target.y < height, target.x < width else { return }
        #expect(buffer[target.x, target.y].character == "[",
                "indicator overwrote the Button's opening bracket")
    }
}
