import Synchronization

/// A text-editing command, named apart from the keys that invoke it — the
/// shape of Cocoa's standard key-binding selectors and of readline's and
/// Emacs's commands. TextInput, TextArea and PromptInput perform the ones
/// declared here; a ``TextKeymap`` says which key performs which.
///
/// Open, like ``ActionID``: the raw value is the command's name, so a
/// command added later, or one an app defines, is just another name, and a
/// keymap can bind it without the framework knowing it in advance. An input
/// ignores a command it does not perform, and the key passes on.
public struct TextEditCommand: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    /// One character back.
    public static let moveBackward: TextEditCommand = "moveBackward"
    /// One character forward.
    public static let moveForward: TextEditCommand = "moveForward"
    /// To the start of this word, or the previous one: letters and digits.
    public static let moveWordBackward: TextEditCommand = "moveWordBackward"
    /// To the end of this word, or the next one: letters and digits.
    public static let moveWordForward: TextEditCommand = "moveWordForward"
    /// To the start of the current line.
    public static let moveToLineStart: TextEditCommand = "moveToLineStart"
    /// To the end of the current line.
    public static let moveToLineEnd: TextEditCommand = "moveToLineEnd"
    /// Delete the character before the cursor.
    public static let deleteBackward: TextEditCommand = "deleteBackward"
    /// Delete the character after the cursor.
    public static let deleteForward: TextEditCommand = "deleteForward"
    /// Kill back to the start of a word.
    public static let deleteWordBackward: TextEditCommand = "deleteWordBackward"
    /// Kill forward to the end of a word.
    public static let deleteWordForward: TextEditCommand = "deleteWordForward"
    /// Kill back to whitespace — readline's `unix-word-rubout`: a whole path
    /// or `--flag=value` at once.
    public static let deleteToWhitespaceBackward: TextEditCommand = "deleteToWhitespaceBackward"
    /// Kill to the start of the line; at its start, the line break before it.
    public static let deleteToLineStart: TextEditCommand = "deleteToLineStart"
    /// Kill to the end of the line; at its end, the line break after it.
    public static let deleteToLineEnd: TextEditCommand = "deleteToLineEnd"
    /// Insert the last killed text at the cursor.
    public static let yank: TextEditCommand = "yank"
    /// Undo the last edit, in an input that keeps a history of them.
    public static let undo: TextEditCommand = "undo"
    /// Redo the last undone edit.
    public static let redo: TextEditCommand = "redo"

    private static let movements: Set<TextEditCommand> = [
        .moveBackward, .moveForward, .moveWordBackward, .moveWordForward,
        .moveToLineStart, .moveToLineEnd,
    ]

    private static let deletions: Set<TextEditCommand> = [
        .deleteBackward, .deleteForward, .deleteWordBackward, .deleteWordForward,
        .deleteToWhitespaceBackward, .deleteToLineStart, .deleteToLineEnd,
    ]

    /// Whether the command only moves the cursor — so Shift with its key
    /// extends a selection.
    var isMovement: Bool { Self.movements.contains(self) }

    /// Whether the command deletes — so, with text selected, it takes the
    /// selection instead.
    var isDeletion: Bool { Self.deletions.contains(self) }
}

/// Which key performs which ``TextEditCommand``: data, apart from the
/// commands, as an Emacs keymap or Cocoa's `DefaultKeyBinding.dict` is.
///
/// Inputs read it from the environment, so a subtree can bind differently:
///
///     PromptInput(text: $draft)
///         .textKeymap(.standard.merging([.keyboard(.character("y"), .ctrl): .redo]))
public struct TextKeymap: Sendable, Equatable {
    private var bindings: [InputBinding: TextEditCommand]

    /// A keymap with exactly `bindings`.
    public init(_ bindings: [InputBinding: TextEditCommand]) {
        self.bindings = bindings
    }

    /// The command `event` performs, if any. Shift held with a movement key
    /// is the same movement, extending a selection in an input that keeps
    /// one: Shift+Left is Left.
    public func command(for event: KeyEvent) -> TextEditCommand? {
        if let command = bindings[.keyboard(event.key, event.modifiers)] {
            return command
        }
        guard event.modifiers.contains(.shift),
              let command = bindings[.keyboard(event.key, event.modifiers.subtracting(.shift))],
              command.isMovement else {
            return nil
        }
        return command
    }

    /// This keymap with `overrides` applied: a command binds its key, `nil`
    /// unbinds it.
    public func merging(_ overrides: [InputBinding: TextEditCommand?]) -> TextKeymap {
        var merged = self
        for (binding, command) in overrides {
            merged.bindings[binding] = command
        }
        return merged
    }

