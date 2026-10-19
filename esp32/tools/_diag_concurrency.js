// _diag_concurrency.js —— 峰值并发（决定旋律轴够不够；⭐ 方案 B 之后是 12 条：0..11）
//
// ⚠️ 2026-10-15 修 harness：原来缺 `parentElement` ⇒ `fitCanvas()` 抛
//    `cv.parentElement.getBoundingClientRect is not a function`（boot 里未处理的 rejection
//    ⇒ 整个脚本退出码 1）⇒ ⭐ 这个"轴够不够"的唯一现成工具**一直跑不起来**。
//    ⛔ 临时脚本能算，但工具坏着就等于没有 ⇒ 顺手修掉。
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
  /* ⭐ 必须给 parentElement（fitCanvas 要用）—— 见文件头说明 */
  parentElement: { getBoundingClientRect: () => ({ width: 8, height: 6 }) },
  clientWidth: 8, clientHeight: 6, width: 8, height: 6,
  textContent: "", innerHTML: "", checked: false, scrollTop: 0, scrollHeight: 0,
}, { get: (t, k) => k in t ? t[k] : (typeof k === "string" ? (() => {}) : undefined),
     set: (t, k, v) => { t[k] = v; return true; } });
const doc = { getElementById: () => fakeEl(), querySelector: () => fakeEl(),
  querySelectorAll: () => [], addEventListener() {}, createElement: () => fakeEl(), body: fakeEl() };
const fn = new Function("document", "window", "navigator", "performance", "console",
  "setTimeout", "clearInterval", "setInterval", "requestAnimationFrame",
  "location", "localStorage", "URLSearchParams",
  blk + "\n; return { parseMidi, midiToWords, KIND_ON, KIND_OFF, isDrumAxis };");
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
const mel = evs.filter(e => !API.isDrumAxis(e.axis));
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
/* ⭐ 方案 B：鼓占 12..15 ⇒ 旋律可用 0..11 = 12 条（原 15 条）。
 * ⚠️ 这里的 peak 是【去重之后】的（midiToWords 里已做齐奏去重）——
 *    这正是方案 B 要看的数：去重后 <= 12 才够。 */
const AVAIL = 12;
console.log("  可用轴 = 0..11（" + AVAIL + " 条，⛔ 不含鼓轴 12..15）· ⭐ 已按齐奏去重后统计");
console.log("  => " + (peak <= AVAIL ? "✅ 够用（余量 " + (AVAIL - peak) + " 条）"
                                    : "🔴 不够（差 " + (peak - AVAIL) + " 条）"));

// 用到的轴
const axUsed = new Set(mel.map(e => e.axis));
console.log("  实际用到的轴: " + [...axUsed].sort((a, b) => a - b).join(","));
console.log("  是否用到 12..15（鼓轴段）: " +
            ([...axUsed].some(a => a >= 12) ? "是 🔴（旋律不该占鼓轴）" : "否 ✅"));

// 鼓部分峰值
const dr = evs.filter(e => API.isDrumAxis(e.axis));
dr.sort((a, b) => (a.tick - b.tick) || (b.kind - a.kind));
let dc = 0, dp = 0;
for (const e of dr) {
  if (e.kind === API.KIND_OFF) { if (dc > 0) dc--; }
  else if (e.kind === API.KIND_ON) { dc++; if (dc > dp) dp = dc; }
}
console.log("  鼓部分峰值并发 = " + dp + "（⭐ 方案 B：落在 12..15 四条轴上，" +
            "⚠️ 保留池只有 5 路）");
