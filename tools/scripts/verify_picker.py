#!/usr/bin/env python3
"""Live check that Picker's three styles behave in the real runtime.

Unit tests pin selection and cursor logic against a constructed graph.
This drives the actual Settings example over a PTY, so the whole stack is
under test -- input parser, reconciliation, focus engine, renderer.

The dropdown is the reason this script exists. Opening one *adds nodes*
to the tree, so it is the case where a stale focus index or a missed
re-render would show up as keys reaching the wrong handler -- a failure
mode that graph-level tests are structurally unable to see.

Usage::

    swift build
    python3 tools/scripts/verify_picker.py

Exits 0 on success, non-zero with a diagnosis on failure.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui import Client  # noqa: E402
from terminalui.runner import spawn_and_connect  # noqa: E402


def summary_line(app: Client, key: str) -> str:
    """The echoed model line, which proves a binding actually committed
    rather than merely that a control repainted."""
    for line in app.text().splitlines():
        if key in line:
            return line.strip()
    return ""


def verify(app: Client) -> list[str]:
    failures: list[str] = []
    screen = app.text()
    for expected in ("Settings", "Theme", "Density", "Telemetry", "Editor"):
        if expected not in screen:
            return [f"settings screen did not render (missing {expected!r})"]

    # --- segmented: arrows commit immediately, no confirm step ---
    # The runtime auto-focuses the first focusable, which is the segmented
    # picker — so do NOT Tab here, or the first control under test is skipped.
    before = summary_line(app, "theme=")
    if "theme=dark" not in before:
        failures.append(f"unexpected initial theme line: {before!r}")

    app.send_key("right")
    after = summary_line(app, "theme=")
    if after == before:
        failures.append(
            f"segmented Right did not commit on move (still {after!r})"
        )
    if "theme=auto" not in after:
        failures.append(f"segmented Right landed on the wrong option: {after!r}")

    app.send_key("left")
    if "theme=dark" not in summary_line(app, "theme="):
        failures.append("segmented Left did not move back to the previous option")

    # --- dropdown: opens, moves, commits, and closes ---
    app.tab()
    if "Comfortable" in app.text():
        failures.append("dropdown was already expanded before being opened")

    app.send_key("enter")
    if "Comfortable" not in app.text():
        failures.append("Enter did not open the dropdown list")
        return failures

    # The second key is the one that matters: it must reach the *open*
    # list, which only exists in a tree built after the first keypress.
    app.send_key("down")
    app.send_key("enter")
    committed = summary_line(app, "density=")
    if "density=comfortable" not in committed:
        failures.append(
            f"dropdown Enter did not commit the highlighted option: {committed!r}"
        )
    if "Comfortable" in app.text() and "density=" not in app.text():
        failures.append("dropdown did not close after committing")

    # Esc must abandon rather than commit.
    app.send_key("enter")
    if "Compact" not in app.text():
        failures.append("dropdown did not reopen")
    else:
        app.send_key("up")
        app.send_key("escape")
        if "density=comfortable" not in summary_line(app, "density="):
            failures.append("Esc committed the highlighted option instead of abandoning")

    return failures


def main() -> int:
    with spawn_and_connect("Settings") as (_proc, app):
        failures = verify(app)

    if failures:
        print("FAIL — Picker live behaviour")
        for line in failures:
            print(f"  - {line}")
        return 1
    print("PASS — segmented commits on move; dropdown opens, commits, and Esc abandons")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
