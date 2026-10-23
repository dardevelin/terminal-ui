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
import pty
import select
import shutil
import signal
import subprocess
import tempfile
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Callable, Iterator, Optional, Sequence, Tuple

from .client import Client, RemoteError, default_socket_path, find_diag_dir, set_window_size


# Where the binaries under test live. `TERMINALUI_BUILD_DIR` points automation
# (verify.py, an agent) at its own scratch path: SwiftPM locks a build
# directory while it builds, so automation sharing `.build` made a human's
# `swift run Coder` wait on every verify run.
DEFAULT_BUILD_DIR = os.environ.get("TERMINALUI_BUILD_DIR") or ".build/debug"


def build_dir_path() -> Path:
    """The default build directory, absolute, for scripts that run a binary
    such as ``swtui`` directly instead of through ``spawn_and_connect``."""
    path = Path(DEFAULT_BUILD_DIR)
    return path if path.is_absolute() else _repo_root() / path

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

# Signals a TerminalUI app may die on without having crashed: its handler for
# these restores the terminal and re-raises, so the parent sees the death by
# the signal it sent (a shell reports it as 128 + signal). Any other signal
# is a crash, and whether the terminal was restored is checked separately.
_STOP_SIGNALS = {signal.SIGTERM, signal.SIGINT, signal.SIGHUP}

# How long a case that kills the app on purpose waits for it to die. A
# sanitized build symbolizes a report before it lets the process go, which
# takes seconds.
_EXPECTED_DEATH_TIMEOUT = 20.0

# DEC private modes the framework turns on (`ANSIMode` in Terminal.swift),
# each with the final byte that turns it on. The last time the app's output
# sets one of them it must turn it off: otherwise the shell inherits it, and
# a mouse mode left on types coordinates at the prompt.
_MODES_TO_RESTORE = {
    1049: b"h",  # alternate screen
    1000: b"h", 1002: b"h", 1003: b"h", 1006: b"h",  # mouse tracking
    2004: b"h",  # bracketed paste
    25: b"l",    # cursor hidden
}


class AppExitedBadly(RemoteError):
    """The case's assertions passed, but the app did not end the way a
    TerminalUI app must: it crashed, ignored SIGTERM, left the terminal in a
    mode it turned on, or a sanitizer reported on it. Raised on leaving
    ``spawn_and_connect``, so every harness that spawns an app checks this
    without asking for it."""


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


# How long an app may take to make its data dir and socket. The wait ends as
# soon as they appear, so a generous limit costs a fast start nothing — but
# the first launch of a freshly linked binary is slow: macOS checks a new
# executable before it first runs, and a Thread Sanitizer build maps its
# shadow memory. Three seconds failed the first case of a TSan run straight
# after its build.
BOOT_TIMEOUT = 15.0


