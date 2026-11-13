# Getting a map on screen

Draw a map you can move, offline and with no key, from the sample town the
library ships.

## Overview

![The Maps example: the sample town drawn in braille, zoomed to its streets, searched, seen as a satellite picture and as terrain, then driven through a corner with the map turning.](maps.gif)

A map on screen is three things: a ``MapTileStore`` that loads tiles from a
source, a ``MapCamera`` that says where the map looks, and a ``MapView``
that draws the one through the other and writes every pan and zoom back to
the camera.

## The sample town

``SampleTown`` is Millbrook, a fictional town the library draws from its
own geometry: streets and a river, parks and buildings, cafés and shops
with names and opening hours, a five-way junction and a roundabout. Its
sources — ``SampleTileSource`` for the map, ``SampleSearch``,
``SampleRoutes`` and the rest — answer at once, need no network and no key,
and are what the library's tests and the Maps example open on. Start with
them; swap a real backend in later without touching the view.

```swift
import TerminalUI
import TerminalUIMaps

struct TownMap: TerminalView {
    let store: MapTileStore
    @TerminalState var camera = MapCamera(center: SampleTown.origin, zoom: 15)

    var body: some TerminalView {
        MapView(camera: $camera, store: store)
    }
}
```

Make the store once, in the app's model, not in `body`: it holds the tiles
already loaded, and a view rebuilt with a new store would start again from
nothing.

```swift
let store = MapTileStore(source: SampleTileSource())
```

The store loads what the camera covers as tasks, fetched and decoded off
the main actor, and the map draws again as each tile lands. One store
serves one map on screen: what it keeps and cancels follows the frames of
the map that draws from it.

## Moving the map

A ``MapView`` fills what its container offers, as a `Canvas` does, and
takes the pointer and, when focused, the keyboard:

- drag to pan; the wheel zooms about the pointer, a level a notch;
- arrows or `h` `j` `k` `l` pan, `+` and `-` zoom by a level, `]` and `[`
  by half a level;
- Shift with ↑ and ↓ tips the map away from straight down and back.

Every move writes the camera back through its binding, so the app reads
where the map is from its own state, and moves it by setting it:

```swift
camera = camera.centred(on: place.coordinate, zoom: 16)
```

The camera speaks in the map's cells. ``MapCamera/visibleRegion(in:)``
gives the region on screen — what a search prefers results in, or an
offline download covers — and ``MapCamera/coordinate(atCell:in:)`` the
coordinate under a tap; both take the size the map was last drawn at,
``MapTileStore/viewSize``. ``MapCamera/fitting(_:in:zoomRange:)`` is the
camera that shows a whole region.

## Seeing the map at an angle

![The Maps example's 3D view: the sample town tilted, its buildings standing in light and shade, turned about the middle, then driven through in 3D.](maps-3d.gif)

``MapCamera/pitch`` looks at the ground at an angle, as SwiftUI MapKit's
camera does: 0 is straight down, ``MapCamera/maximumPitch`` the steepest.
The street ahead recedes up the screen, its far part drawn from coarser
tiles and named as a map that far out would name it, while the scale
across the middle stays the zoom's. Names and markers stay upright, and a
drag still keeps the ground under the pointer.

```swift
camera.pitch = 45
```

Set the layers' ``MapLayers/elevation`` to ``MapElevation/realistic``, as
MapKit's `.mapStyle(.standard(elevation: .realistic))` does, and the
buildings stand up from their footprints to the heights the tiles give,
drawn in light and shade with TerminalUI3D. They rise where the ground is
drawn at zoom 16 or closer; further out they lie flat, where a house would
be a dot or two.

Give the layers a terrain store as well, and the ground itself stands up:
hills rise and valleys sink, shaded by a sun from the north-west, with the
roads and names following them and hidden behind a ridge. A
``MapTypeModel`` does both at once: set its ``MapTypeModel/elevation`` to
``MapElevation/realistic`` and every map type it draws stands on the
offer's terrain.

```swift
var layers = MapLayers.explore
layers.elevation = .realistic
MapView(camera: $camera, store: store)
    .mapLayers(layers)
```

Navigation keeps the pitch it is given: ``NavigationCamera`` turns and
zooms the camera, and the traveller sits low in the view, the road ahead
above.

## What goes on the map

The content closure lists what is drawn over the basemap, with `if` and
`for` as in a view body. A handler sets state through a binding projected
in `body`, as every TerminalUI handler does:

```swift
var body: some TerminalView {
    let selected = $selected
    MapView(camera: $camera, store: store) {
        Marker("The Copper Kettle", coordinate: cafe)
        if let route {
            MapPolyline(route)
        }
    }
    .onPointOfInterestTap { point in
        selected.wrappedValue = point.place
    }
}
```

A ``Marker``'s title is placed before any name of the basemap's, so it is
never the one left out. ``MapView/onPointOfInterestTap(perform:)`` hands
over the café, shop or station a tap landed on, as a ``Place`` a
``PlaceDetails`` backend can look up (<doc:SearchPlacesAndRoutes>).

## Map types

A map draws a picture beneath it, terrain over it, or less of its own
basemap, as ``MapLayers`` say. ``MapTypeModel`` offers Explore, Satellite,
Hybrid and Terrain from what a backend has, and gives the layers to draw:

```swift
MapView(camera: $camera, store: store)
    .mapLayers(mapTypes.layers)
```

The sample town has imagery and terrain of its own,
``SampleImagerySource`` and ``SampleTerrainSource``, offered together as
``MapTypeOffer/sample``, so every type works offline too:

```swift
let mapTypes = MapTypeModel(offer: .sample)
mapTypes.select(.satellite)
```

## Credits

Every source says, in its ``TileSourceInfo``, the credit its data's licence
requires, and the map draws it in its bottom-right corner, whole, on a band
of its own. An app need do nothing to keep it there; a source of the app's
own should say its credit the same way.
