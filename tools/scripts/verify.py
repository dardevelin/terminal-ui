#!/usr/bin/env python3
"""Stop-hook verification runner.

Replaces the old bash verify.sh with a Python driver so we exercise the
same bridge our smoke tests use. Steps:

1. Skip unless this turn touched a ``.swift`` or ``.py`` file.
2. Tear down any leftover debug apps + stale sockets.
3. ``swift build`` — compile check (release build is deferred to CI).
4. ``swift test`` — unit + component suites.
5. ``storybook_smoke.py`` — live harness cases against Storybook + Demo.

Each failure prints the relevant output and exits with code 2 so the
stop-hook surfaces it to the conversation.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

# Derived from this file's location (tools/scripts/verify.py) rather than
# hardcoded: an absolute path silently stops matching when the package moves
# or the checkout lives elsewhere, and the hook would then skip every turn.
REPO_ROOT = Path(__file__).resolve().parents[2]
# Automation builds apart from `.build`. SwiftPM locks a build directory for
# the length of a build or test run, and this hook runs on every turn: sharing
# `.build` made a human's `swift run Coder` sit on "Another instance of SwiftPM
# is already running" until it finished.
SCRATCH_PATH = ".build-automation"
BUILD_DIR = REPO_ROOT / SCRATCH_PATH / "debug"
# The suite runs its cases one after another and took 304s at 100 cases; 240s
# cut it off mid-run and reported the cutoff as a smoke regression.
SMOKE_TIMEOUT_SECONDS = 600
BUILD_TIMEOUT_SECONDS = 180
TEST_TIMEOUT_SECONDS = 180


def dirty_relevant_sources() -> bool:
    """Return True if this turn left uncommitted .swift / .py files.
    Skips verification for memory / docs / settings edits."""
    try:
        result = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        return True  # no git → always verify
    for line in result.stdout.splitlines():
        if len(line) < 4:
            continue
        path = line[3:]
        if path.endswith((".swift", ".py")):
            return True
    return False


def reap_dead_apps() -> None:
    """Remove what debug apps from this checkout left when they died — a
    crash, or SIGKILL, leaves their output and socket behind. Calls
    `swtui ctl reap`, which touches only apps whose PID is dead: a live
    `swift run Coder` is never affected.

    Replaces the legacy `kill_strays()` whose `swtui ctl kill all`
    dragnet would `quit` the user's live `swift run Storybook` when
    running from this Stop hook mid-keystroke.
    """
    swtui = BUILD_DIR / "swtui"
    if swtui.exists():
        subprocess.run(
            [str(swtui), "ctl", "reap"],
            cwd=str(REPO_ROOT), check=False,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )


def step(name: str, cmd: list[str], timeout: int) -> tuple[int, str]:
    """Run a subprocess, capturing combined stdout+stderr. Returns (rc, out)."""
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return proc.returncode, (proc.stdout or "") + (proc.stderr or "")
    except subprocess.TimeoutExpired as err:
        # `TimeoutExpired.stdout/stderr` can come back as bytes when the
        # child hit the deadline mid-stream; decode defensively so the
        # error message stays a str.
        def _decode(value: object) -> str:
            if value is None:
                return ""
            if isinstance(value, bytes):
                return value.decode("utf-8", errors="replace")
            return str(value)
        out = _decode(err.stdout) + _decode(err.stderr)
        return 124, f"{name} timed out after {timeout}s\n{out}"


def fail(msg: str, detail: str = "") -> int:
    print(f"✗ {msg}")
    if detail:
        lines = detail.splitlines()
        if len(lines) > 25:
            lines = lines[-25:]
        print("\n".join(lines))
    return 2


def main() -> int:
    if not dirty_relevant_sources():
        return 0

    # Before, for what earlier runs left; after, for what this one leaves —
    # the smoke suite kills one app with SIGKILL on purpose, and nothing in
    # it can remove that app's output.
    reap_dead_apps()
    try:
        return run_gate()
    finally:
        reap_dead_apps()


def run_gate() -> int:
    rc, out = step("escape hatches",
                   [sys.executable, "tools/scripts/check_escape_hatches.py"], 30)
    if rc != 0:
        return fail("a concurrency escape hatch is not listed with its guard", out)

    rc, out = step("swift build", ["swift", "build", "--scratch-path", SCRATCH_PATH],
                   BUILD_TIMEOUT_SECONDS)
    if rc != 0:
        return fail("swift build failed", out)

    rc, out = step("swift test", ["swift", "test", "--scratch-path", SCRATCH_PATH],
                   TEST_TIMEOUT_SECONDS)
    test_summary = next(
        (ln for ln in out.splitlines() if ln.lstrip().startswith("✔ Test run with")),
        "",
    )
    if rc != 0 or any(ln.strip().startswith("✘") for ln in out.splitlines()):
        return fail("swift test failed", out)
    if test_summary:
        print(test_summary)

    rc, out = step(
        "storybook smoke",
        [sys.executable, "tools/scripts/storybook_smoke.py", str(BUILD_DIR)],
        SMOKE_TIMEOUT_SECONDS,
    )
    if out.strip():
        print(out.rstrip())
    if rc != 0:
        return fail("smoke regression(s) above")
    return 0


if __name__ == "__main__":
    sys.exit(main())
