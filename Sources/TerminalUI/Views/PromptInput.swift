import Foundation

/// Which axis arrow Up/Down navigates on.
///
/// `.display` matches editors (vim visual lines, VS Code, Claude Code):
/// one arrow step = one terminal row, so a soft-wrapped logical line splits
/// into several navigable rows. `.logical` treats each `\n`-delimited line
/// as a single step; soft-wrapped rows are skipped.
public enum PromptArrowMode: Sendable, Equatable {
    /// One arrow step moves one terminal display row; soft-wrapped lines
    /// take several steps to cross. The default.
    case display
    /// One arrow step moves one `\n`-delimited logical line; soft-wrapped
    /// continuation rows are skipped.
    case logical
}

/// How the prompt picks its rendered height.
///
/// Default `.fixed(8)` grows with content up to 8 display rows and scrolls
/// once content exceeds the cap — matches Claude Code / Codex. Use
/// `.unbounded` when the parent layout can absorb arbitrary growth (chat
/// panel in a ScrollView). `.container` and `.containerCapped` honour the
/// container's reported height, which is only reliable when the parent
/// explicitly sizes the prompt via `.frame()`.
public enum PromptHeightPolicy: Sendable, Equatable {
    /// Fixed ceiling in display rows. Recommended for VStack layouts.
    /// Content beyond the ceiling scrolls vertically to keep the cursor
    /// visible.
    case fixed(Int)
    /// Grow with content without any cap. The prompt's height equals the
    /// wrapped display-row count. Pair with an outer `ScrollView` if the
    /// parent cannot absorb arbitrary growth.
    case unbounded
    /// Grow to the container's reported height, with no hard ceiling. Use
    /// when the parent explicitly sizes the prompt with `.frame()`.
    case container
    /// Grow up to `min(cap, container.height)`. Use inside fixed-frame
    /// parents only.
    case containerCapped(Int)

    /// Whether the policy grows to the height of the room it is given — and
    /// so needs a reader that is told that height.
    var readsContainer: Bool {
        switch self {
        case .fixed, .unbounded: false
        case .container, .containerCapped: true
        }
    }
}

/// What ``PromptInput`` draws at the start of each of its rows.
///
/// The default is the input's `prompt` glyph on the first row and a blank
/// indent of the same width beneath — ``glyph(_:)``. An agent composer often
/// wants a column that says more: Crush draws `>` on the first row while the
/// prompt is focused and `:::` on every other row, dimmed when focus is
/// elsewhere. That column is a function of the row and of focus:
///
/// ```swift
/// PromptInput(text: $draft, state: $promptState)
///     .promptPrefix(PromptPrefix(width: 4) { row in
///         switch (row.index, row.isFocused) {
///         case (0, true): [TextSpan("  > ", foreground: row.theme.success, bold: true)]
///         case (_, true): [TextSpan("::: ", foreground: row.theme.successSubtle)]
///         default: [TextSpan("::: ", foreground: row.theme.foregroundMuted)]
///         }
///     })
/// ```
///
/// Every row's prefix occupies ``width`` columns; the text wraps in what is
/// left. Rows the prompt reserves past its text (see `minimumHeight`) carry
/// a prefix too, so a three-row composer reads as three rows when empty.
public struct PromptPrefix: Sendable {
    /// One row of the prompt, as its prefix sees it.
    public struct Row: Sendable {
        /// The row's position in the wrapped input, 0 for the first. Rows
        /// scrolled out of view keep their numbers, so the first row's
        /// prefix scrolls away with the text it begins.
        public let index: Int
        /// Whether the prompt holds keyboard focus.
        public let isFocused: Bool
        /// The theme in force where the prompt is drawn.
        public let theme: any Theme
    }

    /// Columns every row's prefix occupies.
    public let width: Int
    private let content: @Sendable (Row) -> [TextSpan]

    /// A prefix `width` columns wide whose spans for each row `content`
    /// decides. Spans narrower than `width` are padded; wider ones clip.
    public init(width: Int, _ content: @escaping @Sendable (Row) -> [TextSpan]) {
        self.width = max(0, width)
        self.content = content
    }

    /// `glyph` and a space on the first row in the theme's accent, a blank
    /// indent of the same width on the rest — ``PromptInput``'s own look.
    public static func glyph(_ glyph: String) -> PromptPrefix {
        let width = glyph.displayWidth + 1
        return PromptPrefix(width: width) { row in
            row.index == 0
                ? [TextSpan("\(glyph) ", foreground: row.theme.accent, bold: true)]
                : [TextSpan(String(repeating: " ", count: width))]
        }
    }

    /// The row's spans, exactly ``width`` columns wide.
    func spans(for row: Row) -> [TextSpan] {
        var spans: [TextSpan] = []
        var used = 0
        for span in content(row) where used < width {
            let room = width - used
            var text = ""
            var taken = 0
            for character in span.text {
                let cells = character.displayWidth
                guard taken + cells <= room else { break }
                text.append(character)
                taken += cells
            }
            var clipped = span
            clipped.text = text
            spans.append(clipped)
            used += taken
        }
        if used < width {
            spans.append(TextSpan(String(repeating: " ", count: width - used)))
        }
        return spans
    }
}

extension TerminalView {
    /// Sets what every ``PromptInput`` in this subtree draws at the start of
    /// its rows, in place of its `prompt` glyph — see ``PromptPrefix``.
    public func promptPrefix(_ prefix: PromptPrefix)
        -> ModifiedView<Self, EnvironmentModifier<PromptPrefix?>> {
        environment(\.promptPrefix, prefix)
    }
}

/// How `PromptInput` presents pasted content. Drives the threshold +
/// rendering decision at the per-paste level.
///
/// User direction (verbatim 2026-04-27):
/// > *"by default we opt for claude code approach but otherwise we
/// > also allow configurable, the user should be able to define what
/// > they consider the proper trigger easily"*
///
/// Defaults match Claude Code: a paste collapses to a marker if it
/// has 1+ newline OR exceeds `chars` characters. Single-line pastes
/// under the threshold land inline (current behaviour).
public enum PasteMode: Equatable, Sendable {
    /// Collapse the paste to a marker when EITHER threshold is hit.
    /// `lines` counts newline-separated logical rows in the payload
    /// (so a single `\n` triggers `lines = 2`); `chars` counts UTF-8
    /// characters. Either condition fires the marker.
    ///
    /// Claude Code defaults: `lines = 2, chars = 200`. SwiftUI parity
    /// is N/A — Claude Code is the reference, this is its mirror.
    case placeholder(lines: Int = 2, chars: Int = 200)
    /// Always render paste content inline (the pre-marker behaviour).
    /// Useful for prompts that want the user to see the full pasted
    /// text every time (e.g. command-bar autocomplete previews).
    case inline
    /// Collapse every paste regardless of size. Useful when the prompt
    /// is meant to look "atomic" (chat-style with ZERO inline paste).
    case alwaysPlaceholder

    /// Convenience constructor matching Claude Code's defaults exactly.
    public static let claudeCode = PasteMode.placeholder(lines: 2, chars: 200)

    /// Decide whether `payload` should collapse under this mode.
    public func shouldCollapse(_ payload: String) -> Bool {
        switch self {
        case .inline: return false
        case .alwaysPlaceholder: return true
        case .placeholder(let lineThreshold, let charThreshold):
            // `lines >= threshold` matches the design's "≥1 newline →
            // collapse" rule when default threshold = 2 (since a single
            // newline produces 2 lines).
            let lineCount = payload.split(separator: "\n", omittingEmptySubsequences: false).count
            if lineCount >= lineThreshold { return true }
            if payload.count > charThreshold { return true }
            return false
        }
    }
}

/// Whether the auto-hint row beneath the prompt ("paste again to
/// expand") is rendered. Library users opt out via `.pasteHint(.hidden)`.
public enum PasteHintVisibility: Equatable, Sendable {
    /// Render the hint row when the cursor sits adjacent to a collapsed
    /// paste marker. The default.
    case visible
    /// Never render the hint row; the prompt keeps its content height.
    case hidden
}

