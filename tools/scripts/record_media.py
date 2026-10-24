#!/usr/bin/env python3
"""Record every picture the documentation shows, from the code it shows.

The tutorial's previews, chapter GIFs and chapter cards were made by hand,
with no script kept: once the framework changed how the apps draw, nobody
could make them again, and they went on showing the old framework. Each one
is now made here, from the tutorial's own code steps and the tapes under
``tools/recordings/``.

- **Previews**, ``preview-<step>.png``: each code step, built and run under
  vhs, driven by the keys ``tools/terminalui/tutorial.py`` lists for it into
  the state its caption describes, then captured.
- **Chapter GIFs**, ``demo-ch<N>.gif``: ``tools/recordings/demo-ch<N>.tape``.
- **Chapter cards**, ``card-ch<N>.png``: a chapter's preview, framed, with
  the fox in its corner.
- **README GIFs**: ``assets/demo.tape`` and ``assets/debug.tape``.

The steps are built as one package of executables in
``.build-recordings/tutorial``, as ``tools/terminalui/tutorial.py`` writes
it, against this checkout.

Run::

    python3 tools/scripts/record_media.py [previews|gifs|cards|readme|all] [--only STEP]

Needs vhs (with ttyd and ffmpeg) and ImageMagick.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui.tutorial import (  # noqa: E402
    REPO_ROOT, RESOURCES, STEPS, Action, Loaded, Press, Step, Type, binary_name, build,
)

RECORDINGS = REPO_ROOT / "tools" / "recordings"
WORK = REPO_ROOT / ".build-recordings"
TUTORIAL_PACKAGE = WORK / "tutorial"
STEP_BINARIES = TUTORIAL_PACKAGE / ".build" / "release"

# One look for every tutorial picture: the size the tutorial pages lay them
# out at, and the palette the README's recordings use.
TUTORIAL_SETTINGS = """\
Set Shell "bash"
Set FontSize 18
Set Width 760
Set Height 460
Set Padding 12
Set Theme "Catppuccin Mocha"
"""

# How long an app has to draw its first frame, and how long the screen is
# left to settle after each key, before anything is captured.
LAUNCH = "Sleep 1.5s"
SETTLE = "Sleep 300ms"
# Long enough for the four-second load chapters 6 and 7 simulate.
LOADED = "Sleep 4s"

# vhs's names for the keys the steps are driven with.
VHS_KEYS = {"down": "Down", "up": "Up", "enter": "Enter", "space": "Space",
            "backspace": "Backspace", "tab": "Tab", "escape": "Escape"}
VHS_MODIFIERS = {"shift": "Shift", "ctrl": "Ctrl", "alt": "Alt"}


def vhs_command(action: Action) -> str:
    """One of a step's actions as a vhs command. A preview is driven by
    keys alone: vhs cannot click."""
    if isinstance(action, Press):
        return "+".join([VHS_MODIFIERS[modifier] for modifier in action.modifiers]
                        + [VHS_KEYS[action.key]])
    if isinstance(action, Type):
        return f'Type "{action.text}"'
    if isinstance(action, Loaded):
        return LOADED
    raise ValueError(f"a preview cannot be driven by {action}")


# Chapter 7's last step saves its tasks to this file and loads them on the
# next launch, so a recording starts by removing it — or it records
# whatever the last run left — and removes it again after.
SAVED_TASKS = '"$HOME/Library/Application Support/tasks-tutorial.json"'
STARTS_FRESH = {"tasks7-03-01"}

# The card frame: a chapter's preview inset on a transparent canvas, corners
# rounded, the fox in the corner beside it, clear of the app's title.
CARD_SIZE = (832, 532)
CARD_INSET = 36
CARD_RADIUS = 18
FOX_WIDTH = 48
FOX_OFFSET = (2, 0)

# The step each chapter's card shows: its last, except where the chapter's
# picture in the table of contents is an earlier screen — chapter 3's card
# is the split view, not the Settings tab its last step ends on, and
# chapter 6's the confirmation dialog.
CARD_STEP = {
    1: "tasks-04-01",
    2: "tasks2-03-01",
    3: "tasks3-02-01",
    4: "tasks4-03-01",
    5: "tasks5-03-01",
    6: "tasks6-01-01",
    7: "tasks7-03-01",
}


def run(command: list[str], cwd: Path = REPO_ROOT) -> None:
    print("$", " ".join(command), flush=True)
    subprocess.run(command, cwd=cwd, check=True)


def vhs(tape: str, name: str) -> None:
    path = WORK / "tapes" / f"{name}.tape"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(tape)
    run(["vhs", str(path)])


def shrink(png: Path) -> None:
    if not png.exists():
        raise SystemExit(f"vhs wrote no {png.name}")
    """A terminal frame holds a handful of colours; an indexed PNG of it is
    a fraction of the size, and the docs ship every one."""
    run(["magick", str(png), "-colors", "128", f"PNG8:{png}"])


def record_preview(step: Step) -> None:
    keys = "".join(f"{vhs_command(action)}\n{SETTLE}\n" for action in step.preview_keys())
    output = RESOURCES / f"preview-{step.name}.png"
    # Removed first, so a shot vhs fails to take cannot leave the old picture
    # in place looking new.
    output.unlink(missing_ok=True)
    fresh = f"Type `rm -f {SAVED_TASKS}`\nEnter\n" if step.name in STARTS_FRESH else ""
    vhs(f'Output "{WORK / "frames" / (step.name + ".gif")}"\n' + TUTORIAL_SETTINGS
        + "Hide\n" + fresh
        + f'Type "{STEP_BINARIES / binary_name(step.name)}"\nEnter\n{LAUNCH}\n'
        + keys
        # vhs takes the shot from the next frame it records: hidden at
        # once, there is no next frame and the file is never written.
        + f'Show\n{SETTLE}\nScreenshot "{output}"\n{SETTLE}\n'
        + "Hide\nCtrl+C\nSleep 300ms\n" + fresh, f"preview-{step.name}")
    shrink(output)


def record_gif(chapter: int) -> None:
    run(["vhs", str(RECORDINGS / f"demo-ch{chapter}.tape")])


def make_card(chapter: int) -> None:
    preview = RESOURCES / f"preview-{CARD_STEP[chapter]}.png"
    card = RESOURCES / f"card-ch{chapter}.png"
    width, height = CARD_SIZE
    fox = WORK / "fox.png"
    run(["magick", "-background", "none", "-density", "300", str(REPO_ROOT / "assets" / "logo.svg"),
         "-resize", f"{FOX_WIDTH}x", str(fox)])
    preview_width, preview_height = width - 2 * CARD_INSET, height - 2 * CARD_INSET
    run(["magick", str(preview), "-alpha", "set",
         "(", "-size", f"{preview_width}x{preview_height}", "xc:none", "-fill", "white",
         "-draw", f"roundrectangle 0,0 {preview_width - 1},{preview_height - 1} {CARD_RADIUS},{CARD_RADIUS}", ")",
         "-compose", "DstIn", "-composite",
         # -extent places the image by the compose mode in force: put back
         # Over, or DstIn clears it against the transparent canvas.
         "-compose", "Over",
         "-background", "none", "-gravity", "center", "-extent", f"{width}x{height}",
         "-gravity", "northwest", str(fox), "-geometry", f"+{FOX_OFFSET[0]}+{FOX_OFFSET[1]}",
         "-compose", "Over", "-composite", str(card)])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("what", nargs="?", default="all",
                        choices=["previews", "gifs", "cards", "readme", "all"])
    parser.add_argument("--only", help="one step (tasks2-03-01) or chapter number")
    parser.add_argument("--no-build", action="store_true", help="reuse the last build of the steps")
    args = parser.parse_args()

    if args.what in ("previews", "gifs", "cards", "all") and not args.no_build:
        build(TUTORIAL_PACKAGE, "release")
    if args.what in ("previews", "all"):
        for step in STEPS:
            if args.only in (None, step.name):
                record_preview(step)
    if args.what in ("gifs", "all"):
        for chapter in CARD_STEP:
            if args.only in (None, str(chapter)):
                record_gif(chapter)
    if args.what in ("cards", "all"):
        for chapter in CARD_STEP:
            if args.only in (None, str(chapter)):
                make_card(chapter)
    if args.what in ("readme", "all"):
        # Apart from .build, whose lock a developer's own `swift run` holds.
        run(["swift", "build", "-c", "release", "--scratch-path", str(WORK / "app")])
        run(["swift", "build", "--scratch-path", str(WORK / "app")])
        run(["vhs", "assets/demo.tape"])
        run(["vhs", "assets/debug.tape"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
