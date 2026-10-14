// _diag_concurrency.js —— 峰值并发（决定 15 条轴够不够）
const fs = require("fs");
const path = require("path");
const midPath = process.argv[2];
const html = fs.readFileSync(path.join(__dirname, "score_studio.html"), "utf8");
const blk = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1])[0];
const fakeCtx = new Proxy({}, {
  get: (t, k) => k === "canvas" ? { width: 1, height: 1 }
    : (k === "measureText" ? () => ({ width: 10 }) : (() => {})), set: () => true });
const fakeEl = () => new Proxy({
  style: {}, classList: { add() {}, remove() {} }, getContext: () => fakeCtx,
  querySelectorAll: () => [], querySelector: () => null,
  addEventListener() {}, appendChild() {}, insertAdjacentHTML() {},
  getBoundingClientRect: () => ({ left: 0, top: 0, width: 8, height: 6 }),
  textContent: "", innerHTML: "", checked: false,
}, { get: (t, k) => k in t ? t[k] : (typeof k === "string" ? (() => {}) : undefined),
     set: (t, k, v) => { t[k] = v; return true; } });
const doc = { getElementById: () => fakeEl(), querySelector: () => fakeEl(),
  querySelectorAll: () => [], addEventListener() {}, createElement: () => fakeEl(), body: fakeEl() };
const fn = new Function("document", "window", "navigator", "performance", "console",
  "setTimeout", "clearInterval", "setInterval", "requestAnimationFrame",
  "location", "localStorage", "URLSearchParams",
  blk + "\n; return { parseMidi, midiToWords, KIND_ON, KIND_OFF, DRUM_AXIS };");
const API = fn(doc, { addEventListener() {} }, { bluetooth: null }, { now: () => 0 },
  console, setTimeout, () => {}, () => 0, () => 0,
  { protocol: "http:", host: "x", search: "" },
  { getItem: () => null, setItem() {} },
  class { constructor() {} get() { return null; } });

const buf = fs.readFileSync(midPath);
const conv = API.midiToWords(API.parseMidi(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length)));
const evs = conv.words.map((w, i) => ({
  tick: Number((w >> 44n) & 0xFFFFFn), kind: Number((w >> 9n) & 0x3n),
  axis: Number((w >> 19n) & 0xFn),
}));

// 旋律部分的峰值并发（按 FPGA 顺序：同 tick 先 OFF 后 ON）
const mel = evs.filter(e => e.axis !== API.DRUM_AXIS);
mel.sort((a, b) => (a.tick - b.tick) || (b.kind - a.kind));
let cur = 0, peak = 0, peakTick = 0;
for (const e of mel) {
  if (e.kind === API.KIND_OFF) { if (cur > 0) cur--; }
  else if (e.kind === API.KIND_ON) { cur++; if (cur > peak) { peak = cur; peakTick = e.tick; } }
}
console.log("=".repeat(70));
console.log("峰值并发（决定需要多少条轴）");
console.log("=".repeat(70));
console.log("  旋律部分峰值并发 = " + peak + "（在 tick " + peakTick + "）");
console.log("  可用轴 = 0..14（15 条，⛔ 不含鼓轴 15）");
console.log("  => " + (peak <= 15 ? "✅ 够用（余量 " + (15 - peak) + " 条）"
                                  : "🔴 不够（差 " + (peak - 15) + " 条）"));

// 用到的轴
const axUsed = new Set(mel.map(e => e.axis));
console.log("  实际用到的轴: " + [...axUsed].sort((a, b) => a - b).join(","));
console.log("  是否用到 14（节拍器的 AXIS_ID）: " +
            (axUsed.has(14) ? "是 ⚠️" : "否"));

// 鼓部分峰值
const dr = evs.filter(e => e.axis === API.DRUM_AXIS);
dr.sort((a, b) => (a.tick - b.tick) || (b.kind - a.kind));
let dc = 0, dp = 0;
for (const e of dr) {
  if (e.kind === API.KIND_OFF) { if (dc > 0) dc--; }
  else if (e.kind === API.KIND_ON) { dc++; if (dc > dp) dp = dc; }
}
console.log("  鼓部分峰值并发 = " + dp + "（⚠️ 全部落在 axis 15）");