/// Library-author-facing translation seam for PromptInput's
/// marker + hint strings. Default English implementation
/// (`DefaultPromptInputLocalizer`) ships verbatim; override to
/// localize for other languages or to customize the marker shape.
///
/// User direction (verbatim 2026-04-26):
/// > *"Notice this text might need to be translatable otherwise
/// > writing a tui for different locals might be difficult."*
///
/// Sendable so app authors can ship custom implementations as
/// reference types without leaking actor-isolation concerns
/// through the env value plumbing.
public protocol PromptInputLocalizer: Sendable {
    /// Marker for a multi-line text paste — e.g. `[Pasted text #1 +24 lines]`.
    /// `id` is the reference's monotonic counter; `lineCount` is the
    /// underlying buffer's `\n`-separated line count.
    func textMarker(id: Int, lineCount: Int) -> String

    /// Marker for a single-line paste over the chars threshold —
    /// e.g. `[Pasted text #2 +250 chars]`.
    func charsMarker(id: Int, charCount: Int) -> String

    /// Marker for an image paste — e.g. `[Image #3]`.
    func imageMarker(id: Int) -> String

    /// Hint row text shown beneath the prompt when the cursor sits
    /// adjacent to a collapsed reference. Default English: "paste
    /// again to expand".
    func pasteAgainHint() -> String
}

/// Default English implementation of `PromptInputLocalizer`. The
/// strings here are the spec'd defaults from the design memo
/// 2026-04-26 (`project_promptinput_paste_design_apr26.md`).
public struct DefaultPromptInputLocalizer: PromptInputLocalizer {
    /// Creates the stock English localizer. Stateless — every instance
    /// produces identical strings.
    public init() {}

    /// `[Pasted text #<id> +<lineCount> lines]` — `id` is the reference's,
    /// so two insertions of one buffer get different numbers.
    public func textMarker(id: Int, lineCount: Int) -> String {
        "[Pasted text #\(id) +\(lineCount) lines]"
    }

    /// `[Pasted text #<id> +<charCount> chars]`, for a single-line paste
    /// long enough to collapse.
    public func charsMarker(id: Int, charCount: Int) -> String {
        "[Pasted text #\(id) +\(charCount) chars]"
    }

    /// `[Image #<id>]`; an image has no length worth stating.
    public func imageMarker(id: Int) -> String {
        "[Image #\(id)]"
    }

    /// `paste again to expand` — lower case, with no trailing punctuation,
    /// as it sits in a hint row rather than a sentence.
    public func pasteAgainHint() -> String {
        "paste again to expand"
    }
}

/// Content held by a `PasteBuffer`. Only text is pasted today; image paste
/// would arrive through a separate input pipeline (kitty graphics /
/// OSC 52). The case shape is forward-compatible so the consumer-facing
/// API stays stable if it does.
public enum PasteBufferContent: Hashable, Equatable, Sendable {
    /// Plain-text paste payload, stored verbatim (newlines included).
    case text(String)
    /// Image buffer — opaque payload bytes plus mime type. The actual
    /// kitty graphics protocol / OSC 52 clipboard wiring lives in its
    /// own pipeline; this case is the stable
    /// data-shape side so the consumer-facing API doesn't churn when
    /// image paste arrives.
    case image(bytes: Data, mimeType: String)
}

/// One paste payload (or future selection-collapsed buffer) stored in the
/// PromptInput's per-state pool. Buffers are append-only and survive
/// reference deletion — that's what lets `Backspace` on a marker
/// "delete the presentation" without losing the data, so the same
/// buffer can be re-inserted later.
///
/// User design quote (verbatim 2026-04-26):
/// > *"deleting regions don't delete the buffer, they delete the
/// > presentation, thus allowing to re-apply"*
public struct PasteBuffer: Identifiable, Equatable, Sendable {
    /// A buffer's identity: a counter value from its prompt's state, so two
    /// prompts may each hold a buffer 1.
    public typealias ID = Int
    /// Buffer identity — allocated from ``PromptInputState/nextBufferID``,
    /// monotonic and never reused within a prompt's lifetime.
    public let id: ID
    /// The stored payload. Immutable once pooled; expansion and collapse
    /// only change the referencing ``PasteReference``.
    public let content: PasteBufferContent
    /// Content hash for dedupe. Same payload pasted twice reuses the
    /// existing buffer (per the C2 sign-off in the design memory).
    /// Plain Hasher-based hash is enough for collision-resistance at
    /// session scope; we don't need a cryptographic hash.
    public let contentHash: Int

    /// Creates a pooled buffer; `contentHash` is computed from `content`
    /// at construction so dedupe lookups never re-hash the payload.
    public init(id: ID, content: PasteBufferContent) {
        self.id = id
        self.content = content
        self.contentHash = Self.hash(content)
    }

    /// The dedupe hash for a payload — the same function that populates
    /// `contentHash`, exposed so callers can probe the pool before
    /// allocating a new buffer. Session-scoped `Hasher` output, not stable
    /// across processes.
    public static func hash(_ content: PasteBufferContent) -> Int {
        var hasher = Hasher()
        hasher.combine(content)
        return hasher.finalize()
    }
}

/// A view of a buffer at a specific position in the binding text. One
/// buffer can be inserted multiple times — each insertion gets its own
/// `Reference`. Only paste creates references.
///
/// `range` is stored as `(start: Int, length: Int)` rather than
/// `Range<String.Index>` because the binding is mutable (cursor edits
/// shift positions); integer offsets survive mutation when we re-anchor
/// references after each text change. Length is in UTF-8 view characters,
/// matching how the binding's String index counts.
public struct PasteReference: Identifiable, Equatable, Sendable {
    /// A reference's identity: a counter value from its prompt's state,
    /// separate from the buffer counter — the number markers show.
    public typealias ID = Int
    /// Reference identity — allocated from
    /// ``PromptInputState/nextReferenceID``, monotonic per prompt.
    public let id: ID
    /// The pooled ``PasteBuffer`` this reference presents. Multiple
    /// references may share one buffer.
    public let bufferID: PasteBuffer.ID
    /// Start offset in the expanded binding text (character count from
    /// `text.startIndex`). Reference's range is `[start, start + length)`.
    public var start: Int
    /// Length in characters of the underlying buffer's expanded text
    /// (the number of characters the marker stands in for). Image
    /// references have length 0 — their marker is a synthetic insertion
    /// that occupies a sentinel character in the binding.
    public var length: Int
    /// `true` when the reference's underlying text is rendered inline.
    /// `false` (default) collapses to a marker (`[Pasted text #N +M lines]`).
    /// Toggled by "paste again to expand".
    public var isExpanded: Bool
    /// Optional human-readable name. Nothing sets it yet, so markers
    /// render with their `#N` numeric tag.
    public var name: String?

    /// Creates a reference into the buffer pool. Defaults produce the
    /// A collapsed marker with no name.
    public init(
        id: ID,
        bufferID: PasteBuffer.ID,
        start: Int,
        length: Int,
        isExpanded: Bool = false,
        name: String? = nil
    ) {
        self.id = id
        self.bufferID = bufferID
        self.start = start
        self.length = length
        self.isExpanded = isExpanded
        self.name = name
    }
}

/// Snapshot of state suitable for storing in `history` so ↑-recall
/// restores both the text and the reference set with original IDs.
public struct PromptInputHistoryEntry: Equatable, Sendable {
    /// The submitted text, exactly as it read at submit time (references
    /// still collapsed to their markers).
    public let text: String
    /// The paste buffers referenced by this entry, preserved with their
    /// original IDs so recall re-links markers to content.
    public let buffers: [PasteBuffer]
    /// The reference set live at submit time. Empty for plain-text entries.
    public let references: [PasteReference]

    /// Creates a history entry. Buffer and reference sets default to empty
    /// for plain-text submissions.
    public init(
        text: String,
        buffers: [PasteBuffer] = [],
        references: [PasteReference] = []
    ) {
        self.text = text
        self.buffers = buffers
        self.references = references
    }
}

