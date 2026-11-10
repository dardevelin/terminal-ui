import TerminalUI
import TerminalUIMaps

extension Backend {
    /// What each preset draws its map types with: the sample town's own
    /// imagery and ground, the open sources for OpenStreetMap, Apple's
    /// imagery (and the open ones) on Apple, and for a region the layers
    /// downloaded with it, the open ones where it has none.
    var mapTypeOffer: MapTypeOffer {
        let open = MapTypeOffer.open(userAgent: Backend.userAgent)
        switch preset {
        case .sample:
            return MapTypeOffer(
                imagery: [ImageryOption(id: "sample", name: "Millbrook from the air",
                                        detail: "sample imagery of the town; no network", source: SampleImagerySource())],
                terrain: TerrainOption(id: "sample", name: "Millbrook's ground",
                                       detail: "sample heights: shaded relief, contours", source: SampleTerrainSource()),
                basemapIsVector: true)
        case .openStreetMap:
            var offer = open
            offer.imagery = offer.imagery.map { option in
                var noted = option
                noted.detail += " · Apple's imagery: Apple backend only"
                return noted
            }
            return offer
        case .apple:
            #if canImport(MapKit)
            let apple = ImageryOption(id: "apple", name: "Apple", detail: "Apple's imagery, MapKit snapshots",
                                      source: MapKitImagerySource(style: .imagery),
                                      hybridSource: MapKitImagerySource(style: .hybrid))
            return MapTypeOffer(imagery: [apple] + open.imagery, terrain: open.terrain, basemapIsVector: false)
            #else
            return MapTypeOffer(imagery: open.imagery, terrain: open.terrain, basemapIsVector: false)
            #endif
        case .offline:
            guard let pack else { return open }
            let imagery = pack.layer(.imagery).map { layer in
                ImageryOption(id: "pack-imagery", name: layer.source, detail: "\(layer.source), downloaded",
                              source: OfflineLayerSource(pack: pack, layer: layer))
            }
            let terrain = pack.layer(.terrain).map { layer in
                TerrainOption(id: "pack-terrain", name: layer.source, detail: "\(layer.source), downloaded",
                              source: OfflineLayerSource(pack: pack, layer: layer))
            }
            let online = open.imagery.map { option in
                var noted = option
                noted.detail = "online: " + option.detail
                return noted
            }
            return MapTypeOffer(imagery: imagery.map { [$0] } ?? online,
                                terrain: terrain ?? open.terrain.map { option in
                                    var noted = option
                                    noted.detail = "online: " + option.detail
                                    return noted
                                },
                                basemapIsVector: true)
        }
    }
}

/// The map-type picker: Explore, Satellite, Hybrid and Terrain, each with
/// what it draws from on this backend, or why it cannot be drawn here.
struct MapTypePanel: TerminalView {
    let model: MapsModel
    let theme: any Theme

    var body: some TerminalView {
        let types = model.mapTypes
        let state = MainActor.assumeIsolated {
            (options: types.options, current: types.mapType, imagery: types.imagery?.name,
             imageryCount: types.offer.imagery.count)
        }
        VStack(alignment: .leading, spacing: 0) {
            Text("Map type").bold().foreground(theme.foregroundEmphasis)
            List(state.options, selection: Binding(get: { model.mapTypeSelection },
                                                   set: { maps.mapTypeSelection = $0 })) { option in
                VStack(alignment: .leading, spacing: 0) {
                    Text(option.type == state.current ? "\(option.type.title) ✓" : option.type.title)
                        .foreground(option.isAvailable
                                    ? (option.type == state.current ? theme.accent : theme.foreground)
                                    : theme.foregroundFaint)
                    Text(option.isAvailable ? option.detail : "not here: \(option.detail)")
                        .foreground(option.isAvailable ? theme.foregroundMuted : theme.foregroundFaint)
                }
            }
            .onKeyPress { event in
                switch event.key {
                case .enter:
                    guard let type = maps.mapTypeSelection.flatMap(MapType.init) else { return .ignored }
                    MainActor.assumeIsolated { maps.chooseMapType(type) }
                case .character("i"):
                    MainActor.assumeIsolated { maps.nextImagery() }
                default:
                    return .ignored
                }
                return .handled
            }
            if let imagery = state.imagery {
                Text("Imagery: \(imagery)").foreground(theme.foregroundSubtle)
            }
            Text(state.imageryCount > 1 ? "Enter show · i other imagery" : "Enter show")
                .foreground(theme.foregroundMuted)
        }
    }
}

extension Backend {
    /// The raster layers a region of this backend is downloaded with, so
    /// its satellite and terrain maps work offline too: sources whose
    /// licences allow keeping their tiles (RegionPackLayers.swift).
    var layerDownloads: [(kind: RegionPackLayerKind, source: any EncodedTileSource, encoding: RasterEncoding)] {
        switch preset {
        case .sample:
            [(.imagery, SampleImagerySource(), .picture), (.terrain, SampleTerrainSource(), .terrarium)]
        case .openStreetMap:
            [(.imagery, RasterTileSource.sentinel2Cloudless2016(userAgent: Backend.userAgent), .picture),
             (.terrain, RasterTileSource.awsTerrain(userAgent: Backend.userAgent), .terrarium)]
        case .apple, .offline:
            []
        }
    }
}

extension MapsModel {
    /// Download the backend's raster layers into the region just
    /// downloaded, showing each one's progress as the region's was.
    @MainActor
    func downloadLayers(named name: String) async throws {
        for layer in backend.layerDownloads {
            guard let pack = try packStore.pack(named: name) else { return }
            let info = try await layer.source.info()
            guard let zooms = RegionLayerDownloader.zoomRange(of: pack, source: info) else { continue }
            download = DownloadProgress(total: RegionDownloader.tileCount(for: pack.manifest.bounds, zoomRange: zooms))
            try await RegionLayerDownloader(source: layer.source, kind: layer.kind, encoding: layer.encoding)
                .download(into: pack) { progress in
                    Task { @MainActor in maps.download = progress }
                }
        }
    }

    /// Show a map type, or say why this backend cannot.
    @MainActor
    func chooseMapType(_ type: MapType) {
        if mapTypes.select(type) {
            notice = nil
            panel = nil
        } else {
            notice = "\(type.title): \(mapTypes.option(for: type).detail)"
        }
    }

    /// The backend's next imagery, for the satellite and hybrid maps.
    @MainActor
    func nextImagery() {
        let count = mapTypes.offer.imagery.count
        guard count > 1 else { return }
        mapTypes.selectImagery((mapTypes.imageryIndex + 1) % count)
    }

    /// `m`: the picker, its selection on the type shown.
    @MainActor
    func openMapTypes() {
        mapTypeSelection = mapTypes.mapType.id
        open(.mapTypes)
    }
}
