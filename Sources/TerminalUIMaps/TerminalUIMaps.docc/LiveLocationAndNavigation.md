# Live location and navigation

Show where the traveller is, follow them along a route turn by turn, and
let the map turn and zoom as a navigation app's does.

## Overview

A position comes from a ``LocationProvider`` as a stream of ``LocationFix``
values. A ``NavigationController`` matches each fix to a route, says which
step the traveller is on, reroutes when they leave it and records the
drive; a ``NavigationCamera`` moves the map after them; a
``NavigationBanner`` says what to do next.

## Where the position comes from

Every provider is a stream that runs until the provider has nothing more to
say, or fails, and stops when the task iterating it is cancelled:

| Provider | Position |
|----------|----------|
| ``GPXReplayProvider`` | A recorded track, replayed at any speed: the simulator every navigation test runs on |
| ``ManualLocationProvider`` | A point the app sets: "I am here" |
| ``GPSDLocationProvider`` | A gpsd daemon over TCP |
| ``NMEALocationProvider`` | NMEA sentences over TCP or UDP, as a phone app or a receiver sends them |
| `CoreLocationProvider` | Location Services, on macOS, for a binary with a location usage description in its Info.plist |

A socket is read on a thread of its own, never on the cooperative pool,
and a live provider keeps only the latest fix for a reader that is busy, so
fixes do not queue up behind a reroute to be replayed later.
``LocationSpec`` reads a provider from a word — `gpx:PATH`, `gpsd`,
`nmea:udp:10110` — as a command line gives one.

```swift
let document = try GPXDocument(contentsOf: URL(fileURLWithPath: "drive.gpx"))
let provider = GPXReplayProvider(track: document.tracks[0].segments[0], speed: 4)
for try await fix in provider.fixes() {
    await navigation.receive(fix)
}
```

## Navigating a route

``NavigationController`` is main-actor state the views observe. Start it
with a route, the stops it goes through and the router to ask for a new one
when the traveller leaves it; feed it every fix:

```swift
let navigation = NavigationController()
navigation.start(route: route, plan: plan, router: routes,
                 configuration: TravelProfile(mode: plan.mode).navigationConfiguration)
```

Its ``NavigationController/session`` is a ``NavigationSession``: the step
the traveller is on and the one after it, the distance to the next
manoeuvre, the distance and time left and the arrival time.
``NavigationBanner`` draws them at the top of a map, with the arrow of the
turn, the street and, on arrival, which side the place is on:

```swift
NavigationBanner(session: session, status: navigation.status, destination: "The Copper Kettle")
```

A reroute leaves the way the traveller is going, not back along it, when
the router can take a heading (OSRM can; MapKit cannot). One answered after
navigation stopped is dropped.

## The camera

``NavigationCamera`` is the camera of a map that follows the traveller. It
carries them along the route between fixes, turns the map to their heading
once they move faster than a walk, keeps them low on the screen so more of
the road ahead shows, and stands back by their speed. Before a junction
whose roads would not read at that zoom — a five-way corner, roads parting
at a shallow angle — it closes in, settled before the turn and held still
through it. Every change is eased, the bearing held to a turn rate, so a
corner is a sweep the eye can follow.

Hand it each fix with ``NavigationCamera/receive(_:at:)``, and let a
`TimelineView` drive it a frame at a time.
``NavigationCamera/advance(to:camera:navigation:store:)`` moves the map's
camera and says whether anything is still moving, so the timeline pauses
and the app goes idle once the traveller and the camera are at rest. The
navigation and the store are main-actor state, so the model that holds
them does the work on the main actor, where the runtime calls every body:

```swift
@MainActor @Observable
final class Drive {
    var camera = MapCamera(center: SampleTown.origin, zoom: 16)
    var navigationCamera = NavigationCamera(profile: .car)
    var isAnimating = false
    let navigation = NavigationController()
    let store = MapTileStore(source: SampleTileSource())

    func receive(_ fix: LocationFix) async {
        navigationCamera.receive(fix)
        await navigation.receive(fix)
        isAnimating = true
    }

    func advance(to date: Date) {
        isAnimating = navigationCamera.advance(to: date, camera: &camera, navigation: navigation, store: store)
    }

    var content: MapContentGroup {
        MapContentGroup(navigationCamera.routeLines(for: navigation).mapElements
            + (navigationCamera.traveller?.mapElements ?? []))
    }
}

struct DriveMap: TerminalView {
    let drive: Drive

    var body: some TerminalView {
        let drive = drive
        let content = MainActor.assumeIsolated { drive.content }
        let camera = Binding(get: { MainActor.assumeIsolated { drive.camera } },
                             set: { camera in MainActor.assumeIsolated { drive.camera = camera } })
        let paused = MainActor.assumeIsolated { !drive.isAnimating }
        ZStack {
            MapView(camera: camera, store: drive.store) {
                content
            }
            TimelineView(.animation(paused: paused)) { context in
                EmptyView().onChange(of: context.date) { _, date in
                    MainActor.assumeIsolated { drive.advance(to: date) }
                }
            }
        }
    }
}
```

A ``TravelProfile`` — car, bicycle or on foot — sets the speeds it stands
back at, when the map turns heading up, how far ahead it looks and what a
junction needs to read. A pan or a zoom by the user stops the following
until ``NavigationCamera/recentre()``; the map can face heading up, north
up or a bearing the user turned it to, and ``MapCompass`` shows which way
north is while it is turned.

For a replay, set ``NavigationCamera/timeScale`` to its speed: the camera
runs in road time, so a replay holds its junction zoom for the same seconds
of road as the drive did, while the map still turns no faster than the eye
can follow.
