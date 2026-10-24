import Synchronization

/// A text-editing command, named apart from the keys that invoke it — the
/// shape of Cocoa's standard key-binding selectors and of readline's and
/// Emacs's commands. TextInput, TextArea and PromptInput perform the ones
/// declared here; a ``TextKeymap`` says which key performs which.
///
/// Open, like ``ActionID``: the raw value is the command's name, so a
/// command added later, or one an app defines, is just another name, and a
/// keymap can bind it without the framework knowing it in advance. An input
/// passes over a command it does not perform — to the next one bound to the
/// key, and after the last, to the app.
public struct TextEditCommand: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    /// The command's name, e.g. `"moveWordForward"` — what a keymap binds
    /// and what an input matches on.
    public let rawValue: String

    /// Names a command. Any string is accepted: one no input performs is
    /// passed over, not rejected.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Names a command with a string literal, so an app's own command is
    /// written `"insertTimestamp"` like the built-in ones.
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
    /// Up a row, in an input that holds more than one.
    public static let moveUp: TextEditCommand = "moveUp"
    /// Down a row, in an input that holds more than one.
    public static let moveDown: TextEditCommand = "moveDown"
    /// Up a screenful, in an input that scrolls.
    public static let pageUp: TextEditCommand = "pageUp"
    /// Down a screenful, in an input that scrolls.
    public static let pageDown: TextEditCommand = "pageDown"
    /// To the start of the text.
    public static let moveToDocumentStart: TextEditCommand = "moveToDocumentStart"
    /// To the end of the text.
    public static let moveToDocumentEnd: TextEditCommand = "moveToDocumentEnd"
    /// The previous entry of a prompt's history — readline's
    /// `previous-history`.
    public static let previousHistory: TextEditCommand = "previousHistory"
    /// The next entry of a prompt's history, and after the newest, the draft
    /// the user left — readline's `next-history`.
    public static let nextHistory: TextEditCommand = "nextHistory"
    /// A new line, in an input that holds more than one.
    public static let insertNewline: TextEditCommand = "insertNewline"
    /// Send what was typed, in an input that sends: a prompt.
    public static let submit: TextEditCommand = "submit"
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

    /// Every command the framework's inputs perform, in the order a listing
    /// of them reads best.
    public static let declared: [TextEditCommand] = [
        .moveBackward, .moveForward, .moveWordBackward, .moveWordForward,
        .moveToLineStart, .moveToLineEnd, .moveUp, .moveDown, .pageUp, .pageDown,
        .moveToDocumentStart, .moveToDocumentEnd, .previousHistory, .nextHistory,
        .insertNewline, .submit, .deleteBackward, .deleteForward, .deleteWordBackward,
        .deleteWordForward, .deleteToWhitespaceBackward, .deleteToLineStart, .deleteToLineEnd,
        .yank, .undo, .redo,
    ]

    private static let movements: Set<TextEditCommand> = [
        .moveBackward, .moveForward, .moveWordBackward, .moveWordForward,
        .moveToLineStart, .moveToLineEnd, .moveUp, .moveDown, .pageUp, .pageDown,
        .moveToDocumentStart, .moveToDocumentEnd,
    ]

    private static let deletions: Set<TextEditCommand> = [
        .deleteBackward, .deleteForward, .deleteWordBackward, .deleteWordForward,
        .deleteToWhitespaceBackward, .deleteToLineStart, .deleteToLineEnd,
    ]

    /// What ``TextEditingBuffer`` performs; the rest — rows, pages, history,
    /// submit, undo — belong to an input that has them.
    private static let bufferCommands: Set<TextEditCommand> = deletions.union([
        .moveBackward, .moveForward, .moveWordBackward, .moveWordForward,
        .moveToLineStart, .moveToLineEnd, .moveToDocumentStart, .moveToDocumentEnd,
        .yank, .insertNewline,
    ])

    /// Whether the command only moves the cursor — so Shift with its key
    /// extends a selection.
    var isMovement: Bool { Self.movements.contains(self) }

    /// Whether the command deletes — so, with text selected, it takes the
    /// selection instead.
    var isDeletion: Bool { Self.deletions.contains(self) }

    /// Whether ``TextEditingBuffer`` performs the command.
    var isBufferCommand: Bool { Self.bufferCommands.contains(self) }
}

