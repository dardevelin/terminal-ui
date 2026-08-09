import Foundation

/// Which axis arrow Up/Down navigates on.
///
/// `.display` matches editors (vim visual lines, VS Code, Claude Code):
/// one arrow step = one terminal row, so a soft-wrapped logical line splits
/// into several navigable rows. `.logical` treats each `\n`-delimited line
/// as a single step; soft-wrapped rows are skipped.
public enum PromptArrowMode: Sendable, Equatable {
    case display
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
    /// Always render paste content inline. Legacy mode (pre-HYP-195).
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
    case visible
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
    public init() {}

    public func textMarker(id: Int, lineCount: Int) -> String {
        "[Pasted text #\(id) +\(lineCount) lines]"
    }

    public func charsMarker(id: Int, charCount: Int) -> String {
        "[Pasted text #\(id) +\(charCount) chars]"
    }

    public func imageMarker(id: Int) -> String {
        "[Image #\(id)]"
    }

    public func pasteAgainHint() -> String {
        "paste again to expand"
    }
}

/// Content held by a `PasteBuffer`. Phase A ships text only; image paste
/// flows through a separate input pipeline (kitty graphics / OSC 52)
/// tracked as a follow-up ticket. The case shape is forward-compatible
/// so the consumer-facing API stays stable when image paste lands.
public enum PasteBufferContent: Hashable, Equatable, Sendable {
    case text(String)
    /// Image buffer — opaque payload bytes plus mime type. The actual
    /// kitty graphics protocol / OSC 52 clipboard wiring lives in its
    /// own pipeline (separate ticket); this case is the stable
    /// data-shape side so the consumer-facing API doesn't churn when
    /// image paste arrives.
    case image(bytes: Data, mimeType: String)
}

/// One paste payload (or future selection-collapsed buffer) stored in the
/// PromptInput's per-state pool. Buffers are append-only and survive
/// reference deletion — that's what lets `Backspace` on a marker
/// "delete the presentation" without losing the data, so a Phase B
/// buffer-picker can re-insert the same buffer later.
///
/// User design quote (verbatim 2026-04-26):
/// > *"deleting regions don't delete the buffer, they delete the
/// > presentation, thus allowing to re-apply"*
public struct PasteBuffer: Identifiable, Equatable, Sendable {
    public typealias ID = Int
    public let id: ID
    public let content: PasteBufferContent
    /// Content hash for dedupe. Same payload pasted twice reuses the
    /// existing buffer (per the C2 sign-off in the design memory).
    /// Plain Hasher-based hash is enough for collision-resistance at
    /// session scope; we don't need a cryptographic hash.
    public let contentHash: Int

    public init(id: ID, content: PasteBufferContent) {
        self.id = id
        self.content = content
        self.contentHash = Self.hash(content)
    }

    public static func hash(_ content: PasteBufferContent) -> Int {
        var hasher = Hasher()
        hasher.combine(content)
        return hasher.finalize()
    }
}

/// A view of a buffer at a specific position in the binding text. One
/// buffer can be inserted multiple times — each insertion gets its own
/// `Reference`. Phase A: paste creates references; Phase B will add
/// selection-collapse and named references.
///
/// `range` is stored as `(start: Int, length: Int)` rather than
/// `Range<String.Index>` because the binding is mutable (cursor edits
/// shift positions); integer offsets survive mutation when we re-anchor
/// references after each text change. Length is in UTF-8 view characters,
/// matching how the binding's String index counts.
public struct PasteReference: Identifiable, Equatable, Sendable {
    public typealias ID = Int
    public let id: ID
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
    /// Toggled by "paste again to expand" and (Phase B) by
    /// `expand(refID:)` API.
    public var isExpanded: Bool
    /// Optional human-readable name. Phase A: always nil — markers
    /// render with `#N` numeric tag. Phase B: selection-collapse and
    /// LLM-suggested names populate this field.
    public var name: String?

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
    public let text: String
    public let buffers: [PasteBuffer]
    public let references: [PasteReference]

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
    /// Buffer pool — append-only across the prompt's lifetime. References
    /// point into here; deleting a reference does NOT delete its buffer
    /// (Phase B re-applies via the buffer picker). Indexed by `id`.
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
/// - `❯` prompt indicator on the left, continuation rows indent to match.
/// - Visible block cursor with per-display-row projection.
/// - Enter submits the trimmed text through `onSubmit` and clears the
///   buffer; Shift+Enter / Option+Enter / Ctrl+Enter insert a newline.
///   (Shift+Enter detection requires a terminal with kitty keyboard or similar;
///    Option+Enter is the universal fallback — sent as `ESC\r`.)
/// - Up arrow from the top display row recalls submitted history; Down
///   walks back toward the live input.
/// - Large pastes collapse to a `[Pasted text #N +M lines]` marker per
///   ``PasteMode``; pasting the same content again expands it.
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
    /// by its width. Defaults to `❯`.
    public let prompt: String
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

