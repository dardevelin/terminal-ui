# vhs script for the README's 3D GIF: the Showcase example's 3D chapter.
# Regenerate with:  python3 tools/scripts/record_media.py showcase --only 3d
#
# vhs keeps its frames here and record_media.py makes assets/3d.gif of them:
# the app plays at an eighth of its speed, so vhs captures every frame
# however many colours it holds, and each frame is shown back for an eighth
# of the time it was on screen. The 143 seconds below are the chapter's
# 17.9, played eight times slower. No key is pressed: the chapter plays on
# its own, from the background it fades in from to the one it fades out to,
# so the GIF loops without a seam.

Output .build-recordings/showcase/3d/

Set FontSize 13
Set Width 800
Set Height 450
Set Padding 10
Set Framerate 15
Set Theme "Catppuccin Mocha"

Hide
Type "TERMINALUI_SHOWCASE=3d TERMINALUI_SHOWCASE_PACE=0.125 .build-recordings/app/release/Showcase"
Enter
Sleep 300ms
Show
Sleep 143s
