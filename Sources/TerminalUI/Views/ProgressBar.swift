/// A determinate horizontal progress bar with an optional label and a
/// percentage readout.
///
/// Renders one row that fills the width its container allocates:
/// `label ███████░░░░░░ 42%` — full blocks (`█`) for the completed
/// fraction, light shade (`░`) for the remainder, both customizable. The
/// percentage suffix is always shown. For indeterminate work (no known
/// fraction), use ``Spinner`` instead.
///
/// ```swift
/// VStack {
///     ProgressBar(value: 0.25, label: "25%")
///     ProgressBar(value: 0.75, label: "75%")
///     ProgressBar(value: 1.00, label: "done")
/// }
/// ```
public struct ProgressBar: TerminalView {
    /// Completed fraction, clamped to 0.0...1.0 at initialization.
    public let value: Double  // 0.0 to 1.0
    /// Optional prefix rendered before the bar.
    public let label: String?
    /// Glyph for the completed portion.
    public let filled: Character
    /// Glyph for the remaining portion.
    public let empty: Character

    /// Creates a progress bar.
    ///
    /// - Parameters:
    ///   - value: Completed fraction; values outside 0...1 are clamped.
    ///   - label: Prefix text before the bar (default none).
    ///   - filled: Completed-portion glyph (default `█`).
    ///   - empty: Remaining-portion glyph (default `░`).
    public init(
        value: Double,
        label: String? = nil,
        filled: Character = "█",
        empty: Character = "░"
    ) {
        self.value = min(1.0, max(0.0, value))
        self.label = label
        self.filled = filled
        self.empty = empty
    }

    @_documentation(visibility: internal)
    public var body: Never { fatalError() }
}

/// A one-cell animated activity indicator for indeterminate work.
///
/// Renders a single glyph from the chosen ``SpinnerStyle``'s frame cycle —
/// braille patterns (`⠋⠙⠹…`) by default. The spinner holds no clock of its
/// own: the app owns the `frame` counter and advances it (typically from a
/// ``TerminalTimer`` event), which keeps animation in step with the render
/// loop and free when idle. Any integer works — it's taken modulo the
/// style's frame count. Use ``ProgressBar`` when the completed fraction is
/// known.
///
/// ```swift
/// // In body — frame comes from app state:
/// Spinner(frame: state.spinnerFrame, style: .dots)
///     .foreground(.cyan)
///
/// // Driven by a timer:
/// static var timers: [TerminalTimer] {[
///     TerminalTimer("spin", every: .milliseconds(80))
/// ]}
/// // In onEvent: case .timer("spin"): state.spinnerFrame += 1
/// ```
public struct Spinner: TerminalView {
    /// Animation counter; the glyph shown is `frame % style.frames.count`.
    public let frame: Int
    /// Which glyph cycle to animate through.
    public let style: SpinnerStyle

    /// Creates a spinner showing the glyph for `frame`.
    ///
    /// - Parameters:
    ///   - frame: App-owned counter, advanced externally per tick.
    ///   - style: Glyph cycle (default `.dots`).
    public init(frame: Int, style: SpinnerStyle = .dots) {
        self.frame = frame
        self.style = style
    }

    /// The glyph for the current frame.
    public var text: String {
        let frames = style.frames
        return frames[frame % frames.count]
    }

    @_documentation(visibility: internal)
    public var body: Never { fatalError() }
}

/// Frame cycle for ``Spinner``.
public enum SpinnerStyle: Sendable {
    /// Rotating braille dots: `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` (10 frames).
    case dots
    /// Classic ASCII rotor: `- \ | /` — safest for limited fonts.
    case line
    /// Heavier braille ring: `⣾⣽⣻⢿⡿⣟⣯⣷` (8 frames).
    case braille
    /// A single dot orbiting the cell: `⠁⠂⠄⡀⢀⠠⠐⠈`.
    case bounce

    var frames: [String] {
        switch self {
        case .dots: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        case .line: ["-", "\\", "|", "/"]
        case .braille: ["⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"]
        case .bounce: ["⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈"]
        }
    }
}
