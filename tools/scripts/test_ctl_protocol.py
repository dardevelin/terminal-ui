#!/usr/bin/env python3
"""`swtui ctl` protocol correctness contract.

Pins the architectural rules that prevent automation from killing live
processes by accident:

1. **`kill` requires explicit `--pid <N>`.** No more `kill all` dragnet,
   no implicit "every socket in this dir." Bare `kill` and `kill all`
   both exit non-zero with a usage error to stderr.
2. **`kill --pid <N>` against a live process** still does the right
   thing: connects, sends `quit`, the process exits cleanly.
3. **`kill --pid <N>` against a dead PID** unlinks the stale socket
   file (preserving the existing graceful-shutdown semantics for the
   explicit-PID path). The PID stays explicit — no fan-out.
4. **`reap` is the new dragnet.** Enumerates `/tmp/terminalui-*/remote/*.sock`,
   probes each PID with `kill(pid, 0)`, unlinks ONLY dead-PID sockets.
   Never sends `quit`. Live processes are always preserved.
5. **`list` is read-only.** Stale sockets that `list` displayed-as-dead
   in the legacy code path were silently unlinked. That side effect
   moves into `reap`. After `list` runs, the filesystem state is
   identical to before.

Run::

    swift build && python3 tools/scripts/test_ctl_protocol.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import os
import socket
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, List

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui.runner import build_dir_path, spawn_and_connect  # noqa: E402


REPO_ROOT = Path(__file__).resolve().parents[2]
SWTUI_BIN = build_dir_path() / "swtui"


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


def _swtui_ctl(*args: str, cwd: Path = REPO_ROOT) -> subprocess.CompletedProcess:
    """Run `swtui ctl <args>` and return the CompletedProcess. Never
    raises on non-zero exit — callers assert on `.returncode`."""
    return subprocess.run(
        [str(SWTUI_BIN), "ctl", *args],
        cwd=str(cwd),
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )


def _make_stale_socket(socket_dir: Path, fake_pid: int) -> Path:
    """Bind a Unix socket file at <socket_dir>/<fake_pid>.sock then close
    it; the file remains. Used to seed dead-PID sockets for reap tests.
    Returns the socket path. Caller is responsible for cleanup if the
    test doesn't reap it."""
    socket_dir.mkdir(parents=True, exist_ok=True)
    path = socket_dir / f"{fake_pid}.sock"
    if path.exists():
        path.unlink()
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.bind(str(path))
    finally:
        sock.close()
    return path


def _pid_is_dead(pid: int) -> bool:
    """`kill(pid, 0)` returns ESRCH for a dead PID. Used to pick a stale
    PID that won't accidentally collide with a real process."""
    try:
        os.kill(pid, 0)
        return False
    except OSError:
        return True


def _find_dead_pid(start: int = 99_990_000) -> int:
    """Pick a PID guaranteed to be dead. Linux defaults to PID_MAX=4194304;
    macOS uses ~99_999. Walk down from a far-future-PID until we find
    one that's not currently in use. The probe is non-destructive."""
    pid = start
    while pid > 1:
        if _pid_is_dead(pid):
            return pid
        pid -= 1
    raise RuntimeError("could not find a dead PID — kernel state is weird")


# ---------------------------------------------------------------------------
# Case 1: bare `kill` is a usage error
# ---------------------------------------------------------------------------


def case_kill_without_pid_refused() -> None:
    result = _swtui_ctl("kill")
    assert result.returncode != 0, (
        f"`swtui ctl kill` (no PID) must exit non-zero; got rc={result.returncode}, "
        f"stdout={result.stdout!r}, stderr={result.stderr!r}"
    )
    combined = (result.stdout + result.stderr).lower()
    assert "--pid" in combined or "explicit" in combined or "usage" in combined, (
        f"kill without --pid must surface a usage hint mentioning --pid; "
        f"got combined output: {combined!r}"
    )


# ---------------------------------------------------------------------------
# Case 2: `kill all` is a usage error (no implicit dragnet)
# ---------------------------------------------------------------------------


def case_kill_all_refused() -> None:
    result = _swtui_ctl("kill", "all")
    assert result.returncode != 0, (
        f"`swtui ctl kill all` must exit non-zero (the 'all' alias was a "
        f"footgun and is removed); got rc={result.returncode}, "
        f"stdout={result.stdout!r}, stderr={result.stderr!r}"
    )


# ---------------------------------------------------------------------------
# Case 3: `kill --pid <N>` against a live process sends quit
# ---------------------------------------------------------------------------


def case_kill_with_pid_against_alive_process() -> None:
    """`kill --pid <N>` against a live process must connect to that PID's
    socket and send `quit`: the command exits 0 and stdout reports
    `status=quit-sent`. This pins the command side only; that the target
    actually dies is the case below."""
    with spawn_and_connect("Storybook") as (proc, client):
        client.wait_for_frame(1, timeout=2.0)
        diag_dir = getattr(client, "diag_dir", None)
        assert diag_dir is not None, "runner did not record diag_dir"
        result = _swtui_ctl(
            "--dir", str(Path(diag_dir) / "remote"),
            "kill", "--pid", str(proc.pid),
        )
        assert result.returncode == 0, (
            f"`kill --pid {proc.pid}` against a live process must exit 0; "
            f"rc={result.returncode}, stdout={result.stdout!r}, stderr={result.stderr!r}"
        )
        assert "status=quit-sent" in result.stdout, (
            f"kill must report `status=quit-sent` when the connect "
            f"+ write succeeded; got stdout={result.stdout!r}"
        )


# ---------------------------------------------------------------------------
# Case 3b: `kill --pid <N>` actually ends the process
# ---------------------------------------------------------------------------


