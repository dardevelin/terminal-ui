#!/usr/bin/env python3
"""The vhs check must compare what vhs showed with what the framework drew,
and object to a screen the framework never drew.

``check_vhs_compat.py`` needs vhs and a build to run at all; what it
concludes from their output is tested here, on output written by hand.

Run::

    python3 tools/tests/test_vhs_compat.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import check_vhs_compat as check  # noqa: E402
from terminalui.cases import run_cases  # noqa: E402

SEPARATOR = check.SCREEN_SEPARATOR


def screens_are_the_window_tall_ones() -> None:
    shell = ["> ", "", "", ""]
    app_one = ["top  ", "mid", ""]
    app_two = ["top", "end", ""]
    text = "\n".join(shell + [SEPARATOR] + app_one + [SEPARATOR] + app_two + [SEPARATOR] + shell)
    assert check.recorded_screens(text, rows=3) == [("top", "mid"), ("top", "end")], \
        check.recorded_screens(text, rows=3)


def frames_are_read_as_drawn() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "frame_0000.txt").write_text("frame: 0\nsize: 5x3\n---\ntop  \nmid  \n     \n")
        (root / "frame_0001.txt").write_text("frame: 1\nsize: 5x3\n---\ntop  \nmid  \n     \n")
        (root / "frame_0002.txt").write_text("frame: 2\nsize: 5x3\n---\ntop  \nend  \n     \n")
        frames, rows = check.framework_frames(root)
    assert rows == 3, rows
    assert frames == {("top", "mid"): 0, ("top", "end"): 2}, frames


def a_screen_the_framework_drew_passes() -> None:
    frames = {("top", "mid"): 0, ("top", "end"): 2}
    assert check.mismatches([("top", "mid"), ("top", "end")], frames) == []


def a_screen_it_never_drew_is_reported_against_the_nearest_frame() -> None:
    frames = {("top", "mid"): 0, ("other", "rows"): 1}
    reports = check.mismatches([("top", "m i d")], frames)
    assert len(reports) == 1, reports
    assert "nearest is frame 0" in reports[0], reports[0]
    assert "row 1" in reports[0] and "'mid'" in reports[0] and "'m i d'" in reports[0], reports[0]
    assert "row 0" not in reports[0], reports[0]


def a_screen_caught_between_two_frames_passes() -> None:
    # Frame 1's first row arrived, its second had not: the top of the new
    # frame over the bottom of the old.
    sequence = [("aaaa", "bbbb"), ("cccc", "dddd"), ("eeee", "ffff")]
    frames = {screen: index for index, screen in enumerate(sequence)}
    assert check.mismatches([("cccc", "bbbb"), ("ccaa", "bbbb"), ("eecc", "dddd")], frames, sequence) == []


def a_screen_mixing_frames_not_drawn_in_turn_is_reported() -> None:
    sequence = [("aaaa", "bbbb"), ("cccc", "dddd"), ("eeee", "ffff")]
    frames = {screen: index for index, screen in enumerate(sequence)}
    [report] = check.mismatches([("aaaa", "ffff")], frames, sequence)
    assert "matches no frame" in report, report


def a_shifted_row_is_reported_even_between_frames() -> None:
    # A character xterm.js draws wider than the framework shifts the rest
    # of its row, which neither frame shows.
    sequence = [("ab─cd", "....."), ("xy─zw", ".....")]
    frames = {screen: index for index, screen in enumerate(sequence)}
    [report] = check.mismatches([("xy─ zw", ".....")], frames, sequence)
    assert "row 0" in report, report


def the_walk_visits_every_page_in_the_readme_window() -> None:
    settings = check.window_settings('Output "x.gif"\nSet FontSize 15\nSet Theme "Mocha"\n'
                                     "Set Width 1020\nSet Height 700\nSet Padding 12\nHide\n")
    assert settings == "Set FontSize 15\nSet Width 1020\nSet Height 700\nSet Padding 12\n", settings
    tape = check.walk_tape(settings, Path("/bin/app"), pages=4, output=Path("/tmp/out.txt"))
    assert tape.count("\nDown\n") == 3, tape
    assert tape.startswith('Output "/tmp/out.txt"\n'), tape
    assert "Type `/bin/app`" in tape and tape.rstrip().endswith("Sleep 1s"), tape


CASES: list[tuple[str, Callable[[], None]]] = [
    ("screens are the window-tall ones", screens_are_the_window_tall_ones),
    ("frames are read as drawn", frames_are_read_as_drawn),
    ("a screen the framework drew passes", a_screen_the_framework_drew_passes),
    ("a screen it never drew is reported against the nearest frame",
     a_screen_it_never_drew_is_reported_against_the_nearest_frame),
    ("a screen caught between two frames passes", a_screen_caught_between_two_frames_passes),
    ("a screen mixing frames not drawn in turn is reported", a_screen_mixing_frames_not_drawn_in_turn_is_reported),
    ("a shifted row is reported even between frames", a_shifted_row_is_reported_even_between_frames),
    ("the walk visits every page in the README window", the_walk_visits_every_page_in_the_readme_window),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
