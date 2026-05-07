#!/usr/bin/env python3
"""Smoke-vs-live isolation contract.

Every smoke-harness child must write its diag output to a per-PID dir under
``/tmp/`` so a concurrent live ``swift run Storybook`` session is never
clobbered. The contract has three legs:

1. **Distinct diag dir.** A spawned smoke child resolves
   ``DiagPaths.dataDir`` to a path containing both ``-smoke-`` and the
   child's PID. NEVER the bare ``/tmp/terminalui-{hash}`` path that the
   live app uses.
2. **PTY mouse cleanup on abort.** When a smoke run is interrupted (Ctrl-C
   simulation), the master PTY receives the SGR-mouse disable byte
   sequence (``ESC[?1006l ?1003l ?1002l ?1000l``) before the FD is
   closed. The live shell never sees raw SGR coords.
3. **Live socket directory unaffected.** Even if a smoke child crashes
   without graceful cleanup, the canonical ``/tmp/terminalui-{hash}/remote/``
   directory used by the live app contains no stray smoke sockets and no
   smoke ``latest.sock`` symlink.

Run::

    swift build && python3 tools/scripts/test_isolation.py

Exit 0 on all green, 1 on any failure. The output format mirrors
``storybook_smoke.py`` so a CI watcher can parse the same lines.
"""

from __future__ import annotations

import os
import re
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, List

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui.runner import spawn_and_connect  # noqa: E402


REPO_ROOT = Path(__file__).resolve().parents[2]
LIVE_HASH_DIR_GLOB = "/tmp/terminalui-*"


@dataclass
class CaseResult:
    name: str
    ok: bool
    detail: str


def _run(name: str, fn: Callable[[], None]) -> CaseResult:
    try:
        fn()
        return CaseResult(name, True, "ok")
    except AssertionError as exc:
        return CaseResult(name, False, str(exc))
    except Exception as exc:  # noqa: BLE001
        return CaseResult(name, False, f"{type(exc).__name__}: {exc}")


# ---------------------------------------------------------------------------
# Case 1: smoke child resolves to PID-namespaced diag dir
# ---------------------------------------------------------------------------


def case_smoke_child_uses_isolated_dir() -> None:
    """A spawned smoke child writes its socket under a per-run
    ``/tmp/terminalui-smoke-{runner_pid}-{n}/`` path that:
      * contains the substring ``-smoke-`` (distinct from the canonical
        ``/tmp/terminalui-{hash}/`` live dir)
      * holds the child's ``<pid>.sock`` (proof the runtime honored
        ``TERMINALUI_DATA_DIR`` and wrote into the isolated dir, not the
        live dir).
    """
    with spawn_and_connect("Storybook") as (proc, client):
        client.wait_for_frame(1, timeout=2.0)
        # The runner exposes the resolved diag dir on the Client so tests
        # can introspect the path the child actually used. If this attribute
        # is missing, the runner has not been wired to set TERMINALUI_DATA_DIR.
        diag_dir = getattr(client, "diag_dir", None)
        assert diag_dir is not None, (
            "Client.diag_dir is None — runner must record the isolated dir "
            "it set via TERMINALUI_DATA_DIR so tests can verify isolation."
        )
        assert "-smoke-" in diag_dir, (
            f"diag_dir {diag_dir!r} must contain '-smoke-' — otherwise "
            "smoke is sharing the live diag dir."
        )
        sock_path = Path(diag_dir) / "remote" / f"{proc.pid}.sock"
        assert sock_path.exists() or sock_path.is_symlink(), (
            f"socket {sock_path} not present in isolated diag dir; the "
            "child did not honor TERMINALUI_DATA_DIR."
        )


# ---------------------------------------------------------------------------
# Case 2: smoke child does NOT touch the canonical live dir
# ---------------------------------------------------------------------------


_HASH_DIR_RE = re.compile(r"^/tmp/terminalui-([0-9a-f]+)$")


