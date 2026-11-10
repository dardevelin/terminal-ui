# Backends and their terms

The services a map can draw from, what each one asks of an app, and the
credit its licence requires.

## Overview

A map's data comes through protocols, split by capability: ``MapTileSource``
for the map, ``PlaceSearch`` for search, ``RouteProvider`` for directions,
``PlaceDetails`` for a place's hours and phone, ``StreetImagery`` for street
view and ``LocationProvider`` for the position. An app composes one of each
it wants — OpenFreeMap's tiles with Nominatim's search, say — and can write
its own against any of them.

The library turns nothing on by default. The sample town needs no network;
every open service needs the app to construct it, and every one that the
network reaches requires a `userAgent`: the application's name and a way to
reach its author, such as `"MyMaps/1.0 (me@example.com)"`. OpenStreetMap's
policies require an application to identify itself, and a library's own
name would identify every app that used it as one.

```swift
let agent = "MyMaps/1.0 (me@example.com)"
let tiles = OpenFreeMapTileSource(userAgent: agent)
let search = NominatimSearch(userAgent: agent)
```

Every request goes through an ``HTTPTransport``, ``URLSessionTransport``
unless given another: an app can route the maps through its own cache or
proxy, and a test answers from a stub and makes no network call.

## The map

``OpenFreeMapTileSource`` draws OpenFreeMap's planet (openfreemap.org):
vector tiles in the OpenMapTiles schema, with no key and no request limit.
The data is © OpenStreetMap contributors under the Open Database Licence
(ODbL) and the schema © OpenMapTiles; the credit the source reports, which
the map draws, says so. OpenFreeMap allows a personal offline cache, not a
mirror: <doc:OfflineRegions> caps a download for that reason.

A source of the app's own — an MBTiles file, a tile server it runs —
conforms to ``EncodedTileSource`` and returns the tile's bytes, or to
``MapTileSource`` and returns a ``MapTile`` made with
``MapTile/vector(decoding:)``, ``MapTile/raster(_:)`` or
``MapTile/terrarium(_:)``, and says its credit in ``TileSourceInfo``.

## Imagery and terrain

``RasterTileSource`` reads picture or height tiles from an XYZ template.
Three open sources come ready, offered together by
``MapTypeOffer/open(basemapIsVector:transport:userAgent:)``:

| Source | Licence | Notes |
|--------|---------|-------|
| ``RasterTileSource/sentinel2Cloudless2016(transport:userAgent:)`` | CC BY 4.0, EOX IT Services GmbH, contains modified Copernicus Sentinel data 2016 | The 2016 mosaic only: EOX's later years are CC BY-NC-SA, which a commercial app may not use. 10 m a pixel, so z14 is its last real zoom. |
| ``RasterTileSource/usgsImagery(transport:userAgent:)`` | Public domain, USGS The National Map | The United States only; elsewhere the server answers 404, read as no tile. |
| ``RasterTileSource/awsTerrain(transport:userAgent:)`` | Mapzen's Terrain Tiles on AWS Open Data: SRTM, GMTED2010, ETOPO1, USGS 3DEP and others, each asking to be named | Heights in Terrarium PNGs, z0 to z15. |

Each source's credit is the one its licence asks for, and the map draws it.

## Search and place details

``NominatimSearch`` and ``NominatimPlaceDetails`` use OpenStreetMap's
Nominatim (nominatim.openstreetmap.org). Its usage policy asks for an
identifying User-Agent, at most one request a second, and no search as the
user types; results are ODbL. The library holds the first two for the app:
the agent is required, and every Nominatim request of the process, search
and lookup together, shares one pacing of a request a second, whatever
server it goes to. The third is the app's to keep: search when the user
submits, never per keystroke.

``OverpassPlaceDetails`` reads a place's tags from the Overpass API
(overpass-api.de), current where Nominatim's copy may lag. The public
instance asks for no more than about 10 000 queries a day, and answers
429 or 504 to a client going too fast; the library paces its requests to
one a second and waits out a busy answer, each wait twice the last, a few
times before giving up.

## Routes

``OSRMRoutes`` routes over an OSRM server, and has no default: the app
names one. ``OSRMRoutes/demoURL``, the OSRM project's demo server, is for
trying the API — at most a request a second, light use only — and routes
cars alone whatever profile is asked; walking and cycling need a server
that loads those profiles, given with the modes it answers. Routes are
drawn from OpenStreetMap data, ODbL.

## Street view

``PanoramaxImagery`` reads Panoramax (panoramax.xyz), the open street-level
imagery commons, with no key. ``MapillaryImagery`` reads Mapillary and
needs an access token, which the app obtains under Mapillary's terms and
passes in; the library never looks for one itself. Each ``StreetImage``
carries its own licence and author, and ``StreetViewPanel`` draws them
under the photo.

## Apple's maps

On Apple's systems, `MapKitSnapshotSource`, `MapKitImagerySource`,
`MapKitSearch`, `MapKitRoutes`, `MapKitPlaceDetails` and
`LookAroundImagery` draw from MapKit, under Apple's terms for the app that
uses them. They build only where MapKit is (`#if canImport(MapKit)`), and a
region download never stores Apple's tiles.

## The sample town

``SampleTown`` and its sources are fictional, drawn by the library itself:
no network, no key, no licence to honour beyond this package's own.
