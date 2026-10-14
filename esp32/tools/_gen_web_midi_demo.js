// _gen_web_midi_demo.js —— 用网页的解析器造一份 events.hex（供真机灌谱验证）
//
// 用途：证明"网页解析 MIDI"这条链【真的能灌进板子】，
//       ⛔ 不是只在 node 里跑通就完事（那是探针假绿）。
//
// 用法：node _gen_web_midi_demo.js
// 产物：_web_midi_demo.hex

const fs = require("fs");
const path = require("path");

const html = fs.readFileSync(path.join(__dirname, "score_studio.html"), "utf8");
const blk = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1])[0];

const fakeCtx = new Proxy({}, {
  get: (t, k) => k === "canvas" ? { width: 1, height: 1 }
    : (k === "measureText" ? () => ({ width: 1 }) : (() => {})), set: () => true });
const fakeEl = () => new Proxy({
  style: {}, classList: { add() {}, remove() {} }, getContext: () => fakeCtx,
  querySelectorAll: () => [], addEventListener() {}, appendChild() {},
  insertAdjacentHTML() {}, getBoundingClientRect: () => ({ left: 0, top: 0, width: 8, height: 6 }),
}, { get: (t, k) => k in t ? t[k] : (typeof k === "string" ? (() => {}) : undefined),
     set: (t, k, v) => { t[k] = v; return true; } });
const doc = { getElementById: () => fakeEl(), querySelector: () => fakeEl(),
  querySelectorAll: () => [], addEventListener() {}, createElement: () => fakeEl(), body: fakeEl() };

const fn = new Function("document", "window", "navigator", "performance", "console",
  "setTimeout", "clearInterval", "setInterval", "requestAnimationFrame",
  "location", "localStorage", "URLSearchParams",
  blk + "\n; return { parseMidi, midiToWords };");
const API = fn(doc, { addEventListener() {} }, { bluetooth: null }, { now: () => 0 },
  console, setTimeout, () => {}, () => 0, () => 0,
  { protocol: "http:", host: "x", search: "" },
  { getItem: () => null, setItem() {} },
  class { constructor() {} get() { return null; } });

// ---- 造 MIDI：BASS 轨 + DRUM 轨 ----
function vlq(n) { const o = [n & 0x7f]; n >>= 7; while (n > 0) { o.unshift((n & 0x7f) | 0x80); n >>= 7; } return o; }
function u32(n) { return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]; }
function u16(n) { return [(n >> 8) & 255, n & 255]; }
function str(s) { return [...s].map(c => c.charCodeAt(0)); }
function nm(s) { return [0xff, 0x03, s.length, ...str(s)]; }   // 长度由字符串算
function track(ev) {
  const b = [];
  for (const e of ev) b.push(...vlq(e[0]), ...e[1]);
  b.push(...vlq(0), 0xff, 0x2f, 0x00);
  return [...str("MTrk"), ...u32(b.length), ...b];
}

// Bass：C3(48) D3(50) E3(52)，各 480 tick（480 PPQN ⇒ 缩放 ×2 到 960）
const trBass = track([
  [0, nm("Bass")],
  [0, [0x90, 48, 100]], [480, [0x80, 48, 0]],
  [0, [0x90, 50, 100]], [480, [0x80, 50, 0]],
  [0, [0x90, 52, 100]], [480, [0x80, 52, 0]],
]);
// Drum：通道 10，音 36/38 交替
const trDrum = track([
  [0, nm("Drum")],
  [0, [0x99, 36, 120]], [240, [0x89, 36, 0]],
  [0, [0x99, 38, 110]], [240, [0x89, 38, 0]],
  [0, [0x99, 36, 120]], [240, [0x89, 36, 0]],
  [0, [0x99, 38, 110]], [240, [0x89, 38, 0]],
]);
const mid = new Uint8Array([...str("MThd"), ...u32(6), ...u16(1), ...u16(2), ...u16(480),
                            ...trBass, ...trDrum]);

const conv = API.midiToWords(API.parseMidi(mid.buffer));
const lines = conv.words.map(w => w.toString(16).padStart(16, "0").toUpperCase());
fs.writeFileSync(path.join(__dirname, "_web_midi_demo.hex"), lines.join("\n") + "\n");
console.log("  写出 _web_midi_demo.hex：" + lines.length + " 个字");
console.log("  BPM = " + conv.bpm + "，tick 最大 = " + conv.tickMax);
console.log("  轨分配：");
for (const a of conv.assign) {
  console.log("    " + a.name + " -> axis " + a.axis + " · " + a.kind + " · " + a.notes + " 音符");
}
