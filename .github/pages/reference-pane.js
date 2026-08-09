// Site enhancements injected into every DocC page (deploy workflow) and into
// the local preview's patched template (tools/scripts/preview_docs.sh):
//
// 1. A slim navigation pill row uniting the three surfaces — landing,
//    tutorials, API reference — so neither side feels like a dead end.
// 2. On tutorial pages, links into /documentation/ open in a slide-over
//    panel instead of navigating away: the reader keeps their place in the
//    steps and dismisses with Escape, the ✕, or the backdrop.
(function () {
  "use strict";

  // Base path: on github.io project pages every route starts with the repo
  // segment; locally routes start at /documentation or /tutorials directly.
  function basePath() {
    var first = window.location.pathname.split("/")[1] || "";
    return (first === "documentation" || first === "tutorials") ? "" : "/" + first;
  }

  function isTutorialPath() {
    return window.location.pathname.indexOf("/tutorials/") !== -1;
  }

  // --- navigation pills ----------------------------------------------------

  function buildNav() {
    var base = basePath();
    var nav = document.createElement("nav");
    nav.className = "tui-docs-nav";
    nav.setAttribute("aria-label", "TerminalUI documentation sections");
    [
      ["Home", base + "/"],
      ["Tutorials", base + "/tutorials/terminaluitutorials"],
      ["Reference", base + "/documentation/terminalui/"],
    ].forEach(function (entry) {
      var link = document.createElement("a");
      link.textContent = entry[0];
      link.href = entry[1];
      nav.appendChild(link);
    });
    document.body.appendChild(nav);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", buildNav);
  } else {
    buildNav();
  }

  // --- slide-over reference pane (tutorial pages only) ---------------------

  var pane = null;

  function buildPane() {
    var backdrop = document.createElement("div");
    backdrop.className = "tui-refpane-backdrop";
    var panel = document.createElement("div");
    panel.className = "tui-refpane";
    var bar = document.createElement("div");
    bar.className = "tui-refpane-bar";
    var open = document.createElement("a");
    open.textContent = "Open full page ↗";
    open.className = "tui-refpane-open";
    open.target = "_blank";
    var close = document.createElement("button");
    close.textContent = "✕";
    close.className = "tui-refpane-close";
    close.setAttribute("aria-label", "Close reference panel");
    var frame = document.createElement("iframe");
    frame.className = "tui-refpane-frame";
    bar.appendChild(open);
    bar.appendChild(close);
    panel.appendChild(bar);
    panel.appendChild(frame);
    backdrop.appendChild(panel);
    document.body.appendChild(backdrop);

    function hide() { backdrop.classList.remove("tui-refpane-visible"); }
    close.addEventListener("click", hide);
    backdrop.addEventListener("click", function (event) {
      if (event.target === backdrop) hide();
    });
    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape") hide();
    });

    return {
      show: function (href) {
        frame.src = href;
        open.href = href;
        backdrop.classList.add("tui-refpane-visible");
      },
    };
  }

  document.addEventListener("click", function (event) {
    if (!isTutorialPath()) return;
    var anchor = event.target.closest && event.target.closest("a[href]");
    if (!anchor) return;
    var href = anchor.getAttribute("href");
    if (!href || href.indexOf("/documentation/") === -1) return;
    if (anchor.closest(".tui-refpane") || anchor.closest(".tui-docs-nav")) return;
    event.preventDefault();
    if (!pane) pane = buildPane();
    pane.show(anchor.href);
  }, true);
})();