    /// Boundary-feedback mode read at body-eval time. Drives the
    /// `BoundaryFeedbackEmitter.shared.emit` calls at the four
    /// buffer-edge walls in `handleKey`. PromptInput's Up/Down walls
    /// are history-aware: emit only when arrow movement was blocked
    /// AND no history entry was available to recall.
    @TerminalEnvironment(\.boundaryFeedback) var boundaryFeedback

    /// Optional `.onBoundaryHit { reason in ... }` callback.
    @TerminalEnvironment(\.onBoundaryHit) var onBoundaryHit

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

    private static let cursorChar: Character = "\u{2588}"  // █
    private static let promptColor: Color = .cyan
    private static let cursorColor: Color = .white
    private static let textColor: Color = .default
    private static let badgeColor: Color = .ansi256(245)
    private static let badgeBgColor: Color = .ansi256(237)
    private static let dimColor: Color = .ansi256(242)

    public init(
        text: Binding<String>,
        state: Binding<PromptInputState>,
        prompt: String = "\u{276F}",
        badge: String? = nil,
        maxVisibleLines: Int? = nil,
        heightPolicy: PromptHeightPolicy = .fixed(8),
        arrowMode: PromptArrowMode = .display,
        onSubmit: ((String) -> Void)? = nil
    ) {
        self.text = text
        self.state = state
        self.prompt = prompt
        self.badge = badge
        self.maxVisibleLines = maxVisibleLines
        self.heightPolicy = heightPolicy
        self.arrowMode = arrowMode
        self.onSubmit = onSubmit
    }