/// Cursor, scroll, history, and paste-buffer state for a ``PromptInput``.
///
/// Create one per prompt and pass it as a `Binding` so the state survives
/// re-evaluations. Submitted entries accumulate in `history` for ↑-recall;
/// the paste-buffer pool is append-only, which is what lets a deleted
/// marker's content be restored later without ever having left the state.
public struct PromptInputState: Equatable, Sendable {
    /// Cursor column within the current text (logical, counts characters
    /// left of the cursor in `lines[cursorRow]`).
    public var cursorCol: Int = 0
    /// Cursor row within the logical `\n`-split `lines` array.
    public var cursorRow: Int = 0
    /// Top visible display row (post-wrap). Unit is display rows, not
    /// logical lines, so scrolling inside a single long wrapped line works.
    public var scrollDisplayRow: Int = 0
    /// Command history — index 0 is most recent. New rich entries
    /// preserve buffers + references for history recall.
    public var history: [PromptInputHistoryEntry] = []
    /// Current history navigation index (-1 = live input, 0 = most recent).
    public var historyIndex: Int = -1
    /// Text saved when entering history so arrow-down can restore it.
    public var savedInput: String = ""
    /// The paste markers in ``savedInput``, put back with it.
    var savedReferences: [PasteReference] = []
    /// Buffer pool — append-only across the prompt's lifetime. References
    /// point into here; deleting a reference does NOT delete its buffer
    /// so it can be re-inserted. Indexed by `id`.
    public var buffers: [PasteBuffer] = []
    /// Live references in the current text. Empty when no paste has
    /// happened yet (or all references were deleted).
    public var references: [PasteReference] = []
    /// Monotonic counter for next-allocated buffer ID. Never rewound,
    /// even when buffers logically disappear from the active set.
    public var nextBufferID: PasteBuffer.ID = 1
    /// Monotonic counter for next-allocated reference ID. Same posture
    /// as `nextBufferID`. The counter is shared across kinds (text +
    /// future image) per the design's "single shared counter" decision.
    public var nextReferenceID: PasteReference.ID = 1

    /// Creates empty prompt state: cursor at origin, no history, empty
    /// buffer pool, ID counters starting at 1.
    public init() {}
}

/// A chat-style multi-line input that grows with content and submits on
/// Enter. Designed for CLI tool prompts — Claude Code, Codex, OpenCode style.
///
/// The command-prompt member of the text-entry trio: ``TextInput`` is a
/// one-line form field, ``TextArea`` a document editor where Enter inserts
/// a newline — here Enter means "send". The prompt joins the Tab order via
/// the framework's `.focusable` machinery, and while it holds focus every
/// printable key belongs to the buffer: an app must not claim bare letters
/// as global chords while a prompt is focused (gate such chords on the
/// field being empty or unfocused instead).
///
/// Features:
/// - Soft-wraps content at the container width; input grows downward up to
///   the ``PromptHeightPolicy`` ceiling, then scrolls to keep the cursor
///   visible.
/// - `❯` prompt indicator on the left, continuation rows indent to match —
///   or any per-row column, via ``PromptPrefix`` and `.promptPrefix(_:)`.
/// - A block cursor with per-display-row projection, drawn while the prompt
///   holds focus.
/// - An optional placeholder while the buffer is empty, and an optional
///   floor on its height (`minimumHeight`).
/// - Colours from the theme: the accent marks the prompt and cursor,
///   `foreground` the text, `foregroundMuted` continuation markers and
///   collapsed pastes, `foregroundFaint` the placeholder.
/// - Enter submits the trimmed text through `onSubmit` and clears the
///   buffer; Shift+Enter / Option+Enter / Ctrl+Enter insert a newline.
///   (Shift+Enter detection requires a terminal with kitty keyboard or similar;
///    Option+Enter is the universal fallback — sent as `ESC\r`.)
/// - Up arrow from the top display row recalls submitted history; Down
///   walks back toward the live input.
/// - Large pastes collapse to a `[Pasted text #N +M lines]` marker per
///   ``PasteMode``; pasting the same content again expands it.
/// - Edits with the environment's ``TextKeymap``, ``TextKeymap/standard``
///   unless a subtree sets one.
/// - Optional context badge on the right (project name, mode).
///
/// Usage — the Chat example's prompt bar, bound to an `@Observable` model:
/// ```
/// @TerminalState var promptState = PromptInputState()
///
/// PromptInput(
///     text: Binding(get: { model.draft }, set: { model.draft = $0 }),
///     state: $promptState,
///     prompt: "❯",
///     heightPolicy: .fixed(3),
///     onSubmit: { _ in model.sendUserMessage() }
/// )
/// ```
public struct PromptInput: TerminalView {
    /// The buffer, always in *expanded* form — collapsed paste markers are
    /// purely a display concern, so `onSubmit`, history, and any other
    /// reader of this binding see the full pasted text.
    public let text: Binding<String>
    /// Cursor, scroll, history, and paste buffers — see ``PromptInputState``.
    public let state: Binding<PromptInputState>
    /// Glyph drawn at the start of the first row; continuation rows indent
    /// by its width. Defaults to `❯`. A `.promptPrefix(_:)` set above the
    /// input replaces it.
    public let prompt: String
    /// Shown, faint, while the buffer is empty.
    public let placeholder: String?
    /// Rows the prompt occupies even when its text needs fewer — the rows
    /// past the text carry the prefix's continuation, as an agent composer
    /// that is three rows tall when empty. Defaults to 1.
    public let minimumHeight: Int
    /// Optional context badge (project name, mode) rendered to the right —
    /// only while the input is a single empty-ish row, so it never overlaps
    /// wrapped content.
    public let badge: String?
    /// Legacy cap kept for source compatibility. When non-nil, overrides
    /// `heightPolicy` with `.fixed(n)` — matches the pre-constructor.
    public let maxVisibleLines: Int?
    /// How the prompt picks its rendered height — see ``PromptHeightPolicy``.
    public let heightPolicy: PromptHeightPolicy
    /// Whether Up/Down step display rows or logical lines — see
    /// ``PromptArrowMode``.
    public let arrowMode: PromptArrowMode
    /// Called with the trimmed buffer when plain Enter is pressed on
    /// non-empty content. The buffer clears and the entry joins history
    /// before this runs; empty or whitespace-only input never fires it.
    public let onSubmit: ((String) -> Void)?

    /// The keymap, kill ring and boundary feedback the prompt edits with.
    /// Read at body-eval time for the handlers, which run when no
    /// environment is bound. Set with `.textKeymap(_:)` and
    /// `.boundaryFeedback(_:)`.
    @TerminalEnvironment(\.textEditing) var textEditing

    /// Paste presentation mode. Default `.claudeCode` collapses
    /// pastes with newlines or > 200 chars into a marker. Override
    /// per-subtree via `.pasteMode(.inline)` etc.
    @TerminalEnvironment(\.pasteMode) var pasteMode

    /// Translation seam for marker + hint strings. Default English
    /// ships via `DefaultPromptInputLocalizer`; override per-subtree
    /// via `.promptInputLocalizer(_:)`.
    @TerminalEnvironment(\.promptInputLocalizer) var localizer

    /// Whether the auto-hint row beneath the prompt is rendered when
    /// cursor sits adjacent to a collapsed reference.
    @TerminalEnvironment(\.pasteHint) var pasteHint

    /// Replaces the `prompt` glyph when set — see ``PromptPrefix``.
    @TerminalEnvironment(\.promptPrefix) var promptPrefix

    @TerminalEnvironment(\.theme) var theme

    fileprivate static let cursorChar: Character = "\u{2588}"  // █

    /// Creates a prompt bound to its text and state.
    ///
    /// `text` is the live buffer; `state` holds cursor/scroll/history and
    /// must outlive re-evaluations (bind it to `@TerminalState` or an
    /// `@Observable` model). `prompt` is the left indicator glyph
    /// (default `❯`); `placeholder` shows, faint, while the buffer is empty;
    /// `badge` is an optional right-aligned context tag. `minimumHeight` is
    /// the fewest rows the prompt occupies. `maxVisibleLines` is a legacy alias for `.fixed(n)` and, when
    /// non-nil, overrides `heightPolicy`. Enter fires `onSubmit` with the
    /// trimmed text; Shift/Option/Ctrl+Enter insert a newline.
    public init(
        text: Binding<String>,
        state: Binding<PromptInputState>,
        prompt: String = "\u{276F}",
        placeholder: String? = nil,
        badge: String? = nil,
        maxVisibleLines: Int? = nil,
        minimumHeight: Int = 1,
        heightPolicy: PromptHeightPolicy = .fixed(8),
        arrowMode: PromptArrowMode = .display,
        onSubmit: ((String) -> Void)? = nil
    ) {
        self.text = text
        self.state = state
        self.prompt = prompt
        self.placeholder = placeholder
        self.minimumHeight = max(1, minimumHeight)
        self.badge = badge
        self.maxVisibleLines = maxVisibleLines
        self.heightPolicy = heightPolicy
        self.arrowMode = arrowMode
        self.onSubmit = onSubmit
    }

