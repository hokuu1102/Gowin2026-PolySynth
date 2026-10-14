// _diag_chord5.js —— 精确测"真正重叠"（按 FPGA 的处理顺序：同 tick 先 OFF 后 ON）
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
const parsed = API.parseMidi(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length));
const conv = API.midiToWords(parsed);
const evs = conv.words.map((w, i) => ({
  tick: Number((w >> 44n) & 0xFFFFFn), kind: Number((w >> 9n) & 0x3n),
  axis: Number((w >> 19n) & 0xFn), src: conv.evTrack[i],
}));

console.log("=".repeat(76));
console.log("精确重叠测量（⭐ 按 FPGA 的处理顺序：同 tick 先处理 OFF 再 ON）");
console.log("=".repeat(76));

const byAxis = new Map();
for (const e of evs) {
  if (!byAxis.has(e.axis)) byAxis.set(e.axis, []);
  byAxis.get(e.axis).push(e);
}
console.log("\n每个 axis 上的【真同时】发声数：");
let worstTuned = 0, worstDrum = 0;
for (const [ax, arr] of [...byAxis].sort((a, b) => a[0] - b[0])) {
  /* ⭐ 关键：同 tick 先 OFF 后 ON（这是 FPGA 看到的顺序，也是我方发的顺序） */
  arr.sort((a, b) => (a.tick - b.tick) || (b.kind - a.kind));
  let cur = 0, mx = 0;
  const hits = [];
  for (const e of arr) {
    if (e.kind === API.KIND_OFF) { if (cur > 0) cur--; }
    else if (e.kind === API.KIND_ON) { cur++; if (cur > mx) { mx = cur; hits.push({ t: e.tick, n: cur }); } }
  }
  if (ax === API.DRUM_AXIS) worstDrum = Math.max(worstDrum, mx);
  else worstTuned = Math.max(worstTuned, mx);
  const warn = (ax !== API.DRUM_AXIS && mx > 1) ? "  <-- ⚠️ 会和弦互抢" : "";
  console.log("    axis " + String(ax).padStart(2) + "  真同时 " + String(mx).padStart(2) +
              (mx > 1 ? "   峰值例: tick=" + hits[hits.length - 1].t : "") + warn);
}
console.log();
console.log("  ⭐ 旋律轴（0..14）最大真同时 = " + worstTuned +
            (worstTuned <= 1 ? "  => ✅ 通过（不会被 same_hit 顶掉）" : "  => 🔴 仍有互抢"));
console.log("  鼓轴（15）最大真同时 = " + worstDrum +
            (worstDrum <= 1 ? "  => ✅ 无重叠"
                            : "  => ⚠️ 鼓有同时敲击（需问 FPGA 侧 same_hit 对鼓的行为）"));

// 统计：有多少个 tick 上有 >=2 个鼓同时敲
if (byAxis.has(API.DRUM_AXIS)) {
  const dArr = byAxis.get(API.DRUM_AXIS);
  const onT = new Map();
  for (const e of dArr) {
    if (e.kind !== API.KIND_ON) continue;
    onT.set(e.tick, (onT.get(e.tick) || 0) + 1);
  }
  let multi = 0, mxm = 0;
  for (const [, n] of onT) { if (n >= 2) multi++; if (n > mxm) mxm = n; }
  console.log("  鼓：同 tick 敲 >=2 件的次数 = " + multi + "，最多 " + mxm + " 件同时");
}