    public var body: some TerminalView {
        // Soft-wrap needs the container width; `GeometryReader` supplies it.
        // We do NOT apply `.frame(height:)` — the spans emitted by
        // `buildDisplay` already contain exactly `renderedHeight` newline-
        // separated display rows, and `Text` sizes itself from span
        // newlines (TextArea uses the same trick). Wrapping in `.frame`
        // would force VStack to give us a fixed allocation on the FIRST
        // frame and then lock that size in, because GR reports last
        // frame's height.
        //
        // Capture boundary-feedback env at body-eval time; the GR
        // closure runs later when GraphContext.currentEnvironment may
        // be nil (`feedback_bindings_in_geometryreader.md`).
        let boundaryMode = boundaryFeedback
        let onBoundaryHit = self.onBoundaryHit
        // Capture the hint visibility + localizer up-front so the
        // VStack body sees a stable value (the GR closure inside
        // would re-read env at rebuild time, which is later than
        // body eval — same `feedback_bindings_in_geometryreader.md`
        // rule).
        let hintVisible = pasteHint == .visible
        let hintLocalizer = localizer
        let st = state.get()
        let cursorAdjacentToCollapsed = Self.isCursorAtCollapsedRightEdge(state: st, expandedText: text.get())
        let promptInput = GeometryReader { size in
            let contentWidth = max(1, size.width - Self.promptReservedWidth(self.prompt))
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
            let lines = Self.splitLines(projection.displayText)
            let wraps = Self.wrapPerLine(lines: lines, width: contentWidth)
            let totalDisplayRows = wraps.reduce(0) { $0 + $1.count }
            let ceiling = Self.resolveCeiling(
                policy: self.heightPolicy,
                legacy: self.maxVisibleLines,
                containerHeight: size.height,
                contentRows: totalDisplayRows
            )
            let renderedHeight = min(max(1, ceiling), max(1, totalDisplayRows))
            let spans = self.buildDisplay(
                lines: lines,
                wraps: wraps,
                totalDisplayRows: totalDisplayRows,
                wrapWidth: contentWidth,
                visibleLines: renderedHeight,
                projection: projection
            )
            return Text(spans: spans)
                .focusable()
                .onKeyPress { [text, state, onSubmit, prompt, arrowMode, boundaryMode, onBoundaryHit] event in
                    Self.handleKey(
                        event, text: text, state: state,
                        onSubmit: onSubmit, promptWidth: prompt.count + 1,
                        maxVisibleLines: renderedHeight,
                        wrapWidth: contentWidth,
                        arrowMode: arrowMode,
                        boundaryMode: boundaryMode,
                        onBoundaryHit: onBoundaryHit
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
        // Compose the prompt + optional auto-hint row. The hint
        // surfaces "paste again to expand" beneath the input when
        // the cursor sits at the right edge of a collapsed
        // reference. `.pasteHint(.hidden)` opts out per-subtree.
        return VStack {
            promptInput
            if hintVisible && cursorAdjacentToCollapsed {
                Text(hintLocalizer.pasteAgainHint())
                    .foreground(Self.dimColor)
            }
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
        let lines = splitLines(expandedText)
        let row = min(state.cursorRow, max(0, lines.count - 1))
        let col = min(state.cursorCol, lines[row].count)
        var absOffset = 0
        for r in 0..<row { absOffset += lines[r].count + 1 }
        absOffset += col
        return state.references.contains { ref in
            !ref.isExpanded && (ref.start + ref.length) == absOffset
        }
    }

    /// Cells reserved at the start of each display row for the prompt glyph
    /// and its trailing space. Wrap width for content is `container.width - this`.
    static func promptReservedWidth(_ prompt: String) -> Int {
        prompt.count + 1
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
        // accumulate deltas. Phase A's "cursor snaps to edge" rule
        // means references never overlap; sort is stable in that case.
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
            // from their buffer (Phase B picker may legitimately
            // produce that state).
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

    private func buildDisplay(
        lines: [String],
        wraps: [[String]],
        totalDisplayRows: Int,
        wrapWidth: Int,
        visibleLines: Int,
        projection: CollapsedProjection
    ) -> [TextSpan] {
        let st = state.get()
        // Translate cursor from expanded coordinates → display
        // coordinates. Markers shift the column count for any
        // position past their start. Phase A: cursor never lives
        // INSIDE a collapsed range (input handlers snap to edges),
        // so a single-pass delta lookup is sufficient.
        let expandedLines = Self.splitLines(text.get())
        let cursorRowInExpanded = min(st.cursorRow, max(0, expandedLines.count - 1))
        let cursorColInExpanded = min(st.cursorCol, expandedLines[cursorRowInExpanded].count)
        var expandedOffset = 0
        for r in 0..<cursorRowInExpanded { expandedOffset += expandedLines[r].count + 1 }
        expandedOffset += cursorColInExpanded
        let displayOffset = Self.translateOffset(expandedOffset, deltas: projection.deltas)
        let (cursorRow, cursorCol) = Self.absoluteOffsetToRowCol(displayOffset, lines: lines)
        let _ = cursorCol  // silence unused-let if mapping changes
        let (cursorDisplayRow, cursorDisplayCol) = Self.projectCursor(
            logicalRow: cursorRow, logicalCol: cursorCol, wraps: wraps
        )

        // Flatten (logicalRow, chunkIndex) pairs for the visible window.
        let startDisplayRow = max(0, min(st.scrollDisplayRow, max(0, totalDisplayRows - visibleLines)))
        let endDisplayRow = min(totalDisplayRows, startDisplayRow + visibleLines)

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

                // Prompt on the first chunk of the first logical line,
                // dim continuation indent everywhere else.
                if logicalIdx == 0 && chunkIdx == 0 {
                    spans.append(TextSpan("\(prompt) ", foreground: Self.promptColor, bold: true))
                } else {
                    let indent = String(repeating: " ", count: prompt.count + 1)
                    spans.append(TextSpan(indent, foreground: Self.dimColor))
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

                let isCursorRow = (currentDisplayRow == cursorDisplayRow)
                if isCursorRow {
                    // Split the chunk around the cursor column.
                    let col = min(cursorDisplayCol, chunk.count)
                    if col > 0 {
                        let before = String(chunk.prefix(col))
                        appendStyledChunkSpans(into: &spans,
                                                chunk: before,
                                                chunkStartInDisplay: chunkStartInDisplay,
                                                projection: projection)
                    }
                    if col < chunk.count {
                        let idx = chunk.index(chunk.startIndex, offsetBy: col)
                        let cursorGlyph = chunk[idx]
                        spans.append(TextSpan(
                            String(cursorGlyph),
                            foreground: Self.cursorColor,
                            background: Self.promptColor,
                            bold: true
                        ))
                        if col + 1 < chunk.count {
                            let after = String(chunk.suffix(from: chunk.index(after: idx)))
                            appendStyledChunkSpans(into: &spans,
                                                    chunk: after,
                                                    chunkStartInDisplay: chunkStartInDisplay + col + 1,
                                                    projection: projection)
                        }
                    } else {
                        // Cursor sits past the last character of this chunk —
                        // render the block glyph. `projectCursor` only lands
                        // here for the last chunk of the last logical line
                        // (otherwise it rolls to the next chunk's col 0).
                        spans.append(TextSpan(String(Self.cursorChar), foreground: Self.promptColor))
                    }
                } else {
                    appendStyledChunkSpans(into: &spans,
                                            chunk: chunk,
                                            chunkStartInDisplay: chunkStartInDisplay,
                                            projection: projection)
                }
            }
        }

        // Badge only fits cleanly on single-row empty input; otherwise the
        // render would overlap wrapped content. Wide-screen callers can use
        // an explicit HStack instead.
        if let badge, !badge.isEmpty, totalDisplayRows == 1 {
            spans.append(TextSpan("  "))
            spans.append(TextSpan(" \(badge) ", foreground: Self.badgeColor, background: Self.badgeBgColor))
        }

        return spans
    }

    /// Emit `chunk` as one or more `TextSpan`s, splitting at marker
    /// boundaries so collapsed-reference text gets `dimColor` while
    /// regular content stays in `textColor`. `chunkStartInDisplay`
    /// is the chunk's character offset in the collapsed display text;
    /// the helper intersects it with `projection.markerRanges` to
    /// locate marker segments inside the chunk.
    private func appendStyledChunkSpans(
        into spans: inout [TextSpan],
        chunk: String,
        chunkStartInDisplay: Int,
        projection: CollapsedProjection
    ) {
        guard !chunk.isEmpty else { return }
        if projection.markerRanges.isEmpty {
            spans.append(TextSpan(chunk, foreground: Self.textColor))
            return
        }
        let chunkEndInDisplay = chunkStartInDisplay + chunk.count
        // Find marker ranges that intersect this chunk.
        let intersecting = projection.markerRanges.filter { range in
            range.start < chunkEndInDisplay && range.end > chunkStartInDisplay
        }
        if intersecting.isEmpty {
            spans.append(TextSpan(chunk, foreground: Self.textColor))
            return
        }
        // Walk the chunk left-to-right, alternating text-color and
        // dim-color segments. Marker ranges are sorted by start so a
        // simple sweep is sufficient (Phase A: no nested markers).
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
                    spans.append(TextSpan(segment, foreground: Self.textColor))
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
                spans.append(TextSpan(segment, foreground: Self.dimColor, italic: true))
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
            spans.append(TextSpan(segment, foreground: Self.textColor))
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
    /// Phase A intentionally keeps "paste again to expand" + auto-hint
    /// scaffolding integrated; the cursor-adjacency check fires when
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
        var lines = splitLines(text.get())

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
            (st.cursorRow, st.cursorCol) = absoluteOffsetToRowCol(endOffset, lines: lines)
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
        // point are split: not supported in Phase A (cursor snaps to
        // edges, so insertion inside a reference can't happen).
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
        text.set(lines.joined(separator: "\n"))
        adjustScroll(&st, maxVisibleLines: maxVisibleLines, wrapWidth: wrapWidth, lines: lines)
        state.set(st)
    }

    /// Convert an absolute character offset (counting `\n` as one
    /// character) back to `(row, col)` against `lines`. Used by the
    /// "paste again to expand" path to position the cursor at the
    /// end of the newly expanded range.
    static func absoluteOffsetToRowCol(_ offset: Int, lines: [String]) -> (row: Int, col: Int) {
        var remaining = offset
        for (i, line) in lines.enumerated() {
            if remaining <= line.count {
                return (i, remaining)
            }
            remaining -= line.count + 1   // +1 for the joining `\n`
        }
        let lastIdx = max(0, lines.count - 1)
        return (lastIdx, lines[lastIdx].count)
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
        boundaryMode: BoundaryFeedback = .bounce,
        onBoundaryHit: BoundaryHitCallback? = nil
    ) -> KeyEventResult {
        let content = text.get()
        var st = state.get()
        var lines = splitLines(content)
        let lineCount = lines.count

        // Clamp cursor
        st.cursorRow = min(st.cursorRow, lineCount - 1)
        st.cursorCol = min(st.cursorCol, lines[st.cursorRow].count)

        // Synthesize emit env slice — same pattern as TextInput/TextArea.
        var emitEnv = EnvironmentValues()
        emitEnv.boundaryFeedback = boundaryMode
        emitEnv.onBoundaryHit = onBoundaryHit

        switch event.key {
        // MARK: Submit (Enter) / Newline (Shift+Enter, Alt+Enter, Ctrl+Enter)
        case .enter where !event.modifiers.isEmpty:
            // Any modified Enter = insert newline (expand the input box).
            // Option+Enter is the universal fallback — Terminal.app cannot
            // distinguish Shift+Enter from plain Enter without kitty keyboard.
            let line = lines[st.cursorRow]
            let idx = line.index(line.startIndex, offsetBy: st.cursorCol)
            let before = String(line[..<idx])
            let after = String(line[idx...])
            lines[st.cursorRow] = before
            lines.insert(after, at: st.cursorRow + 1)
            st.cursorRow += 1
            st.cursorCol = 0
            text.set(lines.joined(separator: "\n"))
            adjustScroll(&st, maxVisibleLines: maxVisibleLines, wrapWidth: wrapWidth, lines: lines)
            state.set(st)
            return .handled

        case .enter:
            // Plain Enter = submit. The submitted text is the EXPANDED
            // binding content; references are stripped before
            // `onSubmit` fires (per design — receivers get pristine
            // text, marker UX is purely a display concern). History
            // entry preserves both so ↑-recall restores the marker
            // view alongside the text.
            let submitted = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !submitted.isEmpty {
                let snapshot = PromptInputHistoryEntry(
                    text: submitted,
                    buffers: st.buffers,
                    references: st.references
                )
                st.history.insert(snapshot, at: 0)
                st.historyIndex = -1
                st.savedInput = ""
                onSubmit?(submitted)
                text.set("")
                st.cursorRow = 0
                st.cursorCol = 0
                st.scrollDisplayRow = 0
                st.references = []  // Clear live references; buffers stay in pool.
            }
            state.set(st)
            return .handled

        // MARK: Character input
        case .character(let c):
            guard !event.modifiers.contains(.ctrl) && !event.modifiers.contains(.alt) else {
                return .ignored
            }
            let line = lines[st.cursorRow]
            let idx = line.index(line.startIndex, offsetBy: st.cursorCol)
            lines[st.cursorRow] = String(line[..<idx]) + String(c) + String(line[idx...])
            st.cursorCol += 1
            st.historyIndex = -1
            text.set(lines.joined(separator: "\n"))
            adjustScroll(&st, maxVisibleLines: maxVisibleLines, wrapWidth: wrapWidth, lines: lines)
            state.set(st)
            return .handled

        // MARK: Backspace
        case .backspace:
            // Atomic delete of a collapsed marker: if cursor sits at
            // the right edge of a collapsed reference, remove the
            // ENTIRE underlying range instead of one character. The
            // buffer stays in the pool (Phase B picker can re-insert).
            //
            // Compute current absolute cursor offset.
            var absCursor = 0
            for r in 0..<st.cursorRow { absCursor += lines[r].count + 1 }
            absCursor += st.cursorCol
            if let refIdx = st.references.firstIndex(where: {
                !$0.isExpanded && $0.start + $0.length == absCursor
            }) {
                let ref = st.references[refIdx]
                // Splice the underlying range out of `lines`.
                var joined = lines.joined(separator: "\n")
                let lo = joined.index(joined.startIndex, offsetBy: ref.start)
                let hi = joined.index(joined.startIndex, offsetBy: ref.start + ref.length)
                joined.removeSubrange(lo..<hi)
                lines = splitLines(joined)
                // Cursor lands where the marker used to start.
                (st.cursorRow, st.cursorCol) = absoluteOffsetToRowCol(ref.start, lines: lines)
                // Shift later refs left by `ref.length`. Remove this ref.
                let length = ref.length
                st.references.remove(at: refIdx)
                for i in 0..<st.references.count where st.references[i].start > ref.start {
                    st.references[i].start -= length
                }
                st.historyIndex = -1
                text.set(joined)
                adjustScroll(&st, maxVisibleLines: maxVisibleLines, wrapWidth: wrapWidth, lines: lines)
                state.set(st)
                return .handled
            }

            if st.cursorCol > 0 {
                let line = lines[st.cursorRow]
                let delIdx = line.index(line.startIndex, offsetBy: st.cursorCol - 1)
                let endIdx = line.index(line.startIndex, offsetBy: st.cursorCol)
                lines[st.cursorRow] = String(line[..<delIdx]) + String(line[endIdx...])
                st.cursorCol -= 1
            } else if st.cursorRow > 0 {
                // Merge with previous line
                let prevLen = lines[st.cursorRow - 1].count
                lines[st.cursorRow - 1] += lines[st.cursorRow]
                lines.remove(at: st.cursorRow)
                st.cursorRow -= 1
                st.cursorCol = prevLen
            }
            // After a single-char delete, shift any reference whose
            // range starts after the deletion offset left by 1.
            for i in 0..<st.references.count {
                if st.references[i].start > absCursor - 1 {
                    st.references[i].start -= 1
                }
            }
            text.set(lines.joined(separator: "\n"))
            adjustScroll(&st, maxVisibleLines: maxVisibleLines, wrapWidth: wrapWidth, lines: lines)
            state.set(st)
            return .handled

        // MARK: Delete
        case .delete:
            let line = lines[st.cursorRow]
            if st.cursorCol < line.count {
                let delIdx = line.index(line.startIndex, offsetBy: st.cursorCol)
                let endIdx = line.index(after: delIdx)
                lines[st.cursorRow] = String(line[..<delIdx]) + String(line[endIdx...])
            } else if st.cursorRow < lineCount - 1 {
                lines[st.cursorRow] += lines[st.cursorRow + 1]
                lines.remove(at: st.cursorRow + 1)
            }
            text.set(lines.joined(separator: "\n"))
            state.set(st)
            return .handled

        // MARK: Cursor movement
        case .left:
            if st.cursorCol > 0 {
                st.cursorCol -= 1
            } else if st.cursorRow > 0 {
                st.cursorRow -= 1
                st.cursorCol = lines[st.cursorRow].count
            } else {
                // Wall: cursor at (0, 0).
                BoundaryFeedbackEmitter.shared.emit(
                    reason: .leftEdge, env: emitEnv, callback: onBoundaryHit)
            }
            adjustScroll(&st, maxVisibleLines: maxVisibleLines, wrapWidth: wrapWidth, lines: lines)
            state.set(st)
            return .handled

        case .right:
            let lineLen = lines[st.cursorRow].count
            if st.cursorCol < lineLen {
                st.cursorCol += 1
            } else if st.cursorRow < lineCount - 1 {
                st.cursorRow += 1
                st.cursorCol = 0
            } else {
                // Wall: cursor at end of last logical row.
                BoundaryFeedbackEmitter.shared.emit(
                    reason: .rightEdge, env: emitEnv, callback: onBoundaryHit)
            }
            adjustScroll(&st, maxVisibleLines: maxVisibleLines, wrapWidth: wrapWidth, lines: lines)
            state.set(st)
            return .handled

        case .up:
            let moved = moveCursorUp(&st, lines: lines, wrapWidth: wrapWidth, arrowMode: arrowMode)
            var recalled = false
            if !moved {
                // At the visual top of the current input → recall history.
                if !st.history.isEmpty {
                    if st.historyIndex == -1 {
                        st.savedInput = text.get()
                    }
                    let nextIdx = min(st.historyIndex + 1, st.history.count - 1)
                    if nextIdx != st.historyIndex {
                        st.historyIndex = nextIdx
                        let entry = st.history[nextIdx]
                        text.set(entry.text)
                        // Restore reference-set snapshot too — markers
                        // re-appear on recall instead of devolving into
                        // raw paste content. Buffers stay in pool
                        // throughout, so re-binding by ID is enough.
                        st.references = entry.references
                        let newLines = splitLines(entry.text)
                        st.cursorRow = newLines.count - 1
                        st.cursorCol = newLines.last?.count ?? 0
                        recalled = true
                    }
                }
            }
            if !moved && !recalled {
                // Wall: arrow couldn't navigate AND no older history.
                BoundaryFeedbackEmitter.shared.emit(
                    reason: .topEdge, env: emitEnv, callback: onBoundaryHit)
            }
            adjustScroll(&st, maxVisibleLines: maxVisibleLines, wrapWidth: wrapWidth, lines: lines)
            state.set(st)
            return .handled

        case .down:
            let moved = moveCursorDown(&st, lines: lines, wrapWidth: wrapWidth, arrowMode: arrowMode)
            var advanced = false
            if !moved && st.historyIndex >= 0 {
                st.historyIndex -= 1
                if st.historyIndex < 0 {
                    text.set(st.savedInput)
                    st.references = []
                    let newLines = splitLines(st.savedInput)
                    st.cursorRow = newLines.count - 1
                    st.cursorCol = newLines.last?.count ?? 0
                } else {
                    let entry = st.history[st.historyIndex]
                    text.set(entry.text)
                    st.references = entry.references
                    let newLines = splitLines(entry.text)
                    st.cursorRow = newLines.count - 1
                    st.cursorCol = newLines.last?.count ?? 0
                }
                advanced = true
            }
            if !moved && !advanced {
                // Wall: arrow couldn't navigate AND no newer history.
                BoundaryFeedbackEmitter.shared.emit(
                    reason: .bottomEdge, env: emitEnv, callback: onBoundaryHit)
            }
            adjustScroll(&st, maxVisibleLines: maxVisibleLines, wrapWidth: wrapWidth, lines: lines)
            state.set(st)
            return .handled

        case .home:
            st.cursorCol = 0
            state.set(st)
            return .handled

        case .end:
            st.cursorCol = lines[st.cursorRow].count
            state.set(st)
            return .handled

        default:
            return .ignored
        }
    }

    // MARK: - Helpers

    static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [""] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

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
