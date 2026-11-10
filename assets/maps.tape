# vhs script for the README's maps GIF: the Maps example on the sample town,
# offline. Regenerate with:  python3 tools/scripts/record_media.py maps
# The film: the town appears, the camera closes in from the town to its
# streets, a search finds a café and its card, the map turns to Satellite
# and to Terrain, and the demo drive takes the car through a corner, the
# map turning with it under the banner and the compass. The packs variable
# points at no directory, so a developer's own downloaded regions never
# show; the replay speed is the drive's, chosen with `g`.

Output assets/maps.gif

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
Type "[["
Sleep 1s
Show

# The town.
Sleep 2s

# From the town to its streets, half a level at a time.
Type@600ms "]]]]]"
Sleep 2s

# A search, and the café's card with its hours.
Type "/"
Sleep 400ms
Type@80ms "copper"
Enter
Sleep 1s
Enter
Sleep 2.5s
Escape
Sleep 300ms

# Satellite, then Terrain, from a little higher.
Type "[["
Sleep 300ms
Type "m"
Sleep 300ms
Up 4
Down 1
Enter
Sleep 2.5s
Type "m"
Sleep 300ms
Up 4
Down 3
Enter
Sleep 2.5s
Type "m"
Sleep 300ms
Up 4
Enter
Sleep 300ms

# The demo drive: chosen from the location panel, routed and navigated.
Type "g"
Sleep 300ms
Down 2
Enter
Sleep 7.5s
