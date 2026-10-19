import Testing
@testable import TerminalUI

// A DiffView embedded in something larger — a transcript card, a list row —
// has to behave like content, not like a control: it must not take focus it
// has no use for, and it must wear the surrounding theme rather than a fixed
// green and red.

@MainActor
@Suite struct DiffViewEmbeddingTests {

    /// Roles set to values no literal in the codebase would produce, so a cell
    /// wearing one can only have come from the theme.
    private struct LoudTheme: Theme {
        var foreground: Color = .rgb(10, 20, 30)
        var foregroundEmphasis: Color = .rgb(11, 21, 31)
        var foregroundMuted: Color = .rgb(12, 22, 32)
        var separator: Color = .rgb(15, 25, 35)
        var success: Color = .rgb(40, 50, 60)
        var error: Color = .rgb(41, 51, 61)
    }

    private let edit = DiffEngine.diff(original: "keep\nold", modified: "keep\nnew")

    // MARK: - Focus

    private func focusAfterTab(_ view: DiffView) -> NodeID? {
        let graph = AttributeGraph()
        let engine = FocusEngine()
        GraphContext.$currentFocusEngine.withValue(engine) {
            GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
                graph.update(from: view)
            }
        }
        engine.rebuildIndex(root: graph.root!)
        engine.focusNext()
        return engine.keyboardFocusID
    }

    /// The transcript case: every row is already on screen, so there is
    /// nothing for arrows to do — taking focus would only steal them.
    @Test func aDiffThatFitsItsViewportTakesNoFocus() {
        #expect(focusAfterTab(DiffView(lines: edit, visibleHeight: edit.count)) == nil)
    }

    @Test func aDiffWithRowsBelowTheViewportIsFocusable() {
        #expect(focusAfterTab(DiffView(lines: edit, visibleHeight: edit.count - 1)) != nil)
    }

    /// Side-by-side pairs a removal with the addition after it, so the same
    /// lines occupy fewer rows. The threshold must count rows, not lines.
    @Test func sideBySideCountsPairedRowsNotLines() {
        // keep / old→new: three lines, two paired rows.
        #expect(focusAfterTab(DiffView(lines: edit, mode: .sideBySide, visibleHeight: 2)) == nil)
        #expect(focusAfterTab(DiffView(lines: edit, mode: .sideBySide, visibleHeight: 1)) != nil)
    }

    // MARK: - Theme

    private func render(_ view: DiffView, width: Int, height: Int) -> CellBuffer {
        let graph = AttributeGraph()
        var buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        var env = EnvironmentValues()
        env.theme = LoudTheme()
        env.terminalSize = TerminalSize(cols: width, rows: height)
        GraphContext.$currentEnvironment.withValue(env) {
            GraphContext.$currentProposedSize.withValue(Size(width: width, height: height)) {
                graph.update(from: view)
                Layout.measureAndPlace(graph: graph.root!, in: rect)
                GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
            }
        }
        return buffer
    }

    /// Foreground of the first cell on row `y` showing `character`.
    private func foreground(of character: Character, onRow y: Int, in buffer: CellBuffer) -> Color? {
        for x in 0..<buffer.width where buffer[x, y].character == character {
            return buffer[x, y].style.foreground
        }
        return nil
    }

    @Test func unifiedLinesWearTheThemeRoles() {
        let buffer = render(DiffView(lines: edit), width: 20, height: 3)
        let theme = LoudTheme()
        #expect(foreground(of: "1", onRow: 0, in: buffer) == theme.foregroundMuted)
        #expect(foreground(of: "k", onRow: 0, in: buffer) == theme.foreground)
        #expect(foreground(of: "-", onRow: 1, in: buffer) == theme.error)
        #expect(foreground(of: "+", onRow: 2, in: buffer) == theme.success)
    }

    @Test func sideBySideDividerAndHeaderWearTheThemeRoles() {
        let buffer = render(DiffView(lines: edit, mode: .sideBySide).diffHeader("f.swift"),
                            width: 30, height: 4)
        let theme = LoudTheme()
        #expect(foreground(of: "a", onRow: 0, in: buffer) == theme.foregroundMuted)
        #expect(foreground(of: "f", onRow: 0, in: buffer) == theme.foregroundEmphasis)
        #expect(foreground(of: "\u{2502}", onRow: 2, in: buffer) == theme.separator)
    }
}