    @_documentation(visibility: internal)
    public var body: some TerminalView {
        // Soft-wrap needs the container width, which a reader supplies (see
        // `inputReader`). We do NOT apply `.frame(height:)` — the spans
        // emitted by `buildDisplay` already contain exactly `renderedHeight`
        // newline-separated display rows, and `Text` sizes itself from span
        // newlines (TextArea uses the same trick), so the prompt is as tall
        // as its wrapped text at the width it is given.
        //
        // Capture boundary-feedback env at body-eval time; the GR
        // closure runs later when GraphContext.currentEnvironment may
        // be nil (`feedback_bindings_in_geometryreader.md`).
        let textEditing = self.textEditing
        // Capture the hint visibility + localizer up-front so the
        // VStack body sees a stable value (the GR closure inside
        // would re-read env at rebuild time, which is later than
        // body eval — same `feedback_bindings_in_geometryreader.md`
        // rule).
        let hintVisible = pasteHint == .visible
        let hintLocalizer = localizer
        let st = state.get()
        let cursorAdjacentToCollapsed = Self.isCursorAtCollapsedRightEdge(state: st, expandedText: text.get())
        // The two families of height policy need different readers. A
        // `.fixed` or `.unbounded` prompt grows with its text up to a cap, so
        // its height follows from its width alone — a `WidthReader`, which a
        // stack measures. `.container` and `.containerCapped` grow to the
        // room they are given, so they take it from a greedy `GeometryReader`;
        // their documentation pairs them with a `.frame`, which is that room.
        // Compose the prompt + optional auto-hint row. The hint
        // surfaces "paste again to expand" beneath the input when
        // the cursor sits at the right edge of a collapsed
        // reference. `.pasteHint(.hidden)` opts out per-subtree.
        return VStack {
            inputReader(textEditing: textEditing)
            if hintVisible && cursorAdjacentToCollapsed {
                Text(hintLocalizer.pasteAgainHint())
                    .foreground(theme.foregroundMuted)
            }
        }
    }

    /// The reader the input is built inside, chosen by height policy — see
    /// the comment in `body`.
    @TerminalViewBuilder
    private func inputReader(textEditing: TextEditingContext) -> some TerminalView {
        if maxVisibleLines == nil, heightPolicy.readsContainer {
            GeometryReader { size in
                self.inputField(width: size.width, containerHeight: size.height,
                                textEditing: textEditing)
            }
        } else {
            WidthReader { width in
                self.inputField(width: width, containerHeight: 0,
                                textEditing: textEditing)
            }
        }
    }

    /// The input itself — wrapped, projected, and bound to its keys — built for
    /// a width and, under the policies that read it, the container's height.
    /// `containerHeight` is 0 when the prompt's policy does not depend on it.
    private func inputField(width: Int, containerHeight: Int,
                            textEditing: TextEditingContext) -> some TerminalView {
        let prefix = resolvedPrefix
        let contentWidth = max(1, width - prefix.width)
        let st = self.state.get()
        // Project the EXPANDED binding text + reference set into
        // the COLLAPSED display text. Markers replace each
        // collapsed reference's range with `[Pasted text #N +M
        // lines]`. The mapping is also used to translate cursor
        // (row, col) in expanded space → display space.
        let projection = Self.projectCollapsedDisplay(
            expandedText: self.text.get(),
            references: st.references,
            buffers: st.buffers,
            localizer: localizer
        )
        let lines = TextLines.split(projection.displayText)
        let wraps = Self.wrapPerLine(lines: lines, width: contentWidth)
        let totalDisplayRows = wraps.reduce(0) { $0 + $1.count }
        let ceiling = Self.resolveCeiling(
            policy: self.heightPolicy,
            legacy: self.maxVisibleLines,
            containerHeight: containerHeight,
            contentRows: totalDisplayRows
        )
        let renderedHeight = max(self.minimumHeight, min(max(1, ceiling), max(1, totalDisplayRows)))
        // The rows read focus, so they are a view of their own under the
        // focusable — `isFocused` reports to the content *below* the focusable
        // that holds it. They are handed values, not the bindings: a body that
        // read the bindings would be re-run alone on the next keystroke, with
        // this build's wrapping and the new text.
        let rows = PromptRows(
            text: self.text.get(),
            state: st,
            placeholder: self.placeholder,
            badge: self.badge,
            prefix: prefix,
            lines: lines,
            wraps: wraps,
            totalDisplayRows: totalDisplayRows,
            visibleLines: renderedHeight,
            projection: projection
        )
        return rows
            .focusable()
            // A click puts the cursor on the character it lands on.
            .onClick { [state] x, y in
                var current = state.get()
                (current.cursorRow, current.cursorCol) = Self.cursor(
                    atColumn: x - prefix.width, row: y, rows: rows)
                state.set(current)
            }
            .onKeyPress { [text, state, onSubmit, arrowMode, textEditing] event in
                Self.handleKey(
                    event, text: text, state: state,
                    onSubmit: onSubmit, promptWidth: prefix.width,
                    maxVisibleLines: renderedHeight,
                    wrapWidth: contentWidth,
                    arrowMode: arrowMode,
                    textEditing: textEditing
                )
            }
            .onPaste { [text, state, pasteMode] payload in
                Self.handlePaste(
                    payload,
                    text: text,
                    state: state,
                    maxVisibleLines: renderedHeight,
                    wrapWidth: contentWidth,
                    pasteMode: pasteMode
                )
            }
    }

    /// Returns true when the cursor sits exactly at the right edge of
    /// a collapsed `PasteReference` in the live reference set. Used
    /// by the auto-hint row to decide whether to render. Computes the
    /// cursor's absolute character offset in the expanded text and
    /// matches it against `ref.start + ref.length` for any
    /// non-expanded reference.
    static func isCursorAtCollapsedRightEdge(state: PromptInputState, expandedText: String) -> Bool {
        guard !state.references.isEmpty else { return false }
        let lines = TextLines.split(expandedText)
        let row = min(state.cursorRow, max(0, lines.count - 1))
        let col = min(state.cursorCol, lines[row].count)
        let offset = TextLines.offset(row: row, col: col, in: lines)
        return state.references.contains { ref in
            !ref.isExpanded && (ref.start + ref.length) == offset
        }
    }

    /// What each row begins with: a `.promptPrefix` set above, or the
    /// `prompt` glyph.
    var resolvedPrefix: PromptPrefix {
        promptPrefix ?? .glyph(prompt)
    }

    /// Picks the display-row ceiling. Legacy `maxVisibleLines` wins for
    /// source compatibility, then the policy.
    private static func resolveCeiling(
        policy: PromptHeightPolicy,
        legacy: Int?,
        containerHeight: Int,
        contentRows: Int
    ) -> Int {
        if let legacy { return max(1, legacy) }
        switch policy {
        case .fixed(let n): return max(1, n)
        case .unbounded: return max(1, contentRows)
        case .container: return max(1, containerHeight > 0 ? containerHeight : 8)
        case .containerCapped(let cap):
            let container = containerHeight > 0 ? containerHeight : cap
            return max(1, min(cap, container))
        }
    }

    // MARK: - Soft wrap

    /// Splits a logical line into ≤`width`-character chunks, breaking
    /// on whitespace boundaries. Now a thin wrapper over the shared
    /// `TextLayout.wrapWords` primitive so PromptInput, Text, and
    /// future text-view components share one wrap algorithm.
    static func wrapLine(_ line: String, width: Int) -> [String] {
        TextLayout.wrapWords(line, width: width)
    }

    /// Pre-computes wrapped chunks for every logical line. Used by both the
    /// renderer and the scroll/navigation math so they agree on display rows.
    static func wrapPerLine(lines: [String], width: Int) -> [[String]] {
        lines.map { wrapLine($0, width: width) }
    }

