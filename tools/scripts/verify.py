#!/usr/bin/env python3
"""Stop-hook verification runner.

Replaces the old bash verify.sh with a Python driver so we exercise the
same bridge our smoke tests use. Steps:

1. Skip unless this turn touched a ``.swift`` or ``.py`` file.
2. Tear down any leftover debug apps + stale sockets.
3. Repository checks: the tooling's own tests (``tool_tests.py``), then the
   escape-hatch and tracker-id checks they test.
4. ``swift build`` — compile check (release build is deferred to CI).
5. ``swift test`` — unit + component suites.
6. ``storybook_walk.py`` — every Storybook page, as CI walks them.
7. ``integration_suite.py`` — every ``verify_*`` and ``test_*`` script.
8. ``storybook_smoke.py`` — live harness cases against Storybook + Demo.

Each failure prints the relevant output and exits with code 2 so the
stop-hook surfaces it to the conversation.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui.process import step as run_step  # noqa: E402

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
# Sized for the suite run in turn, as it is on a machine with two CPUs or
# fewer: 304s at 100 cases, where 240s cut it off mid-run and reported the
# cutoff as a smoke regression. Side by side it takes a fraction of that.
SMOKE_TIMEOUT_SECONDS = 600
# The whole integration suite, its scripts in turn: seconds each, and the
# suite's own limit per script catches one that hangs first.
INTEGRATION_TIMEOUT_SECONDS = 600
WALK_TIMEOUT_SECONDS = 180
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


def reap_dead_apps(build_dir: Path = BUILD_DIR) -> None:
    """Remove what debug apps from this checkout left when they died — a
    crash, or SIGKILL, leaves their output and socket behind. Calls
    `swtui ctl reap`, which touches only apps whose PID is dead: a live
    `swift run Coder` is never affected.

    Replaces the legacy `kill_strays()` whose `swtui ctl kill all`
    dragnet would `quit` the user's live `swift run Storybook` when
    running from this Stop hook mid-keystroke.

    `build_dir` holds the `swtui` to run: verify's own build, unless a
    test of this function is checking another.
    """
    swtui = build_dir / "swtui"
    if swtui.exists():
        subprocess.run(
            [str(swtui), "ctl", "reap"],
            cwd=str(REPO_ROOT), check=False,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )


def step(name: str, cmd: list[str], timeout: int) -> tuple[int, str]:
    return run_step(name, cmd, timeout, cwd=REPO_ROOT)


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


# Source-only checks, cheap enough to run ahead of the build: (step label,
# script, what a failure means).
REPOSITORY_CHECKS = (
    ("tooling tests", "tools/scripts/tool_tests.py",
     "a check the gate rests on misses a case"),
    ("escape hatches", "tools/scripts/check_escape_hatches.py",
     "a concurrency escape hatch is not listed with its guard"),
    ("tracker ids", "tools/scripts/check_tracker_ids.py",
     "a tracker id is in the repository"),
)


def run_gate() -> int:
    for label, script, failure in REPOSITORY_CHECKS:
        rc, out = step(label, [sys.executable, script], 30)
        if rc != 0:
            return fail(failure, out)

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

    # The quick checks first: a walk and the integration scripts take
    # seconds, the smoke suite minutes.
    rc, out = step("storybook walk",
                   [sys.executable, "tools/scripts/storybook_walk.py", str(BUILD_DIR)],
                   WALK_TIMEOUT_SECONDS)
    if rc != 0:
        return fail("a Storybook page failed the walk", out)

    rc, out = step(
        "integration scripts",
        [sys.executable, "tools/scripts/integration_suite.py", str(BUILD_DIR)],
        INTEGRATION_TIMEOUT_SECONDS,
    )
    if rc != 0:
        return fail("integration script failure(s)", out)
    print(f"integration scripts: {out.strip().splitlines()[-1]}")

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
