#!/usr/bin/env python3
"""Live check that a Form taller than its window scrolls.

Unit tests pin the composition against a constructed graph. This drives
Storybook's Form page over a PTY, where the form sits inside a window
shorter than its content -- the shape that made the bug worth fixing,
because the rows below the fold stayed focusable while invisible.

Three things have to hold at once, and only the live runtime exercises all
three together: Tab reaches a row below the fold, the viewport follows it,
and the label column -- measured across every row, on screen or not --
does not shift as rows come and go.

Usage::

    swift build
    python3 tools/scripts/verify_form.py

Exits 0 on success, non-zero with a diagnosis on failure.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui import Client  # noqa: E402
from terminalui.runner import spawn_and_connect  # noqa: E402

# The form's first and last labelled rows. One is on screen at rest, the
# other only after the viewport has moved. `FIRST_SECTION` is the header
# above the first row: scroll-to-focused brings the focused *row* back, not
# whatever sits above it, so the header is checked only at rest.
FIRST_SECTION = "APPEARANCE"
FIRST_ROW = "Theme"
LAST_ROW = "History depth"

# A checkbox marks a row whose control is a Toggle; the column it sits in
# is the shared label column.
CHECKBOX = "["

# Tab visits eight controls before it leaves the preview for the sidebar.
# Bounded so a form that never scrolls fails rather than spins.
MAX_TABS = 12


def window_bounds(app: Client) -> tuple[int, list[str]]:
    """The preview window's first screen row and its rows. Located by the
    pane's own box: this page's longer summary pushes the preview below
    `PREVIEW_RECT`."""
    return app.boxed_rows("Preview")


def window_rows(app: Client) -> list[str]:
    return window_bounds(app)[1]


def window_text(app: Client) -> str:
    return "\n".join(window_rows(app))


def control_columns(app: Client) -> set[int]:
    return {row.index(CHECKBOX) for row in window_rows(app) if CHECKBOX in row}


def scroll_to_last_row(app: Client) -> bool:
    for _ in range(MAX_TABS):
        app.tab()
        if LAST_ROW in window_text(app):
            return True
    return False


def verify(app: Client) -> list[str]:
    failures: list[str] = []
    app.goto_page("Form")
    top = window_text(app)
    if FIRST_SECTION not in top or FIRST_ROW not in top:
        return ["Form page did not render its first section"]
    if LAST_ROW in top:
        return ["the form fits its window, so this page cannot prove it scrolls"]

    columns_before = control_columns(app)
    window_height = len(window_rows(app))

    if not scroll_to_last_row(app):
        return [f"tabbing through the form never brought {LAST_ROW!r} into view"]

    if FIRST_ROW in window_text(app):
        failures.append("the viewport never moved -- the first section is still drawn")

    # A control the user cannot see is the defect this fixes; the focused
    # row has to be inside the window it scrolled into. The window's own
    # rows are found above, so its bounds come from the frame rather than
    # from a coordinate baked into this script.
    rect = app.focus().rect
    pane_top, _ = window_bounds(app)
    if len(rect) == 4 and pane_top:
        focus_y = rect[1]
        if not pane_top <= focus_y < pane_top + window_height:
            failures.append(
                f"the focused control sits outside the preview window "
                f"(y={focus_y}, window rows {pane_top}..{pane_top + window_height - 1})"
            )

    # One column, before and after: the union catches both a form whose
    # visible rows disagree with each other and one whose column shifted as
    # the rows scrolled past.
    columns = columns_before | control_columns(app)
    if len(columns) > 1:
        failures.append(f"controls do not share one label column across the scroll: {sorted(columns)}")

    # Scrolling back has to work from the keyboard alone, or a user who
    # tabbed past the fold is stranded there.
    for _ in range(MAX_TABS):
        app.tab(reverse=True)
        if FIRST_ROW in window_text(app):
            break
    else:
        failures.append("Shift-Tab back through the form never returned to the first section")

    return failures


def main() -> int:
    with spawn_and_connect("Storybook", cols=120, rows=50) as (_proc, app):
        failures = verify(app)

    if failures:
        print("FAIL — Form scrolling")
        for line in failures:
            print(f"  - {line}")
        return 1
    print("PASS — Tab scrolls the form, focus stays in the window, the label column holds")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
