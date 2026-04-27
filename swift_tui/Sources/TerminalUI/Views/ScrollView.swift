/// A view that scrolls its content along a single axis.
///
/// Measures inner content at unlimited size in the scroll axis, then clips
/// to the available viewport. Scroll offset auto-adjusts to keep the
/// keyboard-focused child visible (scroll-to-focused).
///
/// Usage:
/// ```swift
/// ScrollView(.horizontal) {
///     HStack {
///         ForEach(items) { item in
///             Text(item.name)
///         }
///     }
/// }
/// ```
public struct ScrollView<Content: TerminalView>: TerminalView {
    public let axes: ScrollAxis
    public let content: Content

    public init(_ axes: ScrollAxis = .vertical, @TerminalViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
    }

    public var body: Never { fatalError() }
}

/// Scroll direction — horizontal or vertical.
/// Separate from layout axis to avoid name collision with TerminalUI.Axis if one exists.
public enum ScrollAxis: Sendable, Equatable {
    case horizontal
    case vertical
}

/// Whether the framework paints the small edge glyphs that tell the user
/// "there is more content in this direction." Default `.visible` — the user
/// gets affordance out of the box. Hide per-view via `.scrollIndicators(.hidden)`.
public enum ScrollIndicatorVisibility: Sendable, Equatable {
    case visible
    case hidden
}

/// Type-erased identifier carried through the environment by
/// `.scrollPosition(id:)` to point an enclosing `ScrollView` at a
/// `.id(_:)`-tagged descendant. Exists as a Sendable wrapper because
/// `EnvironmentValues` itself is `Sendable` and bare `AnyHashable?`
/// is only conditionally Sendable on its inner type.
///
/// The framework relies on the same MainActor runtime invariant as
/// the rest of `EnvironmentValues` — env values are read during body
/// evaluation, which happens on the main actor. The `@unchecked`
/// marker formalises that contract for the type-system without
/// changing runtime behaviour.
public struct ScrollTargetID: Equatable, @unchecked Sendable {
    public let id: AnyHashable

    public init<ID: Hashable>(_ id: ID) {
        self.id = AnyHashable(id)
    }

    public static func == (lhs: ScrollTargetID, rhs: ScrollTargetID) -> Bool {
        lhs.id == rhs.id
    }
}

extension TerminalView {
    /// Show or hide the scroll-indicator glyphs on enclosed `ScrollView`s.
    public func scrollIndicators(_ visibility: ScrollIndicatorVisibility)
        -> ModifiedView<Self, EnvironmentModifier<ScrollIndicatorVisibility>> {
        environment(\.scrollIndicators, visibility)
    }

    /// Scroll an enclosing `ScrollView` so the descendant tagged with
    /// `.id(id)` stays visible. Independent of keyboard focus — the
    /// runtime adjusts the ScrollView's offset on every render so the
    /// targeted node sits inside the viewport.
    ///
    /// SwiftUI parity: `View.scrollPosition(id:)` (iOS 17+ / macOS 14+).
    /// HIG basis: *"Avoid changing focus without user interaction"* —
    /// `.scrollPosition` moves the viewport, NOT focus, so an
    /// app-driven autoscroll (chat tail, jump-to-bookmark) doesn't
    /// surprise the keyboard-focus location.
    ///
    /// Pass `nil` to clear an inherited target.
    public func scrollPosition<ID: Hashable>(id: ID?)
        -> ModifiedView<Self, EnvironmentModifier<ScrollTargetID?>> {
        environment(\.scrollTargetID, id.map { ScrollTargetID($0) })
    }

    /// Configure how `PromptInput` (and any descendant prompt-style
    /// inputs) handle paste. Default — `.claudeCode` shape — collapses
    /// pastes with newlines or over ~200 chars into a `[Pasted text #N
    /// +M lines]` marker. `.inline` keeps the legacy expand-everything
    /// behaviour; `.alwaysPlaceholder` collapses every paste.
    ///
    /// User direction (verbatim 2026-04-27):
    /// > *"by default we opt for claude code approach but otherwise
    /// > we also allow configurable, the user should be able to
    /// > define what they consider the proper trigger easily"*
    public func pasteMode(_ mode: PasteMode)
        -> ModifiedView<Self, EnvironmentModifier<PasteMode>> {
        environment(\.pasteMode, mode)
    }

    /// Show or hide the "paste again to expand" auto-hint row beneath
    /// `PromptInput`s in this subtree. Default `.visible`. Set
    /// `.hidden` to suppress when the hint would crowd the layout
    /// (e.g. status-bar-driven prompts).
    public func pasteHint(_ visibility: PasteHintVisibility)
        -> ModifiedView<Self, EnvironmentModifier<PasteHintVisibility>> {
        environment(\.pasteHint, visibility)
    }
}
