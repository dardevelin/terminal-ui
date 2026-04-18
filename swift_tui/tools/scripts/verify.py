#!/usr/bin/env python3
"""Stop-hook verification runner (HYP-71).

Replaces the old bash verify.sh with a Python driver so we exercise the
same bridge our smoke tests use. Steps:

1. Skip unless this turn touched ``.swift`` or ``.py`` under ``swift_tui/``.
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

REPO_ROOT = Path("/Users/dbrasdasilva/workspace/swift-workspace/swift_tui")
SMOKE_TIMEOUT_SECONDS = 240
BUILD_TIMEOUT_SECONDS = 180
TEST_TIMEOUT_SECONDS = 180


def dirty_relevant_sources() -> bool:
    """Return True if this turn left uncommitted .swift / .py under
    swift_tui/. Skips verification for memory / docs / settings edits."""
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


def kill_strays() -> None:
    """Ask every running debug app to exit cleanly via the HYP-71 socket,
    then clean up the socket directory. Uses `swtui ctl kill` so the
    teardown happens through the same channel the tests themselves use —
    no more pkill hunts for binaries behaving incorrectly."""
    swtui = REPO_ROOT / ".build" / "debug" / "swtui"
    if swtui.exists():
        subprocess.run(
            [str(swtui), "ctl", "kill", "all"],
            cwd=str(REPO_ROOT), check=False,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    # Belt-and-suspenders: also reap stale socket files from /tmp that the
    # ctl listing couldn't see (e.g. apps that died before writing their
    # socket). The glob covers both the project-local and /tmp directories
    # the config might point at.
    for remote_dir in (
        REPO_ROOT / ".terminalui" / "data" / "remote",
        *Path("/tmp").glob("terminalui-*/remote"),
    ):
        if not remote_dir.is_dir():
            continue
        for entry in remote_dir.iterdir():
            try:
                entry.unlink()
            except OSError:
                pass


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

    kill_strays()

    rc, out = step("swift build", ["swift", "build"], BUILD_TIMEOUT_SECONDS)
    if rc != 0:
        return fail("swift build failed", out)

    rc, out = step("swift test", ["swift", "test"], TEST_TIMEOUT_SECONDS)
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
        [sys.executable, "tools/scripts/storybook_smoke.py"],
        SMOKE_TIMEOUT_SECONDS,
    )
    if out.strip():
        print(out.rstrip())
    if rc != 0:
        return fail("smoke regression(s) above")
    return 0


if __name__ == "__main__":
    sys.exit(main())
