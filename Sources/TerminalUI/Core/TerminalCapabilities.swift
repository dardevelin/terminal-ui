import Foundation
import Observation

// Terminal capabilities surfaced as `@Observable` runtime state, detected by
// sniffing the environment. Apps read `Runtime.capabilities` to know which
// graphics protocol works here and whether Option-modified keys will arrive.
//
// Graphics detection order:
//   1. NO_COLOR set → .asciiArt (terminates).
//   2. TERM contains "kitty" → .kitty.
//   3. TERM_PROGRAM == "iTerm.app" → .iterm2.
//   4. TERM matches sixel pattern → .sixel.
//   5. Default → .halfBlock (assume 24-bit color).
//
// Option-as-Meta detection is a separate probe — see `classifyOptionAsMeta`.
// An active escape-query phase, which could narrow some of these answers, is
// not implemented: nothing currently sends a capability query at startup.

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

/// Whether the terminal delivers Option (macOS) / Alt as a Meta prefix rather
/// than composing it into a character.
///
/// On stock Apple Terminal, Option+R produces `®` and no binding can see it
/// until the user enables "Use Option as Meta key". Nothing in the environment
/// reports that setting, which is why `.unknown` is a distinct answer rather
/// than a pessimistic `false` — the framework warns instead of guessing.
public enum OptionAsMetaState: Sendable, Equatable {
    /// The terminal is known to deliver Option as a Meta prefix.
    case confirmed
    /// Cannot be determined. No terminal reports the setting as *disabled*
    /// either, so there is no third "known bad" case to distinguish — the
    /// framework warns on this one and lets the developer decide.
    case unknown
}

