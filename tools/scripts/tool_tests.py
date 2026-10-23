#!/usr/bin/env python3
"""Every test of the tooling, in one process, before anything is built.

The checks the gate rests on would pass everything if they stopped
objecting: the runner's verdict on how an app ended, the escape-hatch and
tracker-id checkers. Their tests live in ``tools/tests/``, each a script of
``CASES`` that runs on its own; this runs every one found there, so a new
one gates by being named ``test_*.py``. They need no build and spawn no
app, so the gate runs them first, beside the checks they test.

Run::

    python3 tools/scripts/tool_tests.py

Exit 0 when every case passes, 1 otherwise.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from typing import Callable

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))

from terminalui.cases import run_cases  # noqa: E402


def cases_of(script: Path) -> list[tuple[str, Callable[[], None]]]:
    spec = importlib.util.spec_from_file_location(script.stem, script)
    assert spec is not None and spec.loader is not None, script
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return [(f"{script.stem}: {name}", case) for name, case in module.CASES]


if __name__ == "__main__":
    sys.exit(run_cases([case for script in sorted((TOOLS / "tests").glob("test_*.py"))
                        for case in cases_of(script)]))
