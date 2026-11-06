#!/usr/bin/env node
// Node 22+; no npm dependencies. Attach to one explicitly selected Chromium tab.
import { readFile } from "node:fs/promises";
import { parseArgs } from "node:util";

const { values } = parseArgs({ options: {
  cdp: { type: "string" }, url: { type: "string" }, drive: { type: "string" },
} });
if (!values.cdp || !values.url || !values.drive)
  throw new Error("usage: node web/cdp-host.mjs --cdp http://127.0.0.1:9222 --url <exact-page-url> --drive ws://127.0.0.1:9223");

function localUrl(value, protocol) {
  const url = new URL(value);
  if (url.protocol !== protocol || !["127.0.0.1", "localhost", "[::1]"].includes(url.hostname))
    throw new Error("debug transports must be loopback-only");
  return url;
}

async function socket(url) {
  const ws = new WebSocket(url);
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { ws.close(); reject(new Error("WebSocket connect timed out")); }, 5000);
    ws.addEventListener("open", () => { clearTimeout(timer); resolve(); }, { once: true });
    ws.addEventListener("error", () => { clearTimeout(timer); reject(new Error("WebSocket connect failed")); }, { once: true });
  });
  return ws;
}

const discovery = localUrl(values.cdp, "http:");
const driveUrl = localUrl(values.drive, "ws:");
if (new URL(values.url).searchParams.has("drive"))
  throw new Error("remove ?drive= from the page URL: CDP owns the single host connection");
