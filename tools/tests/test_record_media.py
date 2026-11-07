#!/usr/bin/env python3
"""A recording must describe the terminal it is made in: vhs's.

vhs runs its shell under ttyd and draws it with xterm.js, but the shell
inherits everything the terminal ``record_media.py`` was started from put in
the environment. An app recorded from iTerm2 then saw ``TERM_PROGRAM=iTerm.app``
and chose iTerm2's inline images, which xterm.js does not draw.

Run::

    python3 tools/tests/test_record_media.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import sys
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


CASES: list[tuple[str, Callable[[], None]]] = [
    ("the host terminal is not passed on", the_host_terminal_is_not_passed_on),
    ("everything else is kept", everything_else_is_kept),
    ("colour is what vhs draws", colour_is_what_vhs_draws),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
