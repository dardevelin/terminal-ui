import Foundation

/// Which side of the road a place lies, seen along the way the traveller
/// arrives.
public enum ArrivalSide: String, Sendable, Equatable {
    /// On the traveller's left.
    case left
    /// On the traveller's right.
    case right
    /// Straight on, past the route's end.
    case ahead
    /// Back the way the traveller came.
    case behind
}

/// Where a route meets the places it joins: a router ends a route on the
/// road nearest the destination and starts it on the road nearest the
/// origin, so the place itself is a short walk off the line. Apple and
/// Google Maps draw that walk dotted, and say which side the destination
/// is on ("Your destination is on the left").
public struct RouteEnds: MapContent, Sendable, Equatable {
    /// Thresholds for what counts as a gap and as a side.
    public struct Configuration: Sendable, Equatable {
        /// Metres apart under which the place is on the route: a GPS fix's
        /// accuracy, no gap worth drawing.
        public var smallestGap = 5.0
        /// Within this many degrees of straight on, the place is ahead
        /// rather than to a side; as far from straight back, behind.
        public var aheadAngle = 30.0
        /// Metres of the route's end the arrival's direction is read over:
        /// a step's bearing span.
        public var bearingSpan = StepShapes.bearingSpan

        /// The default thresholds, each as its property states.
        public init() {}
    }

    /// The dashed line from the route's end to the destination, if they
    /// are apart.
    public var destinationConnector: [GeoCoordinate]?
    /// The dashed line from where the traveller set off to the route's
    /// start, if they are apart.
    public var originConnector: [GeoCoordinate]?
    /// Metres from the route's end to the destination.
    public var destinationGap: Double
    /// Which side the destination lies, seen arriving.
    public var side: ArrivalSide?

    /// The ends of `route`, which runs from near `origin` to near
    /// `destination`.
    public init(route: Route, origin: GeoCoordinate?, destination: GeoCoordinate?,
                configuration: Configuration = Configuration()) {
        let line = RouteLine(route.coordinates)
        destinationGap = 0
        if let destination, let end = route.coordinates.last {
            destinationGap = GeoMeasure.distance(end, destination)
            if destinationGap >= configuration.smallestGap {
                destinationConnector = [end, destination]
                if let arriving = line.bearing(from: max(0, line.length - configuration.bearingSpan), to: line.length) {
                    let turn = GeoMeasure.turn(from: arriving, to: GeoMeasure.bearing(end, destination))
                    side = abs(turn) < configuration.aheadAngle ? .ahead
                        : abs(turn) > Degrees.halfTurn - configuration.aheadAngle ? .behind
                        : turn < 0 ? .left : .right
                }
            }
        }
        if let origin, let start = route.coordinates.first,
           GeoMeasure.distance(origin, start) >= configuration.smallestGap {
            originConnector = [origin, start]
        }
    }

    /// The connectors as map content.
    public var mapElements: [MapElement] {
        [originConnector, destinationConnector].compactMap { $0 }.map {
            .polyline(MapPolyline(coordinates: $0, lineWidth: 0, style: .connector))
        }
    }

    /// "Public Library, 25 m on your left": the destination's name, how far
    /// it is from the route's end and which side; just the name when it is
    /// on the route.
    public func arrivalWords(destination name: String) -> String {
        guard let side else { return name }
        let distance = NavigationWording.distance(destinationGap)
        switch side {
        case .left, .right: return "\(name), \(distance) on your \(side.rawValue)"
        case .ahead: return "\(name), \(distance) ahead"
        case .behind: return "\(name), \(distance) behind you"
        }
    }
}