    /// readline's bindings, which Claude Code, Codex and Crush follow, and
    /// which macOS terminals' "natural text editing" presets send for
    /// Command and Option chords — Cmd+Left arrives as Ctrl+A, Option+Left
    /// as Alt+B:
    ///
    /// | Keys | Command |
    /// |------|---------|
    /// | Left, Ctrl+B / Right, Ctrl+F | a character back / forward |
    /// | Alt+Left, Alt+B, Ctrl+Left / Alt+Right, Alt+F, Ctrl+Right | a word |
    /// | Home, Ctrl+A / End, Ctrl+E | the line's start / end |
    /// | Backspace, Ctrl+H / Delete, Ctrl+D | delete a character |
    /// | Alt+Backspace / Alt+D, Alt+Delete | kill a word back / forward |
    /// | Ctrl+W | kill back to whitespace |
    /// | Ctrl+U / Ctrl+K | kill to the line's start / end |
    /// | Ctrl+Y | yank |
    /// | Ctrl+Z / Ctrl+Shift+Z | undo / redo |
    public static let standard = TextKeymap([
        .keyboard(.left, []): .moveBackward,
        .keyboard(.character("b"), .ctrl): .moveBackward,
        .keyboard(.right, []): .moveForward,
        .keyboard(.character("f"), .ctrl): .moveForward,
        .keyboard(.left, .alt): .moveWordBackward,
        .keyboard(.left, .ctrl): .moveWordBackward,
        .keyboard(.character("b"), .alt): .moveWordBackward,
        .keyboard(.right, .alt): .moveWordForward,
        .keyboard(.right, .ctrl): .moveWordForward,
        .keyboard(.character("f"), .alt): .moveWordForward,
        .keyboard(.home, []): .moveToLineStart,
        .keyboard(.character("a"), .ctrl): .moveToLineStart,
        .keyboard(.end, []): .moveToLineEnd,
        .keyboard(.character("e"), .ctrl): .moveToLineEnd,
        .keyboard(.backspace, []): .deleteBackward,
        .keyboard(.character("h"), .ctrl): .deleteBackward,
        .keyboard(.delete, []): .deleteForward,
        .keyboard(.character("d"), .ctrl): .deleteForward,
        .keyboard(.backspace, .alt): .deleteWordBackward,
        .keyboard(.character("d"), .alt): .deleteWordForward,
        .keyboard(.delete, .alt): .deleteWordForward,
        .keyboard(.character("w"), .ctrl): .deleteToWhitespaceBackward,
        .keyboard(.character("u"), .ctrl): .deleteToLineStart,
        .keyboard(.character("k"), .ctrl): .deleteToLineEnd,
        .keyboard(.character("y"), .ctrl): .yank,
        .keyboard(.character("z"), .ctrl): .undo,
        .keyboard(.character("z"), [.ctrl, .shift]): .redo,
    ])
}

/// The text killed last, which ``TextEditCommand/yank`` puts back — Cocoa's
/// kill buffer: one entry. A running app supplies one for all its inputs,
/// so a line killed in one field yanks into another; a subtree that must
/// not share, such as a field for a secret, gives itself its own:
///
///     SecretField().environment(\.killBuffer, KillBuffer())
public final class KillBuffer: Sendable, Equatable {
    private let killed = Mutex<[Character]>([])

    /// An empty kill buffer.
    public init() {}

    /// The kill buffer of inputs no running app supplies one to.
    static let detached = KillBuffer()

    /// What was killed last; empty before the first kill.
    public var text: String {
        String(lastKill)
    }

    func kill(_ text: ArraySlice<Character>) {
        guard !text.isEmpty else { return }
        killed.withLock { $0 = Array(text) }
    }

    var lastKill: [Character] {
        killed.withLock { $0 }
    }

    /// The same buffer: what one input kills, another yanks.
    public static func == (lhs: KillBuffer, rhs: KillBuffer) -> Bool {
        lhs === rhs
    }
}

/// What a text input reads from its environment to edit — the keymap, the
/// kill buffer and the boundary feedback — in one value its key handler
/// captures at body-evaluation time.
struct TextEditingContext: Sendable {
    let keymap: TextKeymap
    let killBuffer: KillBuffer
    let boundaryHit: BoundaryHitAction

    /// Performs `command` on `buffer`, giving the wall feedback itself: a
    /// caller sees a wall hit as a move that went nowhere.
    func perform(_ command: TextEditCommand, on buffer: inout TextEditingBuffer) -> TextEditResult {
        let result = buffer.perform(command, killBuffer: killBuffer)
        if case .hitWall(let reason) = result {
            boundaryHit(reason)
            return .moved
        }
        return result
    }
}

extension EnvironmentValues {
    var textEditing: TextEditingContext {
        TextEditingContext(keymap: textKeymap, killBuffer: killBuffer, boundaryHit: boundaryHit)
    }
}

extension TerminalView {
    /// Bind text-editing keys for this subtree.
    public func textKeymap(_ keymap: TextKeymap)
        -> ModifiedView<Self, EnvironmentModifier<TextKeymap>> {
        environment(\.textKeymap, keymap)
    }
}
