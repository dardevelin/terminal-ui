/// Chooses the colour table for pictures of terminal screens — a GIF's
/// global table, or one frame's local table — from the pixels they show.
///
/// A screen's pixels are few colours, solid, and the anti-aliased edges
/// between them: each edge pixel is a foreground over a background at some
/// coverage (``BlendedPixel``). So the table is built from those, not from
/// colours alone:
///
/// - every solid colour, and both ends of every edge's ramp, are the exact
///   colours, and the table holds each of them exactly;
/// - an edge's coverage is shaded in ``coverageLevels`` steps from its
///   background to its foreground, so the ends of every ramp are the exact
///   terminal colours and the steps between them are blends of the two;
/// - while the steps overflow the table, the ramp of the least-used pair of
///   colours loses steps — every level, then every third, every fifth, then
///   its ends only, each set inside the one before — and then the next
///   least-used pair's;
/// - only when the exact colours alone overflow it do colours change: the
///   least-used map to the nearest kept one by `coordinates`, a perceptual
///   space the caller gives (the recording renderer gives Oklab), and the
///   result lists them, for a warning.
///
/// No dithering: a screen's flat fields stay flat. Every tie is broken by
/// colour value, so a table is the same on every system.
package struct IndexedPaletteBuilder: Sendable {
    /// Coverage in 16 steps, 0 to 15, step `L` covering `L · 17` of 255.
    package static let coverageLevels = 16
    private static let topLevel = coverageLevels - 1
    private static let coveragePerLevel = Int(UInt8.max) / topLevel
    /// The steps a ramp keeps: every level, every third, every fifth, then
    /// its ends. 15 is 3 · 5, so each set holds the next and both ends.
    static let rampStrides = [1, 3, 5, 15]

    /// A pair of colours an edge blends between.
    struct Pair: Hashable, Comparable, Sendable {
        let foreground: RGBA
        let background: RGBA

        static func < (lhs: Pair, rhs: Pair) -> Bool {
            (lhs.foreground.packed, lhs.background.packed) < (rhs.foreground.packed, rhs.background.packed)
        }

        func colour(level: Int) -> RGBA {
            switch level {
            case 0: background
            case IndexedPaletteBuilder.topLevel: foreground
            default: BlendedPixel.blend(foreground, over: background, coverage: level * IndexedPaletteBuilder.coveragePerLevel)
            }
        }
    }

    private var solids: [RGBA: Int] = [:]
    /// Each pair's edge pixels by coverage level.
    private var ramps: [Pair: [Int]] = [:]

    package init() {}

    package mutating func add(_ pixel: BlendedPixel, count: Int = 1) {
        if pixel.isSolid {
            solids[pixel.foreground, default: 0] += count
            return
        }
        let pair = Pair(foreground: pixel.foreground, background: pixel.background)
        ramps[pair, default: [Int](repeating: 0, count: Self.coverageLevels)][Self.level(pixel.coverage)] += count
    }

    /// Coverage to the nearest level, a half rounded up.
    static func level(_ coverage: UInt8) -> Int {
        (Int(coverage) * topLevel + Int(UInt8.max) / 2) / Int(UInt8.max)
    }

    /// `level` moved to the nearest one a ramp of `stride` keeps.
    static func quantised(_ level: Int, stride: Int) -> Int {
        (2 * level + stride) / (2 * stride) * stride
    }

    /// The colours the table must hold unchanged: every solid one, and the
    /// two ends of every ramp.
    package var exactColours: Set<RGBA> {
        Set(solids.keys).union(ramps.keys.flatMap { [$0.foreground, $0.background] })
    }

    package var isEmpty: Bool { solids.isEmpty && ramps.isEmpty }

    /// The table, at most `capacity` colours, and one more at index 0 that
    /// draws nothing when `reservingTransparency`. `coordinates` places a
    /// colour in a perceptual space, for a colour the table cannot hold.
    package func build(capacity: Int, reservingTransparency: Bool,
                       coordinates: (RGBA) -> (Int, Int, Int)) -> IndexedPalette {
        precondition(capacity >= 1 && capacity + (reservingTransparency ? 1 : 0) <= IndexedImage.maximumPaletteCount,
                     "a table of \(capacity) colours")
        let exact = exactColours
        var strides: [Pair: Int] = [:]
        var standIns: [RGBA: RGBA] = [:]
        var approximations: [IndexedPalette.Approximation] = []
        let kept: Set<RGBA>
        if exact.count <= capacity {
            (strides, kept) = reducedRamps(exact: exact, capacity: capacity)
        } else {
            for pair in ramps.keys { strides[pair] = Self.rampStrides.last }
            (kept, standIns, approximations) = nearestStandIns(capacity: capacity, coordinates: coordinates)
        }
        var colours = kept.sorted { $0.packed < $1.packed }
        if reservingTransparency { colours.insert(.transparent, at: 0) }
        if colours.isEmpty { colours = [.transparent] }
        return IndexedPalette(colours: colours, transparentIndex: reservingTransparency ? 0 : nil,
                              approximations: approximations, strides: strides, standIns: standIns)
    }

    /// Every pair's ramp at the most steps that let the table fit: the
    /// least-used pair's ramp cut first, step by step to its ends, then the
    /// next. A ramp's ends are exact colours, so they always fit.
    private func reducedRamps(exact: Set<RGBA>, capacity: Int) -> (strides: [Pair: Int], colours: Set<RGBA>) {
        var strideIndex: [Pair: Int] = [:]
        // How many contributions hold each colour in the table; an exact
        // colour has one of its own that never goes.
        var holders: [RGBA: Int] = [:]
        for colour in exact { holders[colour] = 1 }
        func steps(_ pair: Pair, stride: Int) -> Set<RGBA> {
            guard let counts = ramps[pair] else { return [] }
            return Set(counts.indices.filter { counts[$0] > 0 }
                .map { Self.quantised($0, stride: stride) }
                .filter { $0 != 0 && $0 != Self.topLevel }
                .map { pair.colour(level: $0) })
        }
        for pair in ramps.keys {
            strideIndex[pair] = 0
            for colour in steps(pair, stride: Self.rampStrides[0]) { holders[colour, default: 0] += 1 }
        }
        let leastUsedFirst = ramps.map { (pair: $0.key, use: $0.value[1..<Self.topLevel].reduce(0, +)) }
            .sorted { ($0.use, $0.pair) < ($1.use, $1.pair) }
            .map(\.pair)
        var next = leastUsedFirst.makeIterator()
        var current = next.next()
        while holders.count > capacity, let pair = current {
            let index = strideIndex[pair] ?? 0
            guard index + 1 < Self.rampStrides.count else {
                current = next.next()
                continue
            }
            for colour in steps(pair, stride: Self.rampStrides[index]) {
                holders[colour, default: 0] -= 1
                if holders[colour] == 0 { holders[colour] = nil }
            }
            strideIndex[pair] = index + 1
            for colour in steps(pair, stride: Self.rampStrides[index + 1]) { holders[colour, default: 0] += 1 }
        }
        return (strideIndex.mapValues { Self.rampStrides[$0] }, Set(holders.keys))
    }

    /// With every ramp cut to its ends, the `capacity` most-used colours
    /// kept and every other one shown as the kept colour nearest it.
    private func nearestStandIns(capacity: Int, coordinates: (RGBA) -> (Int, Int, Int))
        -> (kept: Set<RGBA>, standIns: [RGBA: RGBA], approximations: [IndexedPalette.Approximation]) {
        var use = solids
        let endsOnly = Self.rampStrides[Self.rampStrides.count - 1]
        for (pair, counts) in ramps {
            for (level, count) in counts.enumerated() where count > 0 {
                use[pair.colour(level: Self.quantised(level, stride: endsOnly)), default: 0] += count
            }
            // An end no pixel rounds to is still one of the exact colours.
            use[pair.foreground, default: 0] += 0
            use[pair.background, default: 0] += 0
        }
        let ranked = use.sorted { ($1.value, $0.key.packed) < ($0.value, $1.key.packed) }
        let kept = ranked.prefix(capacity).map(\.key)
        let keptPlaces = kept.map { (colour: $0, place: coordinates($0)) }
        var standIns: [RGBA: RGBA] = [:]
        var approximations: [IndexedPalette.Approximation] = []
        for (colour, pixels) in ranked.dropFirst(capacity) {
            let place = coordinates(colour)
            // The first nearest in the ranking: the most-used wins a tie.
            var best = keptPlaces[0]
            var bestDistance = Int.max
            for candidate in keptPlaces {
                let distance = Self.squaredDistance(place, candidate.place)
                if distance < bestDistance { (best, bestDistance) = (candidate, distance) }
            }
            standIns[colour] = best.colour
            approximations.append(.init(colour: colour, standIn: best.colour, pixels: pixels))
        }
        return (Set(kept), standIns, approximations)
    }

    private static func squaredDistance(_ first: (Int, Int, Int), _ second: (Int, Int, Int)) -> Int {
        let (dx, dy, dz) = (first.0 - second.0, first.1 - second.1, first.2 - second.2)
        return dx * dx + dy * dy + dz * dz
    }
}