/// Whether the running platform can compose Option into a character instead of
/// sending it as a Meta prefix. True on macOS; elsewhere Alt is an ESC prefix
/// by default and there is no setting to get wrong.
///
/// Public only so it can be the default for `detect(environment:…)`, which
/// Swift requires to be at least as visible as the function itself.
public let platformComposesOptionDefault: Bool = {
    #if os(macOS)
    return true
    #else
    return false
    #endif
}()

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

    /// Whether Option-modified keys reach the framework as `.alt` events.
    public private(set) var optionAsMetaConfigured: OptionAsMetaState

    /// Whether this platform is one where Option can be composed into a
    /// character instead of sent as a Meta prefix. True on macOS; elsewhere
    /// Alt is an ESC prefix by default and there is no setting to get wrong.
    ///
    /// Resolved by the caller rather than branched on inside detection, so the
    /// classifier stays a pure function of its inputs and both answers are
    /// testable on either platform.
    static var platformComposesOption: Bool { platformComposesOptionDefault }

    /// Default initialiser detects from `ProcessInfo.processInfo.environment`.
    /// Tests use `detect(environment:)` to inject a deterministic dictionary.
    public init() {
        let result = TerminalCapabilities.classify(
            environment: ProcessInfo.processInfo.environment,
            optionMetaIsAmbiguous: TerminalCapabilities.platformComposesOption
        )
        self.graphics = result.graphics
        self.optionAsMetaConfigured = result.optionAsMeta
        self.detectionLog = result.log
    }

    private init(
        graphics: GraphicsProtocol,
        optionAsMeta: OptionAsMetaState,
        log: [DetectionStep]
    ) {
        self.graphics = graphics
        self.optionAsMetaConfigured = optionAsMeta
        self.detectionLog = log
    }

    /// Classify a given environment dictionary. Public so tests
    /// can verify behaviour deterministically.
    ///
    /// `optionMetaIsAmbiguous` says whether this platform can compose Option
    /// into a character instead of sending it as a Meta prefix — true on
    /// macOS, and defaulted from the running platform. Passed in rather than
    /// branched on internally so the classifier stays a pure function and both
    /// answers are testable on either platform.
    public static func detect(
        environment env: [String: String],
        optionMetaIsAmbiguous: Bool = platformComposesOptionDefault
    ) -> TerminalCapabilities {
        let result = classify(environment: env, optionMetaIsAmbiguous: optionMetaIsAmbiguous)
        return TerminalCapabilities(
            graphics: result.graphics,
            optionAsMeta: result.optionAsMeta,
            log: result.log
        )
    }

    private static func classify(
        environment env: [String: String],
        optionMetaIsAmbiguous: Bool
    ) -> (graphics: GraphicsProtocol, optionAsMeta: OptionAsMetaState, log: [DetectionStep]) {
        // Option-meta probes run first and seed the log. Graphics
        // classification below returns early from four separate branches, so
        // anything appended after it is dropped for whichever terminals take
        // the earliest exit — `NO_COLOR` users would lose the probe entirely.
        let optionMeta = classifyOptionAsMeta(
            environment: env, optionMetaIsAmbiguous: optionMetaIsAmbiguous
        )
        var log = optionMeta.log
        let graphics = classifyGraphics(environment: env, log: &log)
        return (graphics, optionMeta.state, log)
    }

    /// Decide whether Option arrives as a Meta prefix.
    ///
    /// kitty's keyboard protocol encodes the modifier bitmask in the escape
    /// sequence itself, so Option never composes there
    /// (sw.kovidgoyal.net/kitty/keyboard-protocol). Everywhere else on macOS
    /// the answer lives in a per-profile preference — Terminal.app's "Use
    /// Option as Meta key", iTerm2's per-profile "Esc+" — and neither is
    /// exported to the environment. A kitty-protocol reply would prove the
    /// protocol is active, which is a different question from how Option is
    /// mapped, so it would not settle this either.
    private static func classifyOptionAsMeta(
        environment env: [String: String],
        optionMetaIsAmbiguous: Bool
    ) -> (state: OptionAsMetaState, log: [DetectionStep]) {
        var log: [DetectionStep] = []

        if let term = env["TERM"], term.contains("kitty") {
            log.append(DetectionStep(probe: "option-meta/TERM", result: "\(term) → confirmed"))
            return (.confirmed, log)
        }

        guard optionMetaIsAmbiguous else {
            log.append(DetectionStep(probe: "option-meta/platform",
                                     result: "no compose behaviour → confirmed"))
            return (.confirmed, log)
        }

        let program = env["TERM_PROGRAM"] ?? "(none)"
        log.append(DetectionStep(probe: "option-meta/TERM_PROGRAM",
                                 result: "\(program) → unknown (setting is not exported)"))
        return (.unknown, log)
    }

    private static func classifyGraphics(
        environment env: [String: String],
        log: inout [DetectionStep]
    ) -> GraphicsProtocol {
        if env["NO_COLOR"] != nil {
            log.append(DetectionStep(probe: "NO_COLOR", result: "set → asciiArt"))
            return .asciiArt
        }
        log.append(DetectionStep(probe: "NO_COLOR", result: "unset"))

        if let term = env["TERM"], term.contains("kitty") {
            log.append(DetectionStep(probe: "TERM", result: "\(term) → kitty"))
            return .kitty
        }
        log.append(DetectionStep(probe: "TERM", result: env["TERM"] ?? "(none)"))

        if let program = env["TERM_PROGRAM"], program == "iTerm.app" {
            log.append(DetectionStep(probe: "TERM_PROGRAM", result: "\(program) → iterm2"))
            return .iterm2
        }
        log.append(DetectionStep(probe: "TERM_PROGRAM", result: env["TERM_PROGRAM"] ?? "(none)"))

        if let term = env["TERM"], term.contains("sixel") {
            log.append(DetectionStep(probe: "TERM/sixel", result: "\(term) → sixel"))
            return .sixel
        }

        log.append(DetectionStep(probe: "default", result: "halfBlock"))
        return .halfBlock
    }
}

/// Framework-level runtime singletons. `Runtime.capabilities`
/// is the canonical place to read graphics-protocol detection.
public enum Runtime {
    public static let capabilities = TerminalCapabilities()
}