def case_kill_with_pid_actually_exits() -> None:
    """The other half of `kill`: the target has to die.

    The command reporting `status=quit-sent` only proves the byte left this
    process. What a user means by `swtui ctl kill` is that the app stops, and
    a queued quit that nothing wakes is indistinguishable from a hang."""
    with spawn_and_connect("Storybook") as (proc, client):
        client.wait_for_frame(1, timeout=2.0)
        diag_dir = getattr(client, "diag_dir", None)
        assert diag_dir is not None, "runner did not record diag_dir"
        result = _swtui_ctl(
            "--dir", str(Path(diag_dir) / "remote"),
            "kill", "--pid", str(proc.pid),
        )
        assert result.returncode == 0, f"kill failed: {result.stdout!r} {result.stderr!r}"

        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                return
            time.sleep(0.05)
        raise AssertionError(
            "the process was still running 3s after `kill --pid` returned "
            "status=quit-sent — the quit is queued but nothing wakes the loop"
        )


# ---------------------------------------------------------------------------
# Case 4: `kill --pid <N>` against a dead PID unlinks the stale socket
# ---------------------------------------------------------------------------


def case_kill_with_pid_against_dead_unlinks() -> None:
    fake_pid = _find_dead_pid()
    # Use the live diag dir for this test — `swtui ctl` defaults there.
    # We need a writable dir. Carve one off /tmp explicitly.
    socket_dir = Path("/tmp") / f"terminalui-test-ctl-{os.getpid()}" / "remote"
    try:
        sock_path = _make_stale_socket(socket_dir, fake_pid)
        assert sock_path.exists()
        result = _swtui_ctl("--dir", str(socket_dir), "kill", "--pid", str(fake_pid))
        # exit code may be 0 (graceful "stale socket cleaned up") or 1
        # (no live process to kill); the contract is the file is GONE.
        assert not sock_path.exists(), (
            f"`kill --pid {fake_pid}` (dead PID) must unlink the stale "
            f"socket file at {sock_path}; survived after rc={result.returncode}"
        )
    finally:
        # Cleanup the test dir
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
# Case 5: `reap` preserves live sockets
# ---------------------------------------------------------------------------


def case_reap_preserves_live_sockets() -> None:
    with spawn_and_connect("Storybook") as (proc, client):
        client.wait_for_frame(1, timeout=2.0)
        diag_dir = getattr(client, "diag_dir", None)
        assert diag_dir is not None, "runner did not record diag_dir"
        live_sock = Path(diag_dir) / "remote" / f"{proc.pid}.sock"
        assert live_sock.exists(), f"live socket missing at {live_sock} before reap"
        result = _swtui_ctl("--dir", str(Path(diag_dir) / "remote"), "reap")
        assert result.returncode == 0, (
            f"reap must exit 0; rc={result.returncode}, "
            f"stdout={result.stdout!r}, stderr={result.stderr!r}"
        )
        assert live_sock.exists(), (
            f"reap must NOT touch live sockets; {live_sock} was unlinked. "
            f"reap output: {result.stdout!r}"
        )


# ---------------------------------------------------------------------------
# Case 6: `reap` removes dead sockets
# ---------------------------------------------------------------------------


def case_reap_removes_dead_sockets() -> None:
    fake_pid = _find_dead_pid()
    socket_dir = Path("/tmp") / f"terminalui-test-reap-{os.getpid()}" / "remote"
    try:
        sock_path = _make_stale_socket(socket_dir, fake_pid)
        assert sock_path.exists()
        result = _swtui_ctl("--dir", str(socket_dir), "reap")
        assert result.returncode == 0, (
            f"reap must exit 0 even when only dead sockets exist; "
            f"rc={result.returncode}, stderr={result.stderr!r}"
        )
        assert not sock_path.exists(), (
            f"reap must unlink dead-PID socket {sock_path}; survived. "
            f"reap output: {result.stdout!r}"
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
# Case 7: `list` does not unlink dead sockets (read-only contract)
# ---------------------------------------------------------------------------


def case_list_is_read_only() -> None:
    fake_pid = _find_dead_pid()
    socket_dir = Path("/tmp") / f"terminalui-test-list-{os.getpid()}" / "remote"
    try:
        sock_path = _make_stale_socket(socket_dir, fake_pid)
        assert sock_path.exists()
        before_inode = sock_path.stat().st_ino
        result = _swtui_ctl("--dir", str(socket_dir), "list")
        assert result.returncode == 0, (
            f"list must exit 0 even when only dead sockets exist; "
            f"rc={result.returncode}, stderr={result.stderr!r}"
        )
        assert sock_path.exists(), (
            f"list must NOT unlink dead-PID sockets — that's reap's job. "
            f"{sock_path} was unlinked. list output: {result.stdout!r}"
        )
        assert sock_path.stat().st_ino == before_inode, (
            "list must not replace the socket file (inode changed)"
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
    ("ctl.kill_without_pid_refused",            case_kill_without_pid_refused),
    ("ctl.kill_all_refused",                    case_kill_all_refused),
    ("ctl.kill_with_pid_against_alive_process", case_kill_with_pid_against_alive_process),
    ("ctl.kill_with_pid_actually_exits",         case_kill_with_pid_actually_exits),
    ("ctl.kill_with_pid_against_dead_unlinks",  case_kill_with_pid_against_dead_unlinks),
    ("ctl.reap_preserves_live_sockets",         case_reap_preserves_live_sockets),
    ("ctl.reap_removes_dead_sockets",           case_reap_removes_dead_sockets),
    ("ctl.list_is_read_only",                   case_list_is_read_only),
]


def main() -> int:
    if not SWTUI_BIN.exists():
        print(f"[SKIP] {SWTUI_BIN} not found — run `swift build` first")
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