/// A colour table and how each pixel a builder was given maps into it.
package struct IndexedPalette: Sendable {
    /// A colour the table could not hold, and the one shown in its place.
    package struct Approximation: Equatable, Sendable {
        package var colour: RGBA
        package var standIn: RGBA
        /// The pixels that showed it.
        package var pixels: Int
    }

    package let colours: [RGBA]
    package let transparentIndex: UInt8?
    /// Empty when every exact colour is in the table as it is.
    package let approximations: [Approximation]
    let strides: [IndexedPaletteBuilder.Pair: Int]
    let standIns: [RGBA: RGBA]
    private let indexOf: [RGBA: UInt8]

    init(colours: [RGBA], transparentIndex: UInt8?, approximations: [Approximation],
         strides: [IndexedPaletteBuilder.Pair: Int], standIns: [RGBA: RGBA]) {
        self.colours = colours
        self.transparentIndex = transparentIndex
        self.approximations = approximations
        self.strides = strides
        self.standIns = standIns
        var indexOf: [RGBA: UInt8] = [:]
        for (index, colour) in colours.enumerated() where UInt8(index) != transparentIndex {
            indexOf[colour] = UInt8(index)
        }
        self.indexOf = indexOf
    }

    /// The colour the table shows for `pixel`: its edge on the steps its
    /// ramp kept, then any stand-in.
    package func shown(_ pixel: BlendedPixel) -> RGBA {
        var colour = pixel.foreground
        if !pixel.isSolid {
            let pair = IndexedPaletteBuilder.Pair(foreground: pixel.foreground, background: pixel.background)
            let stride = strides[pair] ?? IndexedPaletteBuilder.rampStrides[0]
            colour = pair.colour(level: IndexedPaletteBuilder.quantised(IndexedPaletteBuilder.level(pixel.coverage),
                                                                         stride: stride))
        }
        return standIns[colour] ?? colour
    }

    /// The index of the colour shown for `pixel`, one of those the table
    /// was built from.
    package func index(of pixel: BlendedPixel) -> UInt8 {
        let colour = shown(pixel)
        guard let index = indexOf[colour] else {
            preconditionFailure("\(colour) is not in the table: the pixel was not among those it was built from")
        }
        return index
    }
}

extension RGBA {
    /// Red, green, blue and alpha in one number, red highest: the order
    /// colours are sorted and tied in.
    var packed: UInt32 {
        UInt32(red) << 24 | UInt32(green) << 16 | UInt32(blue) << 8 | UInt32(alpha)
    }
}
