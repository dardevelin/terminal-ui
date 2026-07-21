#!/usr/bin/env python3
"""Live check that an idle `.onDemand` app still answers its control socket.

`.onDemand` renders only in response to events. The runtime pumps the
remote-control socket at the top of the outer loop, then parks in a wait
loop until an event arrives -- so if that loop does not also pump, the
only source of events for an otherwise-idle app is the socket it has
stopped reading. The app is then undrivable, and the harness times out.

This is the regression guard for that deadlock. It spawns the Settings
example (`.onDemand`), lets it go idle, and asserts a command still gets
an answer.

Usage::

    swift build
    python3 tools/scripts/verify_ondemand_socket.py

Exits 0 on success, non-zero with a diagnosis on failure.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui import Client  # noqa: E402
from terminalui.runner import spawn_and_connect  # noqa: E402

# Long enough that the app has certainly finished its startup frames and is
# sitting in the idle wait loop rather than still churning.
IDLE_SECONDS = 1.0


def verify(app: Client) -> list[str]:
    failures: list[str] = []
    app.wait_for_frame(1)

    time.sleep(IDLE_SECONDS)

    # The app is now idle. Every call below reaches it only if the wait
    # loop is still servicing the socket.
    try:
        before = app.frame_number()
    except Exception as exc:  # noqa: BLE001 - reporting, not handling
        return [f"idle app stopped answering the socket: {exc!r}"]

    try:
        app.send_key("down")
        app.wait_for_frame(1, timeout=2.0)
    except Exception as exc:  # noqa: BLE001
        return [f"idle app did not process an injected key: {exc!r}"]

    after = app.frame_number()
    if after <= before:
        failures.append(
            f"key injected while idle produced no new frame ({before} -> {after})"
        )
    return failures


def main() -> int:
    with spawn_and_connect("Settings") as (_proc, app):
        failures = verify(app)

    if failures:
        print("FAIL — idle .onDemand app is not drivable over its control socket")
        for line in failures:
            print(f"  - {line}")
        return 1
    print("PASS — idle .onDemand app still answers, and acts on, socket commands")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
