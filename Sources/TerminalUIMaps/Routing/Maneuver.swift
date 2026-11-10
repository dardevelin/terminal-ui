/// What a traveller does at the start of a route step — OSRM's
/// `StepManeuver` (project-osrm.org/docs/v5.24.0/api/#stepmaneuver-object),
/// the model Mapbox's Directions API and Ferrostar's `ManeuverType` /
/// `ManeuverModifier` share.
public struct Maneuver: Sendable, Hashable, Codable {
    /// The kind of manoeuvre: OSRM's `maneuver.type`.
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case depart
        case turn
        case newName = "new name"
        case `continue`
        case merge
        case onRamp = "on ramp"
        case offRamp = "off ramp"
        case fork
        case endOfRoad = "end of road"
        case roundabout
        case rotary
        case roundaboutTurn = "roundabout turn"
        case exitRoundabout = "exit roundabout"
        case exitRotary = "exit rotary"
        case notification
        case arrive
    }

    /// Which way it goes: OSRM's `maneuver.modifier`.
    public enum Direction: String, Sendable, Hashable, Codable, CaseIterable {
        case uturn
        case sharpRight = "sharp right"
        case right
        case slightRight = "slight right"
        case straight
        case slightLeft = "slight left"
        case left
        case sharpLeft = "sharp left"
    }

    public var kind: Kind
    public var direction: Direction?
    /// The bearing the traveller arrives on, degrees clockwise from north.
    public var bearingBefore: Double?
    /// The bearing the traveller leaves on.
    public var bearingAfter: Double?
    /// The exit to take at a roundabout, counted from 1.
    public var exit: Int?

    public init(kind: Kind, direction: Direction? = nil, bearingBefore: Double? = nil,
                bearingAfter: Double? = nil, exit: Int? = nil) {
        self.kind = kind
        self.direction = direction
        self.bearingBefore = bearingBefore
        self.bearingAfter = bearingAfter
        self.exit = exit
    }

    /// The turn from one bearing to another, as a direction. The bands are
    /// OSRM's guidance (osrm-backend, `getTurnDirection` in
    /// `include/util/guidance/toolkit.hpp`), which measures an angle with
    /// 180° straight on: within 20° of straight is straight, to 40° slight,
    /// to 120° a plain turn, beyond that sharp. A reversal OSRM reserves
    /// exactly 180° for is taken here from 170°, as a polyline's last
    /// segment before a U-turn is rarely exact.
    static func direction(turningBy angle: Double) -> Direction {
        let magnitude = abs(angle)
        let right = angle >= 0
        switch magnitude {
        case ..<TurnBands.straight: return .straight
        case ..<TurnBands.slight: return right ? .slightRight : .slightLeft
        case ..<TurnBands.plain: return right ? .right : .left
        case ..<TurnBands.reversal: return right ? .sharpRight : .sharpLeft
        default: return .uturn
        }
    }

    /// The manoeuvre between two steps a router gave no type for — MapKit's
    /// `MKRoute.Step` has only a sentence and a polyline — from the bearing
    /// the traveller arrives on and the one they leave on: straight on is
    /// a new name, anything else a turn.
    static func inferred(bearingBefore: Double, bearingAfter: Double) -> Maneuver {
        let direction = direction(turningBy: GeoMeasure.turn(from: bearingBefore, to: bearingAfter))
        return Maneuver(kind: direction == .straight ? .newName : .turn, direction: direction,
                        bearingBefore: bearingBefore, bearingAfter: bearingAfter)
    }

    enum TurnBands {
        static let straight = 20.0
        static let slight = 40.0
        static let plain = 120.0
        static let reversal = 170.0
    }

    /// The sentence for the manoeuvre onto a road, or with none named.
    public func instruction(onto road: String?) -> String {
        let road = road ?? ""
        let onto = road.isEmpty ? "" : " onto \(road)"
        let way = (direction ?? .straight).words
        switch kind {
        case .depart:
            return road.isEmpty ? "Depart" : "Head along \(road)"
        case .arrive:
            return "Arrive at your destination"
        case .roundabout, .rotary, .roundaboutTurn:
            let exitWords = exit.map { " at exit \($0)" } ?? ""
            return "Enter the roundabout and leave\(exitWords)\(onto)"
        case .exitRoundabout, .exitRotary:
            return "Leave the roundabout\(onto)"
        case .merge:
            return "Merge \(way)\(onto)"
        case .fork:
            return "Keep \(way) at the fork\(onto)"
        case .onRamp:
            return "Take the ramp\(onto)"
        case .offRamp:
            return "Take the exit\(onto)"
        case .endOfRoad:
            return "At the end of the road, turn \(way)\(onto)"
        case .continue, .newName, .notification:
            return direction == nil || direction == .straight ? "Continue\(onto)" : "Continue \(way)\(onto)"
        case .turn:
            switch direction ?? .straight {
            case .straight: return "Go straight\(onto)"
            case .uturn: return "Make a U-turn\(onto)"
            case .slightLeft: return "Bear left\(onto)"
            case .slightRight: return "Bear right\(onto)"
            default: return "Turn \(way)\(onto)"
            }
        }
    }
}

extension Maneuver.Direction {
    /// The direction as words in a sentence: "slight left".
    public var words: String {
        switch self {
        case .uturn: "back"
        default: rawValue
        }
    }
}
