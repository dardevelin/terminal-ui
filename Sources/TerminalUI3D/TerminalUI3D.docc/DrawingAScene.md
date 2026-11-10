# Drawing a scene

Put a lit model on screen, choose how its samples become cells, and set it
moving with a timeline.

## Overview

A scene is a value: models placed by a transform and drawn in materials,
the lights they are lit by, and the camera they are seen from. A
``SceneView`` draws one, filling the space it is offered, as a `Canvas`
does.

![Lettering extruded with Text3D turns into view on a Turntable; a torus turns as a shaded image, then in braille and character shading; a CameraTour flies over a fogged terrain with labelled peaks.](showcase-3d.gif)

What the picture shows is the `Showcase` example's 3D chapter, every frame
of it a `SceneView` in a `TimelineView`: `swift run Showcase 3d`.

## Getting a scene on screen

Build a ``Scene3D``, add a mesh to it, and hand it to a ``SceneView``. Take
the materials' colours from the theme, read once in `body`, so the scene is
painted in the app's own roles:

```swift
import TerminalUI
import TerminalUI3D

struct Ring: TerminalView {
    @TerminalEnvironment(\.theme) var theme

    var body: some TerminalView {
        let theme = theme
        var scene = Scene3D(camera: Camera3D(position: Vector3(0, 1.5, 4)))
        scene.add(.torus(), materials: [Material(theme.accent, specular: 0.8)])
        return SceneView(scene)
            .framing(.fit())
            .frame(height: 20)
    }
}
```

The scene's camera looks at the origin from where it stands, through a
perspective of 60 degrees. `.framing(.fit())` keeps the way it looks but
aims it at the models and brings it in until they fill the view, measured
on cells about twice as tall as they are wide, so a sphere stays round.

A scene that says nothing about light is lit by ``Light3D/standard``: a key
from above and to the left, a weak fill, an ambient term and a rim light
that keeps the outline legible against a dark ground. Set
``Scene3D/lights`` to light it your own way:

```swift
scene.lights = [.ambient(0.15), .directional(toward: Vector3(-0.4, 0.8, 0.6)), .rim(0.4)]
```

A scene can also be built in a closure, which runs as the view draws, with
what it reads from an `@Observable` model tracked as a body's reads are:

```swift
SceneView { scene in
    scene.camera = .orbit(around: .zero, distance: 8, azimuth: model.heading, elevation: 0.5)
    scene.add(terrain, materials: [Material(gradient: [theme.info, theme.success, theme.foreground])])
    scene.add(Label3D("summit", at: model.summit))
}
```

Meshes come from the primitives — ``Mesh/box(width:height:depth:material:)``,
``Mesh/sphere(radius:segments:rings:material:)``,
``Mesh/torus(majorRadius:minorRadius:majorSegments:minorSegments:material:)``,
cylinders and prisms — from a grid of heights with
``Mesh/heightField(columns:rows:spacing:heights:tints:material:)``, from
lettering with ``Text3D``, or from your own positions and triangles. Build
a large one once, in a constant or a model, and place it each frame: a
scene is cheap to make, a mesh's triangles are not.

## Shading styles

Every style starts from the same samples, lit in Oklab from the materials'
colours, so a shadow keeps its hue and darkens as an eye sees it darken.
What differs is how a cell's eight samples are drawn:

- term ``ShadingStyle/image(_:)``: The default. Each half cell is the mean
  of its four samples, averaged in linear light, and a shape's edge is
  blended toward the background. Over a terminal's own background, which
  no program can know, an edge cell keeps its shape in braille dots
  instead. `.image(.dots)` draws dots throughout.
- term ``ShadingStyle/halfBlock``: Two true-colour pixels a cell, the
  image without its dotted edges.
- term ``ShadingStyle/braille(_:)``: Eight dots a cell in the cell's shade:
  dithered by brightness, a plain silhouette, or the edges alone.
- term ``ShadingStyle/characterRamp(_:)``: A character a cell, from a
  ``CharacterRamp``, by how far its shade stands out from the background —
  legible at any colour depth.
- term ``ShadingStyle/hybrid(_:)``: The shade as the cell's background with
  a ramp character over it: the most contrast a cell can carry.

The character and braille styles outline the silhouette and the creases by
default; the image styles leave form to the light.
``ShadingStyle/outlines(_:)`` turns them on or off:

```swift
SceneView(scene, shading: .characterRamp(.detailed).outlines(false))
```

Give the scene a ``Scene3D/background`` to paint behind it; edges and
``Fog3D`` are mixed toward it, or toward the theme's background when it has
none.

## Animating with TimelineView

A scene changes when the view is built again, so to animate one, build it
inside a `TimelineView` from the timeline's date. Only the timeline's body
runs again; the rest of the screen is left as it was.

```swift
TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
    let seconds = context.date.timeIntervalSinceReferenceDate
    SceneView { scene in
        scene.add(.torus(), transform: Turntable().rotation(at: seconds).matrix,
                  materials: [Material(theme.accent, specular: 0.9, shininess: 36)])
    }
    .framing(.fit())
}
```

``Turntable`` turns a model as a thing with weight turns — eased up to
speed and down to rest, a pause, a slight wobble — and lit from a fixed
direction, its highlight slides across the surface as it goes.
``CameraTour`` moves the camera instead, holding at each stop and easing
between them:

```swift
let tour = CameraTour([
    .init(Camera3D(position: Vector3(0, 6, 11)), hold: 1.5, travel: 5),
    .init(Camera3D(position: Vector3(8, 2, 3), target: Vector3(-1, 0.8, -2)), hold: 1, travel: 5),
])
scene.camera = tour.camera(at: seconds)
```

Twenty frames a second is smooth to the eye and a third of the bytes of
sixty over a slow link. Pass `paused: true` to the schedule to hold the
frame, at no cost while it holds. In a release build a 200 × 60 cell frame
of some ten thousand triangles takes a few milliseconds:

```bash
swift run -c release SceneBenchmark
```
