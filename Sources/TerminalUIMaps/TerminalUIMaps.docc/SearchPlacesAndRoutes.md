# Search, places and routes

Find a place, show what it is like, and route to it through any number of
stops.

## Overview

Search, a place's details and routing are three backends, each its own
protocol, so an app can take them from different services, or from the
sample town while it is being built.

## Searching

A ``PlaceSearch`` answers a query with ``Place`` values, best first. The
region in view is a hint to prefer what is near it, not a filter:

```swift
let search: any PlaceSearch = SampleSearch()
let places = try await search.search("market", near: camera.visibleRegion(in: store.viewSize))
if let first = places.first {
    camera = camera.centred(on: first.coordinate, zoom: 16)
}
```

Search when the user submits the query, not as they type: Nominatim's
usage policy forbids search as you type, and a terminal's Enter is the
natural moment.

## A place's details

A ``PlaceDetails`` backend says what a place is like: its hours, phone,
website, cuisine and wheelchair access, as a ``PlaceInformation``. Backends
know different things — OpenStreetMap's tags have opening hours, Apple's
`MKMapItem` has none — and each says in ``PlaceDetails/fields`` what it can
ever give, so a card tells "this backend does not say" from "nobody has
said for this place".

``PlaceDetailsLoader`` asks for the place on show and keeps what it found;
``PlaceCardView`` draws a card of it, saying whether the place is open now:

```swift
let loader = PlaceDetailsLoader(provider: SamplePlaceDetails())
loader.show(place)

PlaceCardView(PlaceCardContent(state: loader.state, provider: loader.provider, now: .now,
                               timeZone: .current))
```

A tap on a point of interest drawn on the map gives a place too, through
``MapView/onPointOfInterestTap(perform:)``. Where the tile source's feature
ids name the map data's own elements — OpenFreeMap's do, as its
``TileSourceInfo/featureIdentifiers`` says — the place carries the
OpenStreetMap element, which ``NominatimPlaceDetails`` and
``OverpassPlaceDetails`` look up by.

## Routes

A ``RouteProvider`` answers a ``Route``: its path, length, time and
turn-by-turn ``RouteStep``s, each with the ``Maneuver`` it begins with. A
route goes through any number of stops; a router that takes them in one
request does, and the rest ask for each leg and join them.

```swift
let routes: any RouteProvider = SampleRoutes()
let route = try await routes.route(from: start, to: cafe, mode: .driving)
```

``RoutePlan`` holds the stops a user is marking, in order, and edits them
as a panel does — append, insert, move, reverse — keeping each stop's id
as it moves:

```swift
var plan = RoutePlan(mode: .driving)
plan.append("Home", at: home)
plan.append("The Copper Kettle", at: cafe)
let planned = try await routes.route(through: plan.coordinates, mode: plan.mode)
```

Draw a route with ``MapPolyline``, and its ends with ``RouteEnds``: the
dashed walk from the road to the place itself when the route stops short
of it, as Apple and Google Maps draw it.

```swift
MapView(camera: $camera, store: store) {
    MapPolyline(route)
    RouteEnds(route: route, origin: start, destination: cafe)
    Marker("The Copper Kettle", coordinate: cafe)
}
```

``GPXDocument`` reads and writes a plan as a GPX route, and a recorded
drive as a GPX track, so a route made in another app opens here.
