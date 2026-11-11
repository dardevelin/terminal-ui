# ``TerminalUIMaps``

Maps drawn in text: vector and picture tiles, search, places, routes, live
location and navigation, behind protocols an app fills with the backends it
chooses.

## Overview

TerminalUIMaps draws a moving map in a ``MapView``, a view like any other in
a TerminalUI app: streets and areas in braille at eight dots a cell, names
placed so none overlap, points of interest marked by kind, imagery in
half-blocks and terrain shaded and contoured, all in the app's theme. The
map's data comes through protocols — ``MapTileSource``, ``PlaceSearch``,
``RouteProvider``, ``PlaceDetails``, ``StreetImagery`` and
``LocationProvider`` — so an app chooses its backends, and a test answers
from a stub.

Nothing reaches the network unless the app asks for it. The library ships a
fictional town, ``SampleTown``, with tiles, search, routes, imagery,
terrain, place details and street view of its own, so a map is on screen
offline with no key; the open services it can use instead each require the
app to name itself, and each one's terms are in <doc:BackendsAndTheirTerms>.

The library is opt-in, as TerminalUI3D is: an app without maps never builds
it.

```swift
.product(name: "TerminalUIMaps", package: "terminal-ui")
```

`swift run Maps` in the package is a whole maps app built on it: search,
directions, map types, street view, offline regions and a replayed drive.

## Topics

### Essentials

- <doc:GettingAMapOnScreen>
- ``MapView``
- ``MapCamera``
- ``MapTileStore``

### The map's content

- ``MapContent``
- ``MapContentBuilder``
- ``Marker``
- ``MapPolyline``
- ``TravellerMarker``
- ``RouteEnds``
- ``MapContentGroup``
- ``MapElement``
- ``MapCompass``

### Map types

- ``MapLayers``
- ``MapElevation``
- ``BasemapDetail``
- ``TerrainStyle``
- ``MapTypeModel``
- ``MapType``
- ``MapTypeOffer``
- ``MapTypeOption``
- ``ImageryOption``
- ``TerrainOption``

### Backends

- <doc:BackendsAndTheirTerms>
- ``MapTileSource``
- ``EncodedTileSource``
- ``MapTile``
- ``TileSourceInfo``
- ``TileID``
- ``OpenFreeMapTileSource``
- ``RasterTileSource``
- ``RasterEncoding``
- ``HTTPTransport``
- ``HTTPRequest``
- ``HTTPResponse``
- ``URLSessionTransport``
- ``MapServiceError``

### Search, places and routes

- <doc:SearchPlacesAndRoutes>
- ``PlaceSearch``
- ``Place``
- ``NominatimSearch``
- ``PlaceDetails``
- ``PlaceInformation``
- ``PlaceDetailsLoader``
- ``PlaceCardView``
- ``PointOfInterestLegend``
- ``MapPointOfInterest``
- ``NominatimPlaceDetails``
- ``OverpassPlaceDetails``
- ``RouteProvider``
- ``Route``
- ``RoutePlan``
- ``OSRMRoutes``

### Live location and navigation

- <doc:LiveLocationAndNavigation>
- ``LocationProvider``
- ``LocationFix``
- ``NavigationController``
- ``NavigationSession``
- ``NavigationCamera``
- ``NavigationBanner``
- ``TravelProfile``

### Offline regions

- <doc:OfflineRegions>
- ``RegionPackStore``
- ``RegionPack``
- ``RegionDownloader``
- ``RegionLayerDownloader``
- ``OfflineTileSource``
- ``OfflineSearch``
- ``OfflineLayerSource``

### Street view

- ``StreetImagery``
- ``StreetImage``
- ``StreetViewModel``
- ``StreetViewPanel``
- ``StreetPhotoView``
- ``PanoramaxImagery``
- ``MapillaryImagery``

### The sample town

- ``SampleTown``
- ``SampleTileSource``
- ``SampleSearch``
- ``SampleRoutes``
- ``SamplePlaceDetails``
- ``SampleImagerySource``
- ``SampleTerrainSource``
- ``SampleStreetImagery``

### Geography

- ``GeoCoordinate``
- ``GeoRect``
- ``GPXDocument``