const response = await fetch(new URL("/json/list", discovery), { signal: AbortSignal.timeout(5000) });
if (!response.ok) throw new Error(`CDP discovery: HTTP ${response.status}`);
const pages = (await response.json()).filter((p) => p.type === "page" && p.url === values.url);
if (pages.length !== 1) throw new Error(`expected exactly one tab at ${values.url}, found ${pages.length}`);
const cdp = await socket(localUrl(pages[0].webSocketDebuggerUrl, "ws:"));
const pending = new Map();
let sequence = 0;
function command(method, params = {}) {
  if (cdp.readyState !== WebSocket.OPEN) return Promise.reject(new Error("CDP disconnected"));
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timed out`)); }, 5000);
    pending.set(id, { resolve, reject, timer });
    cdp.send(JSON.stringify({ id, method, params }));
  });
}
cdp.addEventListener("message", ({ data }) => {
  const message = JSON.parse(data);
  const waiter = pending.get(message.id);
  if (!waiter) return;
  pending.delete(message.id);
  clearTimeout(waiter.timer);
  if (message.error) waiter.reject(new Error(message.error.message));
  else waiter.resolve(message.result);
});
cdp.addEventListener("close", () => {
  for (const p of pending.values()) { clearTimeout(p.timer); p.reject(new Error("CDP disconnected")); }
  pending.clear();
});
async function evaluate(expression) {
  const result = await command("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  if (result.exceptionDetails)
    throw new Error((result.exceptionDetails.exception?.description || result.exceptionDetails.text).split("\n")[0]);
  return result.result.value;
}

const source = await readFile(new URL("./lui-drive.js", import.meta.url), "utf8");
const snapshotExpression = `(() => {
  if (!globalThis.LuiDrive?.snapshot) { ${source} }
  return globalThis.LuiDrive.snapshot();
})()`;
await command("Page.enable");
await command("Page.bringToFront");
const mac = await evaluate("/Mac/.test(navigator.platform)");
const drive = await socket(driveUrl);
const send = (message) => drive.send(JSON.stringify(message));
let previous = "";
async function snapshot() {
  const state = await evaluate(snapshotExpression);
  if (!state.ops.some((op) => op.op === "create-node"))
    throw new Error("page has no data-lui-node-id nodes; enable host node tagging before attaching");
  const encoded = JSON.stringify(state);
  if (encoded !== previous) {
    send({ ops: state.ops });
    send({ frames: state.frames });
    previous = encoded;
  }
}

async function settle() {
  await evaluate(`new Promise((resolve, reject) => {
    const start = performance.now();
    let changed = start, last = "";
    const observer = new MutationObserver(() => { changed = performance.now(); });
    observer.observe(document.documentElement, { subtree: true, attributes: true, childList: true, characterData: true });
    const timer = setTimeout(() => { observer.disconnect(); reject(new Error("UI did not settle within 2s")); }, 2000);
    function frame() {
      const now = performance.now();
      const rects = JSON.stringify([...document.querySelectorAll("[data-lui-node-id]")].map(el => {
        const r = el.getBoundingClientRect();
        return [r.x, r.y, r.width, r.height, el.scrollLeft, el.scrollTop];
      }));
      if (rects !== last) { last = rects; changed = now; }
      const animating = document.getAnimations().some(a =>
        a.playState === "running" && a.effect?.getComputedTiming().iterations !== Infinity);
      if (!animating && now - changed >= 100) {
        observer.disconnect(); clearTimeout(timer); resolve();
      } else if (now - start < 2000) requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  })`);
}

async function position(id, editable = false, scroll = true) {
  if (!Number.isSafeInteger(id)) throw new Error("invalid node id");
  return evaluate(`(async () => {
    const nodes = document.querySelectorAll('[data-lui-node-id="${id}"]');
    if (nodes.length !== 1) throw new Error("target #${id} is missing or ambiguous");
    let el = nodes[0];
    if (${editable}) {
      if (!el.matches("input,textarea,[contenteditable=true]")) el = el.querySelector("input,textarea,[contenteditable=true]");
      if (!el || el.readOnly || (el.tagName === "INPUT" && !["text", "search", "url", "tel", "email", "password", "number"].includes(el.type)))
        throw new Error("target is not editable");
    }
    if (el.matches(":disabled") || el.closest('[inert],[aria-disabled="true"],[data-lui-enabled="false"]'))
      throw new Error("target is disabled");
    if (!el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) throw new Error("target is hidden");
    if (${scroll}) el.scrollIntoView({ behavior: "instant", block: "center", inline: "center" });
    await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
    if (!el.isConnected) throw new Error("target was removed before input");
    const r = el.getBoundingClientRect();
    const x = r.x + r.width / 2, y = r.y + r.height / 2;
    if (r.width <= 0 || r.height <= 0 || x < 0 || y < 0 || x >= innerWidth || y >= innerHeight)
      throw new Error("target center is outside the viewport");
    const hit = document.elementFromPoint(x, y);
    if (!hit || !el.contains(hit)) throw new Error("target is occluded");
    return { x, y };
  })()`);
}

const mouse = (type, point, extra = {}) => command("Input.dispatchMouseEvent", { type, ...point, ...extra });
async function click(point, count = 1, hold = 0) {
  await mouse("mouseMoved", point);
  for (let n = 1; n <= count; n++) {
    await mouse("mousePressed", point, { button: "left", buttons: 1, clickCount: n });
    try { if (hold) await new Promise(r => setTimeout(r, hold)); }
    finally { await mouse("mouseReleased", point, { button: "left", buttons: 0, clickCount: n }); }
  }
}

const namedKeys = {
  Enter: ["Enter", 13, "\r"], Tab: ["Tab", 9, "\t"], Escape: ["Escape", 27],
  Backspace: ["Backspace", 8], Delete: ["Delete", 46], Space: ["Space", 32, " "],
  ArrowLeft: ["ArrowLeft", 37], ArrowUp: ["ArrowUp", 38], ArrowRight: ["ArrowRight", 39], ArrowDown: ["ArrowDown", 40],
  Home: ["Home", 36], End: ["End", 35], PageUp: ["PageUp", 33], PageDown: ["PageDown", 34],
};
const modifierKeys = {
  alt: [1, "Alt", "AltLeft", 18], ctrl: [2, "Control", "ControlLeft", 17],
  meta: [4, "Meta", "MetaLeft", 91], shift: [8, "Shift", "ShiftLeft", 16],
};
async function key(combo) {
  const parts = combo.split("+");
  let name = parts.pop();
  const modifiers = [...new Set(parts.map(m => {
    const normalized = ({ mod: mac ? "meta" : "ctrl", cmd: "meta", control: "ctrl", option: "alt" })[m.toLowerCase()] || m.toLowerCase();
    if (!modifierKeys[normalized]) throw new Error(`unsupported key modifier: ${m}`);
    return normalized;
  }))];
  if (name === "Esc") name = "Escape";
  let info = namedKeys[name];
  if (!info && /^[a-zA-Z0-9]$/.test(name))
    info = [/\d/.test(name) ? `Digit${name}` : `Key${name.toUpperCase()}`, name.toUpperCase().charCodeAt(0), name];
  if (!info) throw new Error(`unsupported key: ${name}; use type for arbitrary text`);
  const [code, vk, text] = info;
  const held = [];
  let flags = 0;
  try {
    for (const m of modifiers) {
      const [bit, key, code, vk] = modifierKeys[m]; flags |= bit;
      await command("Input.dispatchKeyEvent", { type: "rawKeyDown", key, code, windowsVirtualKeyCode: vk, modifiers: flags });
      held.push(m);
    }
    const character = text && !(flags & 7) ? ((flags & 8) ? text.toUpperCase() : text) : undefined;
    const event = { key: namedKeys[name] ? (name === "Space" ? " " : name) : character || name,
      code, windowsVirtualKeyCode: vk, modifiers: flags };
    await command("Input.dispatchKeyEvent", { type: character ? "keyDown" : "rawKeyDown", ...event, text: character });
    await command("Input.dispatchKeyEvent", { type: "keyUp", ...event });
  } finally {
    for (const m of held.reverse()) {
      const [bit, key, code, vk] = modifierKeys[m]; flags &= ~bit;
      await command("Input.dispatchKeyEvent", { type: "keyUp", key, code, windowsVirtualKeyCode: vk, modifiers: flags });
    }
  }
}

async function perform(msg) {
  switch (msg.action) {
    case "click": await click(await position(msg.id)); break;
    case "double-click": await click(await position(msg.id), 2); break;
    case "long-click": await click(await position(msg.id), 1, 600); break;
    case "tap":
      if (!Number.isFinite(msg.x) || !Number.isFinite(msg.y)) throw new Error("invalid coordinates");
      if (!await evaluate(`(${msg.x} >= 0 && ${msg.y} >= 0 && ${msg.x} < innerWidth && ${msg.y} < innerHeight)`))
        throw new Error("tap is outside viewport");
      await click({ x: msg.x, y: msg.y }); break;
    case "type":
      await click(await position(msg.id, true));
      await key("mod+a");
      if (msg.text === "") await key("Backspace");
      else await command("Input.insertText", { text: msg.text });
      break;
    case "key": await key(msg.combo); break;
    case "scroll": {
      if (!Number.isFinite(msg.dx) || !Number.isFinite(msg.dy)) throw new Error("invalid scroll deltas");
      const point = await position(msg.id);
      await mouse("mouseMoved", point);
      await mouse("mouseWheel", point, { deltaX: msg.dx, deltaY: msg.dy }); break;
    }
    case "drag": {
      await position(msg.id);
      const end = await position(msg.target), start = await position(msg.id, false, false);
      await mouse("mouseMoved", start);
      await mouse("mousePressed", start, { button: "left", buttons: 1, clickCount: 1 });
      try {
        for (let i = 1; i <= 12; i++) {
          await mouse("mouseMoved", { x: start.x + (end.x - start.x) * i / 12, y: start.y + (end.y - start.y) * i / 12 }, { button: "left", buttons: 1 });
          await new Promise(r => setTimeout(r, 16));
        }
      } finally { await mouse("mouseReleased", end, { button: "left", buttons: 0, clickCount: 1 }); }
      break;
    }
    case "settle": break;
    case "screenshot": break;
    default: throw new Error(`unsupported native action: ${msg.action}`);
  }
  await settle();
  await snapshot();
  if (msg.action === "screenshot") {
    const { data } = await command("Page.captureScreenshot", { format: "png" });
    return { png: data };
  }
  return {};
}

let chain = Promise.resolve();
let stopping = false;
const capabilities = ["click", "double-click", "long-click", "tap", "type", "key", "scroll", "drag", "screenshot", "settle"];
drive.addEventListener("message", ({ data }) => {
  chain = chain.then(async () => {
    const msg = JSON.parse(data);
    if (msg.drive !== "action" || msg.version !== 1 || !Number.isSafeInteger(msg.request))
      throw new Error("CDP host requires version 1 native action requests; run drive --input native");
    try {
      const result = await perform(msg);
      send({ drive: "result", version: 1, request: msg.request, ok: true, ...result });
    } catch (error) {
      send({ drive: "result", version: 1, request: msg.request, ok: false, error: error.message });
    }
  }).catch(fatal);
});
function fatal(error) {
  if (stopping) return;
  stopping = true;
  console.error(`cdp-host: ${error.message}`);
  process.exitCode = 1;
  drive.close(); cdp.close();
}
send({ drive: "hello", version: 1, capabilities });
try { await snapshot(); } catch (error) { fatal(error); }
let scheduled = false;
const timer = setInterval(() => {
  if (stopping || scheduled) return;
  scheduled = true;
  chain = chain.then(() => { if (!stopping) return snapshot(); })
    .catch(fatal).finally(() => { scheduled = false; });
}, 100);
drive.addEventListener("close", () => { stopping = true; clearInterval(timer); cdp.close(); });
cdp.addEventListener("close", () => {
  clearInterval(timer);
  if (!stopping) fatal(new Error("CDP disconnected"));
});
