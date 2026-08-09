# vhs script for the README debug-tools GIF.
# Regenerate with:  swift build && vhs assets/debug.tape
#
# vhs cannot send function keys, so the tape backgrounds a timed driver that
# injects them through the app's own remote-control socket — the same
# mechanism the README's agent-driven section describes. The driver is fully
# silenced so its output can never paint over the recording. F1 stats
# overlay, F2 debug panel, F3 inspector; the recording ends on the inspector,
# and the driver's trailing quit fires after capture stops.

Output assets/debug.gif

Set FontSize 15
Set Width 1020
Set Height 700
Set Padding 12
Set Theme "Catppuccin Mocha"

Hide
Type `(sleep 3; B=.build/debug/swtui; until $B ctl ping; do sleep 0.3; done; $B ctl send-key f1; sleep 3; $B ctl send-key f2; sleep 3.5; $B ctl send-key f2; $B ctl send-key f3; sleep 3.5; $B ctl quit) >/dev/null 2>&1 & .build/debug/Demo`
Enter
Sleep 1.5s
Show
Sleep 11.5s
