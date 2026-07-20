public struct ProgressBar: TerminalView {
    public let value: Double  // 0.0 to 1.0
    public let label: String?
    public let filled: Character
    public let empty: Character

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

    public var body: Never { fatalError() }
}

public struct Spinner: TerminalView {
    public let frame: Int
    public let style: SpinnerStyle

    public init(frame: Int, style: SpinnerStyle = .dots) {
        self.frame = frame
        self.style = style
    }

    public var text: String {
        let frames = style.frames
        return frames[frame % frames.count]
    }

    public var body: Never { fatalError() }
}

public enum SpinnerStyle: Sendable {
    case dots
    case line
    case braille
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