/// Which keys perform which ``TextEditCommand``s: data, apart from the
/// commands, as an Emacs keymap or Cocoa's `DefaultKeyBinding.dict` is.
///
/// A key binds an ordered list of commands, and the focused input performs
/// the first that means something to it — as a key goes up Cocoa's responder
/// chain. Enter is `[.submit, .insertNewline]`: a prompt sends, an editor
/// starts a line, and a single-line field, performing neither, leaves the
/// key to the app.
///
/// Inputs read it from the environment, so a subtree can bind differently —
/// here, a prompt that takes Enter as a new line and sends on Shift+Enter:
///
///     PromptInput(text: $draft)
///         .textKeymap(.standard.merging([
///             .keyboard(.enter, []): [.insertNewline],
///             .keyboard(.enter, .shift): [.submit],
///         ]))
public struct TextKeymap: Sendable, Equatable {
    /// Each bound key with the commands it tries, in order.
    public private(set) var bindings: [InputBinding: [TextEditCommand]]

    /// A keymap with exactly `bindings`.
    public init(_ bindings: [InputBinding: [TextEditCommand]]) {
        self.bindings = bindings
    }

    /// The commands `event` performs, in the order an input tries them;
    /// empty when it is not bound. Shift held with a movement key is the same
    /// movement, extending a selection in an input that keeps one.
    public func commands(for event: KeyEvent) -> [TextEditCommand] {
        if let commands = bindings[.keyboard(event.key, event.modifiers)] {
            return commands
        }
        guard event.modifiers.contains(.shift),
              let unshifted = bindings[.keyboard(event.key, event.modifiers.subtracting(.shift))] else {
            return []
        }
        return unshifted.filter(\.isMovement)
    }

    /// This keymap with `overrides` applied: each key gets its list of
    /// commands, and an empty list unbinds it.
    public func merging(_ overrides: [InputBinding: [TextEditCommand]]) -> TextKeymap {
        var merged = self
        for (binding, commands) in overrides {
            merged.bindings[binding] = commands.isEmpty ? nil : commands
        }
        return merged
    }

