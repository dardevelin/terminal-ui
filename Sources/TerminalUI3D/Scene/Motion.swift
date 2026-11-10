import Foundation

/// Curves that take time, 0 to 1, to progress, 0 to 1, starting and
/// stopping gently: the difference between a model that is moved and one
/// that seems to have weight.
public enum Easing {
    /// 3t² − 2t³: no jump in speed at either end.
    public static func smoothstep(_ time: Double) -> Double {
        let clamped = min(1, max(0, time))
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// 6t⁵ − 15t⁴ + 10t³ (Perlin, "Improving Noise", SIGGRAPH 2002): no jump
    /// in speed or in acceleration at either end, so a turn winds up and
    /// settles as a weighted thing does.
    public static func smootherstep(_ time: Double) -> Double {
        let clamped = min(1, max(0, time))
        return clamped * clamped * clamped * (clamped * (clamped * 6 - 15) + 10)
    }
}

/// A model turning on a stand: a whole turn, eased up to speed and down to
/// rest, a pause, and again — with a slight wobble that follows the turn
/// and a slow roll, so it reads as a thing with weight rather than a
/// diagram spun at a constant rate. Lit from a fixed direction, its
/// highlight slides across the surface as it turns.
///
/// The timing is the Codex CLI's empty-state animation's: a turn every
/// 3.6 s, 82% of it moving, a wobble of about 6° and a roll of about 2.5°.
///
/// ```swift
/// TimelineView(.animation) { context in
///     let seconds = context.date.timeIntervalSinceReferenceDate
///     var scene = Scene3D()
///     scene.add(.torus(), transform: Turntable().rotation(at: seconds).matrix)
///     SceneView(scene).framing(.fit())
/// }
/// ```
public struct Turntable: Sendable, Equatable {
    /// What the model turns about.
    public var axis: Vector3
    /// Seconds from the start of one turn to the start of the next.
    public var period: Double
    /// The share of each period spent turning; the rest it holds still.
    public var turningShare: Double
    /// How far, in radians, the model tips back and forth as it turns.
    public var wobble: Double
    /// How far, in radians, it rolls, back and forth over two turns.
    public var roll: Double

    /// A turntable turning about `axis` every `period` seconds.
    public init(axis: Vector3 = .unitY, period: Double = Turntable.standardPeriod,
                turningShare: Double = Turntable.standardTurningShare,
                wobble: Double = Turntable.standardWobble, roll: Double = Turntable.standardRoll) {
        self.axis = axis
        self.period = period
        self.turningShare = turningShare
        self.wobble = wobble
        self.roll = roll
    }

    /// 3.6 seconds a turn.
    public static let standardPeriod = 3.6
    /// 82% of a period turning.
    public static let standardTurningShare = 0.82
    /// About 6°.
    public static let standardWobble = 0.112
    /// About 2.5°.
    public static let standardRoll = 0.045

    /// How far round the model has turned at `seconds`, in radians: whole
    /// turns, and the current one eased.
    public func angle(at seconds: Double) -> Double {
        guard period > 0, seconds.isFinite else { return 0 }
        let turns = (seconds / period).rounded(.down)
        let within = seconds / period - turns
        let eased = Easing.smootherstep(within / max(turningShare, .ulpOfOne))
        return (turns + eased) * 2 * .pi
    }

    /// The model's orientation at `seconds`.
    public func rotation(at seconds: Double) -> Quaternion {
        let angle = angle(at: seconds)
        let unit = axis.normalized == .zero ? Vector3.unitY : axis.normalized
        // Tip about an axis square to the turn, and roll about a third.
        let tipAxis = abs(unit.x) < Self.parallelLimit ? unit.cross(.unitX).normalized : unit.cross(.unitZ).normalized
        let rollAxis = unit.cross(tipAxis).normalized
        let rollPhase = guardedSeconds(seconds) / (period * 2) * 2 * .pi
        return Quaternion(axis: rollAxis, angle: sin(rollPhase) * roll)
            * Quaternion(axis: tipAxis, angle: sin(angle) * wobble)
            * Quaternion(axis: unit, angle: angle)
    }

    private func guardedSeconds(_ seconds: Double) -> Double {
        seconds.isFinite && period > 0 ? seconds.truncatingRemainder(dividingBy: period * 2) : 0
    }

    /// The component below which an axis has turned away from x.
    private static let parallelLimit = 0.9
}

/// A camera's path through a scene: stops it holds at and travels between,
/// eased out of each and into the next — a fly-over, or the route a map
/// follows.
///
/// ```swift
/// let tour = CameraTour([
///     .init(Camera3D(position: Vector3(0, 6, 9)), hold: 1, travel: 4),
///     .init(Camera3D(position: Vector3(8, 3, 0)), hold: 1, travel: 4),
/// ])
/// scene.camera = tour.camera(at: seconds)
/// ```
public struct CameraTour: Sendable, Equatable {
    /// A place on the tour.
    public struct Stop: Sendable, Equatable {
        /// What is seen from it.
        public var camera: Camera3D
        /// Seconds spent still there.
        public var hold: Double
        /// Seconds taken to reach the next stop.
        public var travel: Double

        /// A stop at `camera`, held `hold` seconds, `travel` from the next.
        public init(_ camera: Camera3D, hold: Double = 0, travel: Double = 1) {
            self.camera = camera
            self.hold = max(0, hold)
            self.travel = max(0, travel)
        }
    }

    /// The stops, in order.
    public var stops: [Stop]
    /// Whether the last stop travels back to the first and the tour goes
    /// round again; otherwise it ends at the last.
    public var loops: Bool

    /// A tour of `stops`, round and round unless `loops` is false.
    public init(_ stops: [Stop], loops: Bool = true) {
        self.stops = stops
        self.loops = loops
    }

    /// The seconds one time round takes.
    public var duration: Double {
        stops.enumerated().reduce(0) { total, entry in
            let isLast = entry.offset == stops.count - 1
            return total + entry.element.hold + (isLast && !loops ? 0 : entry.element.travel)
        }
    }

    /// Where the camera is at `seconds` into the tour.
    public func camera(at seconds: Double) -> Camera3D {
        guard let first = stops.first else { return Camera3D() }
        let total = duration
        guard stops.count > 1, total > 0, seconds.isFinite else { return first.camera }
        var time = loops ? seconds.truncatingRemainder(dividingBy: total) : min(seconds, total)
        if time < 0 { time += total }
        for (index, stop) in stops.enumerated() {
            if time < stop.hold { return stop.camera }
            time -= stop.hold
            let isLast = index == stops.count - 1
            if isLast && !loops { return stop.camera }
            let next = stops[isLast ? 0 : index + 1].camera
            if time < stop.travel {
                return stop.camera.interpolated(to: next, amount: Easing.smootherstep(time / stop.travel))
            }
            time -= stop.travel
        }
        return stops[loops ? 0 : stops.count - 1].camera
    }
}

extension Camera3D {
    /// The camera a fraction `amount` of the way to `other`: its position,
    /// target, up and clipping planes in between, and its projection that
    /// of whichever it is nearer.
    public func interpolated(to other: Camera3D, amount: Double) -> Camera3D {
        Camera3D(position: position.interpolated(to: other.position, amount: amount),
                 target: target.interpolated(to: other.target, amount: amount),
                 up: up.interpolated(to: other.up, amount: amount),
                 projection: amount < Self.halfway ? projection : other.projection,
                 near: near + (other.near - near) * amount, far: far + (other.far - far) * amount)
    }

    private static let halfway = 0.5
}
