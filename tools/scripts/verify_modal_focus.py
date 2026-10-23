#!/usr/bin/env python3
"""Live check that a presented modal confines keyboard focus.

Modality means the presentation "prevents interaction with the parent
view" (Apple HIG, Patterns -> Modality). Unit tests pin the traversal
logic against a constructed graph; this drives the real Demo app over a
PTY and asserts the rule holds through the whole runtime -- input parser,
reconciliation, focus engine, renderer.

Demo is the surface under test because `.modal` is a screen-level
presentation: it centres on the terminal buffer. Storybook renders each
page inside a ScrollView content buffer, so a modal declared there
centres on that clipped sub-buffer instead of the screen.

Usage::

    swift build
    python3 tools/scripts/verify_modal_focus.py

Exits 0 on success, non-zero with a diagnosis on failure.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui import Client  # noqa: E402
from terminalui.runner import spawn_and_connect  # noqa: E402

TAB_PRESSES = 8


def verify(app: Client) -> list[str]:
    failures: list[str] = []
    outside = app.focus().node_id

    # 'h' toggles the help modal, which carries a single [ Close ] button.
    app.send_text("h")
    if "Keyboard Shortcuts" not in app.text():
        return ["help modal did not present — nothing to verify"]

    presented = app.focus().node_id
    if presented == outside:
        failures.append(
            f"presenting did not move focus into the dialog (still {outside!r})"
        )

    # Every Tab must land inside the dialog. The modal holds exactly one
    # focusable, so a correct implementation re-selects it every time.
    landed = set()
    for i in range(TAB_PRESSES):
        app.tab()
        node = app.focus().node_id
        landed.add(node)
        if node == outside:
            failures.append(
                f"Tab #{i + 1} escaped the modal back to the background ({node!r})"
            )
            break

    if len(landed) > 1:
        failures.append(
            f"Tab reached {len(landed)} nodes but the dialog has one focusable: {sorted(landed)}"
        )

    # Activating [ Close ] dismisses, and the background becomes live again.
    app.send_key("enter")
    if "Keyboard Shortcuts" in app.text():
        failures.append("Enter on [ Close ] did not dismiss the dialog")
    else:
        app.tab()
        if app.focus().node_id is None:
            failures.append("focus was not restored to the background after dismissal")

    return failures


def main() -> int:
    with spawn_and_connect("Demo") as (_proc, app):
        failures = verify(app)

    if failures:
        print("FAIL — modal focus containment")
        for line in failures:
            print(f"  - {line}")
        return 1
    print("PASS — focus stayed inside the presented modal, and was released on dismiss")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