    /// Maps a logical cursor to its (displayRow, displayCol) in the flattened
    /// post-wrap grid. `displayRow` is summed across all preceding logical
    /// lines' chunk counts plus the wrap-index within the current line.
    /// `displayCol` is the cursor's column within that chunk.
    static func projectCursor(
        logicalRow: Int,
        logicalCol: Int,
        wraps: [[String]]
    ) -> (displayRow: Int, displayCol: Int) {
        var displayRow = 0
        for row in 0..<min(logicalRow, wraps.count) {
            displayRow += max(1, wraps[row].count)
        }
        let chunks = wraps[min(logicalRow, wraps.count - 1)]
        // `chunks[i]` covers logical columns [i*W, (i+1)*W). The cursor's
        // position inside the chunk is `logicalCol - i*W`. When the cursor
        // sits at the boundary (`logicalCol == chunkLen` and another chunk
        // follows), prefer the start of the next chunk — matches how editors
        // position a trailing cursor after a word-wrap.
        var remaining = logicalCol
        for (i, chunk) in chunks.enumerated() {
            if remaining < chunk.count {
                return (displayRow + i, remaining)
            }
            if remaining == chunk.count {
                // End of a chunk: if another chunk follows, move to its start;
                // otherwise render at the end of this chunk (cursor block
                // drawn to the right of the last character).
                if i + 1 < chunks.count {
                    return (displayRow + i + 1, 0)
                }
                return (displayRow + i, remaining)
            }
            remaining -= chunk.count
        }
        // Defensive: cursor past end — pin at end of last chunk.
        let lastIdx = max(0, chunks.count - 1)
        return (displayRow + lastIdx, chunks[lastIdx].count)
    }

    /// Where in the text a click at column `x` of the text — past the
    /// prefix — and row `y` of `rows` as `buildDisplay` draws them puts the
    /// cursor: on the character there, at the end of a row clicked past
    /// its end, and at the nearer edge of a collapsed paste marker clicked
    /// inside, as the cursor never lives within one.
    static func cursor(atColumn x: Int, row y: Int, rows: PromptRows) -> (row: Int, col: Int) {
        let expandedLines = TextLines.split(rows.text)
        guard !rows.text.isEmpty else { return (0, 0) }
        let firstRow = max(0, min(rows.state.scrollDisplayRow, max(0, rows.totalDisplayRows - rows.visibleLines)))
        var target = max(0, min(firstRow + y, rows.totalDisplayRows - 1))
        var lineIndex = 0
        var columnInLine = 0
        for (index, chunks) in rows.wraps.enumerated() {
            guard target >= chunks.count else {
                // Chunks follow one another in the line, as `projectCursor`
                // counts them.
                columnInLine = chunks.prefix(target).reduce(0) { $0 + $1.count }
                    + max(0, min(x, chunks[target].count))
                lineIndex = index
                break
            }
            target -= chunks.count
            lineIndex = index
            columnInLine = rows.lines.indices.contains(index) ? rows.lines[index].count : 0
        }
        var offset = TextLines.offset(row: lineIndex, col: columnInLine, in: rows.lines)
        let markers = rows.projection.markerRanges.filter { !$0.isExpanded }
        if let marker = markers.first(where: { $0.start < offset && offset < $0.end }) {
            offset = offset - marker.start <= marker.end - offset ? marker.start : marker.end
        }
        // Each collapsed marker before the offset moved it by its delta.
        var delta = 0
        for (marker, point) in zip(markers, rows.projection.deltas) where offset >= marker.end {
            delta = point.delta
        }
        return TextLines.position(of: offset - delta, in: expandedLines)
    }

    // MARK: - Collapsed-display projection

    /// Result of projecting expanded binding text + references into
    /// the collapsed display string used for rendering. `cursorDelta`
    /// is the per-cursor-offset shift induced by markers BEFORE the
    /// cursor; the body adds it to the cursor's logical position when
    /// computing display row/col.
    struct CollapsedProjection: Equatable {
        let displayText: String
        /// `(start, end, label)` triples in DISPLAY coordinates for
        /// each rendered marker. The renderer can re-style these
        /// segments distinctly (dim color) by walking spans.
        let markerRanges: [(start: Int, end: Int, label: String, isExpanded: Bool)]
        /// Sum of `(markerLength - referenceLength)` for every
        /// reference whose range ends at or before `expandedOffset`.
        /// Caller adds this to cursor offset to get display offset.
        let deltas: [DeltaPoint]

        struct DeltaPoint: Equatable {
            let upToExpandedOffset: Int   // delta applies for positions strictly less than this
            let delta: Int                // accumulated displayLen - expandedLen up to here
        }

        static func == (lhs: CollapsedProjection, rhs: CollapsedProjection) -> Bool {
            lhs.displayText == rhs.displayText
                && lhs.markerRanges.elementsEqual(rhs.markerRanges) { $0 == $1 }
                && lhs.deltas == rhs.deltas
        }
    }

    /// Build a collapsed display projection from the expanded binding
    /// text and the live reference set. Each `isExpanded == false`
    /// reference's range is replaced with a marker label.
    static func projectCollapsedDisplay(
        expandedText: String,
        references: [PasteReference],
        buffers: [PasteBuffer],
        localizer: any PromptInputLocalizer = DefaultPromptInputLocalizer()
    ) -> CollapsedProjection {
        // Sort references by start so we can walk left-to-right and
        // accumulate deltas. The "cursor snaps to edge" rule means
        // references never overlap; sort is stable in that case.
        let sortedRefs = references.sorted { $0.start < $1.start }
        guard !sortedRefs.isEmpty else {
            return CollapsedProjection(
                displayText: expandedText,
                markerRanges: [],
                deltas: []
            )
        }

        var displayText = ""
        var markerRanges: [(start: Int, end: Int, label: String, isExpanded: Bool)] = []
        var deltas: [CollapsedProjection.DeltaPoint] = []
        var cursorDelta = 0
        var expandedCursor = 0

        for ref in sortedRefs {
            // Copy text from `expandedCursor` up to `ref.start`.
            let startIdx = expandedText.index(expandedText.startIndex, offsetBy: expandedCursor)
            let refStartIdx = expandedText.index(expandedText.startIndex, offsetBy: ref.start)
            displayText.append(contentsOf: expandedText[startIdx..<refStartIdx])

            if ref.isExpanded {
                // Render underlying text inline.
                let refEndIdx = expandedText.index(refStartIdx, offsetBy: ref.length)
                displayText.append(contentsOf: expandedText[refStartIdx..<refEndIdx])
            } else {
                // Render marker (routes through the supplied localizer).
                let label = markerLabel(for: ref, buffers: buffers, localizer: localizer)
                let markerStart = displayText.count
                displayText.append(label)
                let markerEnd = displayText.count
                markerRanges.append((markerStart, markerEnd, label, false))
                cursorDelta += label.count - ref.length
                deltas.append(.init(
                    upToExpandedOffset: ref.start + ref.length,
                    delta: cursorDelta
                ))
            }
            expandedCursor = ref.start + ref.length
        }

        // Tail after the last reference.
        if expandedCursor < expandedText.count {
            let startIdx = expandedText.index(expandedText.startIndex, offsetBy: expandedCursor)
            displayText.append(contentsOf: expandedText[startIdx...])
        }

        return CollapsedProjection(
            displayText: displayText,
            markerRanges: markerRanges,
            deltas: deltas
        )
    }

    /// Format the marker label for a reference per the shipping
    /// design. Routes through `PromptInputLocalizer` so app authors
    /// can translate or customize shapes per locale; default English
    /// implementation ships `[Pasted text #N +M lines]` etc.
    static func markerLabel(for ref: PasteReference,
                             buffers: [PasteBuffer],
                             localizer: any PromptInputLocalizer = DefaultPromptInputLocalizer()) -> String {
        guard let buffer = buffers.first(where: { $0.id == ref.bufferID }) else {
            // Defensive: stale reference, render an inert tag. We
            // route through the localizer with chars=0 to keep the
            // shape consistent — apps that customize markers will
            // see this branch when references have been disconnected
            // from their buffer.
            return localizer.charsMarker(id: ref.id, charCount: 0)
        }
        switch buffer.content {
        case .text(let body):
            let lineCount = body.split(separator: "\n", omittingEmptySubsequences: false).count
            if lineCount > 1 {
                return localizer.textMarker(id: ref.id, lineCount: lineCount)
            }
            return localizer.charsMarker(id: ref.id, charCount: body.count)
        case .image:
            return localizer.imageMarker(id: ref.id)
        }
    }

    /// Translate an expanded-text offset to its display-text offset
    /// using the projection's deltas. `expandedOffset == ref.start`
    /// (left edge of a collapsed reference) returns the marker's left
    /// edge; `ref.start + ref.length` (right edge) returns the
    /// marker's right edge.
    static func translateOffset(_ expandedOffset: Int, deltas: [CollapsedProjection.DeltaPoint]) -> Int {
        var cumulative = 0
        for point in deltas {
            if expandedOffset >= point.upToExpandedOffset {
                cumulative = point.delta
            } else {
                break
            }
        }
        return expandedOffset + cumulative
    }

