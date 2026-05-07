#!/usr/bin/env python3
"""Stop-hook verification runner.

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


def reap_dead_sockets() -> None:
    """Unlink stale socket files left by debug apps that crashed without
    cleanup. Calls `swtui ctl reap` which probes every socket's owning
    PID with `kill(pid, 0)` and only unlinks the dead ones. Live
    processes are NEVER touched.

    Replaces the legacy `kill_strays()` whose `swtui ctl kill all`
    dragnet would `quit` the user's live `swift run Storybook` when
    running from this Stop hook mid-keystroke. PID-isolated diag dirs
    plus the explicit-PID `kill` verb make that impossible by
    construction; this function uses the safe verb.
    """
    swtui = REPO_ROOT / ".build" / "debug" / "swtui"
    if not swtui.exists():
        return
    # Reap every dir matching /tmp/terminalui-*/remote — each
    # PID-isolated dir has its own subdir. The verb is read-only with
    # respect to live state; running it across all dirs is safe.
    remote_dirs = sorted(Path("/tmp").glob("terminalui-*/remote"))
    for remote_dir in remote_dirs:
        if not remote_dir.is_dir():
            continue
        subprocess.run(
            [str(swtui), "ctl", "--dir", str(remote_dir), "reap"],
            cwd=str(REPO_ROOT), check=False,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    # Also reap the project-local fallback dir if it exists (config
    # with `useTmp = false` writes here).
    local_remote = REPO_ROOT / ".terminalui" / "data" / "remote"
    if local_remote.is_dir():
        subprocess.run(
            [str(swtui), "ctl", "--dir", str(local_remote), "reap"],
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

    reap_dead_sockets()

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
