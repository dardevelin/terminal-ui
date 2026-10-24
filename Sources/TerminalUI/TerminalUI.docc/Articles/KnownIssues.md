# Known Issues

Limitations of TerminalUI 2.1 that an app may run into, and what to do
about each.

## Keys the terminal sends as one

A terminal's legacy keyboard encoding sends some pairs of keys as the same
byte, so no program can tell them apart: Ctrl+I and Tab, Ctrl+M and Return,
Ctrl+[ and Escape, Ctrl+H and Backspace. The input parser reads the kitty
keyboard protocol, which distinguishes them, but the framework does not yet
ask a terminal to switch it on. Bind actions to keys outside these pairs.

Terminal emulators, multiplexers and window managers also keep some
combinations for themselves — Ctrl+Tab, Cmd+anything on macOS, tmux's prefix
— and those never reach the app.

## The mouse the terminal keeps

Most terminals select text on Shift+click and Shift+drag, and some on
Alt+click, so a ``TapGesture`` waiting for those modifiers may never see
them; Ctrl+click reaches the app wherever the terminal reports the mouse.
A tilting wheel's sideways ticks arrive as Shift plus the wheel, which
scrolls sideways, until ``MouseEventKind`` can grow cases of its own in 3.0.

## Colour depth

Output is truecolor. A theme's named ANSI colours follow the user's terminal
palette on any terminal, but an `.rgb` colour reaches a terminal that has
only 256 or 16 colours as whatever that terminal makes of a 24-bit sequence.
Downconversion is planned; until then, a theme that must look right
everywhere states named colours.

## The inspector draws over the frame

The debug inspector's crosshair recolours every cell on its row and column,
and the highlight on the node under it covers the node's whole rect,
borders included. It is a debugging aid in debug builds only; release builds
contain none of it.