@contextmanager
def spawn_and_connect(target: str,
                      build_dir: Optional[str] = None,
                      env: Optional[dict[str, str]] = None,
                      cwd: Optional[str] = None,
                      cols: int = 140,
                      rows: int = 40,
                      connect_timeout: float = BOOT_TIMEOUT,
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
    # A sanitizer prints to stderr, which the PTY would bury under the app's
    # frames. Send its reports to files the verdict reads instead. Builds
    # without a sanitizer ignore these variables.
    sanitizer_dir = tempfile.mkdtemp(prefix="terminalui-sanitizer-")
    for variable in ("TSAN_OPTIONS", "ASAN_OPTIONS"):
        options = env_full.get(variable, "")
        env_full[variable] = f"{options} log_path={sanitizer_dir}/report".strip()
    # Swift's backtracer holds a crashed process open: on a terminal it
    # counts down 30s offering a debugger, and even non-interactive it kept
    # a crashed Coder alive past 90s. The harness discards stderr, where the
    # backtrace goes, so it has nothing to give here; without it a crash
    # ends at once and the exit check sees it.
    env_full.setdefault("SWIFT_BACKTRACE", "enable=no")

    # Spawn under a PTY so `Terminal.size()` (ioctl TIOCGWINSZ) returns the
    # geometry we want. Piping stdout to /dev/null makes ioctl fall back to
    # the VT100 default (80×24) which drops half the test surface off the
    # bottom of the screen. The PTY lets us control both input and output
    # geometry and still run headless.
    master, slave = pty.openpty()
    # Set window size before spawn so the initial layout pass uses it.
    set_window_size(slave, cols, rows)
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
    # Drain master to avoid pipe-full blocking when the app renders. Most
    # assertions go through the remote-control socket; the bytes are kept
    # for the few that are about the terminal itself, such as what a
    # crashing app leaves it in.
    output = bytearray()
    output_lock = threading.Lock()
    # Closing the master hangs the terminal up, as closing its window does.
    # Only the drain thread closes it, between reads: closed under a read in
    # progress, the descriptor number could be reused by the next open and
    # the read would land in someone else's file. A byte on this pipe asks it
    # to, and wakes it from a quiet terminal.
    hang_up_read, hang_up_write = os.pipe()
    hung_up = threading.Event()

    def _drain(fd: int) -> None:
        try:
            while True:
                readable, _, _ = select.select([fd, hang_up_read], [], [])
                if hang_up_read in readable:
                    os.close(fd)
                    hung_up.set()
                    return
                data = os.read(fd, 4096)
                if not data:
                    return
                with output_lock:
                    output.extend(data)
        except OSError:
            return

    def _hang_up() -> None:
        os.write(hang_up_write, b"\x00")
        if not hung_up.wait(timeout=2.0):
            raise RuntimeError("the PTY master was not closed")
        client.forget_pty()

    def _release_master() -> None:
        # Mouse reporting off before the close, or the bytes are dropped.
        if not hung_up.is_set():
            _post_pty_cleanup(master)
            try:
                os.close(master)
            except OSError:
                pass
        os.close(hang_up_read)
        os.close(hang_up_write)

    def _output() -> bytes:
        with output_lock:
            return bytes(output)
    drain_thread = threading.Thread(target=_drain, args=(master,), daemon=True)
    drain_thread.start()

    diag_dir: Optional[str] = None
    client: Optional[Client] = None
    case_failed = False
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
        client.pid = proc.pid
        client.pty_output = _output
        client.hang_up = _hang_up

        def _wait_for_exit(timeout: float) -> Optional[int]:
            try:
                return proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                return None
        client.wait_for_exit = _wait_for_exit
        yield proc, client
    except BaseException:
        case_failed = True
        raise
    finally:
        if client is not None:
            client.close()
        if client is not None and client.expected_exit_signal is not None:
            try:
                proc.wait(timeout=_EXPECTED_DEATH_TIMEOUT)
            except subprocess.TimeoutExpired:
                pass
        stop = _terminate(proc)
        had_to_kill = stop == _KILLED
        # The child's exit closes the last slave descriptor, so the drain
        # reads to the end of what the app wrote and then stops.
        drain_thread.join(timeout=2.0)
        _release_master()
        sanitizer_reports = _read_sanitizer_reports(sanitizer_dir)
        shutil.rmtree(sanitizer_dir, ignore_errors=True)
        # An app asked to stop — SIGTERM, how this runner ends every app —
        # quits through its own teardown, which removes its PID-isolated
        # dir. One still there after that is a finding; one left by a crash
        # or SIGKILL is expected, and removed here so /tmp does not keep one
        # entry per case.
        leftover_dir = diag_dir if diag_dir is not None and Path(diag_dir).exists() else None
        if leftover_dir is not None:
            shutil.rmtree(leftover_dir, ignore_errors=True)
        # A failing case already says what went wrong; this verdict is for
        # the cases that passed while the app crashed or raced underneath.
        if not case_failed and client is not None:
            problems = _exit_problems(
                returncode=proc.returncode,
                had_to_kill=had_to_kill,
                stopped_by_sigterm=stop == _STOPPED,
                output=_output(),
                sanitizer_reports=sanitizer_reports,
                expected_signal=client.expected_exit_signal,
                leftover_dir=leftover_dir,
                terminal_gone=hung_up.is_set(),
            )
            if problems:
                raise AppExitedBadly(f"{target} (pid {proc.pid}): " + "; ".join(problems))


def _signal_name(signum: int) -> str:
    try:
        return signal.Signals(signum).name
    except ValueError:
        return f"signal {signum}"


def _exit_problems(returncode: Optional[int],
                   had_to_kill: bool,
                   stopped_by_sigterm: bool,
                   output: bytes,
                   sanitizer_reports: list[str],
                   expected_signal: Optional[int],
                   leftover_dir: Optional[str] = None,
                   terminal_gone: bool = False) -> list[str]:
    """Everything wrong with how an app ended, as sentences for a case
    failure; empty when it ended cleanly."""
    problems: list[str] = []
    # A deliberate kill makes the sanitizer report the signal itself; that
    # report is the case working, not a finding. The sanitizer then ends the
    # process with abort(), so the death the parent sees is SIGABRT.
    expected_report = (f"Sanitizer: {_signal_name(expected_signal)[3:]} "
                       if expected_signal is not None else None)
    sanitizer_took_the_signal = expected_report is not None and any(
        expected_report in summary for summary in sanitizer_reports)
    if expected_signal is not None:
        if sanitizer_took_the_signal and returncode == -signal.SIGABRT:
            pass
        elif returncode != -expected_signal:
            problems.append(f"expected to die on {_signal_name(expected_signal)}, "
                            f"but its exit status was {returncode}")
    elif had_to_kill:
        problems.append("ignored SIGTERM and had to be killed")
    elif returncode is not None and returncode < 0:
        if -returncode not in _STOP_SIGNALS:
            problems.append(f"crashed on {_signal_name(-returncode)}")
    elif returncode != 0:
        problems.append(f"exited with status {returncode}")
    elif stopped_by_sigterm:
        # It tore down, then exited 0 rather than dying of the signal, so its
        # parent cannot tell it was stopped. On Linux the re-raised signal
        # stayed pending on a thread that blocked it.
        problems.append("exited 0 on SIGTERM instead of dying by it")
    # Stopped or quit, the app tears down — on purpose too, as when a case
    # hangs its terminal up; only a crash leaves its dir.
    stop_expected = expected_signal is None or expected_signal in _STOP_SIGNALS
    if leftover_dir is not None and stop_expected and not had_to_kill and (
            returncode == 0 or (returncode is not None and -returncode in _STOP_SIGNALS)):
        problems.append(f"left its data dir {leftover_dir}")

    # After a hang-up there is no terminal to restore, and what the app wrote
    # to it on the way out was never read.
    if not terminal_gone:
        for mode, on in _MODES_TO_RESTORE.items():
            off = b"l" if on == b"h" else b"h"
            turned_on = output.rfind(b"\x1b[?%d" % mode + on)
            if turned_on > output.rfind(b"\x1b[?%d" % mode + off):
                problems.append(f"left DEC mode {mode} {'on' if on == b'h' else 'off'}")

    for summary in sanitizer_reports:
        if expected_report is None or expected_report not in summary:
            problems.append(summary)
    return problems


def _read_sanitizer_reports(directory: str) -> list[str]:
    """The SUMMARY line of every report a sanitizer wrote to ``directory``,
    one per finding, deduplicated."""
    summaries: list[str] = []
    for report in sorted(Path(directory).glob("report*")):
        for line in report.read_text(errors="replace").splitlines():
            if line.startswith("SUMMARY:") and line not in summaries:
                summaries.append(line)
    return summaries


def _wait_for_diag_dir(pid: int, timeout: float) -> str:
    """Resolve the spawned child's per-process diag dir by globbing
    `/tmp/terminalui-*-{pid}` until it appears. The framework creates
    the dir during boot before writing its socket, so we can race the
    socket-wait by polling for the parent dir first.

    Returns the absolute path. Raises `RemoteError` if the dir never
    appears (child failed to boot)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        diag_dir = find_diag_dir(pid)
        if diag_dir is not None:
            return diag_dir
        time.sleep(0.05)
    raise RemoteError(
        f"diag dir /tmp/terminalui-*-{pid} never appeared; child pid={pid} "
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


# How an app came to stop, as `_terminate` saw it.
_ENDED_ON_ITS_OWN = "ended on its own"
_STOPPED = "stopped by SIGTERM"
_KILLED = "killed"


def _terminate(proc: subprocess.Popen, grace: float = 2.0) -> str:
    """Stop the app, and say how it came to stop: on its own before it was
    asked, on SIGTERM, or only on SIGKILL. The grace is generous because a
    sanitized build exits slowly, and an app that takes it all is reported,
    not just stopped."""
    if proc.poll() is not None:
        return _ENDED_ON_ITS_OWN
    # Polite shutdown first; some apps drain their debug trace buffers on
    # SIGTERM. Escalate to SIGKILL if the app ignores us.
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except ProcessLookupError:
        proc.wait()
        return _ENDED_ON_ITS_OWN
    try:
        proc.wait(timeout=grace)
        return _STOPPED
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait(timeout=grace)
        return _KILLED