    // MARK: - Display

    /// The spans for `rows`, drawn for whether the prompt holds focus: the
    /// prefix on every row, the text, the placeholder when there is none,
    /// the cursor only while focused, and reserved rows past the text.
    fileprivate static func buildDisplay(_ rows: PromptRows, isFocused: Bool, cursorLit: Bool,
                                         theme: any Theme) -> [TextSpan] {
        let st = rows.state
        let lines = rows.lines
        let wraps = rows.wraps
        let projection = rows.projection
        // Translate cursor from expanded coordinates → display
        // coordinates. Markers shift the column count for any
        // position past their start. The cursor never lives INSIDE a
        // collapsed range (input handlers snap to edges),
        // so a single-pass delta lookup is sufficient.
        let expandedLines = TextLines.split(rows.text)
        let cursorRowInExpanded = min(st.cursorRow, max(0, expandedLines.count - 1))
        let cursorColInExpanded = min(st.cursorCol, expandedLines[cursorRowInExpanded].count)
        let expandedOffset = TextLines.offset(row: cursorRowInExpanded, col: cursorColInExpanded,
                                              in: expandedLines)
        let displayOffset = translateOffset(expandedOffset, deltas: projection.deltas)
        let (cursorRow, cursorCol) = TextLines.position(of: displayOffset, in: lines)
        let (cursorDisplayRow, cursorDisplayCol) = projectCursor(
            logicalRow: cursorRow, logicalCol: cursorCol, wraps: wraps
        )

        // Flatten (logicalRow, chunkIndex) pairs for the visible window.
        let startDisplayRow = max(0, min(st.scrollDisplayRow, max(0, rows.totalDisplayRows - rows.visibleLines)))
        let endDisplayRow = min(rows.totalDisplayRows, startDisplayRow + rows.visibleLines)
        let cursorStyle = (foreground: theme.foregroundEmphasis,
                           background: theme.cursorColor(lit: cursorLit))

        var spans: [TextSpan] = []
        var currentDisplayRow = 0
        var emittedRows = 0

        outer: for (logicalIdx, chunks) in wraps.enumerated() {
            for (chunkIdx, chunk) in chunks.enumerated() {
                defer { currentDisplayRow += 1 }
                if currentDisplayRow < startDisplayRow { continue }
                if currentDisplayRow >= endDisplayRow { break outer }

                if emittedRows > 0 {
                    spans.append(TextSpan("\n"))
                }
                emittedRows += 1
                spans.append(contentsOf: rows.prefix.spans(for: PromptPrefix.Row(
                    index: currentDisplayRow, isFocused: isFocused, theme: theme)))

                if rows.text.isEmpty, let placeholder = rows.placeholder, let first = placeholder.first {
                    // The cursor sits on the placeholder's first character
                    // rather than pushing the placeholder a column right.
                    if isFocused {
                        spans.append(TextSpan(String(first), foreground: cursorStyle.foreground,
                                              background: cursorStyle.background, bold: true))
                        spans.append(TextSpan(String(placeholder.dropFirst()), foreground: theme.foregroundFaint))
                    } else {
                        spans.append(TextSpan(placeholder, foreground: theme.foregroundFaint))
                    }
                    continue
                }

                // Compute this chunk's start offset in the
                // collapsed display text. Walk earlier logical lines
                // (each contributes its full `lines[i].count + 1` for
                // the joining `\n`), then earlier chunks of the
                // current logical line.
                var chunkStartInDisplay = 0
                for r in 0..<logicalIdx {
                    chunkStartInDisplay += lines[r].count + 1
                }
                for c in 0..<chunkIdx {
                    chunkStartInDisplay += wraps[logicalIdx][c].count
                }

                let isCursorRow = isFocused && currentDisplayRow == cursorDisplayRow
                if isCursorRow {
                    // Split the chunk around the cursor column.
                    let col = min(cursorDisplayCol, chunk.count)
                    if col > 0 {
                        let before = String(chunk.prefix(col))
                        appendStyledChunkSpans(into: &spans,
                                               chunk: before,
                                               chunkStartInDisplay: chunkStartInDisplay,
                                               projection: projection,
                                               theme: theme)
                    }
                    if col < chunk.count {
                        let idx = chunk.index(chunk.startIndex, offsetBy: col)
                        let cursorGlyph = chunk[idx]
                        spans.append(TextSpan(
                            String(cursorGlyph),
                            foreground: cursorStyle.foreground,
                            background: cursorStyle.background,
                            bold: true
                        ))
                        if col + 1 < chunk.count {
                            let after = String(chunk.suffix(from: chunk.index(after: idx)))
                            appendStyledChunkSpans(into: &spans,
                                                   chunk: after,
                                                   chunkStartInDisplay: chunkStartInDisplay + col + 1,
                                                   projection: projection,
                                                   theme: theme)
                        }
                    } else {
                        // Cursor sits past the last character of this chunk —
                        // render the block glyph. `projectCursor` only lands
                        // here for the last chunk of the last logical line
                        // (otherwise it rolls to the next chunk's col 0).
                        spans.append(TextSpan(String(cursorChar), foreground: cursorStyle.background))
                    }
                } else {
                    appendStyledChunkSpans(into: &spans,
                                           chunk: chunk,
                                           chunkStartInDisplay: chunkStartInDisplay,
                                           projection: projection,
                                           theme: theme)
                }
            }
        }

        // Badge only fits cleanly on single-row input; otherwise the render
        // would overlap wrapped content. It goes on that row, before any
        // reserved rows. Wide-screen callers can use an explicit HStack.
        if let badge = rows.badge, !badge.isEmpty, rows.totalDisplayRows == 1 {
            spans.append(TextSpan("  "))
            spans.append(TextSpan(" \(badge) ", foreground: theme.foregroundMuted, background: theme.backgroundRaised))
        }

        // Rows reserved past the text, each with its prefix.
        while emittedRows < rows.visibleLines {
            if emittedRows > 0 {
                spans.append(TextSpan("\n"))
            }
            spans.append(contentsOf: rows.prefix.spans(for: PromptPrefix.Row(
                index: startDisplayRow + emittedRows, isFocused: isFocused, theme: theme)))
            emittedRows += 1
        }

        return spans
    }

    /// Emit `chunk` as one or more `TextSpan`s, splitting at marker
    /// boundaries so collapsed-reference text gets `foregroundMuted` while
    /// regular content stays in the theme's `foreground`. `chunkStartInDisplay`
    /// is the chunk's character offset in the collapsed display text;
    /// the helper intersects it with `projection.markerRanges` to
    /// locate marker segments inside the chunk.
    fileprivate static func appendStyledChunkSpans(
        into spans: inout [TextSpan],
        chunk: String,
        chunkStartInDisplay: Int,
        projection: CollapsedProjection,
        theme: any Theme
    ) {
        guard !chunk.isEmpty else { return }
        if projection.markerRanges.isEmpty {
            spans.append(TextSpan(chunk, foreground: theme.foreground))
            return
        }
        let chunkEndInDisplay = chunkStartInDisplay + chunk.count
        // Find marker ranges that intersect this chunk.
        let intersecting = projection.markerRanges.filter { range in
            range.start < chunkEndInDisplay && range.end > chunkStartInDisplay
        }
        if intersecting.isEmpty {
            spans.append(TextSpan(chunk, foreground: theme.foreground))
            return
        }
        // Walk the chunk left-to-right, alternating text-color and
        // dim-color segments. Marker ranges are sorted by start so a
        // simple sweep is sufficient (markers never nest).
        var cursor = chunkStartInDisplay
        for range in intersecting {
            // Pre-marker plain segment.
            if range.start > cursor {
                let preStart = cursor - chunkStartInDisplay
                let preEnd = min(range.start, chunkEndInDisplay) - chunkStartInDisplay
                if preEnd > preStart {
                    let segment = String(chunk[
                        chunk.index(chunk.startIndex, offsetBy: preStart)
                        ..<
                        chunk.index(chunk.startIndex, offsetBy: preEnd)
                    ])
                    spans.append(TextSpan(segment, foreground: theme.foreground))
                }
                cursor = min(range.start, chunkEndInDisplay)
            }
            // Marker segment (clipped to chunk bounds).
            let markStart = max(cursor, range.start) - chunkStartInDisplay
            let markEnd = min(range.end, chunkEndInDisplay) - chunkStartInDisplay
            if markEnd > markStart {
                let segment = String(chunk[
                    chunk.index(chunk.startIndex, offsetBy: markStart)
                    ..<
                    chunk.index(chunk.startIndex, offsetBy: markEnd)
                ])
                spans.append(TextSpan(segment, foreground: theme.foregroundMuted, italic: true))
            }
            cursor = min(range.end, chunkEndInDisplay)
        }
        // Tail after the last marker.
        if cursor < chunkEndInDisplay {
            let tailStart = cursor - chunkStartInDisplay
            let segment = String(chunk[
                chunk.index(chunk.startIndex, offsetBy: tailStart)
                ..<
                chunk.endIndex
            ])
            spans.append(TextSpan(segment, foreground: theme.foreground))
        }
    }

