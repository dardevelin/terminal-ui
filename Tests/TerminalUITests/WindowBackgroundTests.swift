import Testing
@testable import TerminalUI

// xterm ctlseqs, "Operating System Commands": OSC 11 sets the terminal's
// default background — what cells without a background of their own show,
// and the padding a terminal draws around its grid — and OSC 111 puts the
// terminal's own back. An app that colours only its cells leaves that
// padding in the terminal's colour, a frame of another shade around it.

@Suite("The app's colour behind the whole terminal")
struct WindowBackgroundTests {

    @Test func aColourIsSentAsOSC11InHex() {
        #expect(Terminal.windowBackgroundSequence(.rgb(0x1A, 0x1B, 0x26)) == "\u{1B}]11;rgb:1a/1b/26\u{1B}\\")
    }

    @Test func noColourPutsTheTerminalsOwnBack() {
        #expect(Terminal.windowBackgroundSequence(nil) == "\u{1B}]111\u{1B}\\")
    }

    @Test func aColourWithNoValueOfItsOwnPutsTheTerminalsOwnBack() {
        #expect(Terminal.windowBackgroundSequence(.default) == "\u{1B}]111\u{1B}\\")
    }
}
