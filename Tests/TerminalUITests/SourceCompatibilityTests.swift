import Testing
import TerminalUI

// What apps written against 1.0 rely on, through the public API alone — no
// `@testable` here, so nothing internal stands in for what an app can reach.
// Swift's API digester (`diagnose-api-breaking-changes`) catches a removed
// or retyped declaration; these cases catch the breaks it cannot see: a
// declaration that still compiles but no longer does what it did.

/// A theme exactly as 1.0's documentation wrote one.
private struct HighContrast: Theme {
    var accent: Color = .brightCyan
    var muted: Color = .white
    var success: Color = .brightGreen
    var warning: Color = .brightYellow
    var error: Color = .brightRed
    var border: BorderStyle = .heavy
}

@Suite("What 1.0 apps rely on still works")
struct SourceCompatibilityTests {

    /// `muted` was 1.0's whole de-emphasis vocabulary. Once components read
    /// `foregroundMuted` instead, a theme that stated `muted` still compiled
    /// and was silently ignored: its hints and placeholders came out gray.
    @Test func aThemeThatStatesMutedIsHonoured() {
        let theme: any Theme = HighContrast()
        #expect(theme.foregroundMuted == .white)
        // On the terminal's own ground there is nothing to mix toward, so
        // the quieter step falls back to the colour stated — not to gray.
        #expect(theme.foregroundFaint == .white)
    }

    @Test func theStockThemeAnswersMutedWithItsMutedStep() {
        var stock = DefaultTheme()
        stock.foregroundMuted = .magenta
        let theme: any Theme = stock
        #expect(theme.muted == .magenta)
    }

    @Test func wrapModesAreHashable() {
        let modes: Set<TextWrapMode> = [.wrap, .none, .truncate(.tail), .truncate(.head)]
        #expect(modes.count == 4)
    }
}
