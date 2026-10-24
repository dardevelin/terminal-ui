# Chapter 6's GIF: The app loading, then a guarded delete with a confirmation dialog.
# Regenerate with:  python3 tools/scripts/record_media.py gifs --only 6

Output Sources/TerminalUI/TerminalUI.docc/Resources/demo-ch6.gif

Set Shell "bash"
Set FontSize 18
Set Width 760
Set Height 460
Set Padding 12
Set Theme "Catppuccin Mocha"
Set Framerate 25

Hide
Type ".build-recordings/tutorial/.build/release/tasks60301"
Enter
Sleep 300ms
Show

# The load takes four seconds; the spinner is the first half of the story.
Sleep 4.2s
Backspace
Sleep 1s
Down
Sleep 600ms
Enter
Sleep 1.2s

Hide
Ctrl+C
Sleep 300ms
