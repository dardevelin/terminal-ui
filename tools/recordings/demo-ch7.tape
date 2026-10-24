# Chapter 7's GIF: The refactored app loading through its service, then toggling tasks.
# Regenerate with:  python3 tools/scripts/record_media.py gifs --only 7
# Chapter 7's app saves its tasks and loads them next launch; the tape
# starts from none, and removes what it saved.

Output Sources/TerminalUI/TerminalUI.docc/Resources/demo-ch7.gif

Set Shell "bash"
Set FontSize 18
Set Width 760
Set Height 460
Set Padding 12
Set Theme "Catppuccin Mocha"
Set Framerate 25

Hide
Type `rm -f "$HOME/Library/Application Support/tasks-tutorial.json"`
Enter
Type ".build-recordings/tutorial/.build/release/tasks70301"
Enter
Sleep 300ms
Show

Sleep 4.2s
Down
Sleep 400ms
Enter
Sleep 600ms
Down
Sleep 400ms
Enter
Sleep 1.2s

Hide
Ctrl+C
Sleep 300ms
Type `rm -f "$HOME/Library/Application Support/tasks-tutorial.json"`
Enter
