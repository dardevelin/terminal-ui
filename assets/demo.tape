# vhs script for the README demo GIF: a walk through the Storybook sidebar.
# Regenerate with:  python3 tools/scripts/record_media.py readme
# Pauses land on the showpiece pages (SplitView, Form, Table, DiffView, the
# markdown and code views, the charts); the brisk steps between them keep the
# tour honest — every page shown is a real Storybook page, in sidebar order.
# The counts follow PageID's order in Examples/Storybook/StorybookPage.swift,
# and each run of presses names the page it lands on in a `# page:` line;
# tools/tests/test_demo_tape.py replays the presses and fails on a page added
# before a landmark until the counts after it are recounted.

Output assets/demo.gif

Set FontSize 15
Set Width 1020
Set Height 700
Set Padding 12
Set Theme "Catppuccin Mocha"

Hide
Type ".build-recordings/app/release/Storybook"
Enter
Sleep 2s
Show

# Layout — dwell on VStack, walk to SplitView
Sleep 2.5s
Down@250ms 8
# page: splitView
Sleep 2s

# Primitives — brisk, land on Button
Down@200ms 9
# page: button
Sleep 1.2s

# Input — Picker, then Form
Down@250ms 5
# page: picker
Sleep 1.2s
Down@250ms 4
# page: form
Sleep 2s

# Display — Table, TreeView, DiffView, then the markdown and code views
Down@250ms 4
# page: table
Sleep 2s
Down@250ms 2
# page: treeView
Sleep 1.5s
Down
# page: diffView
Sleep 2s
Down@250ms 5
# page: markdown
Sleep 2s
Down
# page: codeView
Sleep 2s

# Charts — BarChart through MorseTicker (the ticker animates)
Down
# page: barChart
Sleep 2s
Down
# page: sparkline
Sleep 1.2s
Down
# page: heatMap
Sleep 1.5s
Down
# page: brailleCanvas
Sleep 1.5s
Down
# page: dotMatrixText
Sleep 2s
Down
# page: morseTicker
Sleep 3s

Hide
Escape
Sleep 500ms
