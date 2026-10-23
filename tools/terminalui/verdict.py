"""How an app the harness ran came to end, and everything wrong with that.

Every case passes through ``exit_problems`` on the way out of
``spawn_and_connect``: it is what fails a case whose assertions all held
while its app crashed, ignored SIGTERM, left a terminal mode on, left its
data dir or drew a sanitizer report. Kept apart from the PTY and process
plumbing so it can be tested as the pure decision it is."""

from __future__ import annotations

import functools
import mmap
import signal
from pathlib import Path
from typing import Optional

# Signals a TerminalUI app may die on without having crashed: its handler for
# these restores the terminal and re-raises, so the parent sees the death by
# the signal it sent (a shell reports it as 128 + signal). Any other signal
# is a crash, and whether the terminal was restored is checked separately.
STOP_SIGNALS = {signal.SIGTERM, signal.SIGINT, signal.SIGHUP}

# DEC private modes the framework turns on (`ANSIMode` in Terminal.swift),
# each with the final byte that turns it on. The last time the app's output
# sets one of them it must turn it off: otherwise the shell inherits it, and
# a mouse mode left on types coordinates at the prompt.
MODES_TO_RESTORE = {
    1049: b"h",  # alternate screen
    1000: b"h", 1002: b"h", 1003: b"h", 1006: b"h",  # mouse tracking
    2004: b"h",  # bracketed paste
    25: b"l",    # cursor hidden
}


# The symbol each sanitizer's runtime starts from, found in a binary built
# with it whether the runtime is linked in (Linux) or loaded (macOS).
SANITIZER_SYMBOLS = {"thread": b"__tsan_init", "address": b"__asan_init"}


@functools.lru_cache(maxsize=None)
def sanitizer_of(exe: Path) -> Optional[str]:
    """The sanitizer ``exe`` was built with, if any."""
    with open(exe, "rb") as binary, mmap.mmap(binary.fileno(), 0, access=mmap.ACCESS_READ) as image:
        return next((name for name, symbol in SANITIZER_SYMBOLS.items() if image.find(symbol) >= 0), None)


def signal_name(signum: int) -> str:
    try:
        return signal.Signals(signum).name
    except ValueError:
        return f"signal {signum}"


def exit_problems(returncode: Optional[int],
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
    expected_report = (f"Sanitizer: {signal_name(expected_signal)[3:]} "
                       if expected_signal is not None else None)
    sanitizer_took_the_signal = expected_report is not None and any(
        expected_report in summary for summary in sanitizer_reports)
    if expected_signal is not None:
        if sanitizer_took_the_signal and returncode == -signal.SIGABRT:
            pass
        elif returncode != -expected_signal:
            problems.append(f"expected to die on {signal_name(expected_signal)}, "
                            f"but its exit status was {returncode}")
    elif had_to_kill:
        problems.append("ignored SIGTERM and had to be killed")
    elif returncode is not None and returncode < 0:
        if -returncode not in STOP_SIGNALS:
            problems.append(f"crashed on {signal_name(-returncode)}")
    elif returncode != 0:
        problems.append(f"exited with status {returncode}")
    elif stopped_by_sigterm:
        # It tore down, then exited 0 rather than dying of the signal, so its
        # parent cannot tell it was stopped. On Linux the re-raised signal
        # stayed pending on a thread that blocked it.
        problems.append("exited 0 on SIGTERM instead of dying by it")
    # Stopped or quit, the app tears down — on purpose too, as when a case
    # hangs its terminal up; only a crash leaves its dir.
    stop_expected = expected_signal is None or expected_signal in STOP_SIGNALS
    if leftover_dir is not None and stop_expected and not had_to_kill and (
            returncode == 0 or (returncode is not None and -returncode in STOP_SIGNALS)):
        problems.append(f"left its data dir {leftover_dir}")

    # After a hang-up there is no terminal to restore, and what the app wrote
    # to it on the way out was never read.
    if not terminal_gone:
        for mode, on in MODES_TO_RESTORE.items():
            off = b"l" if on == b"h" else b"h"
            turned_on = output.rfind(b"\x1b[?%d" % mode + on)
            if turned_on > output.rfind(b"\x1b[?%d" % mode + off):
                problems.append(f"left DEC mode {mode} {'on' if on == b'h' else 'off'}")

    for summary in sanitizer_reports:
        if expected_report is None or expected_report not in summary:
            problems.append(summary)
    return problems


def read_sanitizer_reports(directory: str) -> list[str]:
    """The SUMMARY line of every report a sanitizer wrote to ``directory``,
    one per finding, deduplicated."""
    summaries: list[str] = []
    for report in sorted(Path(directory).glob("report*")):
        for line in report.read_text(errors="replace").splitlines():
            if line.startswith("SUMMARY:") and line not in summaries:
                summaries.append(line)
    return summaries
