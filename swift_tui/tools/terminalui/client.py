"""Typed Python client for the TerminalUI remote-control socket (HYP-71).

Design:
- One request per call, one response per call, framed as JSON lines over
  AF_UNIX. The framework pumps the socket once per frame so every call
  synchronizes on the next rendered frame.
- Responses parse into small frozen dataclasses so tests use dot-access
  instead of dict indexing.
- The default socket path is ``<diag_dir>/remote/latest.sock``. Pass
  ``pid=N`` to target a specific running app (useful when multiple apps are
  under test concurrently).
- Errors raise ``RemoteError`` with the server-reported string — callers do
  not need to interpret the low-level JSON shape.

Not a goal: streaming subscriptions or out-of-band events. The protocol is
strict request/response, which keeps the client boring and predictable.
"""

from __future__ import annotations

import json
import os
import socket
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Optional, Sequence


# ---------------------------------------------------------------------------
# Socket path resolution
# ---------------------------------------------------------------------------

# Default search order matches the framework's DiagPaths: per-project
# `.terminalui/data/remote/` first, then the tmp fallback used when
# `use_tmp` is enabled in terminalui.toml. A user running tests from any
# cwd usually hits one of these without extra configuration.
_DEFAULT_DIRS: Sequence[str] = (
    ".terminalui/data/remote",
    "/tmp/terminalui-*/remote",  # glob-expanded below
)


def default_socket_path(pid: Optional[int] = None,
                        socket_dir: Optional[str] = None) -> str:
    """Resolve the most likely socket path for a running debug app.

    Priority: explicit ``socket_dir`` arg > ``.terminalui/data/remote/`` in
    cwd > any ``/tmp/terminalui-*/remote`` tmp dir. When ``pid`` is given,
    look for ``<pid>.sock``; otherwise follow ``latest.sock``.
    """
    filename = f"{pid}.sock" if pid is not None else "latest.sock"
    if socket_dir:
        return str(Path(socket_dir) / filename)

    local = Path.cwd() / ".terminalui" / "data" / "remote" / filename
    if local.exists() or local.is_symlink():
        return str(local)

    # Fall back to tmp — scan for the newest matching dir rather than the
    # first, so concurrent runs don't confuse the lookup.
    import glob

    candidates = sorted(glob.glob("/tmp/terminalui-*/remote"), key=os.path.getmtime, reverse=True)
    for cand in candidates:
        sock = Path(cand) / filename
        if sock.exists() or sock.is_symlink():
            return str(sock)
    # Return the local path even if it doesn't exist yet — connect() will
    # raise a clearer error than our best-guess logic.
    return str(local)


# ---------------------------------------------------------------------------
# Response dataclasses
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Focus:
    node_id: Optional[str]
    kind: Optional[str]
    rect: Sequence[int]  # [x, y, w, h]; empty when nothing focused
    value: Optional[str]


@dataclass(frozen=True)
class CellSlice:
    x: int
    y: int
    width: int
    height: int
    rows: Sequence[str]
    ruler_top: Optional[Sequence[str]] = None
    ruler_left: Optional[Sequence[str]] = None

    def text(self) -> str:
        """Join all rows with newlines — handy for substring assertions."""
        return "\n".join(self.rows)

    def grid(self, indent: str = "    ") -> str:
        """Pretty-print with coordinate rulers, if present. Useful when
        looking at a snapshot in logs — every cell aligns with its (x, y)."""
        if self.ruler_top is None or self.ruler_left is None:
            return self.text()
        left_width = max(len(r) for r in self.ruler_left)
        parts: list[str] = []
        for ruler_row in self.ruler_top:
            parts.append(indent + " " * left_width + " " + ruler_row)
        for label, row in zip(self.ruler_left, self.rows):
            padded = label.rjust(left_width)
            parts.append(indent + padded + " " + row)
        return "\n".join(parts)


@dataclass(frozen=True)
class Probe:
    cursor_x: int
    cursor_y: int
    active: bool
    node_kind: Optional[str]
    node_rect: Optional[Sequence[int]]
    declared: Mapping[str, str]
    modifier_chain: Sequence[str]


@dataclass(frozen=True)
class Response:
    id: int
    ok: bool
    error: Optional[str] = None
    raw: Mapping[str, Any] = field(default_factory=dict)

    @property
    def result(self) -> Mapping[str, Any]:
        return self.raw.get("result") or {}


class RemoteError(RuntimeError):
    """Raised when the socket reports ``ok: false`` or connection fails."""


# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------


class Client:
    """Connects to one running TerminalUI debug app and issues commands.

    Use as a context manager so the socket closes cleanly on test
    teardown::

        with Client() as app:
            app.send_key("tab")

    The client is NOT thread-safe; create one per test. Reads are
    newline-delimited so large responses arrive in full even when the
    kernel delivers them in chunks.
    """

    def __init__(self,
                 pid: Optional[int] = None,
                 socket_dir: Optional[str] = None,
                 path: Optional[str] = None,
                 connect_timeout: float = 2.0,
                 read_timeout: float = 2.0):
        self._path = path or default_socket_path(pid=pid, socket_dir=socket_dir)
        self._sock: Optional[socket.socket] = None
        self._next_id = 1
        self._rx_buffer = b""
        self._connect_timeout = connect_timeout
        self._read_timeout = read_timeout
        # Optional master-PTY file descriptor for raw-byte injection. Set
        # by the runner after spawn so `paste()` can write
        # bracketed-paste sequences directly to the spawned app's stdin
        # — the JSON-RPC `send_text` path can't synthesise the
        # ESC[200~/ESC[201~ wrappers because they're a TTY-level protocol,
        # not an InputParser-level one.
        self._master_fd: Optional[int] = None

    # -- connection --

    def __enter__(self) -> "Client":
        self.connect()
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()

    def connect(self) -> None:
        """Open the AF_UNIX socket. Raises ``RemoteError`` if the app isn't
        running or the socket path is stale. Retries briefly so tests can
        spawn the app and immediately connect without a hand-tuned sleep."""
        deadline = time.monotonic() + self._connect_timeout
        last_err: Optional[OSError] = None
        while time.monotonic() < deadline:
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(self._read_timeout)
                s.connect(self._path)
                self._sock = s
                return
            except OSError as err:
                last_err = err
                time.sleep(0.05)
        raise RemoteError(f"connect to {self._path} failed: {last_err}")

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    # -- low-level send/recv --

    def _call(self, cmd: str, **fields: Any) -> Response:
        if self._sock is None:
            raise RemoteError("not connected")
        payload = {"id": self._next_id, "cmd": cmd}
        self._next_id += 1
        # Strip None fields so the server sees a compact request matching
        # the Swift decoder's expectations (Optional properties).
        payload.update({k: v for k, v in fields.items() if v is not None})
        data = (json.dumps(payload) + "\n").encode("utf-8")
        self._sock.sendall(data)
        raw = self._recv_line()
        decoded = json.loads(raw)
        response = Response(
            id=int(decoded.get("id", -1)),
            ok=bool(decoded.get("ok", False)),
            error=decoded.get("error"),
            raw=decoded,
        )
        if not response.ok:
            raise RemoteError(f"{cmd}: {response.error}")
        return response

    def _recv_line(self) -> str:
        assert self._sock is not None
        while b"\n" not in self._rx_buffer:
            chunk = self._sock.recv(8192)
            if not chunk:
                raise RemoteError("server closed the connection")
            self._rx_buffer += chunk
        line, _, rest = self._rx_buffer.partition(b"\n")
        self._rx_buffer = rest
        return line.decode("utf-8", errors="replace")

    # -- high-level commands --

    def ping(self) -> None:
        self._call("ping")

    def send_key(self, key: str, *modifiers: str) -> None:
        """Inject a single key event. ``key`` accepts named keys (tab, enter,
        up/down/left/right, home/end, pageup/pagedown, f1..f12, escape) or a
        single character. Modifiers: shift, alt/option/meta, ctrl."""
        self._call("send_key", key=key, modifiers=list(modifiers) or None)

    def send_text(self, text: str) -> None:
        """Inject each character as a key event. Newline becomes ``enter``,
        tab becomes ``tab``."""
        self._call("send_text", text=text)

    def attach_pty(self, master_fd: int) -> None:
        """Wire the spawned app's master-PTY file descriptor so ``paste()``
        can write bracketed-paste sequences directly into the app's stdin.
        The runner calls this after spawn; tests invoking ``Client``
        without the runner (rare) can pass their own FD."""
        self._master_fd = master_fd

    def paste(self, text: str) -> None:
        """Simulate a bracketed-paste at the OS level by writing
        ``ESC[200~<text>ESC[201~`` to the master PTY. The framework's
        InputParser recognises the markers and delivers a single
        ``KeyEvent.paste(text)`` to the focused view.

        Use this anywhere a real OS paste would happen: testing
        PromptInputDraft's collapse logic, asserting the framework's
        bracketed-paste guard rejects malformed sequences, etc.
        Single-character "send_text" can't reproduce paste semantics
        because each character arrives as a typed event, not a paste
        burst — bracketed paste is what disambiguates the two.
        """
        if self._master_fd is None:
            raise RemoteError("paste() requires attach_pty(master_fd) — runner hooks this up automatically")
        # ESC[200~ start, ESC[201~ end. Bytes go straight to stdin.
        payload = f"\x1b[200~{text}\x1b[201~".encode("utf-8")
        os.write(self._master_fd, payload)

    def mouse_move(self, x: int, y: int, *modifiers: str) -> None:
        """Inject a mouse-move event at (x, y). 0-indexed cell coordinates.
        Updates hover target without changing button state."""
        self._call("send_mouse", kind="move", x=x, y=y,
                   modifiers=list(modifiers) or None)

    def mouse_click(self, x: int, y: int, button: str = "left",
                    *modifiers: str) -> None:
        """Inject a press+release at (x, y). ``button`` is left/middle/right."""
        self._call("send_mouse", kind="click", x=x, y=y, button=button,
                   modifiers=list(modifiers) or None)

    def mouse_press(self, x: int, y: int, button: str = "left",
                    *modifiers: str) -> None:
        """Inject a press only — pair with ``mouse_release`` to test drag."""
        self._call("send_mouse", kind="press", x=x, y=y, button=button,
                   modifiers=list(modifiers) or None)

    def mouse_release(self, x: int, y: int, button: str = "left",
                      *modifiers: str) -> None:
        self._call("send_mouse", kind="release", x=x, y=y, button=button,
                   modifiers=list(modifiers) or None)

    def mouse_wheel(self, direction: str, x: int, y: int,
                    *modifiers: str) -> None:
        """Inject a scroll-wheel event. ``direction`` is "up" or "down"."""
        kind = f"wheel_{direction}"
        self._call("send_mouse", kind=kind, x=x, y=y,
                   modifiers=list(modifiers) or None)

    def press_many(self, key: str, count: int, *modifiers: str,
                   sleep_between: float = 0.02) -> None:
        """Convenience: send ``key`` ``count`` times with a small pause to
        give each frame time to process. ``sleep_between`` defaults to ~20ms
        which is long enough for default ``.fps60`` render mode."""
        for _ in range(count):
            self.send_key(key, *modifiers)
            if sleep_between > 0:
                time.sleep(sleep_between)

    def send_keys(self, sequence: Iterable[Any],
                  sleep_between: float = 0.02) -> None:
        """Inject an ordered sequence of key events. Each entry may be:

        * a bare string — a single key name (``"tab"``, ``"enter"``, ``"a"``)
          or a ``+``-joined chord (``"ctrl+k"``, ``"shift+tab"``)
        * a tuple ``(key, [modifiers])`` — same spelling as ``send_key``

        Useful for multi-step compose sequences: ``send_keys(["ctrl+x",
        "ctrl+c"])`` fires the two chords in order, waiting one render tick
        between them. Returns after the last key has been queued; callers
        should follow with ``wait_for_frame`` if they need to observe the
        post-sequence state.
        """
        for item in sequence:
            if isinstance(item, str):
                key, modifiers = _parse_key_expression(item)
            elif isinstance(item, tuple) and len(item) == 2:
                key = str(item[0])
                modifiers = tuple(item[1]) if item[1] else ()
            else:
                raise TypeError(f"invalid key sequence entry: {item!r}")
            self.send_key(key, *modifiers)
            if sleep_between > 0:
                time.sleep(sleep_between)

    def chord(self, *chords: str, sleep_between: float = 0.02) -> None:
        """Fire a chord or a sequence of chords written as ``mod+mod+key``.

        Examples::

            app.chord("ctrl+c")                 # single chord
            app.chord("ctrl+x", "ctrl+s")       # Emacs-style compose
            app.chord("shift+tab")              # Shift-Tab

        Case-insensitive. Accepts ``cmd`` / ``meta`` / ``option`` as aliases
        for ``alt``. Raises ``ValueError`` for empty strings.
        """
        for chord in chords:
            if not chord.strip():
                raise ValueError("empty chord")
            key, modifiers = _parse_key_expression(chord)
            self.send_key(key, *modifiers)
            if sleep_between > 0:
                time.sleep(sleep_between)

    def tab(self, count: int = 1, reverse: bool = False) -> None:
        """Advance keyboard focus by ``count`` tab stops (positive integer).
        Pass ``reverse=True`` for Shift+Tab. Settles one render tick per
        press so the focus-change lands before the next call."""
        if count < 0:
            raise ValueError("count must be non-negative")
        for _ in range(count):
            if reverse:
                self.send_key("tab", "shift")
            else:
                self.send_key("tab")
            time.sleep(0.02)

    def focus(self) -> Focus:
        data = self._call("focus_get").result.get("focus") or {}
        return Focus(
            node_id=data.get("node_id"),
            kind=data.get("kind"),
            rect=data.get("rect") or [],
            value=data.get("value"),
        )

    def set_focus(self, node_id: str) -> None:
        """Focus the node whose stringified id matches ``node_id``. Use the
        id returned by ``focus()`` or ``tree()``."""
        self._call("focus_set", text=node_id)

    def text(self, rect: Optional[Sequence[int]] = None) -> str:
        """Shortcut for ``cells(rect).text()`` — the most common assertion
        shape is 'does the rendered frame contain this substring?'. Lets
        tests write ``"OK clicked" in app.text()`` instead of
        ``"OK clicked" in app.cells().text()``."""
        return self.cells(rect=rect).text()

    # Preview-pane geometry in Storybook: 28-col sidebar + 1-col divider,
    # so preview starts around col 30. Y-range after header + Code block
    # lands roughly at rows 22–36. Centralising the magic numbers means
    # smoke cases stop caring about layout drift.
    PREVIEW_RECT: Sequence[int] = (28, 20, 80, 18)

    def preview_cells(self) -> CellSlice:
        """Snapshot the preview-pane region the Storybook layout hands
        each page. Keeps assertions scoped to the page's rendered output
        and avoids matching substrings in the Code block or sidebar.
        Storybook-specific by convention; other apps call ``cells()``."""
        return self.cells(rect=self.PREVIEW_RECT)

    def preview_text(self) -> str:
        return self.preview_cells().text()

    def contains(self, needle: str, rect: Optional[Sequence[int]] = None) -> bool:
        """Substring check over the rendered cells. Replaces the
        ubiquitous ``needle in app.text()`` pattern with a form that's
        easier to assert-message over: ``assert app.contains("OK")``."""
        return needle in self.text(rect=rect)

    def count_glyph(self, glyph: str, rect: Optional[Sequence[int]] = None) -> int:
        """Count occurrences of ``glyph`` in the snapshot. Used by chart
        tests (`█`/braille dots) to verify bar heights monotonicity
        without pixel-exact assertions that would be brittle."""
        return self.text(rect=rect).count(glyph)

    def wait_until(self, predicate: Callable[["Client"], bool],
                   timeout: float = 2.0,
                   interval: float = 0.04) -> bool:
        """Poll until ``predicate(client)`` returns True or ``timeout``
        elapses. Returns the last predicate result — True on success,
        False on timeout. Replaces ``wait_for_frame`` guesses with a
        real condition wait for flakiness-prone assertions."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate(self):
                return True
            time.sleep(interval)
        return predicate(self)

    def goto_storybook_page(self, index: int) -> None:
        """Drive Storybook's sidebar to the page at ``index`` (0-based).
        Sends ``index`` down-arrow events back-to-back and then waits
        one frame for the final page's body to render. Previous versions
        slept 40ms between each press — unnecessary, the runtime drains
        the event queue in a single frame tick and any work done inside
        a page's body is already deterministic."""
        for _ in range(index):
            self.send_key("down")
        self.wait_for_frame(1, timeout=1.0)

    def cells(self,
              rect: Optional[Sequence[int]] = None,
              grid: bool = False) -> CellSlice:
        """Dump rendered cells. ``rect`` defaults to the full frame; pass
        ``grid=True`` to also receive coordinate rulers (handy when eyeballing
        a snapshot to pick probe coordinates)."""
        data = self._call(
            "query_cells",
            rect=list(rect) if rect else None,
            grid=True if grid else None,
        ).result.get("cells") or {}
        return CellSlice(
            x=data.get("x", 0), y=data.get("y", 0),
            width=data.get("width", 0), height=data.get("height", 0),
            rows=tuple(data.get("rows") or ()),
            ruler_top=tuple(data.get("ruler_top") or ()) or None,
            ruler_left=tuple(data.get("ruler_left") or ()) or None,
        )

    def tree(self) -> Mapping[str, Any]:
        """Return the AttributeGraph snapshot as a nested dict. Use for
        structural assertions ('my page contains exactly one TextInput')
        that don't depend on rendered cells."""
        return self._call("query_tree").result.get("tree") or {}

    def probe(self, x: int, y: int) -> Probe:
        """Probe the node at ``(x, y)`` — returns declared values + modifier
        chain, same data the in-app Inspector overlay shows."""
        return self._probe_from(self._call("inspector_probe", x=x, y=y).result.get("inspector"))

    def inspect_range(self,
                      rect: Sequence[int]) -> Sequence[Probe]:
        """Probe every cell in ``rect`` in one round-trip. The crosshair
        follows to the top-left so a human watching the app sees where
        MCP is looking. Capped at 4096 cells — pass smaller rects for huge
        layouts."""
        payload = self._call("inspect_range", rect=list(rect)).result
        return tuple(self._probe_from(p) for p in payload.get("probes") or ())

    def scan(self,
             kind: Optional[str] = None,
             text: Optional[str] = None,
             focused: bool = False) -> Optional[Probe]:
        """Find the first graph node matching one of the supplied criteria.
        Walks the tree (not cells) so it's cheap even for large layouts.
        Returns ``None`` when nothing matches (does not raise)."""
        try:
            data = self._call(
                "scan",
                match_kind=kind, match_text=text,
                match_focused=True if focused else None,
            ).result.get("inspector")
            return self._probe_from(data)
        except RemoteError:
            return None

    def inspector_move(self, x: int, y: int) -> None:
        self._call("inspector_move", x=x, y=y)

    def inspector_toggle(self) -> None:
        self._call("inspector_toggle")

    def frame_number(self) -> int:
        return int(self._call("frame_number").result.get("frame", 0))

    def wait_for_frame(self,
                       frames_ahead: int = 1,
                       timeout: float = 2.0) -> int:
        """Block until the runtime has rendered ``frames_ahead`` more frames
        than the current number, or until ``timeout`` elapses. Returns the
        new frame number. Removes the need for ``sleep`` guesses in tests."""
        start = self.frame_number()
        target = start + frames_ahead
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            current = self.frame_number()
            if current >= target:
                return current
            time.sleep(0.02)
        return self.frame_number()

    def screenshot(self) -> None:
        """Ask the runtime to capture the next rendered frame to disk.
        Files land under the captures directory configured by
        ``.terminalui/terminalui.toml``."""
        self._call("screenshot")

    # -- internal --

    @staticmethod
    def _probe_from(data: Optional[Mapping[str, Any]]) -> Probe:
        # (see implementation below — duplicated declaration guard removed
        # during refactor; real body follows)
        return _probe_from_impl(data)


