#!/usr/bin/env python3
"""vhs must show what the framework drew: every Storybook page, in the
window the README records.

The README's pictures are recorded with vhs, which draws the app with
xterm.js in a headless browser, not with the terminal the harness drives.
The two can disagree about how wide a character is, what a box-drawing or
braille glyph covers, or where a cursor move lands, and a recording would
then show a frame the framework never drew. This walks every Storybook page
under vhs with the framework writing a text screenshot of each frame it
draws (``[trace] screenshots``), takes the screen xterm.js held after each
step (vhs's text output), and fails on any screen that is not one of the
framework's frames.

Run::

    python3 tools/scripts/check_vhs_compat.py [build_dir]

``build_dir`` holds a debug ``Storybook`` (default: ``TERMINALUI_BUILD_DIR``,
else ``.build/debug``). Needs vhs, with ttyd and ffmpeg. Exit 0 when every
screen matches, 1 otherwise.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from record_media import recording_environment  # noqa: E402
from terminalui.runner import DEFAULT_BUILD_DIR  # noqa: E402
from terminalui.storybook import pages  # noqa: E402
from terminalui.tutorial import REPO_ROOT  # noqa: E402

DEMO_TAPE = REPO_ROOT / "assets" / "demo.tape"

# vhs's text output separates the screens it records with this line.
SCREEN_SEPARATOR = "─" * 80

# Long enough for a page's first frame to be drawn and reach xterm.js.
DWELL = "Sleep 400ms"

# Tracing every frame to text, into the project the walk runs from; no
# socket, whose path under a temporary directory outgrows a socket address.
DIAGNOSTICS = """\
[trace]
enabled = true
screenshots = true
events = false
frame_limit = 1000000

[output]
use_tmp = false

[socket]
enabled = false
"""

Screen = tuple[str, ...]


def window_settings(tape: str) -> str:
    """The README tape's window: its font, size and padding, so the walk
    runs in the terminal the README is recorded in."""
    keys = ("FontSize", "Width", "Height", "Padding")
    return "".join(line + "\n" for line in tape.splitlines()
                   if line.startswith("Set ") and line.split()[1] in keys)


def walk_tape(settings: str, app: Path, pages: int, output: Path) -> str:
    """Launch the app, step through every page, then quit."""
    steps = "".join(f"Down\n{DWELL}\n" for _ in range(pages - 1))
    return (f'Output "{output}"\n{settings}Hide\nType `{app}`\nEnter\nSleep 2s\nShow\n{DWELL}\n'
            + steps + "Hide\nEscape\nSleep 1s\n")


def normalised(lines: list[str]) -> Screen:
    """A screen as both sides can state it: vhs drops trailing spaces and
    the framework writes every cell."""
    stripped = [line.rstrip() for line in lines]
    while stripped and not stripped[-1]:
        stripped.pop()
    return tuple(stripped)


def recorded_screens(text: str, rows: int) -> list[Screen]:
    """The screens vhs recorded while the app was on the alternate screen:
    those exactly as tall as the window. The shell's, before and after,
    carry its scrollback too."""
    screens: list[list[str]] = [[]]
    for line in text.split("\n"):
        if line == SCREEN_SEPARATOR:
            screens.append([])
        else:
            screens[-1].append(line)
    return [normalised(screen) for screen in screens if len(screen) == rows]


def framework_frames(screenshot_dir: Path) -> tuple[dict[Screen, int], int]:
    """Every frame the framework drew, by screen, with the window's height."""
    frames: dict[Screen, int] = {}
    rows = 0
    for path in sorted(screenshot_dir.glob("frame_*.txt")):
        header, _, body = path.read_text().partition("---\n")
        rows = int(header.split("size: ")[1].split("x")[1])
        frames.setdefault(normalised(body.split("\n")), int(path.stem.removeprefix("frame_")))
    return frames, rows


def mismatches(screens: list[Screen], frames: dict[Screen, int]) -> list[str]:
    """Each recorded screen no frame matches, against the frame nearest it."""
    reports: list[str] = []
    for index, screen in enumerate(screens):
        if screen in frames:
            continue
        nearest = max(frames, key=lambda frame: sum(a == b for a, b in zip(frame, screen)))
        rows = [f"  row {row}\n    drawn : {drawn!r}\n    vhs   : {shown!r}"
                for row, (drawn, shown) in enumerate(zip(nearest + ("",) * len(screen),
                                                         screen + ("",) * len(nearest)))
                if drawn != shown]
        reports.append(f"screen {index} matches no frame; nearest is frame {frames[nearest]}:\n"
                       + "\n".join(rows))
    return reports


def main() -> int:
    build_dir = Path(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_BUILD_DIR)
    app = (REPO_ROOT / build_dir / "Storybook").resolve()
    if not app.exists():
        print(f"no Storybook in {build_dir}: build it first", file=sys.stderr)
        return 1
    page_count = len(pages())
    with tempfile.TemporaryDirectory(prefix="terminalui-vhs-") as project:
        root = Path(project)
        (root / ".terminalui").mkdir()
        (root / ".terminalui" / "terminalui.toml").write_text(DIAGNOSTICS)
        output = root / "screens.txt"
        tape = root / "walk.tape"
        tape.write_text(walk_tape(window_settings(DEMO_TAPE.read_text()), app, page_count, output))
        subprocess.run(["vhs", str(tape)], cwd=root, check=True, capture_output=True,
                       env=recording_environment(dict(os.environ)))
        frames, rows = framework_frames(root / ".terminalui" / "screenshots")
        screens = recorded_screens(output.read_text(), rows)
    reports = mismatches(screens, frames)
    for report in reports:
        print(report)
    print(f"{len(screens) - len(reports)}/{len(screens)} screens vhs showed are frames the "
          f"framework drew ({len(frames)} distinct frames, {page_count} pages)")
    return 1 if reports or not screens else 0


if __name__ == "__main__":
    sys.exit(main())
