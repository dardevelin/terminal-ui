#!/usr/bin/env python3
"""Every single-purpose harness script, one after another.

Each script pins a contract a smoke case, one app driven by one client,
cannot reach: data dirs kept apart and apps running side by side take
several apps, `swtui ctl` refusing to kill without a PID and a client that
does not read take `swtui` or a raw socket, and verify.py leaving live apps
alone takes verify.py.
They ran only when someone remembered to; this is the one gate CI and
verify.py call. The tooling's own tests, which need no app, are
``tool_tests.py``'s.

They run in turn, never side by side: the concurrent-instance cases count
the apps running from this checkout, and another script's app would be one
too many.

Run::

    python3 tools/scripts/integration_suite.py [build_dir]

Exit 0 when every script passes, 1 otherwise.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui.cases import run_cases  # noqa: E402
from terminalui.process import step  # noqa: E402

SCRIPT_DIR = Path(__file__).resolve().parent

# Every script, found rather than listed: a list is how eleven of them came
# to gate nothing.
SCRIPTS = sorted(SCRIPT_DIR.glob("test_*.py"))

# Each takes seconds, a sanitizer build ten or twenty times that; the limit
# is for one that hangs, and stops it before the gate's own limit does.
SCRIPT_TIMEOUT_SECONDS = 60

# What a failing script printed last, which names the case that failed.
FAILURE_TAIL_CHARACTERS = 2000


def _script(script: Path) -> Callable[[], None]:
    def run() -> None:
        rc, output = step(script.name, [sys.executable, str(script)], SCRIPT_TIMEOUT_SECONDS)
        assert rc == 0, output.strip()[-FAILURE_TAIL_CHARACTERS:]
    return run


if __name__ == "__main__":
    if len(sys.argv) > 1:
        os.environ["TERMINALUI_BUILD_DIR"] = sys.argv[1]
    sys.exit(run_cases([(script.name, _script(script)) for script in SCRIPTS]))
