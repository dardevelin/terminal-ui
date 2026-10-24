import Testing
@testable import TerminalUI

// A notch of the wheel scrolled three lines, fixed: an app whose rows are
// tall, or whose readers want finer steps, could not say otherwise.

private struct FineWheelApp: TerminalAppProtocol {
    static var linesPerWheelNotch: Int { 1 }
    static func content() -> some TerminalView { Text("fine") }
}

private struct PlainApp: TerminalAppProtocol {
    static func content() -> some TerminalView { Text("plain") }
}

private struct NoWheelApp: TerminalAppProtocol {
    static var linesPerWheelNotch: Int { 0 }
    static func content() -> some TerminalView { Text("none") }
}

@Suite("An app says how far a wheel notch scrolls")
@MainActor
struct WheelLinesTests {

    @Test func theAppsLinesPerNotchReachTheRuntime() {
        let runtime = TerminalRuntime(renderMode: .onDemand) { FineWheelApp.content() }
        FineWheelApp.configure(runtime)
        #expect(runtime.linesPerWheelNotch == 1)
    }

    @Test func aNotchScrollsThreeLinesUnlessTheAppSaysOtherwise() {
        let runtime = TerminalRuntime(renderMode: .onDemand) { PlainApp.content() }
        PlainApp.configure(runtime)
        #expect(runtime.linesPerWheelNotch == 3)
    }

    @Test func aNotchScrollsAtLeastALine() {
        let runtime = TerminalRuntime(renderMode: .onDemand) { NoWheelApp.content() }
        NoWheelApp.configure(runtime)
        #expect(runtime.linesPerWheelNotch == 1)
    }
}
