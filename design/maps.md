# Maps

A text-based maps app, in the spirit of Apple Maps, built on TerminalUI to find
the components the framework is missing. It began as an experiment on its own
branch; `TerminalUIMaps` now ships as a public library product (2.6.0) and
`Examples/Maps` as its example, held to the 2.x rule that the public API stays
source-compatible. The demo-as-forcing-function rule from `crush-parity.md` §5
applies: a component gets built because the app needs it. The library is also
the rehearsal for a real app built on it, so its API is what such an app needs.

## The public API, as shipped

The review before shipping kept public only the seams and the views:

- **The map**: `MapView`, `MapCamera` (in cells: `visibleRegion(in:)`,
  `coordinate(atCell:in:)`, `fitting(_:in:zoomRange:)`), `MapTileStore`,
  the content builder and its `Marker`, `MapPolyline`, `RouteEnds`,
  `TravellerMarker`, `MapContentGroup`, an opaque `MapElement`;
  `MapLayers`, `MapTypeModel` and its offers; `MapCompass`.
- **The seams**: `MapTileSource`/`EncodedTileSource` returning an opaque
  `MapTile` (made from MVT bytes, a picture or Terrarium heights),
  `PlaceSearch`, `RouteProvider`, `PlaceDetails`, `StreetImagery`,
  `LocationProvider`, `HTTPTransport`, and their open, MapKit and sample
  implementations.
- **Navigation**: `NavigationController`, `NavigationSession`,
  `NavigationBanner`, `TravelProfile`'s presets, and `NavigationCamera`,
  which gathers the following camera, the traveller's prediction and the
  junction zoom the app had wired by hand from a dozen public pieces.
- **Offline**: the pack store, the downloaders and the offline sources.

Internal: the MVT codec and protobuf, gzip, GPX's XML, the label placer,
the renderer, Web Mercator and the braille dot geometry, terrain shading,
`FollowCamera`, `CameraMotion`, `TravellerPrediction`, `JunctionZoom` and
the junction analysis, `RouteLine`, the socket reader, the request pacing.

Network etiquette is the library's to keep, not the app's to remember:
every network backend takes a `userAgent` with no default, Nominatim and
Overpass share one pacing of a request a second across the process,
Overpass backs off on 429 and 504, and `OSRMRoutes` has no default server.
Nothing reaches the network unless an app constructs it.

## What the app does

- A map that fills the terminal, drawn as text: roads and rivers as coloured
  braille lines, water, parks and land-use as cell-background fills, place, road
  and POI names as text labels that never overlap.
- Pan with the arrow keys / hjkl or by dragging with the mouse; zoom with `+`/`-`
  or the wheel, the wheel zooming about the pointer.
- `/` search: a field over the map, results in a list, Enter flies the camera to
  the place and drops a marker; a place card shows name, kind, address.
- Directions between two places: the route drawn on the map, the steps listed in
  a side panel, distance and time.
- Downloads: pick the visible region, download it for offline use, list and
  delete downloaded regions. Offline, search runs over the names in the
  downloaded tiles.
- Switch backend at runtime; the status bar shows the backend, zoom, centre and
  the data attribution the source requires.

## Backends — split by capability

A backend is not one thing. Apple MapKit has excellent search and directions
but hands out its map only as a picture; OSM has vector geometry; an offline
pack has whatever was downloaded. So there are three protocols, and the app
composes one of each:

| Protocol | Answers | Implementations |
|----------|---------|-----------------|
| `MapTileSource` | the basemap for a tile: vector features, or a raster | `OpenFreeMapTileSource` (OpenMapTiles-schema vector tiles from tiles.openfreemap.org, no key), `OfflineTileSource` (a downloaded region pack), `SampleTileSource` (a fictional town, built in code — no network, the tests' and the first launch's data), `MapKitSnapshotSource` (`#if canImport(MapKit)`: `MKMapSnapshotter`, drawn as half-blocks) |
| `PlaceSearch` | text → places | `NominatimSearch`, `MapKitSearch` (`MKLocalSearch`), `OfflineSearch` (names in a pack's `place`/`poi`/`transportation_name` layers), `SampleSearch` |
| `RouteProvider` | two places → a route with steps | `OSRMRoutes` (router.project-osrm.org demo), `MapKitRoutes` (`MKDirections`), none offline |

Presets the app offers: **OpenStreetMap** (OpenFreeMap + Nominatim + OSRM),
**Apple** (MapKit for all three, macOS only), **Offline** (a pack + its search),
**Sample** (the fictional town). Mixing is a matter of composition (e.g. OSM
tiles with MapKit search), not a separate backend.

Network: Foundation's `URLSession` (`FoundationNetworking` on Linux). Every
request carries a User-Agent naming the app, as Nominatim's policy demands; at
most one Nominatim request a second; search on Enter, not per keystroke.
Attribution "© OpenStreetMap contributors" (and OpenFreeMap's) is always on
screen for OSM data.

### Offline packs ("downloadable")

A pack is a directory: `manifest.json` (name, bounding box, zoom range, source,
date, tile count, bytes) and `tiles/<z>/<x>/<y>.mvt`, the source's bytes as
fetched. Download = enumerate the tiles of the bbox over the zoom range, fetch
with bounded concurrency, report progress, resumable (a tile already on disk is
skipped). Packs live under `~/Library/Application Support/TerminalUIMaps/packs`
(macOS) or `$XDG_DATA_HOME/terminalui-maps/packs` (Linux), overridable.
OpenFreeMap's terms allow this for a personal offline cache; the tile count is
capped (default 2 000) so nobody bulk-downloads a country by accident.

## Components

### In the framework — `Canvas` (SwiftUI parity)

SwiftUI's `Canvas { context, size in … }` with a `GraphicsContext` and a `Path`,
the immediate-mode drawing view the framework lacks: `BrailleCanvas` is
monochrome and renders a String; `BufferView` takes a finished `CellBuffer`.
Coordinates are in cells (`Double`), origin top-left, so `size` is the view's
cell size.

- `Path`: `move(to:)`, `addLine(to:)`, `addLines`, `addRect`, `addEllipse`,
  `closeSubpath`, quadratic/cubic curves (flattened).
- `GraphicsContext`: `stroke(_:with:lineWidth:)`, `fill(_:with:)` (non-zero
  and even-odd), `draw(_ text: String, at:anchor:style)`, `fill` of a whole cell
  rect, `clip(to:)`, `translateBy`/`scaleBy`, an opacity.
- Raster model per cell — two planes, composited when the closure returns:
  - **Background plane** — fills, sampled at half-block resolution (1×2 per
    cell). Where a cell's two halves differ and no stroke or text covers it, it
    draws `▀` with upper/lower colours; otherwise the cell's background is the
    majority colour.
  - **Stroke plane** — braille dots (2×4 per cell), one foreground colour per
    cell: a later stroke of a different colour clears the earlier dots in that
    cell (a road crossing a river reads as a bridge, not a blend).
  - **Text plane** — glyphs on whole cells (wide characters as pairs), over
    both; the cell keeps the background beneath it.
- Resolution as a modifier, `.canvasResolution(.braille | .halfBlock | .cell)`,
  for strokes; braille the default.
- Rendered at draw time with the allocated size, like SwiftUI's renderer
  closure — not rebuilt by layout, not a `GeometryReader` re-running `body`.
  Hit-testing and gestures attach to it as to any view.

`Canvas` is general — charts and diagrams want it too — which is why it goes in
the framework and not the maps library.

### In `TerminalUIMaps`

- **Geo**: `GeoCoordinate` (lat/lon, `Double`), `GeoRect`, Web Mercator
  projection, `TileID` (z/x/y), the tiles covering a viewport, a `MapCamera`
  (centre, zoom as `Double`, the dots-per-world at a zoom). Cells are ~1:2, so a
  braille dot is ~square: the projection works in dots.
- **Vector tiles**: a pure-Swift Mapbox Vector Tile 2.1 decoder (protobuf wire
  format, `MoveTo/LineTo/ClosePath` commands, zig-zag, keys/values tables) into
  `VectorTile { layers: [VectorLayer { name, extent, features }] }`, `VectorFeature
  { id, kind: point/line/polygon, rings: [[TilePoint]], properties }`.
- **Style**: the OpenMapTiles schema mapped to draw order, minimum zoom and a
  theme role (water, park, landuse, road classes motorway→path, rail, building,
  boundary), so the map follows the app's `Theme` — dark and light both read.
- **Renderer**: camera + tiles → `GraphicsContext` calls; tiles at
  `floor(zoom)` clamped to the source's max, over-zoomed beyond; vertices
  simplified to the dot grid; features culled to the viewport.
- **Labels**: prepare once, lay out per frame (the idea from chenglou/pretext:
  the measuring is the expensive part, the placing is arithmetic over cached
  widths). A label is prepared once per (text, style) to its cell width; per
  frame, candidates (right / left / above / below the anchor; along a road, its
  midpoint) are tried in priority order (city → town → suburb → POI → road)
  against a cell-occupancy grid, first fit wins, the rest are dropped.
- **`MapView`**: the SwiftUI MapKit shape — `MapView(camera: $camera, source:
  …) { Marker("Café", coordinate: …); MapPolyline(route.points) }` — on a
  `Canvas`, with drag-to-pan, wheel-zoom about the pointer, keyboard pan/zoom
  when focused, and tile loading as tasks that redraw when a tile lands (a
  missing tile draws its parent over-zoomed, then nothing).

### In the app — `Examples/Maps`

Search field + results `List`, place card, directions panel, downloads panel,
backend picker, status bar. Built from existing views; anything they cannot do
becomes a framework gap here, below.

## Gaps found

What `Examples/Maps` needed that TerminalUI lacked, in the order the app ran
into them. Fixed in the framework where the fix was small and the right one;
written down where it is larger.

### Fixed in TerminalUI

- **A reader rebuilt by a drain kept its old content.** A `WidthReader`
  builds once per width per *update*, keyed on `updateGeneration`; a body
  re-evaluated by a drain — state changed by a task, not by input — hands the
  reader a new closure without a new generation, and the memo kept the old
  build. Every `StatusBar` holds a `WidthReader`, so the status line read
  "connecting…" long after the tile source had answered, until a key forced a
  root update. A `List` of declared height had the same memo. Fixed: a new
  closure forgets the memo (`AttributeGraph`, `DrainedReaderTests`).
- **A stack in a stack swallowed its greedy child's height.** A size-driven
  `List` under a heading, in a panel's `VStack` nested in another, was
  measured as content and drew no rows; the horizontal twin of the rule
  (`isFlexChild`) had been fixed and the vertical one (`isVFlexChild`) not.
  Fixed as SwiftUI has it: a stack holding a view that takes the height it is
  offered takes it too (`NestedStackHeightTests`). The whole smoke suite
  passed unchanged with it.
- **`KeyEventResult` was not `Sendable`,** so a key handler could not return
  what an `@MainActor` model decided through `MainActor.assumeIsolated`.
- **`GraphicsContext` had no rectangle fill, and its palette was a list.** A
  raster tile (MapKit's snapshot) is thousands of half-cell fills of as many
  colours a frame: a `Path` per sample, and a linear search of the palette per
  colour, made it quadratic. Added `fill(_ rect: CanvasRect, with:)`, which
  takes exactly the half cells `fill(Path(rect))` would, and a hashed palette.

### Worked around in the app; larger than a small fix

- **Bodies and handlers are not `@MainActor`, though the runtime only ever
  calls them there.** `MapTileStore` is `@MainActor @Observable`, the natural
  Swift 6 shape for UI state, and every read of it from a `body`, a `Canvas`
  renderer, a key or wheel handler goes through `MainActor.assumeIsolated`,
  carrying only `Sendable` values across (the Canvas cannot hand its
  `GraphicsContext` in). The app's own model follows Coder's and Chat's
  pattern — not isolated, a `nonisolated(unsafe)` global — and handlers that
  start main-actor work name that global rather than capture the model. The
  store needed a `nonisolated init` so the model could make it. The real fix
  is isolating `TerminalView.body` and the handler closure types to the main
  actor: an API change across the framework.
- **No programmatic focus.** There is no `@FocusState`/`.focused(_:)`, so the
  app cannot move focus from the search field to the results when they
  arrive. The field takes ↑/↓ to move the selection and a second Enter to go
  to it; Tab still reaches the list.
- **`.background(color)` colours only the cells its content writes.** Padding
  and the ends of short rows keep what lies beneath, so a card overlaid on the
  map let street names show through it. Worked around with an opaque `Canvas`
  in `.backgroundView`. Missing: an opaque fill view, SwiftUI's `Color` used
  as a view or `Rectangle().fill(_:)`.
- **Keys typed between a presentation closing and the next frame are lost.**
  Choosing a result closes the panel, and focus returns to the map only when
  the next frame is drawn; a `-` sent straight after the Enter reached no
  view. Harmless at human speed, visible to a scripted client.
- **The default focus indicator draws over a full-bleed view.** A focused
  `MapView` got a bar down the map's first column; the map sets
  `.focusIndicator(.none)`. A `Canvas` might default to none.
- **The PTY runner cannot pass arguments to the app it spawns.** The packs
  directory a harness should use is read from `TERMINALUI_MAPS_PACKS` as well
  as `--packs`.

### Seen in the running app, left as they are

- Label placement does not know about overlays (the place card, the credit
  band): a name may be drawn under them and cut.
- Where a braille line crosses a fill's edge mid-cell, the cell takes the
  upper half's colour as its ground (the canvas's rule), so the edge steps by
  half a cell there.
- A MapKit snapshot is rendered for a 256-point tile, so its labels and icons
  come out large at half-block resolution; asking for a tile's snapshot one
  zoom out would show more context.

### Measured

`MapRendererFixtureTests.benchmark` (`TERMINALUI_MAPS_BENCHMARK=1`): a
200 × 60 frame over the real z14 Constância tile, panning a dot a frame, takes
**12.7 ms in a debug build** — 117 features drawn and 62 culled, 3 740 points
drawn and 511 dropped within a dot, 77 of 179 names placed. A release build of
the test bundle was not measured: `swift build -c release --build-tests`
stops compiling `TerminalUITests`, which this experiment did not chase.

## Plan

1. `Canvas`, `GraphicsContext`, `Path` in TerminalUI, with tests and a Storybook
   page. — in parallel with 2.
2. `TerminalUIMaps` data layer: geo, the MVT decoder, style, the three backend
   protocols and every implementation, offline packs. Tested without network
   (fixtures, a stub `URLProtocol`); a live check behind an env var.
3. Renderer + labels + `MapView` on `Canvas`.
4. `Examples/Maps`.
5. A write-up: what worked, which components earned a place in the framework.

## Second round — what a real app needs

The experiment is a rehearsal: these features will be part of an app built on
TerminalUI. So every feature is a component in `TerminalUIMaps` with an API an
app imports — protocols at the seams, state models testable without a screen,
views that take bindings — and `Examples/Maps` stays a thin composition. The
terminal experience comes first and must work well; the glasses come after.

Sources, licences and protocol facts were researched on 2026-11-10 (live checks
from this Mac where marked in the research notes).

### A. Dense cities and business information

- **Legibility at density.** OpenFreeMap stops at z14 (a central-Paris z14
  tile: ~13 800 POIs, 1.2 MB); z15–z19 are over-zoomed. OpenMapTiles' POI
  `rank` is an ordinal within a 6×6 grid per tile, not global importance, so
  a per-zoom `rank` cut admits about 36·N POIs a tile. Drop noise classes
  (bollard, waste basket, bicycle parking …); one glyph per POI class (a
  category legend, `check_font_glyphs`-safe); POIs claim cells in the same
  collision grid as labels; building footprints at z15+; road names spaced
  along the line. A real dense-centre tile becomes a fixture with a frame
  budget measured on it.
- **Business information.** A `PlaceDetails` protocol: opening hours (parsed
  `opening_hours`, open-now), phone, website, cuisine, accessibility, from
  Nominatim `lookup?extratags=1&namedetails=1` and Overpass (by OSM id;
  ≤10 000 queries/day, back off on 429), and from `MKMapItem` (phone, URL,
  category, address — Apple exposes no hours or ratings). The place card shows
  what the backend has and says what it does not.

#### A, as built

**The level-of-detail ladder.** What each zoom adds, held by
`LevelOfDetailTests` (each `MapRole.minimumZoom`, and frames of the sample
town at 10, 12, 14, 15, 17 and 18–22):

| Zoom | Appears |
|------|---------|
| 0 | water, country names |
| 3 | boundaries, region names |
| 5 | motorways, city names |
| 7 | trunk roads, land cover |
| 8 | primary roads, rail, town names |
| 9 | secondary roads, waterways, sea and river names |
| 10 | tertiary roads, parks, land use, village names |
| 12 | minor roads, suburb names |
| 13 | road names, service roads |
| 14 | paths, points of interest (2 ranks a grid cell), lake and pond names |
| 15 | buildings; 8 ranks a cell of a z14 tile |
| 16 | 32 ranks |
| 17 | house numbers; 128 ranks |
| 18+ | every point the tile has |

Beside the table, two rules of size: an area smaller than a half cell both
ways is not drawn, and a line is not named until it is as long on screen as
its name, so at 10 the sample town is named and its river, pond and streets
are not. Names along a line are offered every 40 columns out from its middle,
and where none of those is on screen, at the middle of the longest stretch
that is: a street crossing the view is named at every zoom. The sample source
serves each layer from OpenMapTiles' own first zoom (buildings 13, house
numbers 14, points 12) and ranks its points in the 6 × 6 grid, as OpenFreeMap
does; Millbrook gained 17 businesses, 300-odd numbered houses and four
footpaths so its close zooms have something to show.

A zoom out draws a missing tile from its cached children (two levels down)
when they cover it whole, else from a cached ancestor, else from what children
there are: zooming out never blanks the map (`zoomingOutWhileTilesLoad…`).
`]` and `[` zoom half a level, Shift and the wheel a quarter, and
`MapCamera.centred(on:zoom:)` flies to a target zoom.

**Dense cities.** Central Paris at z14 (8298/5636, 13 832 points) is a
fixture. `PointOfInterestDensity` cuts points by rank per zoom: 2 a grid cell
at the tile's zoom, four times as many each zoom deeper. `PointOfInterestCategory`
drops street furniture and offices and gives every other class one of 16
glyphs (ASCII, or shapes `GlyphGeometry` now draws: ◆ ▪ ⌂ ★ ✚), shown by
`PointOfInterestLegend`; `check_font_glyphs.py` now reads `Sources/TerminalUIMaps`
too. A point's glyph claims its cell in the label grid (`LabelRequest.Style
.pointOfInterest`), and keeps it when its name finds no room.
`MapRenderer.placedPointsOfInterest` and `pointOfInterest(atColumn:row:)`
answer a click; `MapView.onPointOfInterestTap` delivers it.

**Business information.** `PlaceDetails` (a protocol: `sourceName`, `fields`,
`details(for:)`) answers with a `PlaceInformation`: category, `PostalAddress`,
`OpeningHours`, phone, website, cuisine, `WheelchairAccess`, time zone.
`OpeningHours` reads the common forms of `opening_hours` (weekday ranges and
lists, time lists, past midnight, `off`, `24/7`, `;` replacing and `,` adding)
and computes open-now against a given date and time zone; months, dates,
weeks, sun times, open ends, comments and `||` leave it unread and the card
says so; holiday rules are set aside and said to be. Backends:

| Backend | Gives | Lacks |
|---------|-------|-------|
| `NominatimPlaceDetails` (`lookup`, Nominatim's shared pacing) | everything OSM tags hold, address from `addressdetails` | — |
| `OverpassPlaceDetails` (by element; 429 and 504 waited out, 1 s, 2 s, 4 s) | the live tags | — |
| `MapKitPlaceDetails` (by `MKMapItem.Identifier`, else by name within 150 m) | phone, URL, category, address (`addressRepresentations` on macOS 26), time zone | hours, cuisine, accessibility |
| `SamplePlaceDetails` | Millbrook's businesses, made up | — |

A clicked point's OSM element comes from planetiler's feature id (id × 10 +
1, 2, 3 for node, way, relation). `PlaceDetailsLoader` is the card's model;
`PlaceCardContent` its lines, which say what this place has not recorded and,
once, what the backend never gives; `PlaceCardView` draws them.

**Gaps found in round two.**

- *An overlay aligned anywhere but the top-left of a canvas did not show.*
  The legend, given its own `.overlay(alignment: .bottomLeading)`, never
  appeared: the canvas was measured as a cell, and the overlay aligned in it.
  The navigation work fixed the cause in the framework ("An overlay on a view
  that takes its offer is aligned in all of it"); the legend still shares the
  card's top-left overlay, stacked under it.
- *Escape quits an app whose `onEvent` already handled it.* `onEvent`
  returning true does not stop the framework's outermost binding, Escape →
  `dismissOrQuit`; with the place card open and no panel, Escape closed the
  card and quit the app. The map's key handler took Escape until the
  framework fixed it: Escape is the app's `onEvent`'s to decide, and the
  framework's binding only dismisses.
- *A tap with its location.* `TapGesture` hands its action no position; the
  map uses `.onClick`'s cell. It fires on the press, so a drag that starts on
  a point also selects it.
- *A tool's own key names.* The control client's `send_key("?")` sends no
  `?`; `send_text` does.

**Measured.** 200 × 60 over central Paris in a debug build
(`DenseCityTests.benchmark`, `TERMINALUI_MAPS_BENCHMARK=1`): 25 ms at z14.5,
22 ms at 16, 16 ms at 18, held under 40 ms. Before areas and lines were cut
to the viewport and off-screen rings passed over, z18 took 71 ms: a z14
tile's buildings arrive merged into a few features of thousands of points.
The ordinary run holds the work instead: at most 480 names offered and
80 000 points drawn a frame, 20 to 120 points of interest placed at 14–16.

### B. Map types — standard, satellite, terrain, street view

- **Satellite.** Apple: `MKMapSnapshotter` with `MKImageryMapConfiguration` /
  `MKHybridMapConfiguration` (checked: real imagery from a CLI). Open: EOX
  Sentinel-2 cloudless **2016** (CC BY 4.0; later years are non-commercial),
  JPEG, `tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/{z}/{y}/{x}.jpg`;
  USGS orthoimagery for the US. Esri World Imagery is excluded: its licence
  does not cover this use.
- **Terrain.** AWS Terrain Tiles (Terrarium PNG, z0–15, no key,
  `h = R·256 + G + B/256 − 32768`): hillshade computed in the app, contour
  lines drawn as braille strokes, over the vector map.
- **Street view.** Apple Look Around (`MKLookAroundSnapshotter`, checked from a
  CLI; no heading control), Panoramax (no key, CC BY-SA, strongest in France),
  Mapillary (free token, CC BY-SA) — a photo drawn in half-blocks in a panel,
  stepping to the next image along the street.
- Decoders, pure Swift so Linux draws the same: PNG (on the existing inflate)
  and baseline JPEG.
- A map-type picker, as Apple Maps has (Explore / Satellite / Terrain), with
  street view as a panel, not a type.

### B, as built

- **Decoders in TerminalUIIO, not the maps library.** `PNGDecoder` (every
  colour type and depth, the five filters, Adam7, `tRNS`, CRCs and Adler-32
  checked) and `JPEGDecoder` (baseline and extended sequential Huffman,
  4:4:4 to 4:2:0, restart markers; progressive, arithmetic, lossless,
  12-bit and CMYK refused by name). TerminalUIIO already held the
  `ImageDecoder` seam and the inflate PNG needs, and a street photo is not a
  map. `Inflate` gained an output limit so a PNG that would inflate past its
  rows is refused. PNG fixtures are computed from a pixel model and agree
  with ImageMagick; JPEG fixtures are cjpeg's, within 3 levels of djpeg and
  2.5 on average of ImageIO.
- **Layers, not a second renderer.** `MapView(...).mapLayers(MapLayers)`:
  imagery drawn as the ground, the basemap's areas, terrain's hillshade
  (Horn 1981, warm light and cool shadow, mixed through the canvas's
  opacity) and contours (marching squares, 5 m at z15 to 1 000 m), then the
  basemap's lines and names. Hybrid hides the areas and sets names on the
  theme's ground. `MapTypeModel` says per backend what each type draws from
  or why it cannot (a picture basemap cannot have roads drawn over
  imagery); the picker shows it.
- **Sources.** `RasterTileSource` (`sentinel2Cloudless2016`, `usgsImagery`,
  `awsTerrain`), `TileSourceChain` (USGS leading, Sentinel-2 filling in, a
  shallower source cut from its deepest tile), `MapKitImagerySource`
  (imagery, hybrid without pins), and the sample town's own imagery,
  ground and street photos, so every type works offline.
- **Street view.** `StreetImagery` (images near, neighbours along the
  street, the photo), `PanoramaxImagery`, `MapillaryImagery` (token from
  `MAPILLARY_ACCESS_TOKEN`, sent as a header), `LookAroundImagery` (steps by
  a walking bearing: Look Around has no sequence or heading),
  `StreetViewModel`, `StreetViewPanel`.
- **Packs hold raster layers** under `layers/<kind>/`, listed in the
  manifest's optional `layers` — the format number unchanged, as a reader
  that knows none ignores the key. Only sources whose licences allow keeping
  tiles are downloaded; Apple's never.

Found on the way: Escape on the place card reached the framework's
`dismissOrQuit` and quit the app — an overlay is not a presentation, and
`onEvent` cannot consume a key. Fixed in the framework since: an app's
`onEvent` decides whether Escape quits.

### C. Routes, location and live navigation

- **Marking a route.** Waypoints added on the map or from search, reordered,
  removed; a multi-stop route through them; saved and loaded as GPX.
- **Location.** A `LocationProvider` stream of fixes (position, accuracy,
  course, speed, time): CoreLocation (macOS; a CLI needs an Info.plist
  embedded or an `.app` wrapper — to be proven), gpsd (TCP 2947, `?WATCH`,
  TPV), NMEA over TCP/UDP (a phone app streaming its GPS), and GPX replay at
  real or scaled speed — the simulator every navigation test runs on.
- **Navigation.** A `NavigationSession` state model, testable without a
  screen: snap to the route within a threshold, advance steps (also when the
  traveller is already on a later step), off-route after ~50 m beyond the
  route with good accuracy (fixes worse than ~10 m ignored), reroute, ETA and
  distance remaining. Manoeuvres from OSRM's `maneuver{type, modifier}`; for
  MapKit, inferred from the polyline's turn angle at each step boundary.
- **The view.** A banner (arrow, distance, street), the next step, heading-up
  map rotation above walking speed with the traveller a third from the bottom,
  zoom by speed, and the camera following until the user pans away.

### C, as built

**Routes.** `RoutePlan` holds the stops (`append`, `insert`, `move`,
`remove`, `reverse`, `remaining(from:after:)`); `RouteProvider` gained
`route(through:mode:)`, a requirement so `any RouteProvider` dispatches it,
defaulting to a leg at a time joined by `Route.joining` (MapKit, the
sample), and answered by OSRM in one request. `RouteStep` carries the
street `name` and a `Maneuver` — OSRM's `type`, `modifier`, `bearing_before`,
`bearing_after`, `exit` — and MapKit's steps have theirs inferred from the
bend of the step polylines (`StepShapes`, OSRM's `getTurnDirection` bands:
straight within 20°, slight to 40°, plain to 120°, sharp beyond, U-turn from
170°). GPX 1.1 (`GPXDocument`: `wpt`, `rte`, `trk`) is read and written by a
small XML reader and writer of the library's own and a pure-arithmetic
`xsd:dateTime`, so Linux needs neither libxml2 nor FoundationXML.

**Location.** `LocationProvider.fixes()` is an `AsyncThrowingStream` of
`LocationFix` (coordinate, horizontal accuracy, course, speed, timestamp,
source) — throwing, so a refused or dropped connection says why the
position stopped. `GPXReplayProvider` plays a `TrackTimeline` against an
injected clock, a fix every `interval` of track time and a sleep of
`interval / speed`; `GPSDLocationProvider` sends `?WATCH` and reads TPV;
`NMEALocationProvider` reads checksummed RMC and GGA (accuracy ≈ HDOP ×
5 m) over TCP or UDP; both read on a thread of their own (`LineSocket`,
`poll` with a 200 ms timeout so cancellation is seen). `LocationSpec` is
the `--location` spelling.

**CoreLocation from a SwiftPM binary — proven.** A process with no
`Info.plist` has no bundle identifier and no usage description, and
`locationd` refuses it without a prompt. Embedding a plist in the binary's
`__TEXT,__info_plist` section with the linker's `-sectcreate` is enough:
`Bundle.main` reads it, and `locationd`'s log shows the request arriving as
the bundle (`Client: …:iorg.terminalui.clprobe:`), "Showing #AuthPrompt"
and "#AuthPrompt posted" to `CoreLocationAgent` — checked on macOS 27 with a
probe run straight from a terminal, no `.app` wrapper and no signing beyond
the linker's ad-hoc signature. `startUpdatingLocation` before the user
answers gets `kCLErrorDenied` while the prompt is up, so the provider
waits for the authorization status, not the error. The linker flag is an
`unsafeFlags`, which SwiftPM refuses in a target a dependent package
builds, so it is opt-in, as
`TUI_WARNINGS_AS_ERRORS` is: `TERMINALUI_MAPS_LOCATION_PLIST=1` adds it to
the Maps example only (`Examples/Maps/Support/Info.plist`, bundle
`org.terminalui.maps`). The manager lives on a thread running its own run
loop: the runtime's main thread runs none.

**Where the binary lives matters.** Run from this checkout under
`~/Downloads`, the same Maps binary is registered by its executable path
(`clientName …:com.apple.locationd.executable-/Users/…/Maps`) and no prompt
is posted; copied to `/tmp` and run from there, it registers as
`org.terminalui.maps` and the prompt is posted. `~/Downloads` is one of the
folders privacy protection guards, and the agent that verifies a client
evidently cannot read the binary's plist there (inferred from the logs;
`~/Desktop` and `~/Documents` are likely the same). Not yet seen: a granted
fix (the prompt needs a person), and whether a rebuild, whose ad-hoc
signature changes, is asked again.

```bash
TERMINALUI_MAPS_LOCATION_PLIST=1 swift build --product Maps
cp .build/debug/Maps /tmp/Maps        # out of ~/Downloads, ~/Desktop, ~/Documents
/tmp/Maps --location corelocation     # from the checkout; Allow "Maps" in the prompt
# Denied: System Settings › Privacy & Security › Location Services › Maps.
# Built without the variable, the app says the binary has no Info.plist.
```

**Navigation.** `NavigationSession` is a value fed fixes: matched to a
`RouteLine` (no further back than 20 m from the last match, a stretch
heading against a trusted course costing 30 m more); the current step is
the last starting within 10 m ahead (Ferrostar's `DistanceToEndOfStep`), so
a traveller already past several jumps to theirs; a fix more than 50 m off
whose accuracy is 10 m or better is off route (Ferrostar's
`RouteDeviationTracking.staticThreshold`, Mapbox's
`RouteControllerMaximumDistanceBeforeRecalculating`), a worse one or one of
unknown accuracy is not; 20 m from the end is arrival; time left is the
current step's share plus the rest (Mapbox's `durationRemaining`), the
route's time spread by length for MapKit. `NavigationController` (main
actor) reroutes from the fix to the stops not yet reached, retries a failed
reroute after 10 s of fix time, pauses, and records the fixes as a track.
`FollowCamera` turns heading up above 2 m/s, zooms by speed, puts the
traveller two thirds down, and stops following at the user's first pan
until re-centred. `MapCamera.bearing` is one rotation in `screenPoint` /
`worldPoint`, so a drag, a wheel zoom, a Ctrl+click and the renderer agree;
labels stay upright; a travelled polyline is the accent faded toward the
ground; `TravellerMarker` is an arrow the traveller's way on the screen.

The demo: `swift run Maps --location gpx:Examples/Maps/Tracks/millbrook-drive.gpx
--replay-speed 8` routes the file's three stops, misses the turn onto High
Street, is rerouted back, passes the town hall and arrives at the library.
The file is `SampleDrive.document()`; a test fails when they differ.

### C, following a driver and a rider

Feedback on the first live camera: drawing back before every turn was wrong
— the zoom must be settled before the turn, not moving at the apex, and
change only where a junction would not read close in. What replaced it:

**Junction-aware zoom (`JunctionAnalysis`, `JunctionLegibility`,
`JunctionZoom`).** The zoom is the profile's speed table's. At each
manoeuvre the junction's roads are read — the router's intersection bearings
where it gives them (OSRM's `intersections[].bearings`, now decoded into
`RouteStep.intersections`), else the vector tiles' `transportation` lines
around the point (`MapTileStore.lines(near:within:roles:)`, so every vector
backend), else the route's own way in and out — and, from the route itself,
the distance to the next manoeuvre and a roundabout's diameter (its arc's
length over the angle it turns). The rules, a cell being 2 × 4 braille dots
holding one colour:

| Rule | Threshold | Why |
|------|-----------|-----|
| Neighbouring roads part | 4 dots at the mouth: 15 m car, 10 m bicycle, 8 m foot | A cell's height: the route's accent and the road beside it never share a cell, which would read as one line. Two roads at θ lie 2·L·sin(θ/2) apart at L. |
| Which pairs | those beside the way out; every pair from 5 roads | A driver counts the arms of a complex junction ("the second left"). |
| Next manoeuvre | 3 cell heights (12 dots) away | One cell for each bend and one for the road between. |
| Roundabout | 12 dots across | Three cells: a ring with a hole and exits; smaller, a blot. Its entry is read by diameter only — the ring's own line curls back inside the mouth. |
| Same road | bearings within 5° | A U-turn's way in and out, a road in two tiles' buffers. |

The zoom that meets them is closed in to only, capped at +1.5 levels; a
junction already legible at the speed's zoom changes nothing. Junctions whose
holds would come within 8 s of each other are held as one group at the
deepest zoom any needs — two changes of scale seconds apart read as pumping —
and each junction with the one after it must fit the screen from where its
zoom settles (2 cells' margin, traveller two thirds down), which may hold the
zoom back from what legibility asks, never more than 0.5 levels below the
speed's.

Timing is in seconds of travel, each with a floor in metres: the target is
final 9 s before the junction (6 s settled — two of the 2 s glances NHTSA's
driver-distraction guidelines allow, and the time to act — plus 3 s for
`CameraMotion`'s 0.8 s zoom lag to close), reached over a 3 s smoothstep,
held through the junction, let go 2 s after it and eased back over 3 s. The
hold is latched: braking for the turn, which moves the speed table's zoom,
does not change the scale mid-junction, at a simple junction as at a tight
one. A replay runs the camera in road time, so a 4× replay is the drive
played fast, settled the same seconds of road before each junction.

Prior art. Google Maps and Apple Maps keep the scale steady through ordinary
turns and give complex junctions their own treatment: lane guidance on the
banner (both), Apple's Junction View — a drawn picture of the lanes at
complex highway exits (iOS 13 on) — and both zoom and tilt into a complex
interchange as it nears. Mapbox's Navigation SDK frames the geometry after the
upcoming manoeuvre and coalesces manoeuvres close together into one frame
(`FollowingFrameOptions`), which is the group rule here. Neither app zooms
out at a simple turn. These are from the apps' and SDK's documented
behaviour as known, not measured here.

**What the camera does at the sample town's Five Ways** (`SampleFiveWays`,
`Examples/Maps/Tracks/millbrook-five-ways-{drive,ride}.gpx`): the car, at
30 km/h on z16.06, closes in to z16.56 for the five-way (25° between Crown
Street and Abbey Lane), settled 75 m out, and holds it through Kiln Circus
(24 m, needs z16.0) and the staggered turns 20 m apart (need z16.52) as one
group, letting go after Copse Road. The bicycle, at 15 km/h already on
z16.96, closes in by 0.19 for the five-way (its 10 m mouth asks z17.15) and
changes nothing at the roundabout or the stagger.

**Travel profiles (`TravelProfile`: car, bicycle, foot).** Each sets the
speed table, heading-up speed (2, 1.5, 0.8 m/s), look-ahead (≤120, 50, 25 m),
junction timing, legibility mouth, off-route distance (50, 30, 25 m: a cycle
track beside a road lies well inside a car's 50) and which roads count as
branches (a car's exclude footpaths). The profile comes from the route's mode
(a GPX route's `type` too) and `w` switches it live; an unnavigated route is
routed again. OSRM's demo server routes cars only, and the panel says so;
MapKit's `MKDirectionsTransportType.cycling` (macOS 11 on) is used for
bicycle routes. The sample town gained cycleways (the Towpath, the Silver
Greenway across the river) and footways, which its router now honours per
mode, one-way streets, and roundabouts it counts the exits of.

**Heading follows the course (`TravellerPrediction`).** The demo's missed
turn swung the map 0° → 271° for a turn the car never took, then 271° → 180°
for a reroute behind it. Now above the profile's heading-up speed the map
faces the GPS course; the route ahead only leans it toward a turn, by 30° at
most; the traveller is carried along the route only while it runs within 45°
of the course, and where they part — a missed turn — along the course from
the fix; off route or rerouting, the course alone. A reroute leaves along the
course: `RouteProvider.route(through:mode:departing:)`, OSRM's `bearings` on
the first coordinate (±45°), the sample router leaving only by the end ahead
and turning back only when nothing on reaches the stop; MapKit's request has
no heading and ignores it. A route that must still go back starts with "Make a
U-turn" (`NavigationSession.needsUTurn`), the map facing the way the car goes
until it has turned.

**Orientation and the compass.** `u` cycles heading up → north up → locked
(the bearing the map had); `<` `>` turn the map 15°, eased through
`CameraMotion`, browsing or following, and turning a following map locks it
there, as Apple Maps does. `MapCompass` replaces the status bar's: a braille
ring, a needle with "N" where north is, the degrees while turned, opaque, top
right below the banner; a tap takes a turned map north up and a north-up
following one heading up; `C` shows or hides it.

**Arrival (`RouteEnds`).** A route ends on the road nearest the place; a
dashed connector (`MapPolyline.Style.connector`, a cell's height on and off)
joins the end to the place and the traveller's start to the route's, and the
banner says "Eastwood Visitor Centre, 20 m on your right".

Found on the way, fixed in TerminalUI: **an overlay's tap over a focusable
view lost the click** — the focus engine found the map under the compass
first. A press whose topmost target is a tap outside any focusable now acts
there, focus left where it was.

### Gaps found in round two (C)

- **An overlay aligned on a view that takes its offer was squeezed into a
  cell** — fixed: `.overlay(alignment: .top)` on a `Canvas` measured the
  canvas (one cell) for its frame. The banner over the map needed it.
- **No tap said where it landed** — fixed with `SpatialTapGesture`: a
  `TapGesture` knew its modifiers and `onClick` its location, never both.
- **No pointer position without a click.** Nothing reports where the
  pointer rests, so "a key at the pointer" is a key at the map's middle.
- **Every body and handler goes through `MainActor.assumeIsolated`** to
  reach `NavigationController`, as it does for the tile store (round one).
- **The PTY runner passes no arguments**, so `--location` and
  `--replay-speed` are also `TERMINALUI_MAPS_LOCATION` and
  `TERMINALUI_MAPS_REPLAY_SPEED`.

### Performance pass (planned)

Measure first, in release builds, then fix what the numbers show. What is
known now:

- Map frames are measured only in **debug**: 12.7 ms (Constância z14,
  200 × 60), 16–32 ms (central Paris, z14.5–z18). No release figure exists,
  because `swift build -c release --build-tests` stops compiling
  `TerminalUITests` — unblock that first, so every benchmark has a release
  number.
- Navigation now redraws the whole map every frame while the camera moves
  (`TimelineView` at the render cap): every visible tile's features are
  projected, culled, simplified and rasterised again, and labels placed
  again, for a camera that moved a fraction of a dot. Candidates: cache
  each tile's geometry projected at its zoom and only transform it per
  frame; place labels only when the camera moves past a threshold;
  render at a lower rate while only the traveller moves.
- Tile decoding (MVT, gzip, PNG/JPEG) runs off the main actor, but a dense
  tile is 1.2 MB: measure decode cost and memory per tile and the LRU's
  footprint.
- 3D: 1.7–3.8 ms a 200 × 60 frame in release, inside budget; re-check once
  the 3D map (extruded buildings, terrain mesh) lands, which multiplies the
  triangle count.
- The framework's known hot spot — `[Any]` boxing in the graph protocol
  chain (CLAUDE.md, "Known performance hot spot") — costs every frame of
  every app; the maps' full-screen redraw makes it visible.
- Track per-frame CPU and allocation with the `swtui` trace and Instruments
  on the demo drive, the Paris fixture and the 3D pages, and record the
  numbers here before and after.

### E. The 3D map (planned, 2026-11-11)

The map seen at an angle, buildings standing on it, then the ground itself
raised — what SwiftUI MapKit shows with `MapCamera(…, pitch:)` and
`.mapStyle(.standard(elevation: .realistic))`. The API follows MapKit's:

- `MapCamera.pitch`, in degrees from straight down, 0 by default, clamped
  to a `pitchRange` (MapKit stops near 60° at street zoom, less zoomed
  out). Zoom keeps meaning the scale at the view's middle; bearing keeps
  turning about it. Additive: a 2.x camera is a pitch-0 camera.
- `MapLayers.elevation`, `.flat` (today's map, and the default) or
  `.realistic`, as MapKit's `MapStyle.Elevation`: buildings and terrain
  stand up only when asked for.
- `MapView` pitches with keys (and a drag with a modifier, MapKit's
  two-finger drag); the app gets a pitch toggle, live, like every other
  behaviour.

Three stages, each its own branch, in this order:

1. **Pitch.** A flat ground under perspective is a homography: lines stay
   lines. `MapRenderer.Projection` grows from a rotation into the
   ground-to-screen 3×3 matrix (bearing, then pitch about the view's
   middle), and everything that projects already goes through it — tile
   squares become quads and their clips, areas and lines (clipped to the
   near side of the horizon before projecting), rasters per dot through
   the inverse, labels at projected anchors (upright text, nearest ranked
   first, dropped past a distance), markers, polylines, the pointer
   (`coordinate(atCell:)`), and pan and wheel zoom anchoring. Tiles cover
   the visible ground trapezoid at a zoom that falls with distance, so a
   far tile is drawn at the density a near one is, up to a far limit;
   above the horizon is sky, a theme role. `NavigationCamera` gets a
   pitched follow, the traveller low in the view.
   **As built.** `GroundProjection` (`Geo/`) is the one homography: the
   camera's `screenPoint` (nil behind the eye) and `worldPoint`, the
   renderer's `Projection`, the drag (`panned(dragging:to:in:)`, ground
   under the pointer) and the wheel all go through it. The eye stands 1.5
   view heights back, so at 60° the top edge sees 2.4 eye distances ahead
   and the horizon never enters the view: no sky is drawn, and every
   screen point is ground. Pitched, every area and line is cut to the
   view's ground (`ConvexRegion`: Sutherland–Hodgman for rings,
   Cyrus–Beck for lines) before it is projected; flat, the old path runs
   unchanged, byte for byte. `pitchedCoveringTiles` is the quadtree: a
   200 × 60 view at z16, 60°, draws 7 tiles, its far rows from z15. A
   label is shown by the zoom its ground is drawn at, so the far rows
   carry no house numbers. Keys: Shift-↑/↓, 10° a press. The example
   tilts with `3` and a Camera-panel toggle.

   **Gap found:** a `DragGesture` value carries no modifiers or button, so
   MapKit's tilt-by-drag (two-finger drag; a right or Ctrl drag in
   MapLibre) cannot be offered yet.

2. **Buildings.** `Vector2`, `Polygon2D` and `Mesh.extrusion(of:height:)`
   return to TerminalUI3D (they wait on the `worktree-maps-experiment`
   branch, `Sources/TerminalUI3D/Mesh/Mesh+Extrusion.swift`, with their
   tests), and TerminalUIMaps depends on TerminalUI3D. Each tile's
   buildings (OpenMapTiles `building`: `render_height`,
   `render_min_height`) become one mesh, built off the main actor with the
   tile and cached beside it, drawn after the ground and before labels by
   the internal `SceneRenderer` (`package` access) through a `Camera3D`
   that agrees with the homography on the ground — a test holds a ground
   point to the same dot through both. Edges blend toward the drawn
   ground.
   **As built.** `BuildingExtrusion` keeps each footprint's
   `render_min_height`/`render_height` beside it in the tile (`hide_3d`
   outlines not raised; 5 m, the schema's fallback, without a height).
   `BuildingScene.camera` sits at the projection's eye distance, tipped and
   turned as it is, with the field of view that makes a middle dot a dot:
   a test holds a ground point to the same dot through both, to 1e-6. A
   tile's buildings are a `BuildingTile`: polygons (not features — a z14
   tile merges a block's buildings into one feature) sorted into a 16 × 16
   grid by their middles, each cell's mesh built the first time the view
   reaches it and only where its nearest ground is drawn at zoom 16 or
   closer. Central Paris at z16.5, 55°, 200 × 60: 11 698 triangles built
   of some 150 000 (a test's budget), 140 ms a frame in debug against 40
   flat; TerminalUI3D draws ~10 000 triangles at that size in ~4 ms in
   release (`SceneBenchmark`). Roofs take `foregroundSubtle`, walls
   `foregroundMuted`, lit by `Light3D.standard`. The example's `3` is the
   3D view (tilt and buildings together), each also a Camera-panel
   toggle.

3. **Terrain** (designed 2026-11-13). With `.realistic` elevation and a
   terrain layer (`MapLayers.terrain`), the ground rises as MapKit's
   does: hills stand, valleys sink, roads and names follow the ground and
   go behind a hill, buildings stand on it. Without a terrain layer, or
   flat, today's paths run unchanged.

   *Why not a draped picture.* Drawing the flat map into a texture and
   sampling it per dot through the terrain would break every braille line
   — a road is one dot wide, and resampling breaks it into specks — and
   TerminalUI3D has no textures. So the ground and its areas are a mesh,
   and the lines and names stay vectors, projected point by point with
   their heights and tested against the mesh's depth.

   *Heights.* Relative to the ground under the camera's centre, so the
   centre keeps its scale and the camera its target, in dots by the
   buildings' dots per metre.

   1. `ElevationField`: the height at a north-up point, from the terrain
      layer's tiles at hand (the plan's tile or a stand-in), bilinear;
      zero where none has landed.
   2. A projection with height: `toScreen(x, y, height)` through the
      buildings' camera (one 3D camera for the whole map), and
      `toGround(screen)` by marching the view ray over the field and
      bisecting the crossing — for the pointer, the wheel and a drag.
   3. The ground: per basemap tile a `heightField` grid (33 × 33 at its
      own zoom) in the shared scene, each triangle's material the area
      under its middle — water, park, landuse, plain — from a land-cover
      grid rasterised once from the tile's areas; lit by the scene's
      lights, which shade the slopes as hillshade did.
   4. The drape: roads, rivers, rail, routes and contours densified to a
      dot apart on screen, each point projected with its height and drawn
      only where it is nearer than the scene's depth there (the
      rasterizer's depth buffer, at package access); names, points of
      interest, markers and the traveller anchored the same way, hidden
      behind a hill.
   5. Buildings stand on the ground at their footprint's height; the
      covering uses the ground the view's corners reach, the flat
      footprint as the fallback.
   6. The example's `3` brings the sample town's terrain, so Beacon Hill
      (160 m) stands; its film shows it.

   **As built.** Steps 1–5 as designed. The ground is drawn half-block
   (the canvas's fill plane), so braille roads and text stay over it and
   the depth test alone hides what is behind; the building-only map keeps
   its image shading. A high key light left gentle slopes unshaded, so the
   ground is lit by hillshade's sun (NW, 45° up) and a sky of 0.35; the
   plain ground takes `backgroundOverlay`. `MapTypeModel.elevation` puts
   realistic elevation in the map's style, with the offer's terrain store
   under every type. Tests: a 600 m ridge hides a marker behind it, not one
   before it; the ray march finds a hill's face before what stands behind.

   **Left for a step of its own:** the pointer on terrain. A click, a drag
   and the wheel still read the flat ground: a drag on a hillside slips by
   the hill's height, and the camera, whose reference is the ground under
   its centre, rises and falls as it pans. Imagery on terrain (satellite
   draped) waits too.

   Cost: a 33 × 33 grid is ~2 000 triangles a tile, ~20 000 for a view —
   ~5–8 ms in release by `SceneBenchmark`'s numbers. Imagery on terrain
   (satellite draped) waits: it needs a picture sampled per triangle or
   per dot, its own step after these.

Then the performance pass's 3D item above: measure the triangle counts and
frame times stages 2 and 3 add, in release.

### D. Even Realities G2 (after the terminal is right)

G2: 576×288 per eye, 4-bit green. The official route is Even Hub — apps are web
apps in the Even phone app — so the Swift app serves navigation state over a
local WebSocket and a small Even Hub plugin draws it (text containers for the
instruction, distance and street; one ≤288×144 image for the arrow or a
mini-map, redrawn only on a manoeuvre change). A reverse-engineered direct BLE
path (g2-kit) exists and stays an option. The terminal gets a HUD preview that
draws exactly the glasses' frame, at their resolution and grey levels.
