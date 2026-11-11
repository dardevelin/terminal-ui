# ``TerminalUI3D``

Lit, shaded 3D in a terminal: meshes, a scene, and a view that draws it in
text.

## Overview

TerminalUI3D draws a ``Scene3D`` — models, the lights on them, a camera and
labels — in a ``SceneView``, a view like any other in a TerminalUI app. A
software rasterizer renders the scene at braille resolution, eight samples
to a cell, lights each sample once, and a ``ShadingStyle`` turns the
samples into cells: an image in averaged true colour, braille dots, or
characters from a ramp.

The library is opt-in, as TerminalUIIO is: an app without 3D never builds
it. It depends on TerminalUI alone, and draws through TerminalUI's `Canvas`,
so a scene composes with the views around it, under or over them in a
`ZStack`.

```swift
.product(name: "TerminalUI3D", package: "terminal-ui")
```

<doc:DrawingAScene> puts a scene on screen, chooses how it is shaded, and
sets it turning.

## Topics

### Essentials

- <doc:DrawingAScene>
- ``SceneView``
- ``Scene3D``
- ``ShadingStyle``

### What a scene holds

- ``Model3D``
- ``Material``
- ``Light3D``
- ``Label3D``
- ``Fog3D``

### Seeing it

- ``Camera3D``
- ``Projection3D``
- ``SceneFraming``

### Shapes

- ``Mesh``
- ``Polygon2D``
- ``Text3D``

### Shading

- ``CharacterRamp``

### Motion

- ``Turntable``
- ``CameraTour``

### Math

- ``Vector2``
- ``Vector3``
- ``Vector4``
- ``Matrix4``
- ``Quaternion``
