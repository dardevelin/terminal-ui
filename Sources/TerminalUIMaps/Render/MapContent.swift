/// Something a ``MapView`` draws over its basemap — SwiftUI MapKit's
/// `MapContent`: a ``Marker`` or a ``MapPolyline``, listed in the map's
/// content closure.
public protocol MapContent {
    /// The items it adds, in the order they are drawn.
    var mapElements: [MapElement] { get }
}

/// One item of a map's content.
public enum MapElement: Sendable, Equatable {
    case marker(Marker)
    case polyline(MapPolyline)
    case traveller(TravellerMarker)
}

/// Where the traveller is: an arrow pointing their way on the screen —
/// their course less the camera's bearing — or a dot when they have no
/// course. SwiftUI MapKit's `UserAnnotation`.
public struct TravellerMarker: MapContent, Sendable, Equatable {
    public var coordinate: GeoCoordinate
    /// Degrees clockwise from north; nil standing still.
    public var course: Double?

    public init(coordinate: GeoCoordinate, course: Double? = nil) {
        self.coordinate = coordinate
        self.course = course
    }

    public var mapElements: [MapElement] { [.traveller(self)] }

    /// The arrows of the eight directions, clockwise from up: the screen's,
    /// not the compass's.
    static let arrows = ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"]
    /// No course to point.
    static let dot = "●"

    /// The glyph for a course seen through a camera turned to `bearing`.
    public static func glyph(course: Double?, bearing: Double) -> String {
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
    public var title: String
    public var coordinate: GeoCoordinate

    public init(_ title: String, coordinate: GeoCoordinate) {
        self.title = title
        self.coordinate = coordinate
    }

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

    public var coordinates: [GeoCoordinate]
    /// How many braille dots wide it is drawn.
    public var lineWidth: Double
    public var style: Style

    /// The width a polyline is drawn at unless given one: wider than any
    /// road but the biggest, so a route reads over the streets it follows.
    public static let defaultLineWidth = 2.0

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

    public var mapElements: [MapElement] { [.polyline(self)] }
}

/// Content made of other content, as a ``MapContentBuilder`` gathers it.
public struct MapContentGroup: MapContent, Sendable, Equatable {
    public var mapElements: [MapElement]

    public init(_ elements: [MapElement] = []) {
        mapElements = elements
    }
}

/// Builds a map's content from a list of markers and polylines, with `if`,
/// `switch` and `for` — SwiftUI MapKit's `MapContentBuilder`.
@resultBuilder
public enum MapContentBuilder {
    public static func buildExpression(_ content: some MapContent) -> MapContentGroup {
        MapContentGroup(content.mapElements)
    }

    public static func buildBlock(_ components: MapContentGroup...) -> MapContentGroup {
        MapContentGroup(components.flatMap(\.mapElements))
    }

    public static func buildOptional(_ component: MapContentGroup?) -> MapContentGroup {
        component ?? MapContentGroup()
    }

    public static func buildEither(first component: MapContentGroup) -> MapContentGroup { component }

    public static func buildEither(second component: MapContentGroup) -> MapContentGroup { component }

    public static func buildArray(_ components: [MapContentGroup]) -> MapContentGroup {
        MapContentGroup(components.flatMap(\.mapElements))
    }
}
