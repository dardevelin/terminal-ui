/// A view wrapped with a modifier — the value every chainable modifier
/// method (`.padding()`, `.foreground(_:)`, `.onKeyPress { }`) returns.
///
/// Pure composition data: it pairs the wrapped content with the modifier
/// value, and the graph layer turns the pair into a modifier node above the
/// content's nodes. Its `body` is `Never` for the same reason as the layout
/// primitives — the graph dispatches on the structure rather than
/// evaluating a body.
public struct ModifiedView<Content: TerminalView, Modifier: ViewModifier>: TerminalView {
    /// The wrapped view.
    public let content: Content
    /// The modifier value applied to ``content``.
    public let modifier: Modifier

    public var body: Never { fatalError() }
}

/// The marker every modifier value conforms to so ``ModifiedView`` can
/// carry it. Modifiers are inert data — the graph layer interprets each
/// concrete type; there is no `body(content:)` to implement.
public protocol ViewModifier {
    /// The payload type this modifier configures — informational; the
    /// graph dispatches on the concrete modifier type, not on this.
    associatedtype ModifierType
}

/// Payload of `.foreground(_:)` — text color for the subtree.
public struct ForegroundModifier: ViewModifier {
    public typealias ModifierType = Color
    /// The foreground color applied; inner modifiers win over outer ones.
    public let color: Color
}

/// Payload of `.background(_:)` — fill color behind the subtree's rect.
public struct BackgroundModifier: ViewModifier {
    public typealias ModifierType = Color
    /// The fill color painted across the view's laid-out rect.
    public let color: Color
}

/// Payload of `.bold()`. Carries no data — presence is the whole signal.
public struct BoldModifier: ViewModifier {
    public typealias ModifierType = Bool
}

/// Payload of `.italic()`. Carries no data — presence is the whole signal.
public struct ItalicModifier: ViewModifier {
    public typealias ModifierType = Bool
}

/// Payload of `.underline()`. Carries no data — presence is the whole
/// signal.
public struct UnderlineModifier: ViewModifier {
    public typealias ModifierType = Bool
}

/// Payload of `.padding(_:)` — uniform space inside the view's rect.
public struct PaddingModifier: ViewModifier {
    public typealias ModifierType = Int
    /// Blank cells added on all four sides.
    public let amount: Int
}

/// Payload of `.border(_:)` — a one-cell box-drawing frame.
public struct BorderModifier: ViewModifier {
    public typealias ModifierType = BorderStyle
    /// Which box-drawing glyph set the frame uses.
    public let style: BorderStyle
}

/// Payload of `.frame(...)` — fixed or bounded dimensions for the view's
/// rect.
///
/// `width` / `height` are `Int?` since SwiftUI doesn't accept `.infinity`
/// in those slots either ("fixed size or no constraint"); the min/max
/// bounds are ``FrameDimension`` so `.frame(maxWidth: .infinity)` opts
/// into flex distribution, while integer literals keep
/// `.frame(maxWidth: 40)` call sites working unchanged.
public struct FrameModifier: ViewModifier {
    public typealias ModifierType = (Int?, Int?)
    /// Fixed width in cells; `nil` leaves width unconstrained.
    public let width: Int?
    /// Fixed height in rows; `nil` leaves height unconstrained.
    public let height: Int?
    /// Width floor; `nil` for no minimum.
    public var minWidth: FrameDimension?
    /// Width ceiling; `.infinity` opts into flex distribution, `nil` for
    /// no maximum.
    public var maxWidth: FrameDimension?
    /// Height floor; `nil` for no minimum.
    public var minHeight: FrameDimension?
    /// Height ceiling; `.infinity` opts into flex distribution, `nil` for
    /// no maximum.
    public var maxHeight: FrameDimension?
    /// Where the content sits when the frame is bigger than it is. Without
    /// this a view smaller than its frame had no stated placement rule and
    /// simply drew from the top-left corner.
    public var alignment: Alignment = .topLeading
}

/// Payload of `.id(_:)` — explicit node identity for scroll targeting and
/// reconciliation.
public struct IDModifier: ViewModifier {
    public typealias ModifierType = AnyHashable
    /// The erased identity value; `.scrollPosition(id:)` matches against
    /// it.
    public let id: AnyHashable
}

