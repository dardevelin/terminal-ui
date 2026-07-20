#!/usr/bin/env python3
"""verify.py must NEVER affect a live TerminalUI process.

verify.py runs from the project Stop hook on every Claude turn that
touches a `.swift` or `.py` file. The legacy implementation called
`kill_strays()` which invoked `swtui ctl kill all` against the
canonical socket dir — a dragnet that sent `quit` to whatever was
running there, including the user's live `swift run Storybook`. Per
HYP-349 + the protocol-correctness work in HYP-348, this is replaced
with `swtui ctl reap` which only touches sockets whose owning PID is
already dead.

The contract:

1. **Live processes survive verify.** Spawning a Storybook child,
   running `verify.reap_dead_sockets()`, then asserting the child is
   still alive and its socket file is still present.
2. **Dead sockets are reaped.** A stale socket file with a guaranteed-
   dead PID is unlinked.

Run::

    swift build && python3 tools/scripts/test_verify_no_live_kill.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import os
import socket as socketlib
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui.runner import spawn_and_connect  # noqa: E402

# Import the script-as-module so we can call its public surface
# directly. This is the right test seam: black-box at the function
# level, NOT subprocess-orchestrating verify.py's main() (which would
# pull in `swift build` + `swift test` + smoke and take 5+ minutes).
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import verify  # noqa: E402


REPO_ROOT = Path(__file__).resolve().parents[2]


@dataclass
class CaseResult:
    name: str
    ok: bool
    detail: str


def _run(name: str, fn: Callable[[], None]) -> CaseResult:
    try:
        fn()
        return CaseResult(name, True, "ok")
    except AssertionError as exc:
        return CaseResult(name, False, str(exc))
    except Exception as exc:  # noqa: BLE001
        return CaseResult(name, False, f"{type(exc).__name__}: {exc}")


def _make_stale_socket(socket_dir: Path, fake_pid: int) -> Path:
    socket_dir.mkdir(parents=True, exist_ok=True)
    path = socket_dir / f"{fake_pid}.sock"
    if path.exists():
        path.unlink()
    sock = socketlib.socket(socketlib.AF_UNIX, socketlib.SOCK_STREAM)
    try:
        sock.bind(str(path))
    finally:
        sock.close()
    return path


def _pid_is_dead(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return False
    except OSError:
        return True


def _find_dead_pid(start: int = 99_990_000) -> int:
    pid = start
    while pid > 1:
        if _pid_is_dead(pid):
            return pid
        pid -= 1
    raise RuntimeError("could not find a dead PID")


# ---------------------------------------------------------------------------
# Case 1: verify cleanup does not quit a live process
# ---------------------------------------------------------------------------


def case_verify_does_not_quit_live_process() -> None:
    """Spawn a Storybook in a PTY. Run the cleanup verify.py runs at
    the start of every turn. Assert the process is still alive AND its
    socket file is still on disk. The legacy `kill_strays()` would
    `swtui ctl kill all` against the canonical dir, killing the live
    process; the new `reap_dead_sockets()` must leave it alone."""
    with spawn_and_connect("Storybook") as (proc, client):
        client.wait_for_frame(1, timeout=2.0)
        diag_dir = getattr(client, "diag_dir", None)
        assert diag_dir is not None, "runner did not record diag_dir"
        live_sock = Path(diag_dir) / "remote" / f"{proc.pid}.sock"
        assert live_sock.exists(), f"live socket missing at {live_sock} before reap"

        # Call the cleanup verify.py would invoke — but only the
        # cleanup, not the full verify pipeline (would take 5min+
        # because of swift build + test + smoke).
        verify.reap_dead_sockets()

        # Brief settle — `swtui ctl reap` is synchronous but the test
        # window must close before any racy event arrives.
        time.sleep(0.1)

        assert proc.poll() is None, (
            f"reap_dead_sockets killed the live process (pid={proc.pid}, "
            f"exit_code={proc.poll()}). Live processes must NEVER be "
            "touched by automation."
        )
        assert live_sock.exists(), (
            f"reap_dead_sockets unlinked the live socket at {live_sock}. "
            "Live socket files must survive cleanup."
        )


# ---------------------------------------------------------------------------
# Case 2: verify cleanup reaps a stale socket
# ---------------------------------------------------------------------------


def case_verify_reaps_dead_sockets() -> None:
    """Create a socket file under a guaranteed-dead PID. Run
    verify.reap_dead_sockets(). The stale file must be unlinked.

    We seed the file inside the canonical dir for THIS cwd
    (`/tmp/terminalui-{cwd-hash}-<dead-pid>/remote/<dead-pid>.sock`)
    because verify.py shells out to `swtui ctl reap` which scans
    `/tmp/terminalui-*/remote/*.sock` via the active socketDir
    resolver — same path the live runtime would use."""
    fake_pid = _find_dead_pid()
    # Build a path that mirrors what a real dead-process diag dir
    # would look like: /tmp/terminalui-{cwd-hash}-<fake_pid>/remote/<fake_pid>.sock
    # That dir name is what `swtui ctl reap` enumerates by default.
    # We don't need to compute the hash — any /tmp/terminalui-*-* dir
    # gets scanned. We use a unique marker so we don't collide with
    # other tests' temp dirs.
    test_marker = f"verify-test-{os.getpid()}"
    socket_dir = Path("/tmp") / f"terminalui-{test_marker}-{fake_pid}" / "remote"
    try:
        sock_path = _make_stale_socket(socket_dir, fake_pid)
        assert sock_path.exists()

        verify.reap_dead_sockets()

        assert not sock_path.exists(), (
            f"reap_dead_sockets did not unlink stale socket at {sock_path}. "
            "Stale-only cleanup is the verb's whole point."
        )
    finally:
        try:
            for entry in socket_dir.iterdir():
                entry.unlink()
        except FileNotFoundError:
            pass
        try:
            socket_dir.rmdir()
            socket_dir.parent.rmdir()
        except (FileNotFoundError, OSError):
            pass


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------


CASES = [
    ("verify.does_not_quit_live_process", case_verify_does_not_quit_live_process),
    ("verify.reaps_dead_sockets",         case_verify_reaps_dead_sockets),
]


def main() -> int:
    swtui = REPO_ROOT / ".build" / "debug" / "swtui"
    if not swtui.exists():
        print(f"[SKIP] {swtui} not found — run `swift build` first")
        return 0

    failures = 0
    for name, fn in CASES:
        result = _run(name, fn)
        marker = "OK" if result.ok else "FAIL"
        line = f"[{marker}] {result.name}"
        if not result.ok:
            line += f" — {result.detail}"
            failures += 1
        print(line)
    print("---")
    print(f"{len(CASES) - failures}/{len(CASES)} pass")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
