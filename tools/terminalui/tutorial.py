"""The tutorial's code steps, as a package that builds every one, and what
each does once it runs.

The steps under ``TerminalUI.docc/Resources`` are complete apps the reader
types in and runs. Each builds as an executable of one generated package,
its file the target's ``main.swift``, against this checkout — the shape
``record_media.py`` records them in and ``check_tutorial_steps.py`` gates
them in.

``STEPS`` says, for each, what its captions claim: the keys and clicks the
tutorial tells the reader to try, and what the screen then shows, hides, or
whether the app has quit. One stage of each is the state its preview
captures, so the picture the tutorial shows and the check of what it says
are driven by the same keys and cannot drift apart.
"""

from __future__ import annotations

import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence, Union

REPO_ROOT = Path(__file__).resolve().parents[2]
RESOURCES = REPO_ROOT / "Sources" / "TerminalUI" / "TerminalUI.docc" / "Resources"


@dataclass(frozen=True)
class Press:
    """A key, by the name ``swtui ctl send-key`` takes, and its modifiers."""
    key: str
    modifiers: tuple[str, ...] = ()


@dataclass(frozen=True)
class Type:
    text: str


@dataclass(frozen=True)
class Click:
    """A left click on the first cell of the first place ``text`` is
    drawn."""
    text: str


@dataclass(frozen=True)
class Loaded:
    """Chapters 6 and 7 simulate a four-second load; ``text`` is on the
    screen once it is over."""
    text: str


Action = Union[Press, Type, Click, Loaded]


@dataclass(frozen=True)
class Stage:
    keys: Sequence[Action] = ()
    shows: Sequence[str] = ()
    hides: Sequence[str] = ()
    # The keys end the app.
    quits: bool = False
    # The stage starts the app again first, with what the last run saved.
    relaunch: bool = False


@dataclass(frozen=True)
class Step:
    name: str
    stages: Sequence[Stage]
    # The stage whose screen the step's preview captures.
    preview: int = 0

    def preview_keys(self) -> list[Action]:
        return [key for stage in self.stages[:self.preview + 1] for key in stage.keys]


SEEDS = ("Read the TerminalUI tutorial", "Build a task list", "Ship it")

