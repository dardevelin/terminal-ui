# Chapter 4's GIF: Pushing a task detail, toggling it, popping back.
# Regenerate with:  python3 tools/scripts/record_media.py gifs --only 4

Output Sources/TerminalUI/TerminalUI.docc/Resources/demo-ch4.gif

Set Shell "bash"
Set FontSize 18
Set Width 760
Set Height 460
Set Padding 12
Set Theme "Catppuccin Mocha"
Set Framerate 25

Hide
Type ".build-recordings/tutorial/.build/release/tasks40301"
Enter
Sleep 1.5s
Show

# Down leaves the tab bar for the first row, the second Down reaches the next.
Sleep 500ms
Down@350ms 2
Sleep 300ms
Enter
Sleep 800ms
Space
Sleep 800ms
Escape
Sleep 1.2s

Hide
Ctrl+C
Sleep 300ms