    // MARK: - Paste Handling

    /// Insert a bracketed-paste payload at the cursor.
    ///
    /// The binding always holds the EXPANDED text — references are
    /// sidecar metadata that drive marker rendering. This keeps
    /// `onSubmit`, history, and downstream consumers oblivious to
    /// the marker UX layer (per design 2026-04-26).
    ///
    /// Three things happen on every paste:
    ///   1. Splice the expanded payload into the binding at cursor.
    ///   2. If `pasteMode.shouldCollapse(payload)` is true, register
    ///      a `PasteBuffer` (deduped by content hash) and a
    ///      `PasteReference` covering the inserted range.
    ///   3. Existing references AFTER the insertion point shift right
    ///      by `payload.count` so their stored offsets stay accurate.
    ///
    /// "Paste again to expand" and the auto-hint live here too; the
    /// cursor-adjacency check fires when
    /// the same content is pasted right after a collapsed reference.
    static func handlePaste(
        _ payload: String,
        text: Binding<String>,
        state: Binding<PromptInputState>,
        maxVisibleLines: Int,
        wrapWidth: Int,
        pasteMode: PasteMode = .claudeCode
    ) {
        guard !payload.isEmpty else { return }

        let normalised = payload.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var st = state.get()
        var lines = TextLines.split(text.get())

        st.cursorRow = min(st.cursorRow, lines.count - 1)
        st.cursorCol = min(st.cursorCol, lines[st.cursorRow].count)

        // Compute the absolute character offset of the cursor in the
        // joined text. Each row contributes `count + 1` (the `+1` is
        // the joining `\n`); the final row contributes its `count`
        // alone.
        var insertOffset = 0
        for r in 0..<st.cursorRow {
            insertOffset += lines[r].count + 1
        }
        insertOffset += st.cursorCol

        // "Paste again to expand" — cursor at the right edge of a
        // collapsed reference + same content hash → flip that
        // reference back to expanded. Don't insert again; the binding
        // already contains the expanded text from the prior paste.
        let incomingHash = PasteBuffer.hash(.text(normalised))
        if let adjacentIdx = st.references.firstIndex(where: { ref in
            ref.start + ref.length == insertOffset && !ref.isExpanded
        }), let buffer = st.buffers.first(where: { $0.id == st.references[adjacentIdx].bufferID }),
           buffer.contentHash == incomingHash
        {
            st.references[adjacentIdx].isExpanded = true
            st.historyIndex = -1
            // Move cursor to the end of the now-expanded range.
            let range = st.references[adjacentIdx]
            let endOffset = range.start + range.length
            (st.cursorRow, st.cursorCol) = TextLines.position(of: endOffset, in: lines)
            adjustScroll(&st, maxVisibleLines: maxVisibleLines, wrapWidth: wrapWidth, lines: lines)
            state.set(st)
            return
        }

        // Splice: insert the EXPANDED payload into the binding.
        let segments = normalised.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let row = lines[st.cursorRow]
        let splitAt = row.index(row.startIndex, offsetBy: st.cursorCol)
        let before = String(row[row.startIndex..<splitAt])
        let after = String(row[splitAt..<row.endIndex])

        if segments.count == 1 {
            lines[st.cursorRow] = before + segments[0] + after
            st.cursorCol = before.count + segments[0].count
        } else {
            lines[st.cursorRow] = before + segments[0]
            var insertAt = st.cursorRow + 1
            for segment in segments[1..<(segments.count - 1)] {
                lines.insert(segment, at: insertAt)
                insertAt += 1
            }
            let lastSegment = segments[segments.count - 1]
            lines.insert(lastSegment + after, at: insertAt)
            st.cursorRow = insertAt
            st.cursorCol = lastSegment.count
        }

        // Shift any existing reference whose range starts at or after
        // the insertion point. References that ENCLOSE the insertion
        // point would be split, which is unsupported: the cursor snaps
        // to edges, so insertion inside a reference can't happen.
        let insertedLength = normalised.count
        for i in 0..<st.references.count {
            if st.references[i].start >= insertOffset {
                st.references[i].start += insertedLength
            }
        }

        // Register a buffer + reference if the mode says collapse.
        if pasteMode.shouldCollapse(normalised) {
            let bufferID: PasteBuffer.ID
            if let existing = st.buffers.first(where: { $0.contentHash == incomingHash }) {
                bufferID = existing.id
            } else {
                let newBuffer = PasteBuffer(id: st.nextBufferID, content: .text(normalised))
                st.buffers.append(newBuffer)
                bufferID = newBuffer.id
                st.nextBufferID += 1
            }
            let ref = PasteReference(
                id: st.nextReferenceID,
                bufferID: bufferID,
                start: insertOffset,
                length: insertedLength,
                isExpanded: false
            )
            st.references.append(ref)
            st.nextReferenceID += 1
        }

        st.historyIndex = -1
        text.set(TextLines.join(lines))
        adjustScroll(&st, maxVisibleLines: maxVisibleLines, wrapWidth: wrapWidth, lines: lines)
        state.set(st)
    }

    // MARK: - Key Handling

