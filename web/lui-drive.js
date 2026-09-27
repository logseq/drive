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
    const visit = (el) => {
      const id = parseInt(el.dataset.luiNodeId, 10);
      const kind = el.dataset.luiKind || el.tagName.toLowerCase();
      ops.push({ op: "create-node", id, kind });
      const setProp = (property, value) =>
        ops.push({ op: "set-prop", id, property, value });
      const text = el.dataset.luiText ?? el.textContent.trim();
      if (text) setProp("text", text);
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

  // drive -> host event dispatch: replay as a real DOM event so the
  // page's own handlers run exactly as a user gesture would.
  function dispatchEvent(msg) {
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
      case "text":
        el.focus();
        el.value = msg.value ?? "";
        el.dispatchEvent(new Event("input", { bubbles: true }));
        break;
      case "key":
        el.dispatchEvent(
          new KeyboardEvent("keydown", { key: msg.value, bubbles: true })
        );
        break;
      default:
        break;
    }
  }

  function attach(url) {
    if (ws) return ws;
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
        dispatchEvent(JSON.parse(e.data));
      } catch (_) {}
    };
    ws.onclose = teardown;
    ws.onerror = () => ws.close();
    return ws;
  }

  // Auto-attach only when the page opted in via ?drive=ws://...
  const auto = new URLSearchParams(location.search).get("drive");
  if (auto) attach(auto);

  return { attach, sendFrames: scheduleFrames };
})();

if (typeof window !== "undefined") window.LuiDrive = LuiDrive;
