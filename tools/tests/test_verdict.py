#!/usr/bin/env python3
"""The runner objects to every way an app can end badly, and to no other.

A verdict that stopped objecting would pass every case in every suite, so
each objection in ``terminalui.verdict``, and each exception to it, is
pinned here. The smoke suite proves two of them end to end against a live
app.

Run::

    python3 tools/tests/test_verdict.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import signal
import sys
import tempfile
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui import verdict  # noqa: E402
from terminalui.cases import run_cases  # noqa: E402

ALTERNATE_SCREEN_ON = b"\x1b[?1049h"
ALTERNATE_SCREEN_OFF = b"\x1b[?1049l"
CURSOR_HIDDEN = b"\x1b[?25l"
CURSOR_SHOWN = b"\x1b[?25h"
RESTORED = ALTERNATE_SCREEN_ON + CURSOR_HIDDEN + ALTERNATE_SCREEN_OFF + CURSOR_SHOWN


# An app stopped by SIGTERM that restored its terminal and removed its dir.
CLEAN_STOP = dict(returncode=-signal.SIGTERM, had_to_kill=False, stopped_by_sigterm=True,
                  output=RESTORED, sanitizer_reports=[], expected_signal=None)


def objections(**ending: object) -> list[str]:
    """The runner's objections to an app that ended as ``ending`` says, and
    otherwise as a clean stop."""
    return verdict.exit_problems(**{**CLEAN_STOP, **ending})


def objects_once(problems: list[str], phrase: str) -> None:
    assert len(problems) == 1 and phrase in problems[0], problems


def a_clean_stop_passes() -> None:
    assert objections() == []


def an_app_that_quit_by_itself_passes() -> None:
    assert objections(returncode=0, stopped_by_sigterm=False) == []


def an_app_that_had_to_be_killed_fails() -> None:
    objects_once(objections(returncode=-signal.SIGKILL, had_to_kill=True, stopped_by_sigterm=False),
                 "ignored SIGTERM")


def a_crash_fails() -> None:
    objects_once(objections(returncode=-signal.SIGSEGV, stopped_by_sigterm=False), "crashed on SIGSEGV")


def a_failing_exit_status_fails() -> None:
    objects_once(objections(returncode=3, stopped_by_sigterm=False), "exited with status 3")


def exiting_zero_on_sigterm_fails() -> None:
    objects_once(objections(returncode=0), "exited 0 on SIGTERM")


def the_expected_death_passes() -> None:
    assert objections(returncode=-signal.SIGSEGV, stopped_by_sigterm=False,
                   expected_signal=signal.SIGSEGV) == []


def surviving_an_expected_death_fails() -> None:
    objects_once(objections(returncode=0, stopped_by_sigterm=False, expected_signal=signal.SIGSEGV),
                 "expected to die on SIGSEGV")


def a_sanitizer_report_of_the_expected_signal_passes() -> None:
    report = "SUMMARY: ThreadSanitizer: SEGV on unknown address (Storybook+0x1234)"
    assert objections(returncode=-signal.SIGABRT, stopped_by_sigterm=False,
                   sanitizer_reports=[report], expected_signal=signal.SIGSEGV) == []


def a_sanitizer_report_fails() -> None:
    report = "SUMMARY: ThreadSanitizer: data race (Storybook+0x1234) in Recorder.append"
    assert objections(sanitizer_reports=[report]) == [report]


def a_data_dir_left_after_a_stop_fails() -> None:
    objects_once(objections(leftover_dir="/tmp/terminalui-x-1"), "left its data dir /tmp/terminalui-x-1")


def a_data_dir_left_by_a_crash_passes() -> None:
    assert objections(returncode=-signal.SIGSEGV, stopped_by_sigterm=False,
                   expected_signal=signal.SIGSEGV, leftover_dir="/tmp/terminalui-x-1") == []


def a_mode_left_on_fails() -> None:
    objects_once(objections(output=ALTERNATE_SCREEN_ON + CURSOR_HIDDEN + CURSOR_SHOWN),
                 "left DEC mode 1049 on")


def a_hidden_cursor_left_hidden_fails() -> None:
    objects_once(objections(output=CURSOR_SHOWN + CURSOR_HIDDEN), "left DEC mode 25 off")


def a_mode_turned_back_on_after_its_reset_fails() -> None:
    objects_once(objections(output=RESTORED + ALTERNATE_SCREEN_ON), "left DEC mode 1049 on")


def modes_are_not_checked_once_the_terminal_is_gone() -> None:
    assert objections(output=ALTERNATE_SCREEN_ON, terminal_gone=True) == []


def every_report_file_is_read_once_per_finding() -> None:
    race = "SUMMARY: ThreadSanitizer: data race in Recorder.append"
    with tempfile.TemporaryDirectory() as directory:
        Path(directory, "report.101").write_text(f"WARNING: ThreadSanitizer\n{race}\n")
        Path(directory, "report.102").write_text(f"{race}\nSUMMARY: ThreadSanitizer: SEGV\n")
        Path(directory, "unrelated.log").write_text("SUMMARY: not a report\n")
        assert verdict.read_sanitizer_reports(directory) == [race, "SUMMARY: ThreadSanitizer: SEGV"]


def a_binary_names_its_sanitizer() -> None:
    with tempfile.TemporaryDirectory() as directory:
        plain, sanitized = Path(directory, "plain"), Path(directory, "sanitized")
        plain.write_bytes(b"_main")
        sanitized.write_bytes(b"__tsan_init")
        assert verdict.sanitizer_of(plain) is None
        assert verdict.sanitizer_of(sanitized) == "thread"


CASES: list[tuple[str, Callable[[], None]]] = [
    ("a clean stop passes", a_clean_stop_passes),
    ("an app that quit by itself passes", an_app_that_quit_by_itself_passes),
    ("an app that had to be killed fails", an_app_that_had_to_be_killed_fails),
    ("a crash fails", a_crash_fails),
    ("a failing exit status fails", a_failing_exit_status_fails),
    ("exiting 0 on SIGTERM fails", exiting_zero_on_sigterm_fails),
    ("the expected death passes", the_expected_death_passes),
    ("surviving an expected death fails", surviving_an_expected_death_fails),
    ("a sanitizer report of the expected signal passes", a_sanitizer_report_of_the_expected_signal_passes),
    ("a sanitizer report fails", a_sanitizer_report_fails),
    ("a data dir left after a stop fails", a_data_dir_left_after_a_stop_fails),
    ("a data dir left by a crash passes", a_data_dir_left_by_a_crash_passes),
    ("a mode left on fails", a_mode_left_on_fails),
    ("a hidden cursor left hidden fails", a_hidden_cursor_left_hidden_fails),
    ("a mode turned back on after its reset fails", a_mode_turned_back_on_after_its_reset_fails),
    ("modes are not checked once the terminal is gone", modes_are_not_checked_once_the_terminal_is_gone),
    ("every report file is read, once per finding", every_report_file_is_read_once_per_finding),
    ("a binary names its sanitizer", a_binary_names_its_sanitizer),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
