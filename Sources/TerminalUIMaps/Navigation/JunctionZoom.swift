import Foundation

/// What a junction needs to read on a text map, where a cell is 2 × 4
/// braille dots and holds one colour: its roads apart from one another
/// near the node, and the next manoeuvre a few cells on from it.
///
/// The rules are written out, with their reasons, in
/// design/maps.md ("Junction-aware zoom").
public struct JunctionLegibilityRules: Sendable, Equatable {
    /// Dots two neighbouring roads must lie apart at the mouth: four, a
    /// cell's height, so the route's accent and the road beside it never
    /// share a cell whichever way they run — a cell has one colour, and
    /// two lines in it read as one.
    public var separationDots = 4.0
    /// Metres from the node at which the roads must have parted: the
    /// junction's mouth, about a carriageway's width plus its pavements.
    /// Past it a reader tells the roads apart by where they lead.
    public var mouthLength = 15.0
    /// Cells a manoeuvre must sit from the next, counted in cell heights —
    /// four dots, the way the road ahead runs heading up: one cell for each
    /// bend and one between them for the road they cross.
    public var spacingCells = 3.0
    /// Dots a roundabout must span to read as a ring with exits around it:
    /// three cells' height. Smaller, its braille is a blot.
    public var roundaboutDiameterDots = 12.0
    /// From this many roads a junction is one a driver counts ("the second
    /// on the left"), so every pair of neighbouring roads must part, not
    /// only those beside the way out.
    public var complexBranchCount = 5
    /// Bearings closer than this, in degrees, are the same road: a U-turn's
    /// way in and out, a road in two tiles' buffers.
    public var sameRoadSeparation = 5.0
    /// A manoeuvre turning less than this is no turn for the spacing rule,
    /// unless it is one that chooses a road whatever its bend: OSRM's
    /// "straight" band.
    public var gentlestTurn = 20.0
    /// How near the node, in metres, a road's line must pass to be one of
    /// its roads: a carriageway's half width.
    public var nodeTolerance = 6.0

    public init(separationDots: Double = 4, mouthLength: Double = 15, spacingCells: Double = 3,
                roundaboutDiameterDots: Double = 12, complexBranchCount: Int = 5, sameRoadSeparation: Double = 5,
                gentlestTurn: Double = 20, nodeTolerance: Double = 6) {
        self.separationDots = separationDots
        self.mouthLength = mouthLength
        self.spacingCells = spacingCells
        self.roundaboutDiameterDots = roundaboutDiameterDots
        self.complexBranchCount = complexBranchCount
        self.sameRoadSeparation = sameRoadSeparation
        self.gentlestTurn = gentlestTurn
        self.nodeTolerance = nodeTolerance
    }
}

/// How legible one junction is: the measures, and the coarsest scale at
/// which the rules hold.
public struct JunctionLegibility: Sendable, Equatable {
    /// How many roads meet.
    public var branchCount: Int
    /// The narrowest angle, in degrees, between roads that must be told
    /// apart: those beside the way out, or every neighbouring pair at a
    /// complex junction. Nil with fewer than two such roads.
    public var minimumSeparation: Double?
    /// Metres to the next manoeuvre that turns, if any.
    public var distanceToNext: Double?
    public var roundaboutDiameter: Double?
    /// The most metres a dot may cover for the junction to read; nil when
    /// nothing about it limits the scale.
    public var largestMetresPerDot: Double?

