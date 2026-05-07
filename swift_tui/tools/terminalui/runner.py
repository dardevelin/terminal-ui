"""Helpers for spawning a TerminalUI app and connecting a ``Client`` to it.

Most smoke tests want: build, run ``.build/debug/<name>``, wait for the
socket to appear, connect, do work, kill. This module ships that pattern
so tests don't each reinvent process + socket plumbing.

Example::

    from terminalui.runner import spawn_and_connect

    with spawn_and_connect("Storybook") as (proc, app):
        app.send_key("down")
        assert app.focus().kind

Not a test framework — the returned tuple is plain; compose with pytest,
unittest, or whatever you prefer. The runner just handles boilerplate.
"""

from __future__ import annotations

import fcntl
import os
import pty
import shutil
import signal
import struct
import subprocess
import termios
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Callable, Iterator, Optional, Sequence, Tuple

from .client import Client, RemoteError, default_socket_path


DEFAULT_BUILD_DIR = ".build/debug"

# Per-process diag-dir isolation is the framework's default — every
# TerminalUI process writes to /tmp/terminalui-{cwd-hash}-{pid}/. The
# smoke harness used to force its own path via TERMINALUI_DATA_DIR
# because the canonical dir was shared across instances; that's no
# longer needed. The env var stays as a documented test-only escape
# hatch (test_isolation can pin a specific path when it needs to
# assert exact filenames) but is no longer set by spawn_and_connect.

# Disable every mouse-tracking mode the framework might have enabled.
# Per xterm ctlseqs §"Any-event mouse tracking" + ECMA-48 DEC private
# mode reset, all four codes must be cleared individually — disabling
# 1006 (SGR encoding) without disabling 1003/1002/1000 (mode selectors)
# leaves the terminal in legacy-encoding tracking mode and downstream
# processes still see raw mouse coords.
_MOUSE_OFF = (
    b"\x1b[?1006l"
    b"\x1b[?1003l"
    b"\x1b[?1002l"
    b"\x1b[?1000l"
)

# Optional observer for tests that want to verify what the runner posted
# to the master PTY before close. Production smoke runs leave this None.
_pty_cleanup_observer: Optional[Callable[[bytes], None]] = None


def set_pty_cleanup_observer(cb: Optional[Callable[[bytes], None]]) -> None:
    """Install (or clear) a callback invoked with the exact byte string
    written to the master PTY during cleanup. Tests use this to assert
    the mouse-disable sequence is posted on abort without intercepting
    raw fd I/O."""
    global _pty_cleanup_observer
    _pty_cleanup_observer = cb


def _post_pty_cleanup(master_fd: int) -> None:
    """Best-effort: write mouse-mode disable bytes to the master PTY so
    even an aborted smoke child doesn't leak tracking state into the
    parent terminal. Failure is non-fatal — the FD may already be closed
    or the child may have died — we still want the test to finish.
    """
    try:
        os.write(master_fd, _MOUSE_OFF)
    except OSError:
        pass
    if _pty_cleanup_observer is not None:
        try:
            _pty_cleanup_observer(_MOUSE_OFF)
        except Exception:  # noqa: BLE001
            pass


def _repo_root() -> Path:
    """Walk up from cwd looking for ``Package.swift``. Tests run from the
    project root or any subdirectory; the runner shouldn't care."""
    here = Path.cwd()
    for parent in (here, *here.parents):
        if (parent / "Package.swift").exists():
            return parent
    return here