// Chainable modifier methods on all TerminalViews
extension TerminalView {
    /// Set the text color for this view and its descendants. Inner
    /// `.foreground` calls win over outer ones, so a subtree can override
    /// its container's color.
    public func foreground(_ color: Color) -> ModifiedView<Self, ForegroundModifier> {
        ModifiedView(content: self, modifier: ForegroundModifier(color: color))
    }

    /// Fill the view's cells with a background color. Covers the view's
    /// laid-out rect, including padding applied *inside* this modifier —
    /// order the chain as `.padding().background(...)` to color the padded
    /// area.
    public func background(_ color: Color) -> ModifiedView<Self, BackgroundModifier> {
        ModifiedView(content: self, modifier: BackgroundModifier(color: color))
    }

    /// Render descendant text bold (SGR 1). Terminals map this to a heavier
    /// face, a brighter color, or both — the terminal's choice, not the
    /// framework's.
    public func bold() -> ModifiedView<Self, BoldModifier> {
        ModifiedView(content: self, modifier: BoldModifier())
    }

    /// Render descendant text italic (SGR 3). Some terminal/font pairs
    /// substitute reverse video or ignore it; use color or ``bold()`` when
    /// the distinction must survive everywhere.
    public func italic() -> ModifiedView<Self, ItalicModifier> {
        ModifiedView(content: self, modifier: ItalicModifier())
    }

    /// Underline descendant text (SGR 4). Reliable across terminals, which
    /// makes it the safest emphasis for links and active selections.
    public func underline() -> ModifiedView<Self, UnderlineModifier> {
        ModifiedView(content: self, modifier: UnderlineModifier())
    }

    /// Inset the view by `amount` cells on all four sides (default 1).
    /// Cells are ~twice as tall as wide, so equal insets look taller than
    /// they are wide — 1 is usually enough.
    public func padding(_ amount: Int = 1) -> ModifiedView<Self, PaddingModifier> {
        ModifiedView(content: self, modifier: PaddingModifier(amount: amount))
    }

    /// Draw a one-cell box-drawing border around the view (default
    /// `.rounded`), adding 2 cells to each axis of its footprint. Apply
    /// `.padding()` inside the border to keep content off the frame.
    public func border(_ style: BorderStyle = .rounded) -> ModifiedView<Self, BorderModifier> {
        ModifiedView(content: self, modifier: BorderModifier(style: style))
    }

    /// Fix the view's size in cells on either or both axes; content larger
    /// than the frame is clipped, smaller content is placed by `alignment`.
    ///
    /// - Parameters:
    ///   - width: exact width in cells; nil leaves the axis to the layout.
    ///   - height: exact height in cells; nil leaves the axis to the layout.
    ///   - alignment: where the content sits inside the frame when
    ///     the frame is the larger of the two. `.topLeading` by default, as
    ///     everywhere else in this framework — SwiftUI centres, and changing
    ///     that here would move every view already written against a frame.
    public func frame(width: Int? = nil, height: Int? = nil,
                      alignment: Alignment = .topLeading) -> ModifiedView<Self, FrameModifier> {
        ModifiedView(content: self, modifier: FrameModifier(
            width: width, height: height, alignment: alignment
        ))
    }

    /// Constrain the view's size in cells with min/max bounds instead of
    /// exact values. `.frame(maxWidth: .infinity)` opts the view into flex
    /// distribution along that axis — the terminal idiom for "take the
    /// remaining space"; integer literals give fixed bounds
    /// (`.frame(maxWidth: 40)`). `nil` leaves that constraint to the layout,
    /// and `alignment` places content when the resolved frame is larger.
    public func frame(minWidth: FrameDimension? = nil, maxWidth: FrameDimension? = nil,
                      minHeight: FrameDimension? = nil, maxHeight: FrameDimension? = nil,
                      alignment: Alignment = .topLeading) -> ModifiedView<Self, FrameModifier> {
        ModifiedView(content: self, modifier: FrameModifier(
            width: nil, height: nil,
            minWidth: minWidth, maxWidth: maxWidth,
            minHeight: minHeight, maxHeight: maxHeight,
            alignment: alignment
        ))
    }

    /// Give the view an explicit identity. When the id changes between
    /// frames the graph treats the subtree as a new view — state resets and
    /// `onAppear` fires again — instead of updating it in place. Use it to
    /// force a fresh start, or to make identity explicit in dynamic content.
    public func id<ID: Hashable>(_ id: ID) -> ModifiedView<Self, IDModifier> {
        ModifiedView(content: self, modifier: IDModifier(id: AnyHashable(id)))
    }
}