STEPS: tuple[Step, ...] = (
    # Chapter 1 — BuildATaskList.
    Step("tasks-01-01", [
        Stage(shows=["Tasks", "Nothing here yet."]),
        Stage([Type("q")], quits=True),
    ]),
    Step("tasks-02-01", [
        Stage(shows=["Tasks", "Nothing here yet."]),
        Stage([Press("escape")], quits=True),
    ]),
    Step("tasks-02-02", [
        Stage(shows=[f"☐ {seed}" for seed in SEEDS]),
    ]),
    Step("tasks-03-01", [
        Stage([Press("down")], shows=["▸ ☐ Build a task list"]),
        Stage([Type("j")], shows=["▸ ☐ Ship it"]),
        Stage([Type("k")], shows=["▸ ☐ Build a task list"]),
    ]),
    Step("tasks-03-02", [
        Stage([Press("down"), Press("space")], shows=["▸ ☑ Build a task list"]),
        Stage([Press("enter")], shows=["▸ ☐ Build a task list"]),
    ]),
    Step("tasks-04-01", [
        Stage([Press("down"), Press("space")],
              shows=["▸ ☑ Build a task list", "2 open", "space toggle", "q quit"]),
        Stage([Type("q")], quits=True),
    ]),
    # Chapter 2 — AddInputAndTheMouse.
    Step("tasks2-01-01", [
        Stage([Type("Feed the fox")], shows=["❯ Feed the fox"]),
        Stage([Press("enter")], shows=["☐ Feed the fox", "4 open"]),
        # Letters reach the field: no letter quits any more.
        Stage([Type("quick fix")], shows=["❯ quick fix"]),
        Stage([Press("escape")], quits=True),
    ]),
    Step("tasks2-02-01", [
        Stage([Press("down"), Press("enter")], shows=["▸ ☑ Build a task list", "2 open"]),
        Stage([Click("Ship it")], shows=["☑ Ship it", "1 open"]),
        # With text typed, Enter submits rather than toggles.
        Stage([Type("Feed the fox"), Press("enter")],
              shows=["☐ Feed the fox", "▸ ☑ Build a task list", "2 open"]),
    ]),
    Step("tasks2-03-01", [
        Stage([Type("Feed the fox"), Press("enter"), Press("down"), Press("down"),
               Press("down"), Press("enter")],
              shows=["▸ ☑ Feed the fox", "3 open", "click or Enter toggle"]),
        Stage([Click("Read the TerminalUI tutorial")],
              shows=["☑ Read the TerminalUI tutorial", "2 open"]),
    ]),
    # Chapter 3 — GiveItStructure.
    # The tab bar holds focus at launch, so a digit switches tabs.
    Step("tasks3-01-01", [
        Stage(shows=["Tasks  |  Settings", "☐ Ship it"]),
        Stage([Type("2")], shows=["Nothing to configure yet."], hides=["Ship it"]),
        Stage([Type("1")], shows=["☐ Ship it"]),
    ]),
    Step("tasks3-02-01", [
        # The detail follows the selection, and so does the list's mark.
        Stage([Press("down")], shows=["▸ ☐ Build a task list", "Detail", "id 2"]),
        Stage([Press("down")], shows=["▸ ☐ Ship it", "id 3"]),
        # Focus has left the tab bar for the prompt: a digit types.
        Stage([Type("2")], shows=["❯ 2"], hides=["Show completed"]),
    ]),
    Step("tasks3-03-01", [
        Stage([Type("2")], shows=["Show completed  [x]"]),
        Stage([Type("1"), Click("Build a task list")], shows=["☑ Build a task list"]),
        Stage([Type("2"), Press("tab"), Press("space")], shows=["Show completed  [ ]"]),
        Stage([Press("tab", ("shift",)), Type("1")],
              shows=["☐ Ship it"], hides=["Build a task list"]),
    ]),
    # Chapter 4 — NavigateToDetail.
    Step("tasks4-01-01", [
        Stage([Press("down"), Press("down"), Press("enter")],
              shows=["Detail", "Build a task list", "id 2"], hides=["Ship it"]),
        Stage([Press("escape")], shows=["☐ Ship it"], hides=["id 2"]),
        Stage([Press("escape")], quits=True),
    ]),
    Step("tasks4-02-01", [
        Stage([Press("down"), Press("down"), Press("enter"), Press("space")],
              shows=["[x] Done", "id 2"]),
        # Popped, focus is back on the link that pushed.
        Stage([Press("escape")], shows=["▎☑ Build a task list", "2 open"]),
    ]),
    Step("tasks4-03-01", [
        Stage([Press("down"), Press("down"), Press("enter"), Press("space")],
              shows=["Tasks ▸ Build a task list", "[x] Done", "Space toggle   Esc back"]),
    ]),
    # Chapter 5 — ShowTheNumbers.
    Step("tasks5-01-01", [
        Stage([Press("enter"), Type("3")],
              shows=["Task", "Status", "Read the TerminalUI tutorial   done",
                     "Build a task list              open"]),
    ]),
    Step("tasks5-02-01", [
        Stage([Press("enter"), Type("3")],
              shows=["Completions, last 14 days", "Open vs done",
                     "open ████████████████████ 2", "done ██████████           1"]),
    ]),
    Step("tasks5-03-01", [
        Stage([Press("enter"), Type("3")], shows=["Open vs done", "Done", "0.33"]),
    ]),
    # Chapter 6 — MakeItProduction.
    Step("tasks6-01-01", [
        Stage([Press("backspace")],
              shows=["Delete task?", "This cannot be undone.", "▎[ Cancel ]", "[ Delete ]"]),
        Stage([Press("enter")], shows=["▸ ☐ Read the TerminalUI tutorial", "3 open"],
              hides=["Delete task?"]),
        Stage([Press("backspace"), Press("tab"), Press("enter")],
              shows=["▸ ☐ Build a task list", "2 open"],
              hides=["Delete task?", "Read the TerminalUI tutorial"]),
    ]),
    # Its preview is taken mid-load.
    Step("tasks6-02-01", [
        Stage(shows=["Loading tasks…", "0 open"]),
        Stage([Loaded("3 open")], shows=[f"☐ {seed}" for seed in SEEDS],
              hides=["Loading tasks…"]),
    ]),
    Step("tasks6-03-01", [
        Stage(shows=["loading", "Loading tasks…", "Loading…"]),
        Stage([Loaded("3 open"), Press("enter")],
              shows=["▸ ☑ Read the TerminalUI tutorial", "2 open", "done"]),
        Stage([Press("down"), Press("enter"), Press("down"), Press("enter")],
              shows=["all done"]),
    ], preview=1),
    # Chapter 7 — ArchitectForGrowth.
    Step("tasks7-01-01", [
        Stage([Loaded("3 open"), Press("enter")],
              shows=["▸ ☑ Read the TerminalUI tutorial", "2 open"]),
    ]),
    Step("tasks7-02-01", [
        Stage([Loaded("3 open"), Press("down"), Press("enter")],
              shows=["▸ ☑ Build a task list", "2 open", "id 2", "done"]),
    ]),
    Step("tasks7-03-01", [
        Stage([Loaded("3 open"), Press("down"), Press("down"), Press("enter")],
              shows=["▸ ☑ Ship it", "2 open", "id 3"]),
        # The file service: what was done survives a relaunch.
        Stage([Loaded("2 open")], shows=["☑ Ship it"], relaunch=True),
    ]),
)


def binary_name(step: str) -> str:
    """The executable a step builds as: its name without dashes, so
    ``tasks2-03-01`` is ``tasks20301``."""
    return step.replace("-", "")


def step_files() -> list[Path]:
    return sorted(RESOURCES.glob("tasks*.swift"))


def write_package(package: Path) -> None:
    """Every code step as an executable target of one package at
    ``package``, depending on this checkout."""
    sources = package / "Sources"
    if sources.exists():
        shutil.rmtree(sources)
    targets = []
    for step_file in step_files():
        name = binary_name(step_file.stem)
        (sources / name).mkdir(parents=True)
        shutil.copy(step_file, sources / name / "main.swift")
        targets.append(
            f'        .executableTarget(name: "{name}", '
            f'dependencies: [.product(name: "TerminalUI", package: "terminal-ui")]),')
    (package / "Package.swift").write_text(
        "// swift-tools-version: 6.2\n"
        "// Generated by tools/terminalui/tutorial.py: every tutorial code step.\n"
        "import PackageDescription\n\n"
        "let package = Package(\n"
        '    name: "TutorialSteps",\n'
        "    platforms: [.macOS(.v15)],\n"
        f'    dependencies: [.package(path: "{REPO_ROOT}")],\n'
        "    targets: [\n" + "\n".join(targets) + "\n    ]\n)\n")


def build(package: Path, configuration: str, extra: Sequence[str] = ()) -> None:
    """Writes the package and builds it; raises on a failed build."""
    write_package(package)
    command = ["swift", "build", "-c", configuration, *extra]
    print("$", " ".join(command), flush=True)
    subprocess.run(command, cwd=package, check=True)
