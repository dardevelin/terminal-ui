#!/usr/bin/env python3
"""Stop-hook verification runner.

Replaces the old bash verify.sh with a Python driver so we exercise the
same bridge our smoke tests use. Steps:

1. Skip unless this turn touched a ``.swift`` or ``.py`` file, or the run
   was asked for with ``--always`` (a merge, whose changes are committed).
2. Tear down any leftover debug apps + stale sockets.
3. Repository checks: the tooling's own tests (``tool_tests.py``), then the
   escape-hatch, colour-literal, font-glyph and tracker-id checks they test.
4. ``swift build --build-tests`` with warnings as errors — the library, the
   examples and the tests (release build is deferred to CI).
5. ``check_api_compat.py`` — the public API against the last release, then
   ``check_doc_pages.py`` — every published documentation page says something.
6. ``swift test`` — unit + component suites, then again on a one-thread
   cooperative pool (macOS), where blocking a pool thread deadlocks.
7. ``storybook_walk.py`` — every Storybook page, as CI walks them.
8. ``integration_suite.py`` — every ``test_*`` script.
9. ``storybook_smoke.py`` — live harness cases against Storybook + Demo.
10. ``check_tutorial_steps.py`` — every tutorial step builds and does what
    its captions say.
11. With ``--release``, what CI runs beyond this gate: the release build,
    the Thread Sanitizer job (tests, examples, integration scripts, smoke)
    and the Linux leg in Docker (build with its tests, test, smoke). Run it
    before tagging, so nothing reaches CI that has not passed here.

Each failure prints the relevant output and exits with code 2 so the
stop-hook surfaces it to the conversation.
"""

from __future__ import annotations

import os
import platform
import subprocess
import sys
from pathlib import Path
from typing import Callable

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
# The steps build as a package of their own, the framework with them: minutes
# the first time, seconds after.
TUTORIAL_TIMEOUT_SECONDS = 600
# The first run builds the baseline release and the package in a directory
# of their own; later runs reuse both.
API_TIMEOUT_SECONDS = 600


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


# How many of a failed step's last lines are shown.
FAILURE_TAIL_LINES = 25

# Lines that say what failed: Swift Testing's issue and failure lines, and
# a compiler's or XCTest's errors. A test step ends in the summaries of the
# targets that passed, and its tail alone left the failing test unnamed.
FAILURE_MARKERS = ("✘", "error:")


def failure_detail(output: str) -> str:
    """What a failed step's output says went wrong, then how it ended."""
    lines = output.splitlines()
    tail = lines[-FAILURE_TAIL_LINES:]
    named = [line for line in lines[:-FAILURE_TAIL_LINES] if any(marker in line for marker in FAILURE_MARKERS)]
    return "\n".join(named + (["…"] if named else []) + tail)


def fail(msg: str, detail: str = "") -> int:
    print(f"✗ {msg}")
    if detail:
        print(failure_detail(detail))
    return 2


def wants_gate(arguments: list[str], has_source_changes: bool) -> bool:
    """Whether to run: on a turn that changed sources, or on ``--always``
    or ``--release``."""
    return has_source_changes or "--always" in arguments or wants_release(arguments)


def wants_release(arguments: list[str]) -> bool:
    """Whether to run, after the gate, what CI runs beyond it."""
    return "--release" in arguments


# CI's Thread Sanitizer job builds apart, as here; its Linux leg runs in this
# image, which Package.swift's tools version requires (swift:6.0 rejects it),
# building into a directory of its own so Linux and macOS artefacts never mix.
TSAN_SCRATCH_PATH = ".build-tsan"
LINUX_IMAGE = "swift:6.2"
# Linux runs natively for this machine: Docker on an Apple-silicon Mac runs
# an x86_64 image under emulation, whose own SIGSEGV handling kept an app the
# smoke suite crashes on purpose alive. CI's Linux leg is x86_64 on real
# hardware, so between the two both architectures run natively. Each gets a
# build directory of its own, as Linux and macOS do.
LINUX_PLATFORM = "linux/arm64" if platform.machine() in ("arm64", "aarch64") else "linux/amd64"
LINUX_SCRATCH_PATH = f".build-linux-{LINUX_PLATFORM.split('/')[1]}"
# A sanitized build and suite run several times slower than a plain one, and
# the Linux leg builds everything from cold the first time.
RELEASE_BUILD_TIMEOUT_SECONDS = 900
SANITIZER_TIMEOUT_SECONDS = 1800
LINUX_TIMEOUT_SECONDS = 2400


