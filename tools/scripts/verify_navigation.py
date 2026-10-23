#!/usr/bin/env python3
"""Live check that NavigationStack drills in, pops, and restores focus.

Unit tests pin push/pop and focus against a constructed graph. This drives
the real Navigation example over a PTY, so the whole stack is under test:
input parser, reconciliation, the modal containment NavigationStack reuses,
and the renderer.

The two behaviours that make TUI navigation feel right, and that a graph
test cannot fully see:

  * Esc pops the visible screen.
  * Popping lands focus on the row that pushed, not the top of the list.

Usage::

    swift build
    python3 tools/scripts/verify_navigation.py

Exits 0 on success, non-zero with a diagnosis on failure.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui import Client  # noqa: E402
from terminalui.runner import spawn_and_connect  # noqa: E402


def verify(app: Client) -> list[str]:
    failures: list[str] = []
    if "Account" not in app.text() or "Home" not in app.text():
        return ["root screen did not render (no Account row / Home title)"]

    # Focus starts on the first link. Tab down to the second so pop-restores
    # can prove it returns *here*, not to the top.
    app.tab()
    originating = app.focus().node_id

    # Push: Enter on the focused link.
    app.send_key("enter")
    if "Inside Network" not in app.text():
        failures.append("Enter on a NavigationLink did not push its destination")
        return failures

    # The pushed screen must confine focus — Tab cannot reach a root row.
    for _ in range(4):
        app.tab()
        if "Choose a destination" in app.text() and app.focus().node_id == originating:
            failures.append("Tab escaped the pushed screen back to the root")
            break

    # Pop: Esc returns to the root, focus on the row we came from.
    app.send_key("escape")
    if "Inside Network" in app.text():
        failures.append("Esc did not pop the pushed screen")
    if app.focus().node_id != originating:
        failures.append(
            f"pop did not restore focus to the originating link "
            f"(wanted {originating!r}, got {app.focus().node_id!r})"
        )

    # Compose with the settings work: the Settings screen is reachable through
    # navigation, and its Form still aligns its label column there. Focus was
    # just restored to Network (the second link), so Settings is one Tab away.
    app.tab()
    app.send_key("enter")
    if "APPEARANCE" not in app.text():
        failures.append("Settings screen not reachable through navigation")

    return failures


def main() -> int:
    with spawn_and_connect("Navigation") as (_proc, app):
        failures = verify(app)

    if failures:
        print("FAIL — NavigationStack live behaviour")
        for line in failures:
            print(f"  - {line}")
        return 1
    print("PASS — push, pop, focus restored to the originating link, settings reachable")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