    public init(_ junction: RouteJunction, next: RouteJunction?,
                rules: JunctionLegibilityRules = JunctionLegibilityRules()) {
        let branches = junction.branches.sorted()
        branchCount = branches.count
        // At a roundabout's entry the ring is read by its diameter: its
        // own line, curving back within the mouth, is no pair of roads.
        let isRoundabout = RouteJunction.roundaboutKinds.contains(junction.maneuver.kind)
        minimumSeparation = isRoundabout ? nil
            : Self.separations(of: branches, exit: junction.exitBearing, rules: rules).min()
        roundaboutDiameter = junction.roundaboutDiameter
        if let next, next.isTurn(gentlestTurn: rules.gentlestTurn) {
            distanceToNext = max(0, next.distanceAlong - junction.distanceAlong)
        }

        var limits: [Double] = []
        // Two roads parting at angle θ lie 2·L·sin(θ/2) apart at L metres
        // from the node: that must span `separationDots` dots.
        if let separation = minimumSeparation {
            let apart = 2 * rules.mouthLength * sin(GeoMeasure.radians(separation) / 2)
            limits.append(apart / rules.separationDots)
        }
        if let distanceToNext {
            limits.append(distanceToNext / (rules.spacingCells * Double(BrailleCell.dotRows)))
        }
        if let diameter = roundaboutDiameter {
            limits.append(diameter / rules.roundaboutDiameterDots)
        }
        largestMetresPerDot = limits.filter { $0 > 0 }.min()
    }

    /// The zoom at which the junction reads, at `latitude`, for a camera of
    /// `tileSize` dots a tile; nil when any zoom does.
    public func requiredZoom(atLatitude latitude: Double, tileSize: Double = MapCamera.defaultTileSize) -> Double? {
        largestMetresPerDot.map { JunctionLegibility.zoom(metresPerDot: $0, latitude: latitude, tileSize: tileSize) }
    }

    /// The zoom at which a dot covers `metresPerDot` metres.
    public static func zoom(metresPerDot: Double, latitude: Double, tileSize: Double = MapCamera.defaultTileSize)
        -> Double {
        log2(WebMercator.metresPerWorldUnit(atLatitude: latitude) / (max(metresPerDot, .ulpOfOne) * tileSize))
    }

    /// The angles between neighbouring roads that matter, going round.
    private static func separations(of branches: [Double], exit: Double?, rules: JunctionLegibilityRules)
        -> [Double] {
        guard branches.count >= 2 else { return [] }
        var gaps: [(first: Double, second: Double, angle: Double)] = []
        for (index, bearing) in branches.enumerated() {
            let next = branches[(index + 1) % branches.count]
            let angle = GeoMeasure.normalizedBearing(next - bearing)
            gaps.append((bearing, next, branches.count == 2 ? min(angle, Degrees.fullTurn - angle) : angle))
            if branches.count == 2 { break }
        }
        let meaningful = gaps.filter { $0.angle >= rules.sameRoadSeparation }
        guard branches.count < rules.complexBranchCount, let exit else { return meaningful.map(\.angle) }
        func isExit(_ bearing: Double) -> Bool { abs(GeoMeasure.turn(from: bearing, to: exit)) < rules.sameRoadSeparation }
        return meaningful.filter { isExit($0.first) || isExit($0.second) }.map(\.angle)
    }
}

/// What the map shows around the traveller: what a group of junctions
/// must fit inside.
public struct JunctionFrame: Sendable, Equatable {
    public var viewport: DotSize
    /// Where the traveller sits, as a share of the height from the top.
    public var travellerHeightShare: Double
    /// The map's bearing when it is held — north up or locked; nil heading
    /// up, where it follows the route.
    public var fixedBearing: Double?

    public init(viewport: DotSize, travellerHeightShare: Double, fixedBearing: Double? = nil) {
        self.viewport = viewport
        self.travellerHeightShare = travellerHeightShare
        self.fixedBearing = fixedBearing
    }
}

/// Junctions close enough to be held at one zoom.
public struct JunctionGroup: Sendable, Equatable {
    /// Indices into the junctions given.
    public var junctions: ClosedRange<Int>
    /// Metres along the route to the first junction and the last.
    public var start: Double
    public var end: Double
    /// The zoom every junction of the group reads at, or the speed's when
    /// that is closer.
    public var legibleZoom: Double
    /// The deepest zoom that keeps the group's junctions and the road out
    /// of the last on screen through the hold; nil with no viewport.
    public var fittingZoom: Double?
    /// Whether the speed's zoom fails a rule here.
    public var isTight: Bool
    /// What the camera holds through the group.
    public var zoom: Double
}

