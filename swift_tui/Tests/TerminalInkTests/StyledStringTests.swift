import Testing
@testable import TerminalInk

// HYP-57 — StyledString builder, ink() print API, and the
// chain-style String extensions.
//
// These tests pin the contract from HYP-57's spec:
//
//   "Error".styled(.red, .bold) + ": " + "file not found".styled(.dim)
//   ink("Build failed", .red, .bold)
//   "error".red.bold      // String → StyledString chain
//
// All three surfaces compose into the same underlying StyledString.
// `render(capability:)` emits ECMA-48 SGR sequences and respects
// `ColorCapability.none` (NO_COLOR / piped output) by stripping ANSI.

@Suite("TextTraits — option set covering SGR boolean attributes")
struct TextTraitsTests {

    @Test("six traits per HYP-57 spec: bold, italic, underline, dim, strikethrough, inverse")
    func sixTraits() {
        // Each trait must be a distinct option-set member so callers
        // can compose with `[.bold, .underline]`.
        let bold: TextTraits = .bold
        let italic: TextTraits = .italic
        let underline: TextTraits = .underline
        let dim: TextTraits = .dim
        let strikethrough: TextTraits = .strikethrough
        let inverse: TextTraits = .inverse
        let all: TextTraits = [bold, italic, underline, dim, strikethrough, inverse]
        // 6 distinct bits set — confirms no aliasing.
        #expect(all.rawValue.nonzeroBitCount == 6,
                "six SGR traits must occupy six distinct bits; got \(all.rawValue.nonzeroBitCount)")
    }

    @Test("contains() round-trips through union")
    func unionContains() {
        let s: TextTraits = [.bold, .italic]
        #expect(s.contains(.bold))
        #expect(s.contains(.italic))
        #expect(!s.contains(.underline))
    }
}

@Suite("StyledString — builder")
struct StyledStringBuilderTests {

    @Test("empty initializer produces no runs")
    func emptyInit() {
        let s = StyledString()
        #expect(s.runs.isEmpty)
    }

    @Test("text-only initializer produces one plain run")
    func plainText() {
        let s = StyledString("hello")
        #expect(s.runs.count == 1)
        #expect(s.runs[0].text == "hello")
        #expect(s.runs[0].foreground == nil)
        #expect(s.runs[0].background == nil)
        #expect(s.runs[0].traits == [])
    }

    @Test("StyledString + StyledString concatenates runs in order")
    func concatStyled() {
        let a = StyledString("hello").foreground(.named(.red))
        let b = StyledString(" world").foreground(.named(.blue))
        let combined = a + b
        #expect(combined.runs.count == 2)
        #expect(combined.runs[0].text == "hello")
        #expect(combined.runs[1].text == " world")
    }

    @Test("StyledString + String appends a plain run")
    func concatString() {
        let combined = StyledString("hello").foreground(.named(.red)) + " plain"
        #expect(combined.runs.count == 2)
        #expect(combined.runs[1].foreground == nil)
        #expect(combined.runs[1].text == " plain")
    }

    @Test("String + StyledString prepends a plain run")
    func prependString() {
        let combined = "plain " + StyledString("styled").foreground(.named(.red))
        #expect(combined.runs.count == 2)
        #expect(combined.runs[0].foreground == nil)
        #expect(combined.runs[0].text == "plain ")
    }
}

@Suite("StyledString — render produces SGR sequences")
struct StyledStringRenderTests {

    @Test("plain text renders with no SGR sequences")
    func plainRender() {
        let out = StyledString("hi").render(capability: .trueColor)
        #expect(out == "hi")
    }

    @Test("foreground renders CSI ... m around the run")
    func foregroundRender() {
        let s = StyledString("err").foreground(.named(.red))
        let out = s.render(capability: .basic16)
        // CSI 31 m + "err" + CSI 0 m
        #expect(out == "\u{1B}[31merr\u{1B}[0m",
                "expected SGR-31 wrapped run; got \(out.debugDescription)")
    }

    @Test("traits emit 1m / 4m / etc. before the text")
    func traitRender() {
        let s = StyledString("bold").traits(.bold)
        let out = s.render(capability: .basic16)
        #expect(out.contains("\u{1B}[1m"),
                "bold trait must emit SGR 1; got \(out.debugDescription)")
    }

    @Test("ColorCapability.none strips all SGR — piped/NO_COLOR safety")
    func noneStrips() {
        let s = StyledString("err")
            .foreground(.named(.red))
            .traits(.bold)
        let out = s.render(capability: .none)
        // No escape sequences at all.
        #expect(out == "err",
                "capability=.none must strip ANSI entirely; got \(out.debugDescription)")
    }

    @Test("RGB foreground downgrades to ansi256 under .ansi256 capability")
    func rgbDowngrades() {
        let s = StyledString("x").foreground(.rgb(255, 0, 0))
        let out = s.render(capability: .ansi256)
        // RGB→256 routes pure red to slot 196 per HYP-56 mapping.
        #expect(out.contains("\u{1B}[38;5;196m"),
                "RGB(255,0,0) must downgrade to ansi256 196 under .ansi256 cap; got \(out.debugDescription)")
    }

    @Test("multi-run output emits reset between runs")
    func multiRunReset() {
        let s = StyledString("a").foreground(.named(.red))
            + StyledString("b").foreground(.named(.blue))
        let out = s.render(capability: .basic16)
        // Each styled run is wrapped with its own CSI ... m + reset.
        // Implementation MAY collapse adjacent resets; this test
        // checks both runs are present and surrounded.
        #expect(out.contains("a"))
        #expect(out.contains("b"))
        #expect(out.hasSuffix("\u{1B}[0m"),
                "rendered output must end with SGR reset; got \(out.debugDescription)")
    }
}

@Suite("String chain extensions — .red.bold etc.")
struct StringChainTests {

    @Test(".red on String produces a StyledString with red foreground")
    func redChain() {
        let s = "err".red
        #expect(s.runs.count == 1)
        #expect(s.runs[0].foreground == .named(.red))
    }

    @Test(".bold on String produces a StyledString with bold trait")
    func boldChain() {
        let s = "loud".bold
        #expect(s.runs[0].traits.contains(.bold))
    }

    @Test("chain composes — \"x\".red.bold carries both")
    func compose() {
        let s = "loud".red.bold
        #expect(s.runs[0].foreground == .named(.red))
        #expect(s.runs[0].traits.contains(.bold))
    }

    @Test("Semantic shorthand on String — .error / .success / etc.")
    func semantic() {
        // These should map to the same InkColor.error / .success
        // values exposed in HYP-56.
        let e = "boom".error
        #expect(e.runs[0].foreground == InkColor.error)
        let ok = "ok".success
        #expect(ok.runs[0].foreground == InkColor.success)
    }
}
