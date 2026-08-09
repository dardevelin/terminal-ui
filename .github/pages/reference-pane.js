// Slide-over reference pane for tutorial pages.
//
// Inside a tutorial, links into /documentation/ open in a right-hand panel
// instead of navigating away — the reader keeps their place in the steps and
// can dismiss the reference with Escape, the ✕, or a click on the backdrop.
// Injected at deploy by the docs workflow; plain-page navigation everywhere
// else is untouched.
(function () {
  "use strict";

  function isTutorialPath() {
    return window.location.pathname.indexOf("/tutorials/") !== -1;
  }

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
    if (anchor.closest(".tui-refpane")) return;
    event.preventDefault();
    if (!pane) pane = buildPane();
    pane.show(anchor.href);
  }, true);
})();
