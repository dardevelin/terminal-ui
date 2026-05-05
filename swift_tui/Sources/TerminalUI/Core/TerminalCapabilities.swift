import Foundation
import Observation

// HYP-295 — Terminal graphics-protocol capability surfaced as
// `@Observable` runtime state. Apps and components read
// `Runtime.capabilities.graphics` to know which graphics protocol
// works in the current terminal. Phase A1 — env-sniff only.
//
// Detection order:
//   1. NO_COLOR set → .asciiArt (terminates).
//   2. TERM contains "kitty" → .kitty.
//   3. TERM_PROGRAM == "iTerm.app" → .iterm2.
//   4. TERM matches sixel pattern → .sixel.
//   5. Default → .halfBlock (assume 24-bit color).

/// Graphics-protocol capability of the current terminal.
/// Ordered roughly by fidelity: kitty has the highest, asciiArt
/// the lowest.
public enum GraphicsProtocol: Sendable, Equatable {
    case kitty
    case iterm2
    case sixel
    case halfBlock     // 24-bit color, no graphics protocol
    case asciiArt      // monochrome / NO_COLOR
}

/// One step of the detection process. Logged for DevTools
/// inspection — apps and developers can read the log to
/// understand why a particular protocol was chosen.
public struct DetectionStep: Sendable, Equatable {
    public let probe: String
    public let result: String
}

/// Observable framework-level capability state.
///
/// Non-isolated to match the framework's "main thread by convention"
/// rule (matches `GraphRenderer`, `Runtime.outputs` and the existing
/// `nonisolated(unsafe)` statics in `GraphContext`). Capabilities are
/// detected once at startup and read from view bodies that run on the
/// main thread; making this `@MainActor` was over-restrictive and
/// blocked cross-module access from non-isolated render contexts.
@Observable
public final class TerminalCapabilities: @unchecked Sendable {
    public private(set) var graphics: GraphicsProtocol
    public private(set) var detectionLog: [DetectionStep]

    /// Default initialiser detects from `ProcessInfo.processInfo.environment`.
    /// Tests use `detect(environment:)` to inject a deterministic dictionary.
    public init() {
        let result = TerminalCapabilities.classify(
            environment: ProcessInfo.processInfo.environment
        )
        self.graphics = result.graphics
        self.detectionLog = result.log
    }

    private init(graphics: GraphicsProtocol, log: [DetectionStep]) {
        self.graphics = graphics
        self.detectionLog = log
    }

    /// Classify a given environment dictionary. Public so tests
    /// can verify behaviour deterministically.
    public static func detect(environment env: [String: String]) -> TerminalCapabilities {
        let result = classify(environment: env)
        return TerminalCapabilities(graphics: result.graphics, log: result.log)
    }

    private static func classify(
        environment env: [String: String]
    ) -> (graphics: GraphicsProtocol, log: [DetectionStep]) {
        var log: [DetectionStep] = []

        if env["NO_COLOR"] != nil {
            log.append(DetectionStep(probe: "NO_COLOR", result: "set → asciiArt"))
            return (.asciiArt, log)
        }
        log.append(DetectionStep(probe: "NO_COLOR", result: "unset"))

        if let term = env["TERM"], term.contains("kitty") {
            log.append(DetectionStep(probe: "TERM", result: "\(term) → kitty"))
            return (.kitty, log)
        }
        log.append(DetectionStep(probe: "TERM", result: env["TERM"] ?? "(none)"))

        if let program = env["TERM_PROGRAM"], program == "iTerm.app" {
            log.append(DetectionStep(probe: "TERM_PROGRAM", result: "\(program) → iterm2"))
            return (.iterm2, log)
        }
        log.append(DetectionStep(probe: "TERM_PROGRAM", result: env["TERM_PROGRAM"] ?? "(none)"))

        if let term = env["TERM"], term.contains("sixel") {
            log.append(DetectionStep(probe: "TERM/sixel", result: "\(term) → sixel"))
            return (.sixel, log)
        }

        log.append(DetectionStep(probe: "default", result: "halfBlock"))
        return (.halfBlock, log)
    }
}

/// Framework-level runtime singletons. `Runtime.capabilities`
/// is the canonical place to read graphics-protocol detection.
public enum Runtime {
    public static let capabilities = TerminalCapabilities()
}
