import Testing
@testable import TerminalUI

// Controls painted their labels in the theme's foreground beneath whatever
// colour was stated above them, so `.foreground(_:)` on a button, a toggle
// or a stepper did nothing — and a dialog's destructive action, which
// states the theme's destructive colour that way, came out in plain
// foreground. A colour stated above a control is its label's, as SwiftUI's
// foreground style is.

private struct LoudTheme: Theme {
    var foreground: Color = .rgb(200, 200, 200)
    var foregroundMuted: Color = .rgb(90, 90, 90)
    var destructive: Color = .rgb(230, 40, 40)
}

@Suite("A colour stated above a control reaches its label")
@MainActor
struct ButtonColourTests {

    private func colour(of label: String, in buffer: CellBuffer) -> Color? {
        for y in 0..<buffer.height {
            let row = buffer.text(row: y)
            if let range = row.range(of: label) {
                return buffer[row.distance(from: row.startIndex, to: range.lowerBound), y].style.foreground
            }
        }
        return nil
    }

    @Test func aButtonDrawsInTheThemesForegroundByDefault() {
        let buffer = renderedBuffer(Button("Save") {}, width: 20, height: 1, theme: LoudTheme())
        #expect(colour(of: "Save", in: buffer) == LoudTheme().foreground)
    }

    @Test func aColourStatedOnAButtonIsItsLabels() {
        let buffer = renderedBuffer(Button("Save") {}.foreground(.green), width: 20, height: 1,
                                    theme: LoudTheme())
        #expect(colour(of: "Save", in: buffer) == .green)
    }

    @Test func aColourStatedOnAToggleIsItsLabels() {
        let buffer = renderedBuffer(Toggle("Done", isOn: .constant(false)).foreground(.green),
                                    width: 20, height: 1, theme: LoudTheme())
        #expect(colour(of: "Done", in: buffer) == .green)
    }

    @Test func aColourStatedOnAStepperIsItsLabels() {
        let buffer = renderedBuffer(Stepper("Count", value: .constant(3), in: 0...9).foreground(.green),
                                    width: 30, height: 1, theme: LoudTheme())
        #expect(colour(of: "Count", in: buffer) == .green)
        #expect(colour(of: SliderGlyph.increment, in: buffer) == .green, "the arrows are the stepper's too")
    }

    @Test func aColourStatedOnATextInputIsItsTexts() {
        let buffer = renderedBuffer(TextInput(text: .constant("draft")).foreground(.green),
                                    width: 20, height: 1, theme: LoudTheme())
        #expect(colour(of: "draft", in: buffer) == .green)
    }

    @Test func aDisabledButtonStaysMuted() {
        let buffer = renderedBuffer(Button("Save") {}.foreground(.green).disabled(), width: 20,
                                    height: 1, theme: LoudTheme())
        #expect(colour(of: "Save", in: buffer) == LoudTheme().foregroundMuted)
    }

    @Test func aDialogsDestructiveActionIsDrawnDestructive() {
        let buffer = renderedBuffer(
            Text("bg").focusable()
                .confirmationDialog("Delete task?", isPresented: .constant(true)) {
                    AlertAction("Delete", role: .destructive) {}
                    AlertAction("Cancel", role: .cancel) {}
                },
            width: 40, height: 12, theme: LoudTheme())
        #expect(colour(of: "Delete ]", in: buffer) == LoudTheme().destructive)
        #expect(colour(of: "Cancel", in: buffer) == LoudTheme().foreground)
    }
}
