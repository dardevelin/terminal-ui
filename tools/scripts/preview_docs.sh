#!/usr/bin/env bash
# Preview the DocC documentation locally, resiliently.
#
# This wraps `swift package preview-documentation` to fix two sharp edges:
#
# 1. Port squatting. docc binds a fixed port (8080 by default) and refuses to
#    start if it is taken. The script probes upward from the requested port and
#    passes the first free one via --port.
#
# 2. Orphaned servers. SwiftPM detaches the plugin process (and its docc child)
#    into their own process groups, so SIGTERM to the `swift package` wrapper —
#    what `kill` and `pkill` send by default — kills only the wrapper and leaves
#    docc alive, squatting the port for the next run. SIGINT is different:
#    SwiftPM forwards it to the plugin, which takes docc down with it. The trap
#    below translates INT/TERM/HUP into SIGINT on the wrapper, so however this
#    script is stopped (Ctrl+C, kill, pkill -f preview_docs), nothing outlives it.
#
# Usage:
#   tools/scripts/preview_docs.sh              # target TerminalUI, port 8080+
#   tools/scripts/preview_docs.sh 9000         # start probing at port 9000
#   tools/scripts/preview_docs.sh 9000 TerminalUIIO

set -euo pipefail

port=${1:-8080}
target=${2:-TerminalUI}

port_in_use() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3>&-; true; }
  fi
}

limit=$((port + 100))
while port_in_use "$port"; do
  port=$((port + 1))
  if [ "$port" -gt "$limit" ]; then
    echo "error: no free port found in $((limit - 100))-$limit" >&2
    exit 1
  fi
done

# The local preview serves the same site enhancements the deploy workflow
# injects — the light-mode assessment fix, the docs/tutorials navigation
# pills, and the tutorial slide-over reference pane — by patching a copy of
# the toolchain's render template and serving it via DOCC_HTML_DIR. The
# toolchain itself is never touched.
render_dir="$(dirname "$(xcrun --find docc 2>/dev/null || command -v docc)")/../share/docc/render"
if [ -d "$render_dir" ] && [ -d ".github/pages" ]; then
  patched="$(mktemp -d)/render"
  cp -R "$render_dir" "$patched"
  python3 - "$patched/index.html" <<'PYEOF'
import sys
path = sys.argv[1]
html = open(path).read()
head = "<style>{}\n{}</style>".format(
    open(".github/pages/docc-fixes.css").read(),
    open(".github/pages/reference-pane.css").read(),
)
body = "<script>{}</script>".format(open(".github/pages/reference-pane.js").read())
html = html.replace("</head>", head + "</head>", 1)
html = html.replace("</body>", body + "</body>", 1)
open(path, "w").write(html)
PYEOF
  export DOCC_HTML_DIR="$patched"
fi

echo "Serving documentation for $target at http://localhost:$port/documentation/"

TUI_BUILD_DOCS=1 swift package --disable-sandbox preview-documentation \
  --target "$target" --port "$port" &
wrapper=$!

shutdown() {
  kill -INT "$wrapper" 2>/dev/null || true
}
trap shutdown INT TERM HUP

# A signal interrupts the first wait before the wrapper has exited; the second
# wait rides out the shutdown so the port is guaranteed free on return.
status=0
wait "$wrapper" || status=$?
wait "$wrapper" 2>/dev/null || true
exit "$status"
