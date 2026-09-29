// lui-drive.js — reference web host adapter for drive's live protocol.
//
// A browser page cannot accept sockets, so topology inverts: run
// `drive --ws-listen <port> <scenario>` and the page dials out to it.
//
// Usage:
//   <script src="lui-drive.js"></script>
//   ... then open the page with ?drive=ws://127.0.0.1:9222
// or call  LuiDrive.attach("ws://127.0.0.1:9222")  explicitly.
//
// Node tagging: elements carry data-lui-node-id="<n>" and
// data-lui-kind="<kind>". Optional data-lui-press-enabled /
// data-lui-enabled / data-lui-text map to LUI props. DOM nesting is
// reported as the node tree. On connect, the client sends one wire
// batch describing the tree, then pushes {"frames":[[id,x,y,w,h],...]}
// snapshots (viewport coords) so drive's `tap x y`/`tap <sel>` hit-test
// against real layout.
//
// Performance: everything is gated on a live connection. Without
// ?drive= (or an explicit attach() call) this file registers no
// listeners, no observers, no timers — it only defines the API.
// While connected, frames are re-measured at most once per animation
// frame, and only after a DOM mutation, scroll, or resize.

const LuiDrive = (() => {
  let ws = null;
  let rafPending = false;
  // ids reported in the previous tree snapshot — DOM nodes removed
  // since then need drop-node ops or they stay as stale orphans in
  // drive's model (expect-absent would give false negatives).
  let lastIds = new Set();

  const nodeEl = (id) =>
    document.querySelector(`[data-lui-node-id="${id}"]`);

  const allNodes = () => document.querySelectorAll("[data-lui-node-id]");

  function boolAttr(el, name) {
    if (!el.hasAttribute(name)) return null;
    const v = el.getAttribute(name);
    return v === "" || v === "true";
  }

  // Emit the node's tree as one wire batch (create/set-prop/insert-child).
  function sendTree() {
    const ops = [];
    const seen = new Set();
    const visit = (el) => {
      const id = parseInt(el.dataset.luiNodeId, 10);
      seen.add(id);
      // data-lui-kind wins (backends report e.g. "lui-button"); fall
      // back to a lui-* class or the tag name.
      const kind =
        (el.dataset.luiKind || "")
          .split(/\s+/)[0]
          .replace(/^lui-/, "") ||
        ((el.className.match(/\blui-(\S+)/) || [])[1] ||
          el.tagName.toLowerCase());
      ops.push({ op: "create-node", id, kind });
      const setProp = (property, value) =>
        ops.push({ op: "set-prop", id, property, value });
      const text = el.dataset.luiText ?? el.textContent.trim();
      if (text) setProp("text", text);
      // id/class visible as prop:id=/prop:class= selectors so
      // scenarios can assert DOM structure the way in-process tests
      // assert extension props.
      if (el.id) setProp("id", el.id);
      const cls = el.getAttribute("class");
      if (cls) setProp("class", cls);
      const pe = boolAttr(el, "data-lui-press-enabled");
      if (pe !== null) setProp("press-enabled", pe);
      const en = boolAttr(el, "data-lui-enabled");
      if (en !== null) setProp("enabled", en);
      const parent = el.parentElement?.closest("[data-lui-node-id]");
      if (parent) {
        const siblings = [...parent.children].filter((c) =>
          c.hasAttribute("data-lui-node-id")
        );
        ops.push({
          op: "insert-child",
          parent: parseInt(parent.dataset.luiNodeId, 10),
          child: id,
          index: siblings.indexOf(el),
        });
      }
      for (const child of el.children) {
        if (child.hasAttribute("data-lui-node-id")) visit(child);
      }
    };
    for (const el of allNodes()) {
      if (!el.parentElement?.closest("[data-lui-node-id]")) visit(el);
    }
    for (const id of lastIds) {
      if (!seen.has(id)) ops.push({ op: "drop-node", id });
    }
    lastIds = seen;
    ws.send(JSON.stringify({ ops }));
  }

  function sendFrames() {
    const frames = [];
    for (const el of allNodes()) {
      const r = el.getBoundingClientRect();
      frames.push([parseInt(el.dataset.luiNodeId, 10), r.x, r.y, r.width, r.height]);
    }
    ws.send(JSON.stringify({ frames }));
  }

  function scheduleFrames() {
    if (rafPending || !ws || ws.readyState !== WebSocket.OPEN) return;
    rafPending = true;
    requestAnimationFrame(() => {
      rafPending = false;
      if (ws && ws.readyState === WebSocket.OPEN) sendFrames();
    });
  }

  // Combos like "mod,k"/"cmd,p" become real modifier flags so
  // global shortcuts (e.g. a palette on mod+k) can be driven from
  // scenarios. `mods` arrives comma-separated from the scenario
  // `key "mod+k"` command.
  function dispatchKeydown(target, key, mods) {
    const flags = {
      metaKey: false,
      ctrlKey: false,
      shiftKey: false,
      altKey: false,
    };
    for (const m of String(mods || "").split(",").map((s) => s.toLowerCase())) {
      if (m === "mod" || m === "cmd" || m === "meta") flags.metaKey = true;
      else if (m === "ctrl" || m === "control") flags.ctrlKey = true;
      else if (m === "shift") flags.shiftKey = true;
      else if (m === "alt" || m === "option") flags.altKey = true;
    }
    target.dispatchEvent(
      new KeyboardEvent("keydown", { key, ...flags, bubbles: true })
    );
  }

  // drive -> host event dispatch: replay as a real DOM event so the
  // page's own handlers run exactly as a user gesture would.
  function dispatchEvent(msg) {
    // key-surface ext events carry {key, mods}; id 0 (no key-surface
    // node in the tree) means a document-level keydown that reaches
    // capture listeners on document.
    if (
      msg.event === "ext" &&
      msg.ident === "key-surface" &&
      msg.name === "key"
    ) {
      const f = msg.fields || {};
      dispatchKeydown(
        nodeEl(msg.id) || document.activeElement || document.body,
        f.key,
        f.mods
      );
      return;
    }
    const el = nodeEl(msg.id);
    if (!el) return;
    switch (msg.event) {
      case "press":
        el.click();
        break;
      case "double-press":
        el.dispatchEvent(new MouseEvent("dblclick", { bubbles: true }));
        break;
      case "long-press":
        el.dispatchEvent(
          new MouseEvent("contextmenu", { bubbles: true })
        );
        break;
      case "text": {
        const input = el.matches("input,textarea")
          ? el
          : el.querySelector("input,textarea");
        if (!input) break;
        input.focus();
        input.value = msg.value ?? "";
        input.dispatchEvent(new Event("input", { bubbles: true }));
        break;
      }
      case "key":
        dispatchKeydown(el, msg.value, msg.mods);
        break;
      default:
        break;
    }
  }

  function dispatchNav(msg) {
    if (msg.hash) location.hash = msg.hash;
  }

  function attach(url) {
    if (ws) return ws;
    // Let the host backend know a drive client is attached before the
    // app mounts, so it can tag DOM nodes (see web.cljc tag-drive-nodes!).
    window.luiDrive = true;
    ws = new WebSocket(url);
    let observer = null;
    const teardown = () => {
      observer?.disconnect();
      window.removeEventListener("resize", scheduleFrames);
      window.removeEventListener("scroll", scheduleFrames, true);
      ws = null;
    };
    ws.onopen = () => {
      sendTree();
      sendFrames();
      observer = new MutationObserver(() => {
        sendTree();
        scheduleFrames();
      });
      observer.observe(document.body, {
        subtree: true,
        childList: true,
        attributes: true,
        characterData: true,
      });
      window.addEventListener("resize", scheduleFrames);
      window.addEventListener("scroll", scheduleFrames, true);
    };
    ws.onmessage = (e) => {
      try {
        const msg = JSON.parse(e.data);
        if (msg.event === "nav") dispatchNav(msg);
        else dispatchEvent(msg);
      } catch (_) {}
    };
    ws.onclose = () => {
      teardown();
      window.luiDrive = undefined;
    };
    ws.onerror = () => ws.close();
    return ws;
  }

  // Auto-attach only when the page opted in via ?drive=ws://...
  const auto = new URLSearchParams(location.search).get("drive");
  if (auto) attach(auto);

  return { attach, sendFrames: scheduleFrames };
})();

if (typeof window !== "undefined") window.LuiDrive = LuiDrive;
