import Testing
@testable import TerminalUI

// Crush tints a changed line's whole row, green or red, and highlights the
// code on it. DiffView coloured only the text, so status and syntax competed
// for the one colour a character has. A changed row now takes its status as
// a ground — the theme's `addedBackground` / `removedBackground` — and,
// given a language, its code keeps the syntax colours.

/// A theme with colours the tint can be mixed from.
private struct InkTheme: Theme {
    var background: Color = .rgb(10, 10, 10)
    var foreground: Color = .rgb(230, 230, 230)
    var success: Color = .rgb(0, 200, 0)
    var error: Color = .rgb(200, 0, 0)
}

private let change = [
    DiffLine(id: 0, kind: .unchanged, text: "let a = 1", oldLineNumber: 1, newLineNumber: 1),
    DiffLine(id: 1, kind: .removed, text: "let b = 2", oldLineNumber: 2, newLineNumber: nil),
    DiffLine(id: 2, kind: .added, text: "let b = 3", oldLineNumber: nil, newLineNumber: 2),
]

@Suite("A changed diff row is tinted by its status")
@MainActor
struct DiffRowTintTests {

    @Test func theTintIsTheGroundMixedTowardTheStatus() {
        let theme: any Theme = InkTheme()
        #expect(theme.addedBackground == InkTheme().background.blended(with: InkTheme().success, amount: 0.2))
        #expect(theme.removedBackground == InkTheme().background.blended(with: InkTheme().error, amount: 0.2))
    }

    /// On the terminal's own ground there is nothing to mix, and a full
    /// status colour behind code would bury it: no tint.
    @Test func theStockThemeDoesNotTint() {
        let theme: any Theme = DefaultTheme()
        #expect(theme.addedBackground == .default)
        #expect(theme.removedBackground == .default)
    }

    /// A brand palette that turned derivation off wants no computed shade:
    /// the ground stays the ground.
    @Test func withDerivationOffThereIsNoTint() {
        struct Brand: Theme {
            var derivation: ThemeDerivation = .off
            var background: Color = .rgb(10, 10, 10)
            var success: Color = .rgb(0, 200, 0)
        }
        let theme: any Theme = Brand()
        #expect(theme.addedBackground == Brand().background)
    }

    @Test func aStatedTintIsTheOneUsed() {
        struct Stated: Theme {
            var addedBackground: Color = .rgb(1, 40, 1)
        }
        let theme: any Theme = Stated()
        #expect(theme.addedBackground == .rgb(1, 40, 1))
    }

    @Test func aChangedRowIsTintedAcrossItsWholeWidth() {
        let buffer = renderedBuffer(DiffView(lines: change), width: 30, height: 3, theme: InkTheme())
        let theme: any Theme = InkTheme()
        #expect(buffer[0, 1].style.background == theme.removedBackground)
        #expect(buffer[29, 1].style.background == theme.removedBackground, "to the row's last column")
        #expect(buffer[29, 2].style.background == theme.addedBackground)
        #expect(buffer[29, 0].style.background != theme.addedBackground, "an unchanged row is not tinted")
    }

    @Test func onTheStockThemeNoRowIsPainted() {
        let buffer = renderedBuffer(DiffView(lines: change), width: 30, height: 3)
        #expect((0..<3).allSatisfy { buffer[29, $0].style.background == nil })
    }

    /// The row's ground says it changed, so its code can keep the syntax
    /// colours; the marker keeps the status colour.
    @Test func aLanguageHighlightsTheCodeOnAChangedRow() {
        let buffer = renderedBuffer(DiffView(lines: change).diffLanguage("swift"), width: 30, height: 3,
                                    theme: InkTheme())
        let row = buffer.text(row: 2)
        let marker = row.distance(from: row.startIndex, to: row.firstIndex(of: "+")!)
        let keyword = row.distance(from: row.startIndex, to: row.range(of: "let")!.lowerBound)
        #expect(buffer[marker, 2].style.foreground == InkTheme().success)
        #expect(buffer[keyword, 2].style.foreground == InkTheme().syntax.keyword)
    }
}
