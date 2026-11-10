#!/usr/bin/env python3
"""A recording must describe the terminal it is made in: vhs's; and a
showcase GIF must be the chapter whole, at the speed it plays.

vhs runs its shell under ttyd and draws it with xterm.js, but the shell
inherits everything the terminal ``record_media.py`` was started from put in
the environment. An app recorded from iTerm2 then saw ``TERM_PROGRAM=iTerm.app``
and chose iTerm2's inline images, which xterm.js does not draw.

Run::

    python3 tools/tests/test_record_media.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import record_media  # noqa: E402
from terminalui.cases import run_cases  # noqa: E402


def the_host_terminal_is_not_passed_on() -> None:
    host = {
        "TERM_PROGRAM": "iTerm.app", "TERM_PROGRAM_VERSION": "3.5", "TERM_SESSION_ID": "w0t0p0",
        "LC_TERMINAL": "iTerm2", "LC_TERMINAL_VERSION": "3.5", "ITERM_SESSION_ID": "w0t0p0",
        "ITERM_PROFILE": "Default", "TERMINFO": "/Applications/Ghostty.app/terminfo",
        "GHOSTTY_RESOURCES_DIR": "/x", "KITTY_WINDOW_ID": "1", "WEZTERM_PANE": "0",
        "ALACRITTY_WINDOW_ID": "1", "KONSOLE_VERSION": "230", "VTE_VERSION": "7600",
        "WT_SESSION": "id", "TMUX": "/tmp/tmux", "TMUX_PANE": "%1", "STY": "1.pts",
        "COLORFGBG": "15;0",
    }
    environment = record_media.recording_environment(host)
    assert not set(host) & set(environment), sorted(set(host) & set(environment))


def everything_else_is_kept() -> None:
    host = {"PATH": "/usr/bin", "HOME": "/Users/me", "LANG": "en_US.UTF-8",
            "TERMINALUI_BUILD_DIR": ".build-automation/debug", "TERM_PROGRAM": "ghostty"}
    environment = record_media.recording_environment(host)
    assert {key: environment[key] for key in ("PATH", "HOME", "LANG", "TERMINALUI_BUILD_DIR")} == \
        {key: host[key] for key in ("PATH", "HOME", "LANG", "TERMINALUI_BUILD_DIR")}, environment


def colour_is_what_vhs_draws() -> None:
    assert record_media.recording_environment({})["COLORTERM"] == "truecolor"
    assert record_media.recording_environment({"COLORTERM": "no"})["COLORTERM"] == "truecolor"


SHOWCASE_SOURCES = {"3d": "SceneChapter.swift", "canvas": "CanvasChapter.swift"}
CHAPTER_DURATION = re.compile(r"static let duration = ([0-9.]+)")
TAPE_SLEEP = re.compile(r"^Show\nSleep ([0-9.]+)s$", re.MULTILINE)
# What the tape may leave off a chapter, or run past it, in the chapter's
# own seconds: under a frame or two.
CHAPTER_SLACK = 0.25


def showcase_tape(chapter: str) -> str:
    return (record_media.REPO_ROOT / "assets" / f"{chapter}.tape").read_text()


def each_showcase_tape_records_its_chapter_whole() -> None:
    for chapter, source in SHOWCASE_SOURCES.items():
        tape = showcase_tape(chapter)
        pace = record_media.showcase_pace(tape)
        assert 0 < pace <= 1, (chapter, pace)
        assert f"TERMINALUI_SHOWCASE={chapter} " in tape, chapter
        swift = (record_media.REPO_ROOT / "Examples" / "Showcase" / source).read_text()
        duration = float(CHAPTER_DURATION.search(swift).group(1))
        recorded = float(TAPE_SLEEP.search(tape).group(1)) * pace
        assert abs(recorded - duration) <= CHAPTER_SLACK, (chapter, recorded, duration)


def captured(times: list[float]) -> Path:
    folder = Path(tempfile.mkdtemp())
    for index, moment in enumerate(times):
        frame = folder / f"frame-text-{index + 1:05d}.png"
        frame.write_bytes(b"")
        os.utime(frame, (moment, moment))
    return folder


def a_frame_lasts_as_long_as_it_was_on_screen_at_the_apps_pace() -> None:
    folder = captured([100.0, 100.1, 100.15, 100.25])
    timed = record_media.showcase_frames(folder, 0.25)
    assert [path.name for path, _ in timed] == sorted(path.name for path in folder.iterdir()), timed
    assert [round(seconds, 4) for _, seconds in timed] == [0.025, 0.0125, 0.025, 0.025], timed


def a_recorder_that_fell_behind_is_refused() -> None:
    # At a quarter speed the app draws a frame every fifth of a second; a
    # capture that waited longer missed one.
    folder = captured([100.0, 100.1, 100.35])
    try:
        record_media.showcase_frames(folder, 0.25)
    except SystemExit as refusal:
        assert "fell behind" in str(refusal), refusal
    else:
        raise AssertionError("a recording that missed a frame was accepted")


CASES: list[tuple[str, Callable[[], None]]] = [
    ("the host terminal is not passed on", the_host_terminal_is_not_passed_on),
    ("everything else is kept", everything_else_is_kept),
    ("colour is what vhs draws", colour_is_what_vhs_draws),
    ("each showcase tape records its chapter whole", each_showcase_tape_records_its_chapter_whole),
    ("a frame lasts as long as it was on screen, at the app's pace",
     a_frame_lasts_as_long_as_it_was_on_screen_at_the_apps_pace),
    ("a recorder that fell behind is refused", a_recorder_that_fell_behind_is_refused),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
