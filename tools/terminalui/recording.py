"""Record a running debug app over its control socket.

A driver acts on the app through a ``Client`` and says, with marks, what a
picture made from the recording should show::

    with Recording(app, "walk.tuirec", label="start") as rec:
        app.send_key("down")
        rec.hold(0.4)        # the page the key opened, shown for 0.4s
        rec.live(2.0)        # two real seconds of what animates
    log = rec.stop()

The app answers each mark after every key sent before it is drawn, so a
mark needs no wait. A hold is a number written into the log, not a sleep:
the picture shows the screen that long however little real time passed,
so a long walk records in seconds. ``live`` does sleep, because what moves
on its own needs the time to move in.
"""

from __future__ import annotations

import math
import os
import time
from pathlib import Path
from types import TracebackType
from typing import Callable, Optional

from .client import Client, RecordingInfo, RemoteError

# What a terminal tells the programs it runs about itself. Passed on, an app
# recorded from iTerm2 saw `TERM_PROGRAM=iTerm.app` and chose iTerm2's inline
# images, which the terminal its picture shows does not draw.
HOST_TERMINAL_VARIABLES = {
    "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "TERMINFO",
    "LC_TERMINAL", "LC_TERMINAL_VERSION", "VTE_VERSION", "WT_SESSION", "WT_PROFILE_ID",
    "TMUX", "TMUX_PANE", "STY", "COLORFGBG",
}
HOST_TERMINAL_PREFIXES = ("ITERM_", "KITTY_", "WEZTERM_", "GHOSTTY_", "ALACRITTY_", "KONSOLE_")

# The terminal a recorded app is told it runs in: an xterm that draws 24-bit
# colour, which is what the pictures are rendered as.
RECORDING_TERMINAL = {"TERM": "xterm-256color", "COLORTERM": "truecolor"}

MILLISECONDS_PER_SECOND = 1000


def recording_environment(host: dict[str, str]) -> dict[str, str]:
    """The environment a recorded app runs with: the host's, less what
    describes the host's terminal, with ``COLORTERM`` saying 24-bit colour
    whatever the host's says. ``TERM`` is the caller's to set: vhs's ttyd
    sets its own."""
    environment = {key: value for key, value in host.items()
                   if key not in HOST_TERMINAL_VARIABLES and not key.startswith(HOST_TERMINAL_PREFIXES)}
    environment["COLORTERM"] = RECORDING_TERMINAL["COLORTERM"]
    return environment


def milliseconds(seconds: float) -> int:
    """``seconds`` as the whole milliseconds the log holds."""
    if seconds < 0:
        raise ValueError(f"a hold is a duration, at least 0, not {seconds}")
    # Half up, as `swtui record --hold` rounds, not Python's half to even.
    return math.floor(seconds * MILLISECONDS_PER_SECOND + 0.5)


class Recording:
    """A recording of the app ``client`` drives, written to ``path``, which
    must not exist yet; ``label`` marks its first frame. Started on entering
    the ``with``, stopped on leaving it — on an error too, so the log is
    whole for the post-mortem."""

    def __init__(self, client: Client, path: str | os.PathLike[str], label: Optional[str] = None,
                 *, sleep: Callable[[float], None] = time.sleep):
        self.path = Path(path).absolute()
        self.info: Optional[RecordingInfo] = None
        self._client = client
        self._label = label
        self._sleep = sleep
        self._unnamed = 0

    def __enter__(self) -> "Recording":
        self.info = self._client.record_start(self.path, label=self._label)
        return self

    def __exit__(self, kind: Optional[type[BaseException]], _error: Optional[BaseException],
                 _traceback: Optional[TracebackType]) -> None:
        if self.info is None or not self.info.active:
            return
        if kind is None:
            self.stop()
            return
        try:
            self.stop()
        except (OSError, RemoteError):
            pass  # the case's own error says more than this one would

    def mark(self, label: str, hold: Optional[float] = None) -> RecordingInfo:
        """Name the screen as the input sent so far left it. With ``hold``,
        in seconds, a picture shows it that long; without, it plays the
        time that really passes until the next mark."""
        self.info = self._client.record_mark(label, hold_ms=None if hold is None else milliseconds(hold))
        return self.info

    def hold(self, seconds: float, label: Optional[str] = None) -> RecordingInfo:
        """Show the screen as it is for ``seconds`` of the picture, without
        waiting them out."""
        return self.mark(label or self._name("hold"), hold=seconds)

    def live(self, seconds: float, label: Optional[str] = None) -> RecordingInfo:
        """Let ``seconds`` really pass between two marks, for what changes
        on its own — a spinner, a timer — to be recorded as it plays."""
        start = label or self._name("live")
        self.mark(start)
        self._sleep(seconds)
        return self.mark(f"{start}-end")

    def stop(self) -> Path:
        """End the recording; the path of its log."""
        self.info = self._client.record_stop()
        return self.path

    def _name(self, kind: str) -> str:
        self._unnamed += 1
        return f"{kind}-{self._unnamed}"
