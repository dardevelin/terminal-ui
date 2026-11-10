// MARK: - Geometry

/// A position on a ``Canvas``, in cells: `x` columns from the left edge,
/// `y` rows from the top. SwiftUI's `CGPoint`, on a cell grid.
///
/// Fractions address the inside of a cell — `CanvasPoint(x: 2.5, y: 1.25)`
/// is the middle column of the third cell across, a quarter of the way down
/// the second row — which is where strokes and fills find their sub-cell
/// detail.
public struct CanvasPoint: Equatable, Hashable, Sendable {
    /// Columns from the canvas's left edge.
    public var x: Double
    /// Rows from the canvas's top edge.
    public var y: Double

    /// A point `x` columns across and `y` rows down.
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// The canvas's top-left corner.
    public static let zero = CanvasPoint(x: 0, y: 0)
}

/// An extent on a ``Canvas``, in cells. SwiftUI's `CGSize`, on a cell grid:
/// what a canvas's renderer is handed as the size it was given.
public struct CanvasSize: Equatable, Hashable, Sendable {
    /// Columns.
    public var width: Double
    /// Rows.
    public var height: Double

    /// A size `width` columns wide and `height` rows tall.
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// No extent at all.
    public static let zero = CanvasSize(width: 0, height: 0)
}

/// A rectangle on a ``Canvas``, in cells — SwiftUI's `CGRect`, and the same
/// `LayoutRect` the pixel backends use, so it reads `CanvasRect(x:y:width:height:)`.
public typealias CanvasRect = LayoutRect<Double>

/// A point in a rectangle's own unit square: `(0, 0)` its top-leading corner,
/// `(1, 1)` its bottom-trailing one. SwiftUI's `UnitPoint`; a ``Canvas``
/// anchors text by it.
public struct UnitPoint: Equatable, Hashable, Sendable {
    /// The fraction of the width across, `0` at the leading edge.
    public var x: Double
    /// The fraction of the height down, `0` at the top edge.
    public var y: Double

    /// The point `x` of the width across and `y` of the height down.
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// The top-leading corner, `(0, 0)`.
    public static let zero = UnitPoint(x: 0, y: 0)
    /// The middle, `(0.5, 0.5)`.
    public static let center = UnitPoint(x: 0.5, y: 0.5)
    /// The middle of the leading edge.
    public static let leading = UnitPoint(x: 0, y: 0.5)
    /// The middle of the trailing edge.
    public static let trailing = UnitPoint(x: 1, y: 0.5)
    /// The middle of the top edge.
    public static let top = UnitPoint(x: 0.5, y: 0)
    /// The middle of the bottom edge.
    public static let bottom = UnitPoint(x: 0.5, y: 1)
    /// The top-leading corner.
    public static let topLeading = UnitPoint(x: 0, y: 0)
    /// The top-trailing corner.
    public static let topTrailing = UnitPoint(x: 1, y: 0)
    /// The bottom-leading corner.
    public static let bottomLeading = UnitPoint(x: 0, y: 1)
    /// The bottom-trailing corner.
    public static let bottomTrailing = UnitPoint(x: 1, y: 1)
}

// MARK: - Path

/// The outline of a 2D shape, in cells, for a ``GraphicsContext`` to stroke,
/// fill or clip to — SwiftUI's `Path`.
///
/// A path is a list of subpaths, each begun by ``move(to:)`` and made of
/// straight lines and Bézier curves. Curves are kept exact here and
/// flattened when drawn, finely enough for the resolution they are drawn at.
///
/// ```swift
/// var river = Path()
/// river.move(to: CanvasPoint(x: 0, y: 4))
/// river.addQuadCurve(to: CanvasPoint(x: 30, y: 6), control: CanvasPoint(x: 15, y: 0))
///
/// let lake = Path(ellipseIn: CanvasRect(x: 8, y: 2, width: 10, height: 4))
/// ```
public struct Path: Equatable, Sendable {
    /// One step of a path, as ``GraphicsContext`` walks it.
    enum Element: Equatable, Sendable {
        case move(to: CanvasPoint)
        case line(to: CanvasPoint)
        case quadCurve(to: CanvasPoint, control: CanvasPoint)
        case curve(to: CanvasPoint, control1: CanvasPoint, control2: CanvasPoint)
        case closeSubpath
    }

    private(set) var elements: [Element] = []
    /// Where the open subpath began, which ``closeSubpath()`` returns to.
    private var subpathStart: CanvasPoint?

    /// The point the next segment starts from, or nil before the first
    /// ``move(to:)``.
    public private(set) var currentPoint: CanvasPoint?

    /// An empty path.
    public init() {}

    /// A closed rectangle.
    public init(_ rect: CanvasRect) {
        addRect(rect)
    }

    /// A closed ellipse inscribed in `rect`.
    public init(ellipseIn rect: CanvasRect) {
        addEllipse(in: rect)
    }

    /// The path `build` makes, starting from an empty one.
    ///
    /// ```swift
    /// let triangle = Path { path in
    ///     path.addLines([CanvasPoint(x: 0, y: 4), CanvasPoint(x: 4, y: 0), CanvasPoint(x: 8, y: 4)])
    ///     path.closeSubpath()
    /// }
    /// ```
    public init(_ build: (inout Path) -> Void) {
        build(&self)
    }