/// The following camera's zoom around junctions: the speed table's, except
/// at a junction that would not read at it, where the camera closes in by
/// only as much as the junction needs — and, with the next manoeuvre close
/// behind, only as far as keeps it on screen. The zoom is settled seconds
/// before the junction and held still through it, at every junction,
/// tight or simple: a picture that changes scale at the apex misleads.
///
/// A value fed the traveller's place along the route each frame; it keeps
/// the zoom it holds, so a speed that drops braking for the turn does not
/// change the scale mid-junction.
public struct JunctionZoom: Sendable, Equatable {
    /// When the zoom moves, as seconds of travel at the traveller's speed,
    /// each with a floor in metres so a crawl or a stop still has room.
    public struct Configuration: Sendable, Equatable {
        /// Seconds before a junction its zoom is settled: two of the 2 s
        /// glances NHTSA's driver-distraction guidelines allow, and the
        /// time to act on them.
        public var settleTime = 6.0
        public var minimumSettleDistance = 30.0
        /// Seconds the camera's own easing takes to close the last of a
        /// change: ``CameraMotionConfiguration/zoomSmoothing``'s 0.8 s lag
        /// leaves 2% of it after 3 s. The zoom's target is final this much
        /// earlier than `settleTime`, so the picture is still by then.
        public var easingTime = 3.0
        /// Seconds the zoom takes to move to a junction's, before it is
        /// settled, and back after.
        public var transitionTime = 3.0
        public var minimumTransitionDistance = 15.0
        /// Seconds past a junction the zoom holds, while the road out comes
        /// into view.
        public var releaseTime = 2.0
        public var minimumReleaseDistance = 15.0
        /// Junctions whose holds would come closer than this, in seconds,
        /// are held as one: two changes of scale within a few seconds read
        /// as the map pumping.
        public var mergeTime = 8.0
        public var minimumMergeDistance = 40.0
        /// The most a junction closes the camera in, in levels: a level
        /// and a half shows a third of the road ahead, enough for a mouth
        /// without losing the road to it.
        public var maximumZoomIn = 1.5
        /// The most fitting the next manoeuvre draws the camera back past
        /// the speed's zoom, in levels.
        public var maximumZoomOut = 0.5
        /// Less than this, in levels, is no change worth making.
        public var noticeableZoom = 0.05
        /// Cells kept clear between what must be on screen and its edge.
        public var fitMarginCells = 2.0
        /// Metres of road past a group's last junction that must show.
        public var fitExitLength = 30.0
        /// Metres between the points of the route checked for fitting.
        public var fitSampleSpacing = 5.0

        public init(settleTime: Double = 6, minimumSettleDistance: Double = 30, transitionTime: Double = 3,
                    minimumTransitionDistance: Double = 15, releaseTime: Double = 2,
                    minimumReleaseDistance: Double = 15, mergeTime: Double = 8, minimumMergeDistance: Double = 40) {
            self.settleTime = settleTime
            self.minimumSettleDistance = minimumSettleDistance
            self.transitionTime = transitionTime
            self.minimumTransitionDistance = minimumTransitionDistance
            self.releaseTime = releaseTime
            self.minimumReleaseDistance = minimumReleaseDistance
            self.mergeTime = mergeTime
            self.minimumMergeDistance = minimumMergeDistance
        }

        /// Where the target is final and the hold begins, before a junction.
        func settleDistance(_ speed: Double) -> Double {
            max(max(0, speed) * (settleTime + easingTime), minimumSettleDistance)
        }
        func transitionDistance(_ speed: Double) -> Double {
            max(max(0, speed) * transitionTime, minimumTransitionDistance)
        }
        func releaseDistance(_ speed: Double) -> Double { max(max(0, speed) * releaseTime, minimumReleaseDistance) }
        func mergeDistance(_ speed: Double) -> Double { max(max(0, speed) * mergeTime, minimumMergeDistance) }
    }