    static func handleKey(
        _ event: KeyEvent,
        text: Binding<String>,
        state: Binding<PromptInputState>,
        onSubmit: ((String) -> Void)?,
        promptWidth: Int,
        maxVisibleLines: Int,
        wrapWidth: Int = .max,
        arrowMode: PromptArrowMode = .display,
        textEditing: TextEditingContext = EnvironmentValues().textEditing
    ) -> KeyEventResult {
        let content = text.get()
        var st = state.get()
        var lines = TextLines.split(content)

        // Clamp cursor
        st.cursorRow = min(st.cursorRow, lines.count - 1)
        st.cursorCol = min(st.cursorCol, lines[st.cursorRow].count)

        /// Shows `recalled` in place of the draft, its markers with it, the
        /// cursor at its end.
        func recall(_ recalled: String, references: [PasteReference]) {
            text.set(recalled)
            st.references = references
            lines = TextLines.split(recalled)
            (st.cursorRow, st.cursorCol) = TextLines.position(of: recalled.count, in: lines)
        }

        /// Performs a buffer command on the prompt's text. A collapsed marker
        /// stands for text the user never sees: an edit takes all of it or
        /// none, the cursor never stops inside it, and the markers after an
        /// edit move with the text.
        func edit(_ apply: (inout TextEditingBuffer) -> TextEditResult) -> KeyEventResult? {
            let markers = st.references.filter { !$0.isExpanded }.map { $0.start..<($0.start + $0.length) }
            var buffer = TextEditingBuffer(text: Array(content),
                                           cursor: TextLines.offset(row: st.cursorRow, col: st.cursorCol, in: lines),
                                           atomicRanges: markers)
            switch apply(&buffer) {
            case .unsupported, .unchanged:
                return nil
            case .moved, .hitWall:
                break
            case .edited(let replaced, let insertedCount):
                // The buffers stay in the pool; only the references go.
                st.references = st.references.compactMap { reference in
                    TextEditingBuffer.range(reference.start..<(reference.start + reference.length),
                                            after: replaced, insertedCount: insertedCount)
                        .map { moved in
                            var reference = reference
                            reference.start = moved.lowerBound
                            return reference
                        }
                }
                st.historyIndex = -1
                let edited = String(buffer.text)
                lines = TextLines.split(edited)
                text.set(edited)
            }
            (st.cursorRow, st.cursorCol) = TextLines.position(of: buffer.cursor, in: lines)
            return .handled
        }

        /// What the prompt does with `command`, or nil to pass it over.
        func perform(_ command: TextEditCommand) -> KeyEventResult? {
            switch command {
            case .submit:
                // The submitted text is the expanded content, references
                // stripped: receivers get pristine text, and markers are a
                // display concern. The history entry keeps both, so recall
                // brings the markers back with the text.
                let submitted = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !submitted.isEmpty {
                    st.history.insert(PromptInputHistoryEntry(text: submitted, buffers: st.buffers,
                                                              references: st.references), at: 0)
                    st.historyIndex = -1
                    st.savedInput = ""
                    st.savedReferences = []
                    onSubmit?(submitted)
                    text.set("")
                    st.cursorRow = 0
                    st.cursorCol = 0
                    st.scrollDisplayRow = 0
                    st.references = []
                }
                return .handled
            case .moveUp:
                return moveCursorUp(&st, lines: lines, wrapWidth: wrapWidth, arrowMode: arrowMode) ? .handled : nil
            case .moveDown:
                return moveCursorDown(&st, lines: lines, wrapWidth: wrapWidth, arrowMode: arrowMode) ? .handled : nil
            case .previousHistory:
                guard st.historyIndex + 1 < st.history.count else {
                    textEditing.boundaryHit(.topEdge)
                    return .handled
                }
                if st.historyIndex == -1 {
                    st.savedInput = content
                    st.savedReferences = st.references
                }
                st.historyIndex += 1
                let entry = st.history[st.historyIndex]
                recall(entry.text, references: entry.references)
                return .handled
            case .nextHistory:
                guard st.historyIndex >= 0 else {
                    textEditing.boundaryHit(.bottomEdge)
                    return .handled
                }
                st.historyIndex -= 1
                if st.historyIndex < 0 {
                    recall(st.savedInput, references: st.savedReferences)
                } else {
                    let entry = st.history[st.historyIndex]
                    recall(entry.text, references: entry.references)
                }
                return .handled
            default:
                guard command.isBufferCommand else { return nil }
                return edit { textEditing.perform(command, on: &$0) }
            }
        }

        let commands = textEditing.keymap.commands(for: event)
        var result: KeyEventResult?
        if !commands.isEmpty {
            // The first command that applies wins; each runs at most once.
            for command in commands {
                result = perform(command)
                if result != nil { break }
            }
        } else if case .character(let c) = event.key,
                  !event.modifiers.contains(.ctrl), !event.modifiers.contains(.alt) {
            result = edit { $0.insert([c]) } ?? .handled
        }
        // Otherwise a chord no command claims, which bubbles to the parent.
        guard let result else { return .ignored }
        adjustScroll(&st, maxVisibleLines: maxVisibleLines, wrapWidth: wrapWidth, lines: lines)
        state.set(st)
        return result
    }

    // MARK: - Helpers

    /// Moves the cursor up one step under the selected arrow mode. Returns
    /// false if it could not move (already at top) so the caller can fall
    /// through to history recall.
    private static func moveCursorUp(
        _ st: inout PromptInputState,
        lines: [String],
        wrapWidth: Int,
        arrowMode: PromptArrowMode
    ) -> Bool {
        switch arrowMode {
        case .logical:
            if st.cursorRow > 0 {
                st.cursorRow -= 1
                st.cursorCol = min(st.cursorCol, lines[st.cursorRow].count)
                return true
            }
            return false
        case .display:
            guard wrapWidth > 0, wrapWidth != .max else {
                // No wrap info → fall back to logical.
                if st.cursorRow > 0 {
                    st.cursorRow -= 1
                    st.cursorCol = min(st.cursorCol, lines[st.cursorRow].count)
                    return true
                }
                return false
            }
            // Inside a soft-wrapped logical line: step back by `wrapWidth`.
            if st.cursorCol >= wrapWidth {
                st.cursorCol -= wrapWidth
                return true
            }
            // At the top display row of this logical line → jump to the
            // bottom display row of the previous logical line, preserving
            // the desired column as closely as possible.
            if st.cursorRow > 0 {
                st.cursorRow -= 1
                let prevLine = lines[st.cursorRow]
                let prevLen = prevLine.count
                let lastChunkStart = (prevLen / wrapWidth) * wrapWidth
                // If prevLen is an exact multiple of wrapWidth, `lastChunkStart`
                // lands on the empty trailing chunk; back up one row.
                let adjustedStart: Int
                if prevLen > 0 && prevLen % wrapWidth == 0 {
                    adjustedStart = prevLen - wrapWidth
                } else {
                    adjustedStart = lastChunkStart
                }
                let desiredCol = st.cursorCol  // carry column intent
                let chunkLen = prevLen - adjustedStart
                st.cursorCol = min(adjustedStart + desiredCol, adjustedStart + chunkLen)
                return true
            }
            return false
        }
    }

    private static func moveCursorDown(
        _ st: inout PromptInputState,
        lines: [String],
        wrapWidth: Int,
        arrowMode: PromptArrowMode
    ) -> Bool {
        let lineCount = lines.count
        switch arrowMode {
        case .logical:
            if st.cursorRow < lineCount - 1 {
                st.cursorRow += 1
                st.cursorCol = min(st.cursorCol, lines[st.cursorRow].count)
                return true
            }
            return false
        case .display:
            guard wrapWidth > 0, wrapWidth != .max else {
                if st.cursorRow < lineCount - 1 {
                    st.cursorRow += 1
                    st.cursorCol = min(st.cursorCol, lines[st.cursorRow].count)
                    return true
                }
                return false
            }
            let line = lines[st.cursorRow]
            let remainingInLine = line.count - st.cursorCol
            if remainingInLine >= wrapWidth {
                // Another wrapped chunk exists in this logical line.
                st.cursorCol += wrapWidth
                return true
            }
            // Bottom chunk of current line → jump to first chunk of next line.
            if st.cursorRow < lineCount - 1 {
                st.cursorRow += 1
                let colInChunk = st.cursorCol % wrapWidth
                st.cursorCol = min(colInChunk, lines[st.cursorRow].count)
                return true
            }
            return false
        }
    }

    /// Scrolls so the cursor's display row is visible. Works on DISPLAY rows
    /// throughout: a single long soft-wrapped line scrolls row-by-row, a
    /// short line with lots of `\n`s still scrolls correctly.
    private static func adjustScroll(
        _ st: inout PromptInputState,
        maxVisibleLines: Int,
        wrapWidth: Int,
        lines: [String]
    ) {
        let wraps: [[String]]
        if wrapWidth <= 0 || wrapWidth == .max {
            wraps = lines.map { [$0] }
        } else {
            wraps = wrapPerLine(lines: lines, width: wrapWidth)
        }
        let (cursorDisplayRow, _) = projectCursor(
            logicalRow: min(st.cursorRow, max(0, lines.count - 1)),
            logicalCol: min(st.cursorCol, lines[min(st.cursorRow, max(0, lines.count - 1))].count),
            wraps: wraps
        )
        let totalDisplayRows = wraps.reduce(0) { $0 + $1.count }
        let maxScroll = max(0, totalDisplayRows - maxVisibleLines)

        if cursorDisplayRow < st.scrollDisplayRow {
            st.scrollDisplayRow = cursorDisplayRow
        } else if cursorDisplayRow >= st.scrollDisplayRow + maxVisibleLines {
            st.scrollDisplayRow = cursorDisplayRow - maxVisibleLines + 1
        }
        st.scrollDisplayRow = max(0, min(st.scrollDisplayRow, maxScroll))
    }
}

/// The rows of a ``PromptInput``, drawn for whether it holds focus. A view of
/// its own so it can sit under the input's `.focusable()` and read
/// `isFocused`; it holds the values the input computed for a width, never
/// the bindings.
struct PromptRows: TerminalView {
    let text: String
    let state: PromptInputState
    let placeholder: String?
    let badge: String?
    let prefix: PromptPrefix
    let lines: [String]
    let wraps: [[String]]
    let totalDisplayRows: Int
    let visibleLines: Int
    let projection: PromptInput.CollapsedProjection

    @TerminalEnvironment(\.isFocused) var isFocused
    @TerminalEnvironment(\.theme) var theme
    @TerminalEnvironment(\.cursorFlash) var cursorFlash

    var body: some TerminalView {
        Text(spans: PromptInput.buildDisplay(self, isFocused: isFocused,
                                             cursorLit: isFocused && cursorFlash?.isLit == true, theme: theme))
    }
}
