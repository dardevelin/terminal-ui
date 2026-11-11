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
- **README GIFs**: ``assets/demo.tape`` and ``assets/debug.tape``, once
  ``check_vhs_compat.py`` has shown vhs draws every Storybook page as the
  framework does.
- **The maps films**, ``assets/maps.gif`` and ``assets/maps-3d.gif``:
  ``assets/maps.tape`` and ``assets/maps-3d.tape``, the Maps example on its
  sample town — the second its 3D view — copied into TerminalUIMaps'
  documentation catalog as well. Not Storybook pages, so outside
  ``check_vhs_compat.py``.
- **Showcase GIFs**: ``assets/3d.tape`` and ``assets/canvas.tape``, the
  ``Showcase`` example's chapters, from vhs's frames (see
  ``record_showcase``).

The steps are built as one package of executables in
``.build-recordings/tutorial``, as ``tools/terminalui/tutorial.py`` writes
it, against this checkout.

Run::

    python3 tools/scripts/record_media.py [previews|gifs|cards|readme|maps|showcase|all] [--only STEP|CHAPTER]

Needs vhs (with ttyd and ffmpeg) and ImageMagick.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui.tutorial import (  # noqa: E402
    REPO_ROOT, RESOURCES, STEPS, Action, Loaded, Press, Step, Type, binary_name, build,
)
# vhs's shell inherits the environment of the terminal this script was
# started in, and an app would then detect that terminal's features rather
# than xterm.js's; ttyd sets `TERM` itself.
from terminalui.recording import recording_environment  # noqa: E402

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


def run(command: list[str], cwd: Path = REPO_ROOT, env: dict[str, str] | None = None) -> None:
    print("$", " ".join(command), flush=True)
    subprocess.run(command, cwd=cwd, check=True, env=env)


def run_vhs(tape: Path | str) -> None:
    run(["vhs", str(tape)], env=recording_environment(dict(os.environ)))


def vhs(tape: str, name: str) -> None:
    path = WORK / "tapes" / f"{name}.tape"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(tape)
    run_vhs(path)


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
    run_vhs(RECORDINGS / f"demo-ch{chapter}.tape")


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


# Where the maps film is shown besides the README: the getting-started
# article of TerminalUIMaps' catalog, which embeds it by name.
MAPS_DOCS = REPO_ROOT / "Sources" / "TerminalUIMaps" / "TerminalUIMaps.docc" / "Resources"
# The 3D view's film, made from vhs's frames: its shaded buildings take
# hundreds of colours, which vhs's own encoder dithers.
MAPS_3D_FRAMES = WORK / "maps-3d"


def record_maps() -> None:
    """The Maps example's films — the town, and its 3D view — from its
    release build, recorded, and copied into the documentation catalog."""
    # Apart from .build, whose lock a developer's own `swift run` holds.
    run(["swift", "build", "-c", "release", "--product", "Maps", "--scratch-path", str(WORK / "app")])
    MAPS_DOCS.mkdir(parents=True, exist_ok=True)
    run_vhs("assets/maps.tape")
    shutil.copyfile(REPO_ROOT / "assets" / "maps.gif", MAPS_DOCS / "maps.gif")
    shutil.rmtree(MAPS_3D_FRAMES, ignore_errors=True)
    run_vhs("assets/maps-3d.tape")
    output = REPO_ROOT / "assets" / "maps-3d.gif"
    showcase_gif(captured_frames(MAPS_3D_FRAMES), ShowcaseEncoding(frame_rate="10", colours=128), output)
    print(f"{output.relative_to(REPO_ROOT)}: {output.stat().st_size / 1e6:.2f} MB", flush=True)
    shutil.copyfile(output, MAPS_DOCS / "maps-3d.gif")
# The Showcase example's chapters, each recorded as its own GIF.
#
# vhs's GIF will not do for them. Its browser terminal takes up to a quarter
# of a second to capture a frame of a thousand colours, so at the app's own
# pace it falls behind, drops frames and plays the rest too fast; and its
# encoder dithers, which turned twenty seconds of 3D into 11 MB. So each tape
# plays the app at the pace its TERMINALUI_SHOWCASE_PACE names, an eighth of
# its speed, and keeps vhs's frames rather than a GIF, and the GIF is made
# here: each frame held for as long as it was on screen, scaled back to life,
# sampled at the chapter's frame rate, in one palette with no dither.
SHOWCASE_FRAMES = WORK / "showcase"


@dataclass(frozen=True)
class ShowcaseEncoding:
    """How a chapter's GIF is sampled. GIF delays are whole hundredths of a
    second, so a frame rate is 100 over a whole number: twenty a second is
    five hundredths, 16⅔ six."""
    frame_rate: str
    colours: int


# The 3D chapter changes nearly every pixel on nearly every frame, and at
# twenty frames a second in 256 colours it came to 4.4 MB; the canvas
# changes a few columns at a time, and keeps both.
SHOWCASE_CHAPTERS = {
    "3d": ShowcaseEncoding(frame_rate="50/3", colours=192),
    "canvas": ShowcaseEncoding(frame_rate="20", colours=256),
}
# The app draws twenty frames to a second of its own time.
SHOWCASE_APP_FRAME_RATE = 20
PACE = re.compile(r"TERMINALUI_SHOWCASE_PACE=([0-9.]+)")