    /// A zoom held through a group of junctions.
    public struct Hold: Sendable, Equatable {
        public var zoom: Double
        /// Metres along where the hold began.
        public var start: Double
        /// The last junction it holds through.
        public var lastJunction: Double
        /// Where it lets go.
        public var releaseAlong: Double
    }

    /// A hold let go: where, and its zoom, which the camera eases away
    /// from.
    public struct Release: Sendable, Equatable {
        public var along: Double
        public var zoom: Double
    }

    public var configuration: Configuration
    public var rules: JunctionLegibilityRules
    public private(set) var hold: Hold?
    public private(set) var released: Release?

    public init(configuration: Configuration = Configuration(), rules: JunctionLegibilityRules = JunctionLegibilityRules()) {
        self.configuration = configuration
        self.rules = rules
    }

    public init(profile: TravelProfile) {
        self.init(configuration: profile.junctionTiming, rules: profile.legibility)
    }

    /// Forget any hold: a new route, or following resumed.
    public mutating func reset() {
        hold = nil
        released = nil
    }

    // MARK: - Planning

    /// The groups of junctions ahead of `distanceAlong` on `line`, each with
    /// the zoom it would be held at, for a traveller at `speed` metres a
    /// second whose speed table gives `speedZoom`.
    public func groups(_ junctions: [RouteJunction], on line: RouteLine, after distanceAlong: Double,
                       speed: Double, speedZoom: Double, frame: JunctionFrame?) -> [JunctionGroup] {
        let settle = configuration.settleDistance(speed), release = configuration.releaseDistance(speed)
        let merge = configuration.mergeDistance(speed)
        var ranges: [ClosedRange<Int>] = []
        for index in junctions.indices where junctions[index].distanceAlong > distanceAlong {
            if let last = ranges.last,
               junctions[index].distanceAlong - settle - (junctions[last.upperBound].distanceAlong + release) < merge {
                ranges[ranges.count - 1] = last.lowerBound...index
            } else {
                ranges.append(index...index)
            }
        }
        let latitude = line.coordinates.first?.latitude ?? 0
        return ranges.map { range in
            var legible = speedZoom
            for index in range {
                let next = index + 1 < junctions.count ? junctions[index + 1] : nil
                if let needed = JunctionLegibility(junctions[index], next: next, rules: rules)
                    .requiredZoom(atLatitude: latitude) {
                    legible = max(legible, needed)
                }
            }
            let start = junctions[range.lowerBound].distanceAlong, end = junctions[range.upperBound].distanceAlong
            // Each junction with the one that follows it, from where its
            // zoom settles: the next manoeuvre on screen while this one is
            // taken, and the road out of the last.
            let fitting = frame.flatMap { frame in
                range.compactMap { index -> Double? in
                    let here = junctions[index].distanceAlong
                    let following = index < range.upperBound ? junctions[index + 1].distanceAlong
                        : here + configuration.fitExitLength
                    return fittingZoom(on: line, from: here - settle, through: here...following, frame: frame)
                }.min()
            }
            let isTight = legible > speedZoom + configuration.noticeableZoom
            var zoom = speedZoom
            if isTight {
                zoom = min(legible, fitting ?? legible)
                zoom = min(max(zoom, speedZoom - configuration.maximumZoomOut), speedZoom + configuration.maximumZoomIn)
            }
            return JunctionGroup(junctions: range, start: start, end: end, legibleZoom: legible, fittingZoom: fitting,
                                 isTight: isTight, zoom: zoom)
        }
    }