    /// Whether the path has no elements at all.
    public var isEmpty: Bool { elements.isEmpty }

    /// The smallest rectangle holding every point of the path, control
    /// points included; `.zero` for an empty path.
    public var boundingRect: CanvasRect {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        func include(_ point: CanvasPoint) {
            minX = Swift.min(minX, point.x)
            minY = Swift.min(minY, point.y)
            maxX = Swift.max(maxX, point.x)
            maxY = Swift.max(maxY, point.y)
        }
        for element in elements {
            switch element {
            case .move(let point), .line(let point):
                include(point)
            case .quadCurve(let point, let control):
                include(point)
                include(control)
            case .curve(let point, let control1, let control2):
                include(point)
                include(control1)
                include(control2)
            case .closeSubpath:
                break
            }
        }
        guard minX <= maxX else { return CanvasRect(x: 0, y: 0, width: 0, height: 0) }
        return CanvasRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Begin a new subpath at `point`.
    public mutating func move(to point: CanvasPoint) {
        elements.append(.move(to: point))
        subpathStart = point
        currentPoint = point
    }

    /// A straight line from the current point to `point`. With no current
    /// point it begins a subpath there instead, as Core Graphics does.
    public mutating func addLine(to point: CanvasPoint) {
        guard currentPoint != nil else { return move(to: point) }
        elements.append(.line(to: point))
        currentPoint = point
    }

    /// A new subpath through `points` in turn: a move to the first, and a
    /// line to each one after.
    public mutating func addLines(_ points: [CanvasPoint]) {
        guard let first = points.first else { return }
        move(to: first)
        for point in points.dropFirst() {
            addLine(to: point)
        }
    }

    /// A closed rectangle, as a subpath of its own, drawn clockwise from its
    /// top-left corner.
    public mutating func addRect(_ rect: CanvasRect) {
        move(to: CanvasPoint(x: rect.x, y: rect.y))
        addLine(to: CanvasPoint(x: rect.x + rect.width, y: rect.y))
        addLine(to: CanvasPoint(x: rect.x + rect.width, y: rect.y + rect.height))
        addLine(to: CanvasPoint(x: rect.x, y: rect.y + rect.height))
        closeSubpath()
    }

    /// A closed ellipse inscribed in `rect`, as a subpath of its own, drawn
    /// clockwise from the middle of its trailing edge.
    public mutating func addEllipse(in rect: CanvasRect) {
        // Four cubic Béziers, one per quadrant, with the control points at
        // κ = 4(√2 − 1)/3 of each radius along the tangents: the standard
        // approximation, which puts each quadrant's midpoint on the circle
        // and strays from it nowhere by more than 0.03% of the radius.
        let kappa = 0.552_284_749_830_793_4
        let radiusX = rect.width / 2, radiusY = rect.height / 2
        let centreX = rect.x + radiusX, centreY = rect.y + radiusY
        let handleX = radiusX * kappa, handleY = radiusY * kappa
        move(to: CanvasPoint(x: centreX + radiusX, y: centreY))
        addCurve(to: CanvasPoint(x: centreX, y: centreY + radiusY),
                 control1: CanvasPoint(x: centreX + radiusX, y: centreY + handleY),
                 control2: CanvasPoint(x: centreX + handleX, y: centreY + radiusY))
        addCurve(to: CanvasPoint(x: centreX - radiusX, y: centreY),
                 control1: CanvasPoint(x: centreX - handleX, y: centreY + radiusY),
                 control2: CanvasPoint(x: centreX - radiusX, y: centreY + handleY))
        addCurve(to: CanvasPoint(x: centreX, y: centreY - radiusY),
                 control1: CanvasPoint(x: centreX - radiusX, y: centreY - handleY),
                 control2: CanvasPoint(x: centreX - handleX, y: centreY - radiusY))
        addCurve(to: CanvasPoint(x: centreX + radiusX, y: centreY),
                 control1: CanvasPoint(x: centreX + handleX, y: centreY - radiusY),
                 control2: CanvasPoint(x: centreX + radiusX, y: centreY - handleY))
        closeSubpath()
    }

    /// A quadratic Bézier curve from the current point to `point`, pulled
    /// toward `control`.
    public mutating func addQuadCurve(to point: CanvasPoint, control: CanvasPoint) {
        guard currentPoint != nil else { return move(to: point) }
        elements.append(.quadCurve(to: point, control: control))
        currentPoint = point
    }

    /// A cubic Bézier curve from the current point to `point`, leaving
    /// toward `control1` and arriving from `control2`.
    public mutating func addCurve(to point: CanvasPoint, control1: CanvasPoint, control2: CanvasPoint) {
        guard currentPoint != nil else { return move(to: point) }
        elements.append(.curve(to: point, control1: control1, control2: control2))
        currentPoint = point
    }

    /// Close the open subpath with a straight line back to where it began.
    /// The current point returns there too.
    public mutating func closeSubpath() {
        guard let start = subpathStart else { return }
        elements.append(.closeSubpath)
        currentPoint = start
    }

    /// Every subpath of `path`, appended after this one's.
    public mutating func addPath(_ path: Path) {
        elements.append(contentsOf: path.elements)
        subpathStart = path.subpathStart ?? subpathStart
        currentPoint = path.currentPoint ?? currentPoint
    }
}