def showcase_pace(tape: str) -> float:
    match = PACE.search(tape)
    if not match:
        raise SystemExit("a showcase tape must set TERMINALUI_SHOWCASE_PACE")
    return float(match.group(1))


def showcase_frames(frames: Path, pace: float) -> list[tuple[Path, float]]:
    """vhs's frames of the screen, each with the seconds it stood for, in
    the app's own time. vhs writes each as it captures it, so a frame's time
    is its file's; the cursor is a layer of its own, and the app hides it."""
    captured = captured_frames(frames)
    # A frame the app drew and vhs never captured is a jump in the motion.
    longest, drawn = max(seconds for _, seconds in captured), 1 / (SHOWCASE_APP_FRAME_RATE * pace)
    if longest > drawn:
        raise SystemExit(f"vhs fell behind: {longest:.3f}s between captures, longer than the "
                         f"{drawn:.3f}s between the app's frames; record at a slower pace")
    return [(path, seconds * pace) for path, seconds in captured]


def captured_frames(frames: Path) -> list[tuple[Path, float]]:
    """vhs's frames of the screen in `frames`, each with the seconds it was
    on screen: vhs writes each as it captures it, so a frame's time is its
    file's. The cursor is a layer of its own, and the app hides it."""
    captured = sorted(frames.glob("frame-text-*.png"))
    if len(captured) < 2:
        raise SystemExit(f"vhs captured no frames into {frames}")
    times = [path.stat().st_mtime for path in captured]
    gaps = [later - earlier for earlier, later in zip(times, times[1:])]
    return list(zip(captured, gaps + [gaps[-1]]))


def showcase_gif(frames: list[tuple[Path, float]], encoding: ShowcaseEncoding, output: Path) -> None:
    listing = SHOWCASE_FRAMES / f"{output.stem}.txt"
    listing.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    for path, seconds in frames:
        lines += [f"file '{path}'", f"duration {seconds:.4f}"]
    # The concat demuxer takes the last frame's duration only from a repeat.
    lines.append(f"file '{frames[-1][0]}'")
    listing.write_text("\n".join(lines) + "\n")
    run(["ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(listing),
         "-vf", f"fps={encoding.frame_rate},split[frames][again];"
                f"[frames]palettegen=max_colors={encoding.colours}[palette];"
                f"[again][palette]paletteuse=dither=none:diff_mode=rectangle",
         str(output)])


def record_showcase(only: str | None) -> None:
    run(["swift", "build", "-c", "release", "--scratch-path", str(WORK / "app"), "--product", "Showcase"])
    for chapter, encoding in SHOWCASE_CHAPTERS.items():
        if only not in (None, chapter):
            continue
        tape = REPO_ROOT / "assets" / f"{chapter}.tape"
        frames = SHOWCASE_FRAMES / chapter
        # vhs writes its frames only into a folder it makes itself, in one
        # that is already there.
        shutil.rmtree(frames, ignore_errors=True)
        frames.parent.mkdir(parents=True, exist_ok=True)
        run_vhs(tape)
        output = REPO_ROOT / "assets" / f"{chapter}.gif"
        showcase_gif(showcase_frames(frames, showcase_pace(tape.read_text())), encoding, output)
        print(f"{output.relative_to(REPO_ROOT)}: {output.stat().st_size / 1e6:.2f} MB", flush=True)
        shutil.copyfile(output, SHOWCASE_DOCS[chapter])


# Where the documentation shows each chapter: a catalog's own Resources, as
# the tutorials keep theirs, since an article can show only what its
# catalog holds.
SHOWCASE_DOCS = {
    "3d": REPO_ROOT / "Sources" / "TerminalUI3D" / "TerminalUI3D.docc" / "Resources" / "showcase-3d.gif",
    "canvas": RESOURCES / "showcase-canvas.gif",
}


def wanted(step: Step, only: str | None) -> bool:
    return only in (None, step.name, str(step.chapter))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("what", nargs="?", default="all",
                        choices=["previews", "gifs", "cards", "readme", "maps", "showcase", "all"])
    parser.add_argument("--only", help="one step (tasks2-03-01), chapter number, or showcase chapter (3d)")
    parser.add_argument("--no-build", action="store_true", help="reuse the last build of the steps")
    args = parser.parse_args()

    if args.what in ("previews", "gifs", "cards", "all") and not args.no_build:
        build(TUTORIAL_PACKAGE, "release")
    if args.what in ("previews", "all"):
        for step in STEPS:
            if wanted(step, args.only):
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
        # The README is recorded with vhs; first, vhs must show every page
        # as the framework drew it.
        run([sys.executable, "tools/scripts/check_vhs_compat.py", str(WORK / "app" / "debug")])
        run_vhs("assets/demo.tape")
        run_vhs("assets/debug.tape")
    if args.what in ("maps", "all"):
        record_maps()
    if args.what in ("showcase", "all"):
        record_showcase(args.only)
    return 0


if __name__ == "__main__":
    sys.exit(main())
