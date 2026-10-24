#!/usr/bin/env python3
"""Every tutorial code step builds without a warning, and does what its
captions say.

The steps are code the reader types in and runs, and nothing built them:
an API change could leave the course teaching code that no longer compiles,
or that compiles and no longer behaves as the page describes, and only a
reader would find out. ``check_api_compat.py`` guards released API, not a
step that uses what is new since.

Each step builds as an executable of one package, against this checkout,
with warnings as errors, in ``.build-tutorial/``. Then each runs under a
pseudo-terminal, as the smoke suite runs the examples, driven through the
stages ``tools/terminalui/tutorial.py`` lists for it: the keys and clicks
its captions tell the reader to try, and what the screen must then show,
must not, or whether the app has quit. The runner's exit check holds them to
what it holds every app to: no crash, and the terminal handed back as found.

A step that saves runs with its home directory in a temporary one, so the
check neither reads a reader's saved tasks nor leaves its own.

Run::

    python3 tools/scripts/check_tutorial_steps.py [--jobs N] [--only STEP]

Exit 0 when every step builds and passes, 1 otherwise.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui.client import Client  # noqa: E402
from terminalui.process import usable_cpus  # noqa: E402
from terminalui.runner import AppExitedBadly, spawn_and_connect  # noqa: E402
from terminalui.tutorial import (  # noqa: E402
    REPO_ROOT, STEPS, Action, Click, Loaded, Press, Stage, Step, Type, binary_name, build,
)

PACKAGE = REPO_ROOT / ".build-tutorial"
BUILD_DIR = PACKAGE / ".build" / "debug"

# The size the tutorial's previews are recorded at, near enough: the steps
# lay out for a window of about this many cells.
COLUMNS, ROWS = 94, 26
# The simulated load takes four seconds; a loaded machine may take longer to
# draw what follows it.
LOAD_TIMEOUT_SECONDS = 15.0
QUIT_TIMEOUT_SECONDS = 5.0


class StageFailed(AssertionError):
    pass


def perform(client: Client, action: Action) -> None:
    if isinstance(action, Press):
        client.send_key(action.key, *action.modifiers)
    elif isinstance(action, Type):
        client.send_text(action.text)
    elif isinstance(action, Click):
        x, y = locate(client.text(), action.text)
        client.mouse_click(x, y)
    elif isinstance(action, Loaded):
        if not client.wait_until(lambda c: c.contains(action.text), timeout=LOAD_TIMEOUT_SECONDS):
            raise StageFailed(f"the load never showed {action.text!r}")


def locate(screen: str, text: str) -> tuple[int, int]:
    """The column and row of the first place ``text`` is drawn."""
    for y, row in enumerate(screen.splitlines()):
        x = row.find(text)
        if x >= 0:
            return x, y
    raise StageFailed(f"nothing to click: {text!r} is not on the screen")


def verify(client: Client, stage: Stage) -> None:
    if stage.quits:
        if client.wait_for_exit(QUIT_TIMEOUT_SECONDS) is None:
            raise StageFailed("the app was still running")
        return
    screen = client.text()
    missing = [text for text in stage.shows if text not in screen]
    present = [text for text in stage.hides if text in screen]
    if missing or present:
        detail = "; ".join(
            ([f"does not show {missing}"] if missing else [])
            + ([f"still shows {present}"] if present else []))
        raise StageFailed(f"{detail}\n{indent(screen)}")


def indent(screen: str) -> str:
    return "\n".join("    " + row.rstrip() for row in screen.splitlines() if row.strip())


def launches(step: Step) -> list[list[tuple[int, Stage]]]:
    """The stages each run of the app goes through: a stage that relaunches
    starts the next run."""
    runs: list[list[tuple[int, Stage]]] = [[]]
    for index, stage in enumerate(step.stages):
        if stage.relaunch:
            runs.append([])
        runs[-1].append((index, stage))
    return runs


def check(step: Step) -> Optional[str]:
    """Why ``step`` fails, or None when it passes."""
    with tempfile.TemporaryDirectory(prefix="terminalui-tutorial-home-") as home:
        # Foundation finds the home directory through CFFIXED_USER_HOME on
        # Darwin, where it does not read HOME, and the data directory
        # through XDG_DATA_HOME on Linux.
        env = {"HOME": home, "CFFIXED_USER_HOME": home,
               "XDG_DATA_HOME": f"{home}/.local/share", "XDG_CONFIG_HOME": f"{home}/.config"}
        index = 0
        try:
            for run in launches(step):
                with spawn_and_connect(binary_name(step.name), build_dir=str(BUILD_DIR), env=env,
                                       cwd=home, cols=COLUMNS, rows=ROWS) as (_, client):
                    for index, stage in run:
                        for action in stage.keys:
                            perform(client, action)
                        verify(client, stage)
        except StageFailed as failure:
            return f"stage {index + 1}: {failure}"
        except AppExitedBadly as objection:
            return f"stage {index + 1}: the app ended badly: {objection}"
        except Exception as exc:  # noqa: BLE001 - a step's failure, reported
            return f"stage {index + 1}: {type(exc).__name__}: {exc}"
    return None


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--jobs", type=int, default=max(1, usable_cpus() // 2),
                        help="steps run at once (default: half the CPUs)")
    parser.add_argument("--only", help="one step, such as tasks2-03-01")
    args = parser.parse_args(argv)

    try:
        build(PACKAGE, "debug", ["-Xswiftc", "-warnings-as-errors"])
    except subprocess.CalledProcessError:
        print("a tutorial step does not build, or warns")
        return 1

    steps = [step for step in STEPS if args.only in (None, step.name)]
    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        failures = list(pool.map(check, steps))
    for step, failure in zip(steps, failures):
        print(f"[{'FAIL' if failure else 'OK'}] {step.name}" + (f" — {failure}" if failure else ""))
    failed = sum(1 for failure in failures if failure)
    print("---")
    print(f"{len(steps) - failed}/{len(steps)} steps pass")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