def release_steps() -> list[tuple[str, list[str], int]]:
    """What CI runs that the everyday gate does not, as (name, command,
    timeout): its release build, its Thread Sanitizer job and its Linux leg.
    CI found what the gate had passed whenever a test held its timing here
    and not on CI's slower three-core runner; running these before a tag is
    pushed is what keeps a release's CI green."""
    sanitized = f"{TSAN_SCRATCH_PATH}/debug"
    linux = ["docker", "run", "--rm", "--platform", LINUX_PLATFORM, "-v", f"{REPO_ROOT}:/app", "-w", "/app",
             "-e", "TUI_WARNINGS_AS_ERRORS=1", LINUX_IMAGE]
    return [
        # As CI builds it: with warnings as errors, stated here rather than
        # inherited from the gate, so the step means the same run on its own.
        ("release build", ["env", "TUI_WARNINGS_AS_ERRORS=1", "swift", "build", "-c", "release",
                           "--scratch-path", SCRATCH_PATH], RELEASE_BUILD_TIMEOUT_SECONDS),
        ("swift test, thread sanitizer",
         ["swift", "test", "--sanitize=thread", "--scratch-path", TSAN_SCRATCH_PATH], SANITIZER_TIMEOUT_SECONDS),
        ("examples, thread sanitizer",
         ["swift", "build", "--sanitize=thread", "--scratch-path", TSAN_SCRATCH_PATH], SANITIZER_TIMEOUT_SECONDS),
        ("integration scripts, thread sanitizer",
         [sys.executable, "tools/scripts/integration_suite.py", sanitized], SANITIZER_TIMEOUT_SECONDS),
        ("storybook smoke, thread sanitizer",
         [sys.executable, "tools/scripts/storybook_smoke.py", sanitized], SANITIZER_TIMEOUT_SECONDS),
        ("linux build", linux + ["swift", "build", "--build-tests", "--scratch-path", LINUX_SCRATCH_PATH],
         LINUX_TIMEOUT_SECONDS),
        ("linux test", linux + ["swift", "test", "--scratch-path", LINUX_SCRATCH_PATH], LINUX_TIMEOUT_SECONDS),
        ("linux smoke", ["env", f"TERMINALUI_LINUX_PLATFORM={LINUX_PLATFORM}",
                         f"TERMINALUI_LINUX_SCRATCH={LINUX_SCRATCH_PATH}",
                         "tools/scripts/linux_harness.sh", "storybook_smoke.py"], LINUX_TIMEOUT_SECONDS),
    ]


def main(arguments: list[str]) -> int:
    if not wants_gate(arguments, dirty_relevant_sources()):
        return 0

    # Before, for what earlier runs left; after, for what this one leaves —
    # the smoke suite kills one app with SIGKILL on purpose, and nothing in
    # it can remove that app's output.
    reap_dead_apps()
    try:
        result = run_gate()
        if result == 0 and wants_release(arguments):
            result = run_release_steps(release_steps(), step)
        return result
    finally:
        reap_dead_apps()


def run_release_steps(steps: list[tuple[str, list[str], int]],
                      runner: Callable[[str, list[str], int], tuple[int, str]]) -> int:
    """Run `steps` in turn with `runner`, stopping at the first that fails.
    A Swift Testing run reports a known issue with a ✘ too; only an issue
    it does not expect fails a step."""
    for name, command, timeout in steps:
        rc, out = runner(name, command, timeout)
        if rc != 0 or any(line.strip().startswith("✘") and "known issue" not in line
                          for line in out.splitlines()):
            return fail(f"{name} failed: CI would fail the release the same way", out)
        print(f"{name}: passed")
    return 0


# Source-only checks, cheap enough to run ahead of the build: (step label,
# script, what a failure means).
REPOSITORY_CHECKS = (
    ("tooling tests", "tools/scripts/tool_tests.py",
     "a check the gate rests on misses a case"),
    ("escape hatches", "tools/scripts/check_escape_hatches.py",
     "a concurrency escape hatch is not listed with its guard"),
    ("colour literals", "tools/scripts/check_colour_literals.py",
     "drawing code names a colour the list does not"),
    ("font glyphs", "tools/scripts/check_font_glyphs.py",
     "the framework draws a character that is neither a shape nor listed"),
    ("tracker ids", "tools/scripts/check_tracker_ids.py",
     "a tracker id is in the repository"),
)


def run_gate() -> int:
    for label, script, failure in REPOSITORY_CHECKS:
        rc, out = step(label, [sys.executable, script], 30)
        if rc != 0:
            return fail(failure, out)

    # Warnings as errors for every build in the gate, tests included: a
    # warning in a test target passed `swift build`, which never compiles
    # one. Set once for the whole run, since a build setting that changes
    # between steps rebuilds the directory from scratch.
    os.environ["TUI_WARNINGS_AS_ERRORS"] = "1"
    rc, out = step("swift build",
                   ["swift", "build", "--build-tests", "--scratch-path", SCRATCH_PATH],
                   BUILD_TIMEOUT_SECONDS)
    if rc != 0:
        return fail("swift build failed", out)

    rc, out = step("public API", [sys.executable, "tools/scripts/check_api_compat.py"],
                   API_TIMEOUT_SECONDS)
    if rc != 0:
        return fail("the public API breaks what the last release offered", out)

    rc, out = step("documentation pages", [sys.executable, "tools/scripts/check_doc_pages.py"],
                   API_TIMEOUT_SECONDS)
    if rc != 0:
        return fail("a documentation page says nothing, or DocC warned", out)

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

    # Once more on a one-thread cooperative pool, a Darwin-only switch: a
    # test or framework code that blocks a pool thread deadlocks here, as it
    # did on CI's three-core runner, instead of passing on a many-core Mac.
    # Not in CI: the switch reaches SwiftPM too, and the runner's SwiftPM
    # deadlocks under it before a test runs.
    if sys.platform == "darwin":
        os.environ["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] = "1"
        rc, out = step("swift test, one-thread pool",
                       ["swift", "test", "--scratch-path", SCRATCH_PATH], TEST_TIMEOUT_SECONDS)
        del os.environ["LIBDISPATCH_COOPERATIVE_POOL_STRICT"]
        if rc != 0:
            return fail("on a one-thread pool the tests deadlock or fail: something blocks a pool thread", out)

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

    rc, out = step("tutorial steps", [sys.executable, "tools/scripts/check_tutorial_steps.py"],
                   TUTORIAL_TIMEOUT_SECONDS)
    if rc != 0:
        return fail("a tutorial step does not build, or no longer does what its page says", out)
    print(f"tutorial steps: {out.strip().splitlines()[-1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
