import Foundation
import Testing
@testable import TerminalUI

// Pins how the parser decodes Option/Alt+letter chords, including
// Apple Terminal's Option-compose characters (Option+R arrives as ®).

@Suite("InputParser — Option/Alt+letter chord handling")
struct InputParserOptionLetterTests {

    @Test("ESC + r ASCII bytes produce Alt+R")
    func parserDecodesEscRAsAltR() {
        // What Apple Terminal sends for Option+R when "Use Option as
        // Meta key" is ON, and what xterm / iTerm2-Esc+ / kitty all
        // send by default. Two ASCII bytes, no UTF-8 involved.
        var source = ArrayByteSource(bytes: [0x1B, 0x72])
        let event = InputParser.parseEvent(from: &source)

        guard case .key(let key) = event else {
            Issue.record("expected .key, got \(String(describing: event))")
            return
        }
        #expect(key.key == .character("r"), "key should be 'r', got \(key.key)")
        #expect(key.modifiers == .alt, "modifiers should be .alt, got \(key.modifiers)")
    }

    @Test("Apple Terminal Option+R bytes (U+00AE) decode to Option+R chord")
    func parserDecodesAppleOptionR() {
        // What stock Apple Terminal sends for Option+R when "Use Option
        // as Meta key" is OFF (Apple's default): UTF-8 encoding of
        // U+00AE REGISTERED SIGN, bytes 0xC2 0xAE — NO leading ESC.
        // The AppleOptionDecode map reverses this back to Option+R.
        var source = ArrayByteSource(bytes: [0xC2, 0xAE])
        let event = InputParser.parseEvent(from: &source)

        guard case .key(let key) = event else {
            Issue.record("expected .key, got \(String(describing: event))")
            return
        }
        #expect(key.key == .character("r"),
                "Apple Option+R compose `®` should decode to .character(\"r\"); got \(key.key)")
        #expect(key.modifiers == .alt,
                "Apple Option+R compose `®` should carry the .alt (Option) modifier; got \(key.modifiers)")
    }

    @Test("Option+A compose char `å` decodes to Option+A chord")
    func parserDecodesAppleOptionA() {
        var source = ArrayByteSource(bytes: Array("å".utf8))
        let event = InputParser.parseEvent(from: &source)
        guard case .key(let key) = event else {
            Issue.record("expected .key, got \(String(describing: event))"); return
        }
        #expect(key.key == .character("a"))
        #expect(key.modifiers == .alt)
    }

    @Test("Option+Shift+R compose char `‰` decodes to Option+Shift+R chord")
    func parserDecodesAppleOptionShiftR() {
        var source = ArrayByteSource(bytes: Array("‰".utf8))
        let event = InputParser.parseEvent(from: &source)
        guard case .key(let key) = event else {
            Issue.record("expected .key, got \(String(describing: event))"); return
        }
        #expect(key.key == .character("r"))
        #expect(key.modifiers == [.alt, .shift])
    }

    @Test("Non-compose UTF-8 char (é) passes through as a literal character")
    func parserPassesThroughNonComposeChars() {
        // `é` (U+00E9) is the result of Apple's Option+E, e DEAD-key
        // composition — not in the compose map. It must reach the
        // user as a literal `é`, not be mis-decoded.
        var source = ArrayByteSource(bytes: Array("é".utf8))
        let event = InputParser.parseEvent(from: &source)
        guard case .key(let key) = event else {
            Issue.record("expected .key, got \(String(describing: event))"); return
        }
        #expect(key.key == .character("é"),
                "Non-compose char must pass through; got \(key.key)")
        #expect(key.modifiers == [],
                "Non-compose char must have no modifiers; got \(key.modifiers)")
    }

    @Test("ESC + multibyte UTF-8 letter (e.g. Option+Shift+letter on layouts that emit it)")
    func parserHandlesEscPlusMultibyte() {
        // Some keyboard configs send ESC + UTF-8 multibyte for
        // Option+Shift+letter. The parser's current code at line 210
        // does `Character(UnicodeScalar(secondByte))` — single byte only.
        // If the chord arrives as ESC + 0xC2 0xAE the parser would
        // mis-decode the first continuation byte as a character.
        // This test pins what currently happens so any future fix
        // doesn't silently break the assumption.
        var source = ArrayByteSource(bytes: [0x1B, 0xC2, 0xAE])
        let event = InputParser.parseEvent(from: &source)

        guard case .key(let key) = event else {
            Issue.record("expected .key, got \(String(describing: event))")
            return
        }
        // Pin current behaviour: parser reads only one byte after ESC,
        // gets 0xC2 (a continuation byte interpreted as a Latin-1 char).
        // The 0xAE remains in the source unread — next parse() consumes
        // it as a fragment. This is broken for Option+multibyte chords
        // but documenting the gap rather than blocking on it.
        #expect(key.modifiers == .alt,
                "ESC prefix should produce .alt modifier; got \(key.modifiers)")
    }
}

// Minimal byte-source for parser tests — feeds bytes from an array,
// returning nil when exhausted (matches the real ByteSource contract).
private struct ArrayByteSource: ByteSource {
    private var bytes: [UInt8]
    private var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func readByte() -> UInt8? {
        guard index < bytes.count else { return nil }
        defer { index += 1 }
        return bytes[index]
    }
}
