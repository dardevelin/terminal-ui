/// Something a ``MapView`` draws over its basemap — SwiftUI MapKit's
/// `MapContent`: a ``Marker`` or a ``MapPolyline``, listed in the map's
/// content closure.
public protocol MapContent {
    /// The items it adds, in the order they are drawn.
    var mapElements: [MapElement] { get }
}

/// One item of a map's content: what a ``Marker``, a ``MapPolyline`` or a
/// ``TravellerMarker`` adds, gathered in a ``MapContentGroup``.
public struct MapElement: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case marker(Marker)
        case polyline(MapPolyline)
        case traveller(TravellerMarker)
    }

    let kind: Kind

    static func marker(_ marker: Marker) -> MapElement { MapElement(kind: .marker(marker)) }
    static func polyline(_ polyline: MapPolyline) -> MapElement { MapElement(kind: .polyline(polyline)) }
    static func traveller(_ traveller: TravellerMarker) -> MapElement { MapElement(kind: .traveller(traveller)) }
}

/// Where the traveller is: an arrow pointing their way on the screen —
/// their course less the camera's bearing — or a dot when they have no
/// course. SwiftUI MapKit's `UserAnnotation`.
public struct TravellerMarker: MapContent, Sendable, Equatable {
    /// Where the traveller is.
    public var coordinate: GeoCoordinate
    /// Degrees clockwise from north; nil standing still.
    public var course: Double?

    /// The traveller at `coordinate`, heading on `course` where they move.
    public init(coordinate: GeoCoordinate, course: Double? = nil) {
        self.coordinate = coordinate
        self.course = course
    }

    /// The traveller's arrow or dot, as one element.
    public var mapElements: [MapElement] { [.traveller(self)] }

    /// The arrows of the eight directions, clockwise from up: the screen's,
    /// not the compass's.
    static let arrows = ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"]
    /// No course to point.
    static let dot = "●"

    /// The glyph for a course seen through a camera turned to `bearing`.
    static func glyph(course: Double?, bearing: Double) -> String {
        guard let course else { return dot }
        let onScreen = GeoMeasure.normalizedBearing(course - bearing)
        let sector = Degrees.fullTurn / Double(arrows.count)
        return arrows[Int((onScreen / sector).rounded()) % arrows.count]
    }
}

/// A pin at a coordinate with its title beside it — SwiftUI MapKit's
/// `Marker`. Its title is placed before every name of the basemap's, so it
/// is never the one dropped.
///
/// ```swift
/// MapView(camera: $camera, store: store) {
///     Marker("The Copper Kettle", coordinate: cafe)
/// }
/// ```
public struct Marker: MapContent, Sendable, Equatable {
    /// The text beside the pin.
    public var title: String
    /// Where the pin stands.
    public var coordinate: GeoCoordinate

    /// A pin titled `title` at `coordinate`.
    public init(_ title: String, coordinate: GeoCoordinate) {
        self.title = title
        self.coordinate = coordinate
    }

    /// The pin and its title, as one element.
    public var mapElements: [MapElement] { [.marker(self)] }
}

/// A line through coordinates — SwiftUI MapKit's `MapPolyline`, the shape
/// a route is drawn as.
///
/// ```swift
/// MapView(camera: $camera, store: store) {
///     MapPolyline(coordinates: route.coordinates)
/// }
/// ```
public struct MapPolyline: MapContent, Sendable, Equatable {
    /// How a line reads against the others.
    public enum Style: Sendable, Equatable {
        /// In the theme's accent: a route to follow.
        case route
        /// The accent faded toward the ground: the part of a route already
        /// travelled.
        case travelled
        /// Dashed in the accent: the walk between a route's end on the road
        /// and the place itself, or from where the traveller is to where the
        /// route begins — the dotted line Apple and Google Maps draw there.
        case connector
    }

    /// The points the line runs through, in order.
    public var coordinates: [GeoCoordinate]
    /// How many braille dots wide it is drawn.
    public var lineWidth: Double
    /// How the line reads against the others.
    public var style: Style

    /// The width a polyline is drawn at unless given one: wider than any
    /// road but the biggest, so a route reads over the streets it follows.
    public static let defaultLineWidth = 2.0

    /// A line through `coordinates`, `lineWidth` braille dots wide, drawn in
    /// `style`.
    public init(coordinates: [GeoCoordinate], lineWidth: Double = MapPolyline.defaultLineWidth,
                style: Style = .route) {
        self.coordinates = coordinates
        self.lineWidth = lineWidth
        self.style = style
    }

    /// A route's path.
    public init(_ route: Route, lineWidth: Double = MapPolyline.defaultLineWidth) {
        self.init(coordinates: route.coordinates, lineWidth: lineWidth)
    }

    /// The line, as one element.
    public var mapElements: [MapElement] { [.polyline(self)] }
}

/// Content made of other content, as a ``MapContentBuilder`` gathers it.
public struct MapContentGroup: MapContent, Sendable, Equatable {
    /// The items gathered, in the order they are drawn.
    public var mapElements: [MapElement]

    /// A group of `elements`; none by default.
    public init(_ elements: [MapElement] = []) {
        mapElements = elements
    }
}

/// Builds a map's content from a list of markers and polylines, with `if`,
/// `switch` and `for` — SwiftUI MapKit's `MapContentBuilder`.
@resultBuilder
public enum MapContentBuilder {
    /// One marker, polyline or group of content, as a group.
    public static func buildExpression(_ content: some MapContent) -> MapContentGroup {
        MapContentGroup(content.mapElements)
    }

    /// The content listed in a closure, in order.
    public static func buildBlock(_ components: MapContentGroup...) -> MapContentGroup {
        MapContentGroup(components.flatMap(\.mapElements))
    }

    /// The content of an `if` without an `else`; nothing when it is false.
    public static func buildOptional(_ component: MapContentGroup?) -> MapContentGroup {
        component ?? MapContentGroup()
    }

    /// The content of an `if`'s first branch or a `switch`'s case.
    public static func buildEither(first component: MapContentGroup) -> MapContentGroup { component }

    /// The content of an `if`'s `else` or a `switch`'s later case.
    public static func buildEither(second component: MapContentGroup) -> MapContentGroup { component }

    /// The content a `for` loop gives, every pass's in order.
    public static func buildArray(_ components: [MapContentGroup]) -> MapContentGroup {
        MapContentGroup(components.flatMap(\.mapElements))
    }
}