    /// readline's bindings, which Claude Code, Codex and Crush follow, and
    /// which macOS terminals' "natural text editing" presets send for
    /// Command and Option chords — Cmd+Left arrives as Ctrl+A, Option+Left
    /// as Alt+B:
    ///
    /// | Keys | Commands |
    /// |------|----------|
    /// | Left, Ctrl+B / Right, Ctrl+F | a character back / forward |
    /// | Alt+Left, Alt+B, Ctrl+Left / Alt+Right, Alt+F, Ctrl+Right | a word |
    /// | Home, Ctrl+A / End, Ctrl+E | the line's start / end |
    /// | Up, Ctrl+P / Down, Ctrl+N | a row, then a prompt's history |
    /// | Page Up / Page Down | a screenful |
    /// | Ctrl+Home, Alt+< / Ctrl+End, Alt+> | the text's start / end |
    /// | Enter | submit, or a new line |
    /// | Enter with any modifier | a new line |
    /// | Backspace, Ctrl+H / Delete, Ctrl+D | delete a character |
    /// | Alt+Backspace / Alt+D, Alt+Delete | kill a word back / forward |
    /// | Ctrl+W | kill back to whitespace |
    /// | Ctrl+U / Ctrl+K | kill to the line's start / end |
    /// | Ctrl+Y | yank |
    /// | Ctrl+Z / Ctrl+Shift+Z | undo / redo |
    public static let standard: TextKeymap = {
        var bindings: [InputBinding: [TextEditCommand]] = [
            .keyboard(.left, []): [.moveBackward],
            .keyboard(.character("b"), .ctrl): [.moveBackward],
            .keyboard(.right, []): [.moveForward],
            .keyboard(.character("f"), .ctrl): [.moveForward],
            .keyboard(.left, .alt): [.moveWordBackward],
            .keyboard(.left, .ctrl): [.moveWordBackward],
            .keyboard(.character("b"), .alt): [.moveWordBackward],
            .keyboard(.right, .alt): [.moveWordForward],
            .keyboard(.right, .ctrl): [.moveWordForward],
            .keyboard(.character("f"), .alt): [.moveWordForward],
            .keyboard(.home, []): [.moveToLineStart],
            .keyboard(.character("a"), .ctrl): [.moveToLineStart],
            .keyboard(.end, []): [.moveToLineEnd],
            .keyboard(.character("e"), .ctrl): [.moveToLineEnd],
            .keyboard(.up, []): [.moveUp, .previousHistory],
            .keyboard(.character("p"), .ctrl): [.moveUp, .previousHistory],
            .keyboard(.down, []): [.moveDown, .nextHistory],
            .keyboard(.character("n"), .ctrl): [.moveDown, .nextHistory],
            .keyboard(.pageUp, []): [.pageUp],
            .keyboard(.pageDown, []): [.pageDown],
            .keyboard(.home, .ctrl): [.moveToDocumentStart],
            .keyboard(.character("<"), .alt): [.moveToDocumentStart],
            .keyboard(.end, .ctrl): [.moveToDocumentEnd],
            .keyboard(.character(">"), .alt): [.moveToDocumentEnd],
            .keyboard(.enter, []): [.submit, .insertNewline],
            .keyboard(.backspace, []): [.deleteBackward],
            .keyboard(.character("h"), .ctrl): [.deleteBackward],
            .keyboard(.delete, []): [.deleteForward],
            .keyboard(.character("d"), .ctrl): [.deleteForward],
            .keyboard(.backspace, .alt): [.deleteWordBackward],
            .keyboard(.character("d"), .alt): [.deleteWordForward],
            .keyboard(.delete, .alt): [.deleteWordForward],
            .keyboard(.character("w"), .ctrl): [.deleteToWhitespaceBackward],
            .keyboard(.character("u"), .ctrl): [.deleteToLineStart],
            .keyboard(.character("k"), .ctrl): [.deleteToLineEnd],
            .keyboard(.character("y"), .ctrl): [.yank],
            .keyboard(.character("z"), .ctrl): [.undo],
            .keyboard(.character("z"), [.ctrl, .shift]): [.redo],
        ]
        // Every modified Enter is a new line. Terminal.app cannot tell
        // Shift+Enter from Enter without the kitty keyboard protocol, so
        // Option+Enter is the one that works in every terminal.
        let modifiers: [KeyModifiers] = [.shift, .alt, .ctrl]
        for mask in 1..<(1 << modifiers.count) {
            let held = modifiers.indices.filter { mask & (1 << $0) != 0 }
                .reduce(into: KeyModifiers()) { $0.insert(modifiers[$1]) }
            bindings[.keyboard(.enter, held)] = [.insertNewline]
        }
        return TextKeymap(bindings)
    }()
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
        let keymap = allowsUserKeymap ? userKeymap.applied(to: textKeymap) : textKeymap
        return TextEditingContext(keymap: keymap, killBuffer: killBuffer, boundaryHit: boundaryHit)
    }
}

extension TerminalView {
    /// Bind text-editing keys for this subtree.
    public func textKeymap(_ keymap: TextKeymap)
        -> ModifiedView<Self, EnvironmentModifier<TextKeymap>> {
        environment(\.textKeymap, keymap)
    }
}
