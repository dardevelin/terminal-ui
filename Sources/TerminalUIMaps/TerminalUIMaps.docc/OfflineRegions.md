# Offline regions

Download a region's map, imagery and terrain, and draw and search it with
no network.

## Overview

A region pack is a directory: a `manifest.json` that says what the pack
holds, and the tiles, each as its source served it. ``RegionDownloader``
fetches a region's vector tiles into one; ``RegionLayerDownloader`` adds
imagery and terrain over the same region; ``OfflineTileSource``,
``OfflineLayerSource`` and ``OfflineSearch`` draw and search it with the
network gone.

## Downloading a region

A ``RegionPackStore`` is the directory packs live in —
`~/Library/Application Support/TerminalUIMaps/packs` on macOS,
`$XDG_DATA_HOME/terminalui-maps/packs` elsewhere — or one the app names.
Download the region in view, at the zooms worth keeping:

```swift
let packs = RegionPackStore()
let downloader = RegionDownloader(store: packs, source: OpenFreeMapTileSource(userAgent: agent))
let region = camera.visibleRegion(in: store.viewSize)
let pack = try await downloader.download(RegionDownloadRequest(name: "Lisbon", bounds: region,
                                                               zoomRange: 12...15)) { progress in
    print("\(progress.completed) of \(progress.total)")
}
```

``RegionDownloader/tileCount(for:zoomRange:)`` says how many tiles a
download would fetch before it starts, so an app can show the size and ask.
A download is refused, before any tile is fetched, beyond
``RegionDownloader/defaultTileLimit`` — 2 000 tiles, a city at street
level — unless the app sets a limit of its own: OpenFreeMap allows a
personal offline cache, not a mirror, and nobody should bulk-download a
country by accident. Four tiles are fetched at once, a polite client's
share.

A download stopped part way — cancelled, offline, a server error — picks up
where it was when asked again under the same name: a tile on disk is not
fetched twice, and each is written whole or not at all.

## Imagery and terrain

``RegionLayerDownloader`` fetches a raster layer over a pack's region and
zooms, kept beside its tiles and named in its manifest:

```swift
let imagery = RegionLayerDownloader(source: RasterTileSource.sentinel2Cloudless2016(userAgent: agent),
                                    kind: .imagery, encoding: .picture)
try await imagery.download(into: pack)
```

Only sources whose licences allow keeping their tiles can be downloaded:
the open imagery and terrain of <doc:BackendsAndTheirTerms> do; Apple's
MapKit snapshots are no ``EncodedTileSource``, so they never reach a pack.

## Reading a pack offline

```swift
for pack in try packs.list() {
    let tiles = MapTileStore(source: OfflineTileSource(pack: pack))
    let search = OfflineSearch(pack: pack)
}
```

``OfflineSearch`` searches the names in the pack's tiles — places, points
of interest and streets — read the first time it is asked. A pack's
manifest keeps its source's credit, which the map draws as it would the
source's own, and how the source's feature ids name the map data, so a tap
on a point of interest in a pack of OpenFreeMap's tiles still asks after
the right OpenStreetMap element.
