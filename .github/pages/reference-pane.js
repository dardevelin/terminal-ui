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
    var brand = document.createElement("a");
    brand.className = "tui-docs-brand";
    brand.href = base + "/";
    var mascot = document.createElement("img");
    mascot.alt = "";
    mascot.src = "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0MDAgNTc2IiB3aWR0aD0iNDAwIiBoZWlnaHQ9IjU3NiI+IDxkZWZzPiA8c3R5bGU+IC5iZyAgICAgeyBmaWxsOiAjMEEwQTBBOyB9IC5vcmFuZ2UgeyBmaWxsOiAjRjI5OTRBOyB9IC5ydXN0ICAgeyBmaWxsOiAjQTU2QTJFOyB9IC5waW5rICAgeyBmaWxsOiAjRjlDNkI4OyB9IC53aGl0ZSAgeyBmaWxsOiAjRjRGNEY0OyB9IC5ncmVlbiAgeyBmaWxsOiAjN0RFM0E2OyB9IC5ub3NlICAgeyBmaWxsOiAjMDgwODA4OyB9IDwvc3R5bGU+IDwvZGVmcz4gPHJlY3QgY2xhc3M9ImJnIiB3aWR0aD0iNDAwIiBoZWlnaHQ9IjU3NiIgcng9IjI0Ii8+IDxnIHRyYW5zZm9ybT0idHJhbnNsYXRlKDQwLDMyKSI+IDxwb2x5Z29uIGNsYXNzPSJydXN0IiBwb2ludHM9IjAsOTYgICAgMzIsMzIgICA2NCw5NiIvPiA8cG9seWdvbiBjbGFzcz0icnVzdCIgcG9pbnRzPSIyNTYsOTYgIDI4OCwzMiAgMzIwLDk2Ii8+IDxwb2x5Z29uIGNsYXNzPSJvcmFuZ2UiIHBvaW50cz0iMCwyMjQgICAzMiwxNjAgICA2NCwyMjQiLz4gPHBvbHlnb24gY2xhc3M9InBpbmsiICAgcG9pbnRzPSI2NCwyMjQgIDk2LDE2MCAgMTI4LDIyNCIvPiA8cG9seWdvbiBjbGFzcz0ib3JhbmdlIiBwb2ludHM9IjEyOCwyMjQgMTYwLDE2MCAxOTIsMjI0Ii8+IDxwb2x5Z29uIGNsYXNzPSJwaW5rIiAgIHBvaW50cz0iMTkyLDIyNCAyMjQsMTYwIDI1NiwyMjQiLz4gPHBvbHlnb24gY2xhc3M9Im9yYW5nZSIgcG9pbnRzPSIyNTYsMjI0IDI4OCwxNjAgMzIwLDIyNCIvPiA8cmVjdCBjbGFzcz0ib3JhbmdlIiB4PSIwIiAgIHk9IjI1NiIgd2lkdGg9IjY0IiBoZWlnaHQ9IjEyOCIvPiA8cmVjdCBjbGFzcz0ib3JhbmdlIiB4PSIxMjgiIHk9IjI1NiIgd2lkdGg9IjY0IiBoZWlnaHQ9IjEyOCIvPiA8cmVjdCBjbGFzcz0ib3JhbmdlIiB4PSIyNTYiIHk9IjI1NiIgd2lkdGg9IjY0IiBoZWlnaHQ9IjEyOCIvPiA8Y2lyY2xlIGNsYXNzPSJncmVlbiIgY3g9Ijk2IiAgY3k9IjMyMCIgcj0iMjQiLz4gPGNpcmNsZSBjbGFzcz0iZ3JlZW4iIGN4PSIyMjQiIGN5PSIzMjAiIHI9IjI0Ii8+IDxyZWN0IGNsYXNzPSJ3aGl0ZSIgeD0iMCIgICB5PSIzODQiIHdpZHRoPSI2NCIgaGVpZ2h0PSI2NCIvPiA8cmVjdCBjbGFzcz0id2hpdGUiIHg9IjMyIiAgeT0iNDQ4IiB3aWR0aD0iMzIiIGhlaWdodD0iNjQiLz4gPHJlY3QgY2xhc3M9IndoaXRlIiB4PSI2NCIgIHk9IjM4NCIgd2lkdGg9IjY0IiBoZWlnaHQ9IjY0Ii8+IDxwb2x5Z29uIGNsYXNzPSJub3NlIiBwb2ludHM9IjEyOCw0MTYgMTkyLDQxNiAxNjAsNDgwIi8+IDxyZWN0IGNsYXNzPSJ3aGl0ZSIgeD0iMTkyIiB5PSIzODQiIHdpZHRoPSI2NCIgaGVpZ2h0PSI2NCIvPiA8cmVjdCBjbGFzcz0id2hpdGUiIHg9IjI1NiIgeT0iMzg0IiB3aWR0aD0iNjQiIGhlaWdodD0iNjQiLz4gPHJlY3QgY2xhc3M9IndoaXRlIiB4PSIyNTYiIHk9IjQ0OCIgd2lkdGg9IjMyIiBoZWlnaHQ9IjY0Ii8+IDwvZz4gPC9zdmc+";
    brand.appendChild(mascot);
    brand.appendChild(document.createTextNode("TerminalUI"));
    nav.appendChild(brand);
    [
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

  // Symmetric: from a tutorial, reference links peek open; from the
  // reference, tutorial links peek open. Either way the reader sees where
  // the link leads and chooses "Open full page" deliberately instead of
  // being navigated away.
  document.addEventListener("click", function (event) {
    var anchor = event.target.closest && event.target.closest("a[href]");
    if (!anchor) return;
    if (anchor.closest(".tui-refpane") || anchor.closest(".tui-docs-nav")) return;
    var href = anchor.getAttribute("href");
    if (!href) return;
    var toReference = isTutorialPath() && href.indexOf("/documentation/") !== -1;
    var toTutorial = !isTutorialPath() && href.indexOf("/tutorials/") !== -1;
    if (!toReference && !toTutorial) return;
    event.preventDefault();
    if (!pane) pane = buildPane();
    pane.show(anchor.href);
  }, true);
})();
