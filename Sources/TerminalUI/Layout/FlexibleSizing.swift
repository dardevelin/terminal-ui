// Flexible / responsive sizing.
//
// Apps need a way for components to claim "all available space" along
// one or both axes — like CSS flexbox grow, SwiftUI's
// `frame(maxWidth: .infinity)`, or HTML `width: 100%`. Today only
// `Spacer` and `ScrollView` participate in stack-axis flex distribution
// (see `GraphRenderer.isFlexChild` / `isVFlexChild`); arbitrary views
// can't say "fill remaining."
//
// This file ships the public surface:
//
//   - `FrameDimension` (an `Int`-or-`.infinity` value)
//   - `FrameAxes` (option-set: `.horizontal`, `.vertical`, `.all`)
//   - `FlexibleModifier` (`.flexible(_:grow:)`)
//
// `.frame(maxWidth: .infinity)` is the SwiftUI-shaped alias —
// `FrameDimension`'s `ExpressibleByIntegerLiteral` conformance keeps
// the existing `.frame(maxWidth: 40)` call sites working unchanged.

/// A frame dimension that's either a concrete cell count or
/// "expand to fill" along the relevant axis.
///
/// `ExpressibleByIntegerLiteral` lets `.frame(maxWidth: 40)` keep
/// working — the literal lowers to `.fixed(40)`.
public enum FrameDimension: Sendable, Equatable, ExpressibleByIntegerLiteral {
    /// An exact cell count on the axis.
    case fixed(Int)
    /// Expand to fill the remaining space on the axis — opts the view into
    /// the enclosing stack's flex distribution.
    case infinity

    public init(integerLiteral value: Int) { self = .fixed(value) }

    /// Non-failable promotion from a runtime `Int` so existing call
    /// sites that pass a computed cell count keep working without a
    /// `.fixed(...)` wrapper. Callers writing literals — `.frame(maxWidth: 40)`
    /// — go through `ExpressibleByIntegerLiteral` instead.
    public init(_ value: Int) { self = .fixed(value) }

    /// The cell count if this dimension is fixed, nil if infinity.
    public var fixedValue: Int? {
        switch self {
        case .fixed(let n): return n
        case .infinity: return nil
        }
    }
}

/// Axes along which a view participates in flex distribution.
///
/// Modeled as an option-set so callers can say `.horizontal`,
/// `.vertical`, or `.all`. Mirrors SwiftUI's `Axis.Set`.
public struct FrameAxes: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Flex along the width axis.
    public static let horizontal = FrameAxes(rawValue: 1 << 0)
    /// Flex along the height axis.
    public static let vertical   = FrameAxes(rawValue: 1 << 1)
    /// Flex along both axes — `.flexible()`'s default.
    public static let all: FrameAxes = [.horizontal, .vertical]
}

/// Modifier that opts a view into flex distribution along the given
/// axes. `grow` weights how much of the remainder this view claims
/// when sharing with other flex siblings (default 1, mirroring
/// flexbox's `flex-grow`).
public struct FlexibleModifier: ViewModifier {
    public typealias ModifierType = (FrameAxes, Int)
    /// The axes this view flexes on.
    public let axes: FrameAxes
    /// Share weight when splitting slack with flex siblings; clamped to
    /// at least 1.
    public let grow: Int
}

extension TerminalView {
    /// Opt this view into flex distribution along `axes`.
    ///
    /// Inside an `HStack`, `.flexible(.horizontal)` children divide
    /// remaining horizontal space by their `grow` weight after
    /// fixed-size siblings have claimed theirs. Inside a `VStack`,
    /// `.flexible(.vertical)` divides remaining vertical space.
    /// `.flexible()` applies to both axes.
    public func flexible(_ axes: FrameAxes = .all, grow: Int = 1) -> ModifiedView<Self, FlexibleModifier> {
        ModifiedView(content: self, modifier: FlexibleModifier(axes: axes, grow: max(1, grow)))
    }
}
