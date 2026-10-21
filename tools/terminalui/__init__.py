"""Python client for the TerminalUI remote-control socket.

Every TerminalUI debug build exposes a Unix-domain socket at
``/tmp/terminalui-{checkout}-{pid}/remote/<pid>.sock``. This package wraps the JSON
protocol with a typed client so smoke tests and MCP servers can drive a
running app without hand-crafting bash + jq pipelines.

Quick start::

    from terminalui import Client
    with Client(pid=app_pid) as app:
        app.send_key("tab")
        focus = app.focus()
        assert focus.kind == "ScrollView(V)"

See ``scripts/storybook_walk.py`` for a full Storybook smoke test.
"""

from .client import (
    Client,
    Response,
    Focus,
    CellSlice,
    Probe,
    RemoteError,
)

__all__ = [
    "Client",
    "Response",
    "Focus",
    "CellSlice",
    "Probe",
    "RemoteError",
]
