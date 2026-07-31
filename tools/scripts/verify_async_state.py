#!/usr/bin/env python3
"""Live check that state mutated outside an input event reaches the screen.

The framework's whole promise is SwiftUI's: change `@Observable` state, watch
the UI follow. Nothing in this harness sends a key, and the app under test
declares no timer, so the only thing that can produce a frame is the run loop
noticing that the graph went dirty on its own.

Both render arms are covered: `.capped` — the default every app gets — and
`.onDemand`, whose idle loop has to be woken rather than polled awake by an
event that never comes.

Storybook cannot stand in for this: it declares a timer, whose events set
`needsRender` every tick and mask the defect entirely.

Usage::

    swift build
    python3 tools/scripts/verify_async_state.py

Exits 0 on success, non-zero with a diagnosis on failure.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui import Client  # noqa: E402
from terminalui.runner import spawn_and_connect  # noqa: E402

# Long enough for several 60ms ticks, short enough that a stuck screen is not
# mistaken for a slow one.
OBSERVE_SECONDS = 1.0


def count(app: Client) -> int | None:
    for line in app.text().splitlines():
        if "count=" in line:
            try:
                return int(line.split("count=")[1].split()[0])
            except (IndexError, ValueError):
                return None
    return None


def check(mode: str) -> list[str]:
    env = {"TUI_RENDER_MODE": mode} if mode else None
    label = mode or "capped"
    with spawn_and_connect("AsyncState", cols=60, rows=14, env=env) as (_proc, app):
        app.wait_for_frame(1)
        first = count(app)
        if first is None:
            return [f"[{label}] the app did not render its counter at all"]

        time.sleep(OBSERVE_SECONDS)
        second = count(app)
        if second is None:
            return [f"[{label}] the counter vanished after {OBSERVE_SECONDS}s"]

        if second == first:
            return [
                f"[{label}] the screen never followed the state: count stayed at "
                f"{first} for {OBSERVE_SECONDS}s with no input. The task is "
                f"running and marking the graph dirty; the loop is dropping the frame."
            ]
        return []


def main() -> int:
    failures: list[str] = []
    for mode in ("", "ondemand"):
        failures.extend(check(mode))

    if failures:
        print("FAIL — state mutated outside an input event")
        for line in failures:
            print(f"  - {line}")
        return 1
    print("PASS — .capped and .onDemand both follow state with no input")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