def _parse_key_expression(expr: str) -> tuple[str, tuple[str, ...]]:
    """Split ``"ctrl+shift+tab"`` into ``("tab", ("ctrl", "shift"))``.

    Chord parts are case-insensitive; the returned modifier names match
    what the Swift dispatcher understands (``ctrl``, ``shift``, ``alt``).
    A bare key (``"enter"``) returns empty modifiers.
    """
    parts = [p.strip() for p in expr.split("+") if p.strip()]
    if not parts:
        raise ValueError(f"empty key expression: {expr!r}")
    *mod_names, key = parts
    modifier_aliases = {
        "cmd": "alt", "command": "alt", "meta": "alt", "option": "alt",
        "ctrl": "ctrl", "control": "ctrl", "shift": "shift", "alt": "alt",
    }
    canonical: list[str] = []
    for name in mod_names:
        lowered = name.lower()
        if lowered not in modifier_aliases:
            raise ValueError(f"unknown modifier '{name}' in {expr!r}")
        canonical.append(modifier_aliases[lowered])
    return key, tuple(canonical)


def _probe_from_impl(data: Optional[Mapping[str, Any]]) -> Probe:
    if data is None:
        return Probe(
            cursor_x=0, cursor_y=0, active=False,
            node_kind=None, node_rect=None,
            declared={}, modifier_chain=(),
        )
    return Probe(
        cursor_x=int(data.get("cursor_x", 0)),
        cursor_y=int(data.get("cursor_y", 0)),
        active=bool(data.get("active", False)),
        node_kind=data.get("node_kind"),
        node_rect=tuple(data.get("node_rect")) if data.get("node_rect") else None,
        declared=dict(data.get("declared") or {}),
        modifier_chain=tuple(data.get("modifier_chain") or ()),
    )