def _bare_live_dirs() -> List[str]:
    """Match ``/tmp/terminalui-{hash}`` exactly — i.e. no ``-smoke-`` suffix.
    These are the dirs the LIVE app would write to."""
    out = []
    for entry in Path("/tmp").glob("terminalui-*"):
        if _HASH_DIR_RE.match(str(entry)):
            out.append(str(entry))
    return out


def case_smoke_child_does_not_write_to_live_dir() -> None:
    """Snapshot the canonical live dir before spawn; spawn smoke; assert the
    canonical dir's ``remote/`` got no new ``<pid>.sock`` for the smoke
    child. Proves that env-override actually rebases output."""
    live_dirs_before = {d: set((Path(d) / "remote").glob("*.sock")) for d in _bare_live_dirs()}
    # Some envs run with no live app at all — that's fine, the snapshot
    # is empty and the post-condition is trivially true. We only care
    # the smoke child didn't ADD anything.
    with spawn_and_connect("Storybook") as (proc, _client):
        smoke_sock = f"{proc.pid}.sock"
        for live_dir in live_dirs_before:
            remote = Path(live_dir) / "remote"
            if not remote.exists():
                continue
            current = {p.name for p in remote.glob("*.sock")}
            assert smoke_sock not in current, (
                f"smoke child PID {proc.pid} wrote {smoke_sock} into the "
                f"canonical live dir {live_dir}/remote/. Isolation broken."
            )


# ---------------------------------------------------------------------------
# Case 3: PTY mouse-mode cleanup on abort
# ---------------------------------------------------------------------------


def case_pty_mouse_cleanup_on_abort() -> None:
    """When a smoke child is killed mid-run (the harness path that bypasses
    graceful Terminal.disableRawMode), the runner posts the mouse-mode
    disable bytes to the master PTY before close.

    We assert the runner exposes a ``last_pty_cleanup`` snapshot of the
    bytes it wrote so tests can verify without intercepting raw fd I/O.
    Required disable sequences (per ECMA-48 + xterm ctlseqs):
        ESC[?1006l   # SGR mouse off
        ESC[?1003l   # any-event tracking off
        ESC[?1002l   # cell-motion tracking off
        ESC[?1000l   # X10 tracking off
    """
    from terminalui import runner

    captured: dict[str, bytes] = {}

    def _capture_cleanup(buf: bytes) -> None:
        captured["bytes"] = buf

    # The hook is exported so tests don't have to fd-spy. Production smoke
    # runs leave it None.
    runner.set_pty_cleanup_observer(_capture_cleanup)
    try:
        with spawn_and_connect("Storybook") as (proc, client):
            client.wait_for_frame(1, timeout=2.0)
            # Simulate abort by raising INSIDE the with-block. The runner's
            # finally must still post mouse-cleanup.
            raise KeyboardInterrupt("simulated abort")
    except KeyboardInterrupt:
        pass
    finally:
        runner.set_pty_cleanup_observer(None)

    seen = captured.get("bytes", b"")
    for needle in (b"\x1b[?1006l", b"\x1b[?1003l", b"\x1b[?1002l", b"\x1b[?1000l"):
        assert needle in seen, (
            f"PTY cleanup did not include {needle!r}; smoke abort would "
            f"leak mouse-mode state. Captured bytes: {seen!r}"
        )


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------


CASES = [
    ("isolation.smoke_child_uses_isolated_dir",          case_smoke_child_uses_isolated_dir),
    ("isolation.smoke_child_does_not_write_to_live_dir", case_smoke_child_does_not_write_to_live_dir),
    ("isolation.pty_mouse_cleanup_on_abort",             case_pty_mouse_cleanup_on_abort),
]


def main() -> int:
    failures = 0
    for name, fn in CASES:
        result = _run(name, fn)
        marker = "OK" if result.ok else "FAIL"
        line = f"[{marker}] {result.name}"
        if not result.ok:
            line += f" — {result.detail}"
            failures += 1
        print(line)
    print("---")
    print(f"{len(CASES) - failures}/{len(CASES)} pass")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
