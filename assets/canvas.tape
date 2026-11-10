# vhs script for the README's Canvas GIF: the Showcase example's Canvas and
# TimelineView chapter.
# Regenerate with:  python3 tools/scripts/record_media.py showcase --only canvas
#
# vhs keeps its frames here and record_media.py makes assets/canvas.gif of
# them: the app plays at an eighth of its speed, so vhs captures every frame,
# and each frame is shown back for an eighth of the time it was on screen.
# The 104 seconds below are the chapter's 13, played eight times slower. No
# key is pressed: the chapter plays on its own, from the background it fades
# in from to the one it fades out to, so the GIF loops without a seam.

Output .build-recordings/showcase/canvas/

Set FontSize 13
Set Width 800
Set Height 450
Set Padding 10
Set Framerate 15
Set Theme "Catppuccin Mocha"

Hide
Type "TERMINALUI_SHOWCASE=canvas TERMINALUI_SHOWCASE_PACE=0.125 .build-recordings/app/release/Showcase"
Enter
Sleep 300ms
Show
Sleep 104s
