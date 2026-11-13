/// The ground's height over a frame's north-up map, in dots above the
/// ground under a reference point — the camera's centre, so the middle of
/// the view keeps its scale and the camera its target, as MapKit's does on
/// realistic terrain.
///
/// Read from the terrain tiles a frame has at hand, each a patch of the
/// north-up map; the finest that covers a point gives its height. Where no
/// tile has landed the ground lies at the reference.
struct ElevationField {
    /// A terrain tile placed on the north-up map: its square, in dots.
    struct Patch {
        var originX: Double
        var originY: Double
        var side: Double
        var tile: ElevationTile
        /// The terrain tile it is, where it is one: what names the ground
        /// a mesh built on it stands on (``signature``).
        var id: TileID?
    }

    /// Finest first: a point takes the first patch that covers it.
    private let patches: [Patch]
    /// Instead of patches, a height for a north-up point read from the
    /// world: a field for a camera no frame has been drawn through.
    private let sample: ((Double, Double) -> Double?)?
    /// Dots a metre of height spans: the ground's own scale at the view's
    /// latitude, so a hill stands as tall as it is wide on the map.
    let dotsPerMetre: Double
    /// The height, in metres, the field measures from.
    let reference: Double

    /// A field of `patches`, its heights measured from the ground at
    /// (`referenceX`, `referenceY`), or from sea level where no patch
    /// covers it.
    init(patches: [Patch], dotsPerMetre: Double, referenceX: Double, referenceY: Double) {
        let sorted = patches.sorted { $0.side < $1.side }
        self.init(sortedPatches: sorted, dotsPerMetre: dotsPerMetre,
                  reference: Self.metres(in: sorted, x: referenceX, y: referenceY) ?? 0)
    }

    /// The field `camera` sees over a viewport, its heights read from
    /// `sampler`: what the pointer meets, for whatever camera a drag or the
    /// wheel is trying. Flat where the sampler has no ground under the
    /// camera's centre.
    init(camera: MapCamera, viewport: DotSize, sampler: TerrainSampler) {
        let centre = WebMercator.project(camera.center)
        let scale = camera.dotsPerWorld, middleX = viewport.width / 2, middleY = viewport.height / 2
        let sample: (Double, Double) -> Double? = { x, y in
            sampler.metres(at: WorldPoint(x: centre.x + (x - middleX) / scale, y: centre.y + (y - middleY) / scale))
        }
        let reference = sample(middleX, middleY)
        patches = []
        self.sample = reference == nil ? nil : sample
        dotsPerMetre = scale / WebMercator.metresPerWorldUnit(atLatitude: camera.center.latitude)
        self.reference = reference ?? 0
        signature = 0
    }

    private init(sortedPatches: [Patch], dotsPerMetre: Double, reference: Double) {
        patches = sortedPatches
        sample = nil
        self.dotsPerMetre = dotsPerMetre
        self.reference = reference
        var hasher = Hasher()
        for id in sortedPatches.compactMap(\.id).sorted(by: { ($0.zoom, $0.x, $0.y) < ($1.zoom, $1.x, $1.y) }) {
            hasher.combine(id)
        }
        signature = sortedPatches.isEmpty ? 0 : hasher.finalize()
    }

    /// Which terrain tiles the field reads, as one number: a mesh built on
    /// the ground stays right while it is unchanged, however the camera
    /// moves; 0 for no terrain.
    let signature: Int

    /// No terrain: the ground is the reference everywhere.
    static var flat: ElevationField { ElevationField(sortedPatches: [], dotsPerMetre: 0, reference: 0) }

    /// Whether the field has no terrain in it.
    var isFlat: Bool { patches.isEmpty && sample == nil }

    /// The height of the ground at a north-up point, in dots above the
    /// reference.
    func height(x: Double, y: Double) -> Double {
        guard let metres = metres(x: x, y: y) else { return 0 }
        return (metres - reference) * dotsPerMetre
    }

    /// The height above sea level of the ground at a north-up point, in
    /// metres, or nil where no terrain tile reaches.
    func metres(x: Double, y: Double) -> Double? {
        if let sample { return sample(x, y) }
        return Self.metres(in: patches, x: x, y: y)
    }

    private static func metres(in patches: [Patch], x: Double, y: Double) -> Double? {
        for patch in patches {
            let unitX = (x - patch.originX) / patch.side, unitY = (y - patch.originY) / patch.side
            guard (0...1).contains(unitX), (0...1).contains(unitY) else { continue }
            return patch.tile.elevation(atUnitX: unitX, y: unitY)
        }
        return nil
    }
}
