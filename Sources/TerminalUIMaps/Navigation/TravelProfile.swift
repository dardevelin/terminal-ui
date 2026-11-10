/// A zoom the following camera takes at a speed: one row of a profile's
/// table, interpolated between.
struct SpeedZoom: Sendable, Equatable {
    /// Metres a second.
    var speed: Double
    /// This library's camera zoom, whose tile is 256 braille dots.
    var zoom: Double

    init(speed: Double, zoom: Double) {
        self.speed = speed
        self.zoom = zoom
    }
}

/// How a traveller moves, and so how the map follows them: a car, a bicycle
/// or someone on foot. Each sets how far the camera stands back at each
/// speed, when the map turns heading up, how far ahead the heading looks,
/// when a junction's zoom is settled, what a junction needs to read, and
/// how far off the route counts as off it.
///
/// The profile comes from the route's ``TravelMode`` and can be switched
/// while navigating: the camera takes the new one at its next frame.
public struct TravelProfile: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case car
        case bicycle
        case foot
    }

    public internal(set) var kind: Kind
    /// The zoom at each speed, slowest first. Each table keeps about the
    /// same twenty-odd seconds of road ahead of the traveller on a
    /// terminal of 40 rows: a bicycle at 15 km/h needs the road a car at
    /// 50 km/h covers in a third of the time, so it stands closer at the
    /// same speed's share of its own range.
    var zoomBySpeed: [SpeedZoom]
    /// Above this speed, in metres a second, the map turns heading up.
    var headingUpSpeed: Double
    /// How far ahead the heading looks, and how long a fix is carried on.
    var lookAhead: TravellerPrediction.Configuration
    /// When a junction's zoom is settled, held and let go.
    var junctionTiming: JunctionZoom.Configuration
    /// What a junction needs to read on screen.
    var legibility: JunctionLegibilityRules
    /// Metres from the route beyond which a good fix is off it.
    var maximumDeviation: Double
    /// The road roles that count as a junction's branches: the ones the
    /// traveller could take, and so might take for theirs.
    var branchRoles: Set<MapRole>

    public var id: Kind { kind }

    /// The mode a router is asked for this profile's routes in.
    public var travelMode: TravelMode {
        switch kind {
        case .car: .driving
        case .bicycle: .cycling
        case .foot: .walking
        }
    }

    /// The profile's name, as a person reads it.
    public var title: String {
        switch kind {
        case .car: "Car"
        case .bicycle: "Bicycle"
        case .foot: "On foot"
        }
    }

    /// "by car", "by bicycle", "on foot": how a route's summary says it.
    public var travelPhrase: String {
        switch kind {
        case .car: "by car"
        case .bicycle: "by bicycle"
        case .foot: "on foot"
        }
    }

    /// The profile of a route's mode.
    public init(mode: TravelMode) {
        switch mode {
        case .driving: self = .car
        case .cycling: self = .bicycle
        case .walking: self = .foot
        }
    }

    init(kind: Kind, zoomBySpeed: [SpeedZoom], headingUpSpeed: Double,
                lookAhead: TravellerPrediction.Configuration, junctionTiming: JunctionZoom.Configuration,
                legibility: JunctionLegibilityRules, maximumDeviation: Double, branchRoles: Set<MapRole>) {
        self.kind = kind
        self.zoomBySpeed = zoomBySpeed
        self.headingUpSpeed = headingUpSpeed
        self.lookAhead = lookAhead
        self.junctionTiming = junctionTiming
        self.legibility = legibility
        self.maximumDeviation = maximumDeviation
        self.branchRoles = branchRoles
    }

    /// The next profile in the order the app cycles through them.
    public var next: TravelProfile {
        let kinds = Kind.allCases
        let index = kinds.firstIndex(of: kind) ?? 0
        return TravelProfile.of(kinds[(index + 1) % kinds.count])
    }

    /// The profile of a kind: ``car``, ``bicycle`` or ``foot``.
    public static func of(_ kind: Kind) -> TravelProfile {
        switch kind {
        case .car: .car
        case .bicycle: .bicycle
        case .foot: .foot
        }
    }

    /// The thresholds a navigation along a route of this profile uses.
    public var navigationConfiguration: NavigationConfiguration {
        var configuration = NavigationConfiguration()
        configuration.maximumDeviation = maximumDeviation
        return configuration
    }

    /// Every drawn road a vehicle may use: a footpath is drawn but no car
    /// takes it, and a router never sends one down it.
    private static let carriageways: Set<MapRole> = [
        .serviceRoad, .minorRoad, .tertiary, .secondary, .primary, .trunk, .motorway,
    ]

    /// Driving. The speed table is the one the camera was tuned with on
    /// the sample drive; heading up from a brisk walk's 2 m/s (7.2 km/h),
    /// below which a GPS course swings at random; off route at 50 m, the
    /// threshold Ferrostar and Mapbox's navigation SDKs use.
    public static let car = TravelProfile(
        kind: .car,
        zoomBySpeed: [SpeedZoom(speed: 0, zoom: 17.5), SpeedZoom(speed: 2, zoom: 17),
                      SpeedZoom(speed: 6, zoom: 16.25), SpeedZoom(speed: 12, zoom: 15.75),
                      SpeedZoom(speed: 20, zoom: 15.25), SpeedZoom(speed: 30, zoom: 14.5)],
        headingUpSpeed: 2,
        lookAhead: TravellerPrediction.Configuration(),
        junctionTiming: JunctionZoom.Configuration(),
        legibility: JunctionLegibilityRules(),
        maximumDeviation: 50,
        branchRoles: carriageways)

    /// Cycling. A rider's 4–8 m/s spans what a car's table gives to its
    /// first two rows, so the table is stretched over it. Heading up from
    /// 1.5 m/s (5.4 km/h): slower, a rider is wheeling the bike. The
    /// heading looks no more than 50 m ahead, as cycle paths bend tighter
    /// than roads; a junction's mouth is read over 10 m, as cycle paths are
    /// 2–4 m wide against a carriageway's 6–7; and off route is 30 m, as a
    /// cycle track beside a road lies well inside a car's 50 m.
    public static let bicycle = TravelProfile(
        kind: .bicycle,
        zoomBySpeed: [SpeedZoom(speed: 0, zoom: 17.5), SpeedZoom(speed: 2, zoom: 17.25),
                      SpeedZoom(speed: 4, zoom: 17), SpeedZoom(speed: 6, zoom: 16.5),
                      SpeedZoom(speed: 9, zoom: 16), SpeedZoom(speed: 12, zoom: 15.75)],
        headingUpSpeed: 1.5,
        lookAhead: TravellerPrediction.Configuration(maximumPrediction: 1.5, lookAheadTime: 2.5,
                                                     minimumLookAhead: 12, maximumLookAhead: 50),
        junctionTiming: JunctionZoom.Configuration(settleTime: 5, minimumSettleDistance: 20, transitionTime: 2.5,
                                                   minimumTransitionDistance: 10, releaseTime: 2,
                                                   minimumReleaseDistance: 10, mergeTime: 8,
                                                   minimumMergeDistance: 30),
        legibility: JunctionLegibilityRules(mouthLength: 10),
        maximumDeviation: 30,
        branchRoles: carriageways.union([.path]))

    /// Walking. Heading up from 0.8 m/s, below a slow stroll's 1 m/s; the
    /// heading looks 8–25 m ahead, a street corner's reach; a junction's
    /// mouth is a footway's 8 m; off route at 25 m, half a car's, since a
    /// walker on the wrong side of a block is already on another street.
    public static let foot = TravelProfile(
        kind: .foot,
        zoomBySpeed: [SpeedZoom(speed: 0, zoom: 17.75), SpeedZoom(speed: 1, zoom: 17.5),
                      SpeedZoom(speed: 2, zoom: 17.25), SpeedZoom(speed: 3, zoom: 17)],
        headingUpSpeed: 0.8,
        lookAhead: TravellerPrediction.Configuration(maximumPrediction: 1.5, lookAheadTime: 3,
                                                     minimumLookAhead: 8, maximumLookAhead: 25),
        junctionTiming: JunctionZoom.Configuration(settleTime: 4, minimumSettleDistance: 10, transitionTime: 2,
                                                   minimumTransitionDistance: 6, releaseTime: 2,
                                                   minimumReleaseDistance: 6, mergeTime: 8,
                                                   minimumMergeDistance: 15),
        legibility: JunctionLegibilityRules(mouthLength: 8),
        maximumDeviation: 25,
        branchRoles: carriageways.union([.path]))
}
