# vhs script for the README's 3D map GIF: the Maps example's 3D view on
# the sample town, offline. Regenerate with:  python3 tools/scripts/record_media.py maps
# The film: a search flies to the café, the map closes in, `3` tilts it
# into the 3D view with its buildings standing on the ground, the camera
# moves up toward Beacon Hill, `>` turns it about the middle, and the demo
# drive takes the car through the town in 3D, the map turning with it. The packs variable points at no directory, so a
# developer's own downloaded regions never show.
#
# vhs keeps its frames here and record_media.py makes assets/maps-3d.gif of
# them, in one palette and undithered, as it makes the Showcase's: vhs's
# own encoder dithers the shaded buildings, and its GIF came to 4 MB.

Output .build-recordings/maps-3d/

Set FontSize 13
Set Width 880
Set Height 520
Set Padding 10
Set Framerate 10
Set Theme "Catppuccin Mocha"

Env TERMINALUI_MAPS_PACKS "/nonexistent/terminalui-maps-recording"
Env TERMINALUI_MAPS_REPLAY_SPEED "30"

Hide
Type ".build-recordings/app/release/Maps"
Enter
Sleep 2s
Type "/"
Sleep 400ms
Type "copper"
Enter
Sleep 1s
Enter
Sleep 1s
Escape
Sleep 300ms
Type "]]"
Sleep 1s
Show

# The streets by the café, straight down.
Sleep 1.5s

# The 3D view: tilted, the buildings standing on the ground.
Type "3"
Sleep 2.5s

# Out to the town and north-west toward Beacon Hill: its flank lit from
# the north-west, the roads bending as they climb.
Type@250ms "[[[["
Sleep 300ms
Type@300ms "hhhhhkkk"
Sleep 2.5s

# Turned about the middle, a step at a time.
Type@500ms ">>>>"
Sleep 1.5s

# The demo drive, in 3D: chosen from the location panel, routed and navigated.
Type "g"
Sleep 300ms
Down 2
Enter
Sleep 6s
