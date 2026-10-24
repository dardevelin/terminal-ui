# Chapter 3's GIF: Switching tabs, flipping the settings toggle, watching the list filter.
# Regenerate with:  python3 tools/scripts/record_media.py gifs --only 3

Output Sources/TerminalUI/TerminalUI.docc/Resources/demo-ch3.gif

Set Shell "bash"
Set FontSize 18
Set Width 760
Set Height 460
Set Padding 12
Set Theme "Catppuccin Mocha"
Set Framerate 25

Hide
Type ".build-recordings/tutorial/.build/release/tasks30301"
Enter
Sleep 1.5s
Show

# Toggle a task done first, so the filter has something to hide. The tab
# bar holds focus at launch: digits switch tabs, Tab reaches the toggle.
Sleep 500ms
Enter
Sleep 600ms
Type "2"
Sleep 700ms
Tab
Sleep 400ms
Space
Sleep 600ms
Shift+Tab
Sleep 300ms
Type "1"
Sleep 1.5s

Hide
Ctrl+C
Sleep 300ms