@contextmanager
def spawn_and_connect(target: str,
                      build_dir: Optional[str] = None,
                      env: Optional[dict[str, str]] = None,
                      cwd: Optional[str] = None,
                      cols: int = 140,
                      rows: int = 40,
                      connect_timeout: float = 3.0,
                      ) -> Iterator[Tuple[subprocess.Popen, Client]]:
    """Run ``<build_dir>/<target>`` in a pseudo-TTY, wait for its control
    socket, yield (process, connected Client). Kills + closes on exit.

    The terminal size is set via COLUMNS/LINES env vars so the app doesn't
    inherit the test runner's window geometry — repeatable snapshots matter
    more than matching the user's screen.

    ``cwd`` controls where the spawned process runs. Defaults to the
    repo root (matches harness expectations for resolving build paths).
    Per-config integration tests pass a temp dir holding a custom
    ``.terminalui/terminalui.toml`` so they exercise the production
    config-loading path without touching the real project tree.
    """
    root = _repo_root()
    resolved_build_dir = Path(build_dir or DEFAULT_BUILD_DIR)
    if not resolved_build_dir.is_absolute():
        resolved_build_dir = root / resolved_build_dir
    exe = resolved_build_dir / target
    if not exe.exists():
        raise FileNotFoundError(
            f"{exe} not found — run `swift build` before spawning {target}"
        )

    env_full = os.environ.copy()
    env_full.update(env or {})
    env_full["COLUMNS"] = str(cols)
    env_full["LINES"] = str(rows)
    env_full["TERM"] = env_full.get("TERM") or "xterm-256color"

    # Spawn under a PTY so `Terminal.size()` (ioctl TIOCGWINSZ) returns the
    # geometry we want. Piping stdout to /dev/null makes ioctl fall back to
    # the VT100 default (80×24) which drops half the test surface off the
    # bottom of the screen. The PTY lets us control both input and output
    # geometry and still run headless.
    master, slave = pty.openpty()
    # Set window size before spawn so the initial layout pass uses it.
    winsize = struct.pack("HHHH", rows, cols, 0, 0)
    fcntl.ioctl(slave, termios.TIOCSWINSZ, winsize)
    proc = subprocess.Popen(
        [str(exe)],
        cwd=str(cwd) if cwd is not None else str(root),
        env=env_full,
        stdin=slave,
        stdout=slave,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )
    os.close(slave)
    # Drain master to avoid pipe-full blocking when the app renders. The
    # drained bytes are just the TUI's ANSI output, which we discard —
    # assertions go through the remote-control socket.
    def _drain(fd: int) -> None:
        try:
            while True:
                data = os.read(fd, 4096)
                if not data:
                    return
        except OSError:
            return
    drain_thread = threading.Thread(target=_drain, args=(master,), daemon=True)
    drain_thread.start()

    diag_dir: Optional[str] = None
    try:
        # Resolve the child's PID-isolated diag dir by globbing the
        # framework-default shape. The cwd-hash component is stable
        # but FNV-1a-encoded; cheaper to glob `terminalui-*-{pid}`
        # than reimplement the hash in Python.
        diag_dir = _wait_for_diag_dir(proc.pid, timeout=connect_timeout)
        client = _wait_for_client(
            proc.pid,
            timeout=connect_timeout,
            socket_dir=str(Path(diag_dir) / "remote"),
        )
        client.diag_dir = diag_dir
        # Hand the master FD to the client so `paste()` can write
        # bracketed-paste sequences straight into the app's stdin.
        client.attach_pty(master)
        yield proc, client
    finally:
        try:
            client.close()
        except Exception:
            pass
        # Post mouse-mode disable BEFORE closing the master FD so the
        # bytes actually reach the kernel buffer. Order matters: close
        # first and the write is silently dropped.
        _post_pty_cleanup(master)
        _terminate(proc)
        try:
            os.close(master)
        except OSError:
            pass
        # Best-effort: remove the child's PID-isolated dir so /tmp
        # doesn't accumulate one entry per smoke case. SIGTERM doesn't
        # run Swift defer blocks, so the framework's atexit hook
        # doesn't fire — the parent owns this cleanup. `swtui ctl
        # reap` is the safety net for crashes that bypass even this.
        if diag_dir is not None:
            shutil.rmtree(diag_dir, ignore_errors=True)


def _wait_for_diag_dir(pid: int, timeout: float) -> str:
    """Resolve the spawned child's per-process diag dir by globbing
    `/tmp/terminalui-*-{pid}` until it appears. The framework creates
    the dir during boot before writing its socket, so we can race the
    socket-wait by polling for the parent dir first.

    Returns the absolute path. Raises `RemoteError` if the dir never
    appears (child failed to boot)."""
    deadline = time.monotonic() + timeout
    pattern = f"/tmp/terminalui-*-{pid}"
    while time.monotonic() < deadline:
        matches = list(Path("/tmp").glob(f"terminalui-*-{pid}"))
        for match in matches:
            if match.is_dir():
                return str(match)
        time.sleep(0.05)
    raise RemoteError(
        f"diag dir matching {pattern} never appeared; child pid={pid} "
        "may have failed to boot or did not honor PID-isolated paths"
    )


def _wait_for_client(pid: int,
                     timeout: float,
                     socket_dir: Optional[str] = None) -> Client:
    """Poll for the socket file to appear, then try to connect. Separates
    "app hasn't written its socket yet" from "socket exists but app
    crashed" — the second case surfaces a clean RemoteError rather than
    hanging forever.

    ``socket_dir`` lets callers pin the search to a specific dir (e.g. the
    isolated TERMINALUI_DATA_DIR a smoke child was spawned with) so the
    path resolver doesn't fall through to the canonical glob and pick up
    a stale live-app socket."""
    deadline = time.monotonic() + timeout
    path: Optional[str] = None
    while time.monotonic() < deadline:
        path = default_socket_path(pid=pid, socket_dir=socket_dir)
        if Path(path).exists() or Path(path).is_symlink():
            break
        time.sleep(0.05)
    else:
        raise RemoteError(f"socket for pid={pid} never appeared; app may have failed to boot")
    client = Client(pid=pid, socket_dir=socket_dir)
    client.connect()
    return client


def _terminate(proc: subprocess.Popen, grace: float = 0.5) -> None:
    if proc.poll() is not None:
        return
    # Polite shutdown first; some apps drain their debug trace buffers on
    # SIGTERM. Escalate to SIGKILL if the app ignores us.
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait(timeout=grace)
