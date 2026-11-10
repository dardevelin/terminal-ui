import Foundation
import TerminalUIMaps

/// The backends the app offers, each a tile source, a search and a router
/// composed (design/maps.md, "Backends — split by capability").
enum BackendPreset: String, CaseIterable, Identifiable, Sendable {
    case openStreetMap = "osm"
    case apple
    case offline
    case sample

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openStreetMap: "OpenStreetMap"
        case .apple: "Apple"
        case .offline: "Offline"
        case .sample: "Sample"
        }
    }

    var summary: String {
        switch self {
        case .openStreetMap: "OpenFreeMap tiles, Nominatim search, OSRM directions"
        case .apple: "MapKit snapshots, search and directions"
        case .offline: "a downloaded region and the names in it"
        case .sample: "Millbrook, a fictional town; no network"
        }
    }

    /// The presets this build can offer: Apple's only where MapKit is.
    static var available: [BackendPreset] {
        #if canImport(MapKit)
        allCases
        #else
        allCases.filter { $0 != .apple }
        #endif
    }
}

/// One of each capability, as a preset composes them.
struct Backend: Sendable {
    let preset: BackendPreset
    let tiles: any MapTileSource
    let search: any PlaceSearch
    /// Nil where the backend gives no directions: offline.
    let routes: (any RouteProvider)?
    /// What a region is downloaded from; nil where the tiles are pictures
    /// or already on disk.
    let downloads: (any EncodedTileSource)?
    /// The pack an offline backend reads.
    let pack: RegionPack?
    /// What a place card asks for a place's hours, phone and the rest; nil
    /// where the backend has no such service (PlaceDetailsViews.swift).
    var details: (any PlaceDetails)?

    /// The name Nominatim's usage policy requires every request to carry,
    /// and the other services are sent too.
    static let userAgent = "TerminalUIMaps-Example/0.1 (TerminalUI maps experiment, Examples/Maps)"

    enum Unavailable: Error, CustomStringConvertible {
        case noPack
        case noMapKit

        var description: String {
            switch self {
            case .noPack: "no region downloaded yet: download one with o"
            case .noMapKit: "Apple's maps need MapKit, which this system lacks"
            }
        }
    }

    /// The backend of a preset; offline reads `pack`.
    static func make(_ preset: BackendPreset, pack: RegionPack?,
                     details: PlaceDetailsSource = .nominatim) throws -> Backend {
        var backend = try composed(preset, pack: pack)
        backend.details = details.provider(for: preset, userAgent: userAgent)
        return backend
    }

    private static func composed(_ preset: BackendPreset, pack: RegionPack?) throws -> Backend {
        switch preset {
        case .openStreetMap:
            // The OSRM project's demo server, chosen here as the app is a
            // demonstration: cars only, a request a second at most.
            let tiles = OpenFreeMapTileSource(userAgent: userAgent)
            return Backend(preset: preset, tiles: tiles, search: NominatimSearch(userAgent: userAgent),
                           routes: OSRMRoutes(baseURL: OSRMRoutes.demoURL, userAgent: userAgent), downloads: tiles,
                           pack: nil)
        case .apple:
            #if canImport(MapKit)
            return Backend(preset: preset, tiles: MapKitSnapshotSource(), search: MapKitSearch(),
                           routes: MapKitRoutes(), downloads: nil, pack: nil)
            #else
            throw Unavailable.noMapKit
            #endif
        case .offline:
            guard let pack else { throw Unavailable.noPack }
            return Backend(preset: preset, tiles: OfflineTileSource(pack: pack), search: OfflineSearch(pack: pack),
                           routes: nil, downloads: nil, pack: pack)
        case .sample:
            return Backend(preset: preset, tiles: SampleTileSource(), search: SampleSearch(),
                           routes: SampleRoutes(), downloads: SampleTileSource(), pack: nil)
        }
    }
}

/// What the command line chose.
struct LaunchOptions {
    var backend = BackendPreset.sample
    /// Where downloaded regions live; the platform's place unless given.
    var packsDirectory: URL?
    /// Where OpenStreetMap places' details come from.
    var details = PlaceDetailsSource.nominatim
    /// Where the position comes from (`LocationSpec`'s spellings).
    var location: LocationSpec?
    /// How many times faster than recorded a GPX replay plays.
    var replaySpeed = 1.0

    /// The location and replay speed when `--location` and
    /// `--replay-speed` are not given: the PTY harness cannot pass
    /// arguments.
    static let locationVariable = "TERMINALUI_MAPS_LOCATION"
    static let replaySpeedVariable = "TERMINALUI_MAPS_REPLAY_SPEED"

    /// Names the packs directory when `--packs` does not: a harness's, kept
    /// apart from the user's own regions.
    static let packsVariable = "TERMINALUI_MAPS_PACKS"

    /// `--backend osm|apple|offline|sample`, `--packs DIR`, `--details nominatim|overpass`,
    /// `--location gpx:PATH|gpsd[:HOST:PORT]|nmea:tcp:HOST:PORT|nmea:udp[:PORT]|corelocation|here|none`
    /// and `--replay-speed N`; anything else is left alone.
    static func parse(_ arguments: [String],
                      environment: [String: String] = ProcessInfo.processInfo.environment) -> LaunchOptions {
        var options = LaunchOptions()
        options.packsDirectory = environment[packsVariable].map { URL(fileURLWithPath: $0) }
        options.location = environment[locationVariable].flatMap(LocationSpec.init)
        options.replaySpeed = environment[replaySpeedVariable].flatMap(Double.init) ?? options.replaySpeed
        var remaining = arguments.dropFirst().makeIterator()
        while let argument = remaining.next() {
            switch argument {
            case "--backend":
                if let value = remaining.next(), let preset = BackendPreset(rawValue: value) {
                    options.backend = preset
                }
            case "--packs":
                if let value = remaining.next() { options.packsDirectory = URL(fileURLWithPath: value) }
            case "--details":
                if let value = remaining.next(), let source = PlaceDetailsSource(rawValue: value) {
                    options.details = source
                }
            case "--location":
                if let value = remaining.next() { options.location = LocationSpec(value) }
            case "--replay-speed":
                if let value = remaining.next().flatMap(Double.init), value > 0 { options.replaySpeed = value }
            default:
                continue
            }
        }
        return options
    }
}
