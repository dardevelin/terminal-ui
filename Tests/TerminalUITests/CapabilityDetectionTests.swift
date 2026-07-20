import Foundation
import Testing
@testable import TerminalUI

// HYP-295 — Capability detection (env-sniff phase). Reads
// TERM / TERM_PROGRAM / NO_COLOR to classify the graphics
// protocol the current terminal supports. Active escape-query
// (Phase A2) ships separately.
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
