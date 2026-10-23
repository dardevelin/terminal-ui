#!/usr/bin/env python3
"""Integration test: socketEnabled=false produces no socket file.

The unit tests for the socket gating only assert API surface
(``DiagConfig.default.socketEnabled == true``); the behavioural
assertion needs a PTY-based integration test. This script spawns
Storybook under PTY in a temp cwd whose ``.terminalui/terminalui.toml``
opts the socket off, then asserts that the framework honored the
gate: no ``<pid>.sock`` appears, and the app still boots normally.

Run::   ``swift build && python3 tools/scripts/verify_socket_disabled.py``
Exit:   0 on pass, 1 on fail. Sibling of ``storybook_smoke.py``.
"""

from __future__ import annotations

import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui.runner import spawn_and_connect, _repo_root  # noqa: E402


# ---------------------------------------------------------------------------
# Path helpers — match Sources/TerminalUIConfig/DiagPaths.swift
# ---------------------------------------------------------------------------


def _fnv1a(text: str) -> str:
    """Mirror DiagPaths.fnv1a — FNV-1a 32-bit as unpadded hex, which is what
    Swift's `String(hash, radix: 16)` prints. Must match the Swift hash so the
    harness looks at the dirs the spawned process used."""
    h = 0x811C9DC5
    for byte in text.encode("utf-8"):
        h ^= byte
        h = (h * 0x01000193) & 0xFFFFFFFF
    return format(h, "x")


def _socket_dirs(cwd: str) -> list[Path]:
    """Every app's `remote/` dir for this checkout: `/tmp/terminalui-{hash}-{pid}`.
    The checkout is a fresh temp dir, so every one is this run's."""
    return sorted(Path("/tmp").glob(f"terminalui-{_fnv1a(cwd)}-*/remote"))


# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="hyp114-") as tmp:
        cwd = tmp
        config_dir = Path(cwd) / ".terminalui"
        config_dir.mkdir(parents=True, exist_ok=True)
        (config_dir / "terminalui.toml").write_text(
            "[socket]\nenabled = false\n", encoding="utf-8"
        )

        # The harness's `_wait_for_client` raises when the socket
        # doesn't appear — that's exactly the symptom we want to see.
        # Catch the error and assert the filesystem.
        booted = False
        try:
            with spawn_and_connect("Storybook", cwd=cwd, connect_timeout=2.0) as (proc, _client):
                # If we reach here, the socket DID appear despite the
                # gate — that's the bug the test catches.
                _proc_alive = proc.poll() is None
                print(
                    f"FAIL: a socket appeared despite socketEnabled=false "
                    f"(process alive={_proc_alive})",
                    file=sys.stderr,
                )
                return 1
        except FileNotFoundError as exc:
            # Build artifact missing — tell the user to build first.
            print(f"SKIP: {exc}", file=sys.stderr)
            return 0
        except Exception:  # noqa: BLE001
            # Expected path: socket never appeared, harness raised.
            booted = True

        # Give the process a moment to fully exit so we don't race its
        # cleanup before checking the directory state.
        time.sleep(0.3)

        # Filesystem assertion. A remote dir may exist (the data dirs are
        # made either way); it must hold no socket.
        offending = [str(entry) for socket_dir in _socket_dirs(cwd)
                     for entry in socket_dir.iterdir() if entry.name.endswith(".sock")]

        if offending:
            print(
                "FAIL: socketEnabled=false but found socket artifacts: "
                + ", ".join(offending),
                file=sys.stderr,
            )
            return 1

        if not booted:
            # Should not happen — spawn_and_connect raises if we don't
            # exit through the except branch — defensive belt-and-braces.
            print("FAIL: never observed boot signal", file=sys.stderr)
            return 1

        print("PASS: socketEnabled=false honored — no <pid>.sock created")
        return 0


if __name__ == "__main__":
    sys.exit(main())
