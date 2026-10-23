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
        renderedBuffer(view, width: width, height: height, theme: theme)
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

    // MARK: - Derivation

    /// The point of deriving rather than aliasing: a theme that states its
    /// foreground and background gets a genuinely quieter step below it, not a
    /// duplicate. Five or six stated colours should yield a coherent
    /// twenty-six, which is what makes a role set this size authorable.
    @Test func statingGroundAndTextDerivesTheWholeForegroundRamp() {
        struct Pinned: Theme {
            var foreground: Color = .rgb(236, 235, 240)
            var background: Color = .rgb(27, 26, 36)
        }
        let theme = Pinned()
        let steps = [theme.foreground, theme.foregroundSubtle,
                     theme.foregroundMuted, theme.foregroundFaint]
        let lightness = steps.map { Int($0.nominalRGB!.red) }
        #expect(lightness == lightness.sorted(by: >),
                "each step must be quieter than the one above it, got \(lightness)")
        // And genuinely distinct, not four names for one colour.
        #expect(Set(lightness).count == 4)
    }

    @Test func statusSubtletiesAreQuieterButKeepTheirHue() {
        struct Pinned: Theme {
            var background: Color = .rgb(27, 26, 36)
            var error: Color = .rgb(255, 93, 126)
        }
        let theme = Pinned()
        let base = theme.error.nominalRGB!
        let subtle = theme.errorSubtle.nominalRGB!
        #expect(subtle.red < base.red, "the subtle step must be quieter")
        // Still recognisably red: the red channel stays dominant.
        #expect(subtle.red > subtle.green && subtle.red > subtle.blue)
    }

    @Test func raisedSurfacesLiftOffTheGroundWithoutBecomingText() {
        struct Pinned: Theme {
            var foreground: Color = .rgb(236, 235, 240)
            var background: Color = .rgb(27, 26, 36)
        }
        let theme = Pinned()
        let ground = Int(theme.background.nominalRGB!.red)
        let raised = Int(theme.backgroundRaised.nominalRGB!.red)
        let overlay = Int(theme.backgroundOverlay.nominalRGB!.red)
        #expect(raised > ground && overlay > raised)
        // A surface that travels too far stops reading as a surface.
        #expect(overlay < 100, "overlay \(overlay) drifted toward the text colour")
    }

    /// Derivation needs resolvable endpoints. A theme resting on the
    /// terminal's own colours has none, and must keep the contrast it always
    /// had rather than collapsing every role onto `.default`.
    @Test func aThemeOnTerminalDefaultsDoesNotCollapse() {
        struct Minimal: Theme {}
        let theme = Minimal()
        #expect(theme.foreground == .default)
        #expect(theme.foregroundMuted == .gray)
        #expect(theme.foregroundEmphasis == .white)
        #expect(theme.foregroundSubtle == .default)
    }

    // MARK: - Overrides beat derivation

    /// The classic Swift trap this could have fallen into: a protocol
    /// extension member that is *not* a protocol requirement dispatches
    /// statically, and a conforming type's own version would be ignored
    /// wherever the value is held as `any Theme` — which is exactly how the
    /// environment holds it. Every role is a declared requirement precisely
    /// so this cannot happen, and this pins it through the existential.
    @Test func aStatedRoleBeatsTheDerivedDefaultThroughTheExistential() {
        struct Stated: Theme {
            var foreground: Color = .rgb(236, 235, 240)
            var background: Color = .rgb(27, 26, 36)
            // Would otherwise be mixed from the two above.
            var foregroundMuted: Color = .rgb(1, 2, 3)
        }
        let concrete = Stated()
        let erased: any Theme = Stated()
        #expect(concrete.foregroundMuted == .rgb(1, 2, 3))
        #expect(erased.foregroundMuted == .rgb(1, 2, 3),
                "the override was lost through `any Theme` — static dispatch")
    }

    /// Overriding a role the ramps are measured *from* moves everything below
    /// it. This is the property that makes stating a handful of colours worth
    /// doing at all.
    @Test func overridingAGroundColourMovesTheWholeRamp() {
        struct Light: Theme {
            var foreground: Color = .rgb(20, 20, 20)
            var background: Color = .rgb(250, 250, 250)
        }
        struct Dark: Theme {
            var foreground: Color = .rgb(240, 240, 240)
            var background: Color = .rgb(20, 20, 20)
        }
        // On a light ground the muted step is lighter than the text; on a
        // dark one it is darker. Same role, opposite direction.
        #expect(Light().foregroundMuted.nominalRGB!.red > Light().foreground.nominalRGB!.red)
        #expect(Dark().foregroundMuted.nominalRGB!.red < Dark().foreground.nominalRGB!.red)
    }

    // MARK: - Derivation can be switched off

    /// With derivation off the roles still all answer — they borrow the
    /// nearest stated colour instead of computing one. That is the behaviour
    /// the defaults had before any colour science existed.
    @Test func derivationOffBorrowsInsteadOfMixing() {
        struct Hand: Theme {
            var derivation: ThemeDerivation = .off
            var foreground: Color = .rgb(236, 235, 240)
            var background: Color = .rgb(27, 26, 36)
        }
        let theme = Hand()
        #expect(theme.foregroundSubtle == theme.foreground)
        #expect(theme.foregroundFaint == theme.foregroundMuted)
        #expect(theme.backgroundRaised == theme.background)
        #expect(theme.errorSubtle == theme.error)
    }

    /// The switch and explicit overrides are orthogonal: turning derivation
    /// off must not stop a stated role from being used.
    @Test func derivationOffStillRespectsStatedRoles() {
        struct Hand: Theme {
            var derivation: ThemeDerivation = .off
            var foreground: Color = .rgb(236, 235, 240)
            var foregroundFaint: Color = .rgb(4, 5, 6)
        }
        #expect(Hand().foregroundFaint == .rgb(4, 5, 6))
    }

    /// With derivation on, the same theme mixes rather than borrowing — the
    /// point being that the switch is what changed, not the palette.
    @Test func theSwitchIsWhatChangesNotThePalette() {
        struct Auto: Theme {
            var foreground: Color = .rgb(236, 235, 240)
            var background: Color = .rgb(27, 26, 36)
        }
        struct Off: Theme {
            var derivation: ThemeDerivation = .off
            var foreground: Color = .rgb(236, 235, 240)
            var background: Color = .rgb(27, 26, 36)
        }
        #expect(Auto().foregroundSubtle != Auto().foreground)
        #expect(Off().foregroundSubtle == Off().foreground)
    }

    @Test func derivationDefaultsToAutomatic() {
        struct Minimal: Theme {}
        #expect(Minimal().derivation == .automatic)
        #expect(DefaultTheme().derivation == .automatic)
    }

    /// A themed component must honour the override, not just the theme value
    /// in isolation — the whole chain from conformance to rendered cell.
    @Test func aStatedRoleReachesTheRenderedCells() {
        struct Stated: Theme {
            var foreground: Color = .rgb(236, 235, 240)
            var background: Color = .rgb(27, 26, 36)
            var foregroundMuted: Color = .rgb(1, 2, 3)
        }
        let buffer = render(Button("Save") {}.disabled(), width: 12, height: 1, theme: Stated())
        #expect(colors(buffer).contains(.rgb(1, 2, 3)))
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
