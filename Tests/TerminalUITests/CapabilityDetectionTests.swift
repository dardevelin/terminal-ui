import Foundation
import Testing
@testable import TerminalUI

// Capability detection from the environment: TERM / TERM_PROGRAM /
// NO_COLOR classify the graphics protocol the current terminal
// supports. Querying the terminal with escape sequences is not
// covered.
//
// Tests inject an explicit env dictionary so behaviour is
// deterministic regardless of the test runner's actual env.

@Suite("Capability detection — env-sniff classifies graphics protocol")
@MainActor
struct CapabilityDetectionTests {

    @Test("NO_COLOR set forces asciiArt regardless of TERM")
    func noColorEnvForcesAsciiArt() {
        let env = ["TERM": "xterm-kitty", "NO_COLOR": "1"]
        let caps = TerminalCapabilities.detect(environment: env)
        #expect(caps.graphics == .asciiArt)
    }

    @Test("TERM=xterm-kitty detects kitty")
    func termKittyDetectsKitty() {
        let env = ["TERM": "xterm-kitty"]
        let caps = TerminalCapabilities.detect(environment: env)
        #expect(caps.graphics == .kitty)
    }

    @Test("TERM_PROGRAM=iTerm.app detects iterm2")
    func iTermProgramDetectsITerm2() {
        let env = ["TERM": "xterm-256color", "TERM_PROGRAM": "iTerm.app"]
        let caps = TerminalCapabilities.detect(environment: env)
        #expect(caps.graphics == .iterm2)
    }

    @Test("TERM=xterm-sixel detects sixel")
    func xtermSixelDetectsSixel() {
        let env = ["TERM": "xterm-sixel"]
        let caps = TerminalCapabilities.detect(environment: env)
        #expect(caps.graphics == .sixel)
    }

    @Test("plain xterm-256color defaults to halfBlock")
    func defaultDetectsHalfBlock() {
        let env = ["TERM": "xterm-256color"]
        let caps = TerminalCapabilities.detect(environment: env)
        #expect(caps.graphics == .halfBlock)
    }

    @Test("empty env still defaults to halfBlock")
    func emptyEnvDefaultsToHalfBlock() {
        let caps = TerminalCapabilities.detect(environment: [:])
        #expect(caps.graphics == .halfBlock)
    }

    @Test("detection log records the steps taken")
    func detectionLogRecordsSteps() {
        let env = ["TERM": "xterm-kitty"]
        let caps = TerminalCapabilities.detect(environment: env)
        #expect(!caps.detectionLog.isEmpty,
                "detection should log at least one step")
        // The successful classification step should mention kitty.
        let hasKittyStep = caps.detectionLog.contains { step in
            step.result.lowercased().contains("kitty")
        }
        #expect(hasKittyStep)
    }

    @Test("Runtime.capabilities is the framework-level singleton")
    func runtimeCapabilitiesAccessible() {
        // Compile-only check: Runtime.capabilities exists and is a TerminalCapabilities.
        let caps: TerminalCapabilities = Runtime.capabilities
        // After init, graphics is some GraphicsProtocol value.
        let graphics = caps.graphics
        #expect([.kitty, .iterm2, .sixel, .halfBlock, .asciiArt].contains(graphics))
    }
}

// Whether the terminal delivers Option (macOS) / Alt as a Meta prefix rather
// than composing it into a character. On stock Apple Terminal, Option+R
// produces "®" and no binding can see it; the user has to enable "Use Option
// as Meta key" first. Nothing in the environment reports that checkbox, so
// the honest answer there is `.unknown` — and a framework warning is worth
// more than a confident guess.

@Suite("Option-as-Meta detection")
@MainActor
struct OptionAsMetaDetectionTests {

    @Test("kitty reports modifiers directly, on any platform")
    func kittyIsConfirmed() {
        // The kitty keyboard protocol encodes the modifier bitmask in the
        // escape sequence, so Option never composes.
        let caps = TerminalCapabilities.detect(
            environment: ["TERM": "xterm-kitty"], optionMetaIsAmbiguous: true
        )
        #expect(caps.optionAsMetaConfigured == .confirmed)
    }

    @Test("platforms without the Option compose behaviour are confirmed")
    func nonAmbiguousPlatformIsConfirmed() {
        // X11, Wayland and the Linux console send Alt as an ESC prefix by
        // default — there is no equivalent setting to get wrong.
        let caps = TerminalCapabilities.detect(
            environment: ["TERM": "xterm-256color"], optionMetaIsAmbiguous: false
        )
        #expect(caps.optionAsMetaConfigured == .confirmed)
    }

    @Test("Apple Terminal cannot be determined from the environment")
    func appleTerminalIsUnknown() {
        let caps = TerminalCapabilities.detect(
            environment: ["TERM": "xterm-256color", "TERM_PROGRAM": "Apple_Terminal"],
            optionMetaIsAmbiguous: true
        )
        #expect(caps.optionAsMetaConfigured == .unknown)
    }

    @Test("iTerm2 cannot be determined either")
    func itermIsUnknown() {
        // iTerm2's Esc+ preference is per-profile and is not exported to the
        // environment. A kitty-protocol reply would prove the protocol is
        // active, which is a different question from how Option is mapped.
        let caps = TerminalCapabilities.detect(
            environment: ["TERM": "xterm-256color", "TERM_PROGRAM": "iTerm.app"],
            optionMetaIsAmbiguous: true
        )
        #expect(caps.optionAsMetaConfigured == .unknown)
    }

    @Test("an unrecognised terminal is unknown")
    func unknownTerminalIsUnknown() {
        let caps = TerminalCapabilities.detect(
            environment: [:], optionMetaIsAmbiguous: true
        )
        #expect(caps.optionAsMetaConfigured == .unknown)
    }

    @Test("the probe is logged even when graphics detection exits early")
    func probeIsLoggedDespiteEarlyGraphicsReturn() {
        // `NO_COLOR` short-circuits graphics classification. Appending the
        // option-meta probe afterwards would drop it from the log for exactly
        // the users most likely to be reading the log.
        let caps = TerminalCapabilities.detect(
            environment: ["NO_COLOR": "1", "TERM_PROGRAM": "Apple_Terminal"],
            optionMetaIsAmbiguous: true
        )
        #expect(caps.graphics == .asciiArt)
        #expect(caps.detectionLog.contains { $0.probe.contains("option") },
                "detection log: \(caps.detectionLog.map(\.probe))")
    }
}
