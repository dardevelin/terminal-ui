"""Run one step of a gate as a subprocess and keep what it printed."""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Optional


def step(name: str, cmd: list[str], timeout: int, cwd: Optional[Path] = None) -> tuple[int, str]:
    """Run ``cmd``, capturing stdout and stderr together. Returns its exit
    status and output, or 124 and what it printed before ``timeout`` cut it
    off — which names whatever it was stuck on."""
    try:
        proc = subprocess.run(cmd, cwd=str(cwd) if cwd else None, capture_output=True,
                              text=True, timeout=timeout, check=False)
        return proc.returncode, (proc.stdout or "") + (proc.stderr or "")
    except subprocess.TimeoutExpired as err:
        # Output cut off mid-stream can come back as bytes.
        def _decode(value: object) -> str:
            if value is None:
                return ""
            if isinstance(value, bytes):
                return value.decode("utf-8", errors="replace")
            return str(value)
        return 124, f"{name} timed out after {timeout}s\n{_decode(err.stdout)}{_decode(err.stderr)}"
