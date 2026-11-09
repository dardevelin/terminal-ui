#!/usr/bin/env python3
"""A driver records an app with ``terminalui.recording``: marks with holds
that take no real time, live spans that do, and a log whole when the
``with`` ends — on an error too.

The client is a stand-in that keeps the calls it is sent, so no app runs;
``test_record_cli.py`` drives the same verbs against a running one.

Run::

    python3 tools/tests/test_recording.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, Callable, Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui.cases import run_cases  # noqa: E402
from terminalui.client import RecordingInfo, RemoteError  # noqa: E402
from terminalui.recording import Recording, milliseconds  # noqa: E402
from terminalui.runner import app_environment  # noqa: E402


class FakeClient:
    """Answers the recording verbs as an app would, and keeps what it was
    sent, with the sleeps between, in order."""

    def __init__(self, calls: list[tuple[Any, ...]]):
        self.calls = calls
        self.marks = 0
        self.active = False

    def _info(self) -> RecordingInfo:
        return RecordingInfo(path="/x", frames=1, marks=self.marks, duration_ms=0, active=self.active)

    def record_start(self, path: Path, label: Optional[str] = None,
                     hold_ms: Optional[int] = None) -> RecordingInfo:
        self.calls.append(("start", str(path), label))
        self.active = True
        return self._info()

    def record_mark(self, label: str, hold_ms: Optional[int] = None) -> RecordingInfo:
        self.calls.append(("mark", label, hold_ms))
        self.marks += 1
        return self._info()

    def record_stop(self) -> RecordingInfo:
        self.calls.append(("stop",))
        self.active = False
        return self._info()


def recording(path: str = "walk.tuirec", label: Optional[str] = None) -> tuple[Recording, list[tuple[Any, ...]]]:
    calls: list[tuple[Any, ...]] = []
    client = FakeClient(calls)
    return Recording(client, path, label, sleep=lambda seconds: calls.append(("sleep", seconds))), calls  # type: ignore[arg-type]


def a_hold_is_written_in_whole_milliseconds() -> None:
    assert milliseconds(0.4) == 400
    assert milliseconds(1.5) == 1500
    assert milliseconds(0) == 0
    assert milliseconds(0.0005) == 1, "half a millisecond rounds up"
    assert milliseconds(0.0025) == 3, "not to even, as Python's round would"


def a_negative_hold_is_refused() -> None:
    try:
        milliseconds(-0.1)
    except ValueError:
        return
    raise AssertionError("a negative hold was accepted")


def the_with_starts_and_stops_the_recording() -> None:
    rec, calls = recording(label="start")
    with rec as entered:
        assert entered is rec
        rec.mark("toggle", hold=1.5)
    assert calls == [("start", str(Path("walk.tuirec").absolute()), "start"),
                     ("mark", "toggle", 1500), ("stop",)], calls
    assert rec.path.is_absolute(), "the app opens the path from its own directory"


def a_hold_marks_without_sleeping() -> None:
    rec, calls = recording()
    with rec:
        rec.hold(0.4)
        rec.hold(2, label="end")
    assert calls[1:] == [("mark", "hold-1", 400), ("mark", "end", 2000), ("stop",)], calls


def a_live_span_sleeps_between_two_marks() -> None:
    rec, calls = recording()
    with rec:
        rec.live(2.0, label="spinner")
        rec.live(0.5)
    assert calls[1:] == [("mark", "spinner", None), ("sleep", 2.0), ("mark", "spinner-end", None),
                         ("mark", "live-1", None), ("sleep", 0.5), ("mark", "live-1-end", None),
                         ("stop",)], calls


def stop_returns_the_logs_path_once() -> None:
    rec, calls = recording("/tmp/walk.tuirec")
    with rec:
        assert rec.stop() == Path("/tmp/walk.tuirec")
    assert calls.count(("stop",)) == 1, calls


def an_error_in_the_with_still_stops_and_is_not_hidden() -> None:
    rec, calls = recording()

    def failing_stop() -> RecordingInfo:
        calls.append(("stop",))
        raise RemoteError("record_stop: the app has gone")
    try:
        with rec:
            rec._client.record_stop = failing_stop  # type: ignore[method-assign]
            raise KeyError("the case's own failure")
    except KeyError:
        pass
    else:
        raise AssertionError("the case's error was swallowed")
    assert calls[-1] == ("stop",), calls


def an_app_being_recorded_is_told_its_terminal() -> None:
    host = {"PATH": "/usr/bin", "TERM": "xterm-ghostty", "COLORTERM": "no", "TERM_PROGRAM": "ghostty",
            "GHOSTTY_RESOURCES_DIR": "/x", "TERMINALUI_BUILD_DIR": ".build-automation/debug"}
    recorded = app_environment(host, {"XDG_CONFIG_HOME": "/c"}, inherit_terminal=False)
    assert recorded == {"PATH": "/usr/bin", "TERM": "xterm-256color", "COLORTERM": "truecolor",
                        "TERMINALUI_BUILD_DIR": ".build-automation/debug", "XDG_CONFIG_HOME": "/c"}, recorded


def otherwise_it_inherits_the_terminal_and_the_case_has_the_last_word() -> None:
    host = {"TERM": "xterm-ghostty", "TERM_PROGRAM": "ghostty"}
    assert app_environment(host, None, inherit_terminal=True) == host
    assert app_environment(host, {"TERM": "dumb"}, inherit_terminal=False)["TERM"] == "dumb"


CASES: list[tuple[str, Callable[[], None]]] = [
    ("a hold is written in whole milliseconds", a_hold_is_written_in_whole_milliseconds),
    ("a negative hold is refused", a_negative_hold_is_refused),
    ("the with starts and stops the recording", the_with_starts_and_stops_the_recording),
    ("a hold marks without sleeping", a_hold_marks_without_sleeping),
    ("a live span sleeps between two marks", a_live_span_sleeps_between_two_marks),
    ("stop returns the log's path once", stop_returns_the_logs_path_once),
    ("an error in the with still stops, and is not hidden", an_error_in_the_with_still_stops_and_is_not_hidden),
    ("an app being recorded is told its terminal", an_app_being_recorded_is_told_its_terminal),
    ("otherwise it inherits the terminal, and the case has the last word",
     otherwise_it_inherits_the_terminal_and_the_case_has_the_last_word),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
