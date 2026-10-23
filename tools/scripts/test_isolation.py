#!/usr/bin/env python3
"""Smoke-vs-live isolation contract.

Per-process PID-isolated diag dirs make collision impossible
by construction: every TerminalUI process — including smoke children
— writes to its own ``/tmp/terminalui-{cwd-hash}-{pid}/`` directory.
The smoke harness no longer needs ``-smoke-`` markers or env-var
overrides; isolation is the framework's default.

Three contract legs:

1. **Distinct PID-isolated diag dir.** A spawned smoke child resolves
   ``DiagPaths.dataDir`` to a path that embeds the child's own PID and
   holds its ``<pid>.sock``. The runner-process PID is NOT in the path
   — the framework picks the path based on the child's identity, not
   the parent's.
2. **PTY mouse cleanup on abort.** When a smoke run is interrupted
   (Ctrl-C simulation), the master PTY receives the SGR-mouse disable
   byte sequence (``ESC[?1006l ?1003l ?1002l ?1000l``) before the FD
   is closed. The live shell never sees raw SGR coords.
3. **No smoke-specific path overrides.** The runner doesn't set
   ``TERMINALUI_DATA_DIR``; the framework's per-process default
   handles isolation. The child's diag_dir must use the
   framework-default shape: ``/tmp/terminalui-{hash}-{child_pid}``.
   Cleanup of orphan dirs is delegated to ``swtui ctl reap`` —
   covered separately in the ctl protocol tests.

Run::

    swift build && python3 tools/scripts/test_isolation.py

Exit 0 on all green, 1 on any failure.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui.cases import run_cases  # noqa: E402
from terminalui.runner import spawn_and_connect  # noqa: E402


# ---------------------------------------------------------------------------
# Case 1: smoke child resolves to its own PID-isolated diag dir
# ---------------------------------------------------------------------------


def case_smoke_child_uses_isolated_dir() -> None:
    """A spawned smoke child writes its socket under a per-process
    ``/tmp/terminalui-{cwd-hash}-{child_pid}/`` path that:
      * embeds the CHILD's PID (not the parent runner's) — proves the
        framework picked the path based on `getpid()` inside the child
      * holds the child's ``<pid>.sock`` at ``remote/`` — proves the
        runtime created the dir and wrote its socket into it
    """
    with spawn_and_connect("Storybook") as (proc, client):
        # The runner exposes the resolved diag dir on the Client so tests
        # can introspect the path the child actually used.
        diag_dir = getattr(client, "diag_dir", None)
        assert diag_dir is not None, (
            "Client.diag_dir is None — runner must record the dir the "
            "child wrote to so tests can verify isolation."
        )
        # The child's PID must appear in the path.
        assert str(proc.pid) in diag_dir, (
            f"diag_dir {diag_dir!r} must embed the child's PID {proc.pid} — "
            "otherwise concurrent processes from this checkout would collide."
        )
        sock_path = Path(diag_dir) / "remote" / f"{proc.pid}.sock"
        assert sock_path.exists() or sock_path.is_symlink(), (
            f"socket {sock_path} not present in isolated diag dir; the "
            "child did not write its socket where DiagPaths.tmpDataDir said."
        )


# ---------------------------------------------------------------------------
# Case 2: smoke child uses the framework-default PID-isolated path
# ---------------------------------------------------------------------------


def case_smoke_child_uses_framework_default_path() -> None:
    """The runner no longer forces a smoke-specific
    ``TERMINALUI_DATA_DIR`` — the framework's per-process default
    (``/tmp/terminalui-{cwd-hash}-{pid}/``) handles isolation. The
    child's diag dir must therefore match the framework-default shape:

      * starts with ``/tmp/terminalui-``
      * suffix is the child's own PID, not a runner-supplied value

    Pins the contract that smoke isolation is no longer a special case
    — every TerminalUI process gets the same per-PID treatment.
    """
    with spawn_and_connect("Storybook") as (proc, client):
        diag_dir = getattr(client, "diag_dir", None)
        assert diag_dir is not None
        assert diag_dir.startswith("/tmp/terminalui-"), (
            f"diag_dir {diag_dir!r} must use the framework-default "
            "/tmp/terminalui-* prefix; smoke-specific path overrides "
            "are removed."
        )
        assert diag_dir.endswith(f"-{proc.pid}"), (
            f"diag_dir {diag_dir!r} must end with the child's own PID "
            f"({proc.pid}); the framework picks the path, not the runner."
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
    ("isolation.smoke_child_uses_framework_default_path", case_smoke_child_uses_framework_default_path),
    ("isolation.pty_mouse_cleanup_on_abort",             case_pty_mouse_cleanup_on_abort),
]


if __name__ == "__main__":
    sys.exit(run_cases(CASES))
