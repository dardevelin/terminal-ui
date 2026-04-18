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

import os
import signal
import subprocess
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator, Optional, Sequence, Tuple

from .client import Client, RemoteError, default_socket_path


DEFAULT_BUILD_DIR = ".build/debug"


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
                      cols: int = 140,
                      rows: int = 40,
                      connect_timeout: float = 3.0,
                      ) -> Iterator[Tuple[subprocess.Popen, Client]]:
    """Run ``<build_dir>/<target>`` in a pseudo-TTY, wait for its control
    socket, yield (process, connected Client). Kills + closes on exit.

    The terminal size is set via COLUMNS/LINES env vars so the app doesn't
    inherit the test runner's window geometry — repeatable snapshots matter
    more than matching the user's screen.
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

    # Spawn detached so signals sent to the parent process group don't
    # ripple into the app unintentionally. stdin piped so the app doesn't
    # see an immediate EOF on read — the socket is our only input channel.
    proc = subprocess.Popen(
        [str(exe)],
        cwd=str(root),
        env=env_full,
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )

    try:
        client = _wait_for_client(proc.pid, timeout=connect_timeout)
        yield proc, client
    finally:
        try:
            client.close()
        except Exception:
            pass
        _terminate(proc)


def _wait_for_client(pid: int, timeout: float) -> Client:
    """Poll for the socket file to appear, then try to connect. Separates
    "app hasn't written its socket yet" from "socket exists but app
    crashed" — the second case surfaces a clean RemoteError rather than
    hanging forever."""
    deadline = time.monotonic() + timeout
    path: Optional[str] = None
    while time.monotonic() < deadline:
        path = default_socket_path(pid=pid)
        if Path(path).exists() or Path(path).is_symlink():
            break
        time.sleep(0.05)
    else:
        raise RemoteError(f"socket for pid={pid} never appeared; app may have failed to boot")
    client = Client(pid=pid)
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