    /// The deepest zoom at which, for a traveller anywhere from
    /// `holdStart` to `span`'s end, the route along `span` stays inside the
    /// frame, clear of its edges by `fitMarginCells`.
    func fittingZoom(on line: RouteLine, from holdStart: Double, through span: ClosedRange<Double>,
                     frame: JunctionFrame) -> Double? {
        let rowDots = Double(BrailleCell.dotRows), columnDots = Double(BrailleCell.dotColumns)
        let ahead = frame.viewport.height * frame.travellerHeightShare - configuration.fitMarginCells * rowDots
        let behind = frame.viewport.height * (1 - frame.travellerHeightShare) - configuration.fitMarginCells * rowDots
        let side = frame.viewport.width / 2 - configuration.fitMarginCells * columnDots
        guard ahead > 0, behind > 0, side > 0 else { return nil }
        let last = min(line.length, span.upperBound)
        var samples: [Double] = []
        var position = span.lowerBound
        while position < last {
            samples.append(position)
            position += configuration.fitSampleSpacing
        }
        samples.append(last)
        var largest = 0.0
        for traveller in [max(0, holdStart), span.lowerBound, span.upperBound] {
            let origin = line.coordinate(atDistance: traveller)
            let plane = LocalPlane(reference: origin)
            let bearing = frame.fixedBearing
                ?? line.bearing(from: traveller, to: min(line.length, traveller + StepShapes.bearingSpan)) ?? 0
            let sine = sin(GeoMeasure.radians(bearing)), cosine = cos(GeoMeasure.radians(bearing))
            for sample in samples where sample >= traveller {
                let point = plane.point(line.coordinate(atDistance: sample))
                let forward = point.east * sine + point.north * cosine
                let across = point.east * cosine - point.north * sine
                largest = max(largest, forward > 0 ? forward / ahead : -forward / behind, abs(across) / side)
            }
        }
        guard largest > 0 else { return nil }
        return JunctionLegibility.zoom(metresPerDot: largest, latitude: line.coordinates.first?.latitude ?? 0)
    }

    // MARK: - Following

    /// The zoom for a traveller `distanceAlong` metres along `line` at
    /// `speed`, among `junctions`: held if a hold is under way, else the
    /// speed's eased toward the next group's and away from the last.
    public mutating func zoom(at distanceAlong: Double, speed: Double, speedZoom: Double,
                              junctions: [RouteJunction], line: RouteLine, frame: JunctionFrame?) -> Double {
        let settle = configuration.settleDistance(speed), transition = configuration.transitionDistance(speed)
        if let current = hold, distanceAlong < current.start - settle {
            // Behind where the hold began: a new route counts from its own
            // start.
            reset()
        }
        if var current = hold {
            let ahead = groups(junctions, on: line, after: current.lastJunction, speed: speed, speedZoom: speedZoom,
                               frame: frame)
            if let next = ahead.first, distanceAlong < current.releaseAlong, distanceAlong >= next.start - settle {
                current.lastJunction = next.end
                current.releaseAlong = next.end + configuration.releaseDistance(speed)
            }
            if distanceAlong < current.releaseAlong {
                hold = current
                return current.zoom
            }
            released = Release(along: current.releaseAlong, zoom: current.zoom)
            hold = nil
        }

        var outgoing = 0.0
        if let released {
            let weight = 1 - Self.smoothstep((distanceAlong - released.along) / transition)
            outgoing = weight * (released.zoom - speedZoom)
        }
        guard let next = groups(junctions, on: line, after: distanceAlong, speed: speed, speedZoom: speedZoom,
                                frame: frame).first else { return speedZoom + outgoing }
        let settlePoint = next.start - settle
        if distanceAlong >= settlePoint {
            hold = Hold(zoom: next.zoom, start: distanceAlong, lastJunction: next.end,
                        releaseAlong: next.end + configuration.releaseDistance(speed))
            return next.zoom
        }
        let incoming = Self.smoothstep((distanceAlong - (settlePoint - transition)) / transition)
        return speedZoom + outgoing * (1 - incoming) + incoming * (next.zoom - speedZoom)
    }

    /// 0 to 1 with zero slope at both ends.
    static func smoothstep(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}
