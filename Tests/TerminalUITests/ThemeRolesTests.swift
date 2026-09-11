import Testing
@testable import TerminalUI

// A theme is only worth having if swapping it restyles the components without
// touching their call sites. Before this, `Theme` carried six roles and
// exactly one view read any of them — the rest drew `.gray` and `.cyan`
// literals, so a custom theme changed nothing.
//
// Two things are pinned here. First, that the roles actually reach the
// components: each test swaps in a theme with deliberately absurd colors and
// asserts the rendered cells carry them. Second, that the ramps degrade
// coherently — a theme that states one step must not strand the steps below it
// on colors from a palette it never opted into.

@MainActor
@Suite struct ThemeRolesTests {

    /// Every role set to something no default would produce, so a cell wearing
    /// one of these colors can only have come from the theme.
    private struct LoudTheme: Theme {
        var accent: Color = .rgb(1, 2, 3)
        var foreground: Color = .rgb(10, 20, 30)
        var foregroundEmphasis: Color = .rgb(11, 21, 31)
        var foregroundMuted: Color = .rgb(12, 22, 32)
        var warning: Color = .rgb(13, 23, 33)
        var error: Color = .rgb(14, 24, 34)
        var destructive: Color = .rgb(15, 25, 35)
        var backgroundSelected: Color = .rgb(16, 26, 36)
    }

    private func render(
        _ view: some TerminalView,
        width: Int,
        height: Int,
        theme: any Theme = LoudTheme()
    ) -> CellBuffer {
        let graph = AttributeGraph()
        var buffer = CellBuffer(width: width, height: height)
        let rect = Rect(x: 0, y: 0, width: width, height: height)
        var env = EnvironmentValues()
        env.theme = theme
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

    /// Colors present anywhere in the buffer — components place their glyphs
    /// differently, and the assertion that matters is "the theme's color was
    /// used", not "at column 4".
    private func colors(_ buffer: CellBuffer) -> [Color] {
        var found: [Color] = []
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                if let fg = buffer[x, y].style.foreground, !found.contains(fg) { found.append(fg) }
                if let bg = buffer[x, y].style.background, !found.contains(bg) { found.append(bg) }
            }
        }
        return found
    }

    // MARK: - Roles reach the components

    @Test func buttonUsesTheThemeForeground() {
        let buffer = render(Button("Save") {}, width: 12, height: 1)
        #expect(colors(buffer).contains(LoudTheme().foreground))
    }

    @Test func disabledControlUsesTheMutedRole() {
        let buffer = render(Button("Save") {}.disabled(), width: 12, height: 1)
        #expect(colors(buffer).contains(LoudTheme().foregroundMuted))
    }

    @Test func toggleUsesTheThemeForeground() {
        var flag = false
        let binding = Binding<Bool>(get: { flag }, set: { flag = $0 })
        let buffer = render(Toggle("Wi-Fi", isOn: binding), width: 20, height: 1)
        #expect(colors(buffer).contains(LoudTheme().foreground))
    }

    /// The list's selection cursor is the accent and its selected row the
    /// emphasis step — the two roles that make a selection read as selected.
    @Test func listSelectionUsesAccentAndEmphasis() {
        struct Row: Identifiable { let id: Int; let name: String }
        let rows = [Row(id: 1, name: "alpha"), Row(id: 2, name: "beta")]
        var selection: Int? = 1
        let binding = Binding<Int?>(get: { selection }, set: { selection = $0 })
        let buffer = render(
            List(rows, selection: binding) { Text($0.name) },
            width: 20, height: 4)
        let used = colors(buffer)
        #expect(used.contains(LoudTheme().accent))
        #expect(used.contains(LoudTheme().foregroundEmphasis))
    }

    @Test func listOverflowHintUsesTheMutedRole() {
        struct Row: Identifiable { let id: Int; let name: String }
        let rows = (0..<30).map { Row(id: $0, name: "row \($0)") }
        var selection: Int? = 0
        let binding = Binding<Int?>(get: { selection }, set: { selection = $0 })
        let buffer = render(
            List(rows, selection: binding) { Text($0.name) }.frame(height: 4),
            width: 20, height: 4)
        #expect(colors(buffer).contains(LoudTheme().foregroundMuted))
    }

    @Test func textInputValidationUsesTheStatusRoles() {
        var value = "nope"
        let binding = Binding<String>(get: { value }, set: { value = $0 })
        let buffer = render(
            TextInput("Email", text: binding,
                      validate: { _ in TextInputValidation(.error, "missing @") }),
            width: 30, height: 3)
        #expect(colors(buffer).contains(LoudTheme().error))
    }

    // MARK: - The default theme changes nothing

    /// The whole wiring is a refactor under the stock theme: the roles were
    /// chosen to reproduce the literals the components used to draw. If this
    /// fails, adopting the theme silently restyled every existing app.
    @Test func defaultThemeReproducesTheOriginalLiterals() {
        let theme = DefaultTheme()
        #expect(theme.foreground == .default)
        #expect(theme.foregroundMuted == .gray)
        #expect(theme.foregroundEmphasis == .white)
        #expect(theme.accent == .cyan)
        #expect(theme.warning == .yellow)
        #expect(theme.error == .red)
        #expect(theme.destructive == .red)
        #expect(theme.backgroundSelected == .blue)
    }

    // MARK: - Ramps degrade coherently

    /// A theme stating one step of a ramp must drag the quieter steps with it,
    /// not leave them on a default palette it never opted into.
    @Test func unstatedRampStepsFollowTheStatedOne() {
        struct Sparse: Theme {
            var foregroundMuted: Color = .rgb(9, 9, 9)
        }
        let theme = Sparse()
        #expect(theme.foregroundFaint == .rgb(9, 9, 9))
        #expect(theme.separator == .rgb(9, 9, 9))
    }

    @Test func unstatedBrandRolesFollowTheAccent() {
        struct Sparse: Theme {
            var accent: Color = .rgb(7, 7, 7)
        }
        let theme = Sparse()
        #expect(theme.primary == .rgb(7, 7, 7))
        #expect(theme.busy == .rgb(7, 7, 7))
        #expect(theme.borderActive == .rgb(7, 7, 7))
    }

    @Test func unstatedStatusSubtletiesFollowTheirBase() {
        struct Sparse: Theme {
            var error: Color = .rgb(5, 5, 5)
            var success: Color = .rgb(6, 6, 6)
        }
        let theme = Sparse()
        #expect(theme.errorSubtle == .rgb(5, 5, 5))
        #expect(theme.destructive == .rgb(5, 5, 5))
        #expect(theme.successSubtle == .rgb(6, 6, 6))
    }

    /// An empty conformance must still be a complete, usable theme — that is
    /// what makes the roles additive rather than a migration.
    @Test func anEmptyConformanceIsAWholeTheme() {
        struct Minimal: Theme {}
        let theme = Minimal()
        #expect(theme.accent == .cyan)
        #expect(theme.foregroundMuted == .gray)
        #expect(theme.border == .rounded)
    }
}
