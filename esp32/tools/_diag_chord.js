// _diag_chord.js —— 查"同 tick 的和弦"有没有被正确转换
// 用法：node _diag_chord.js "<文件.mid>"
const fs = require("fs");
const path = require("path");
const midPath = process.argv[2];
if (!midPath || !fs.existsSync(midPath)) { console.error("用法: node _diag_chord.js <文件.mid>"); process.exit(2); }

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
  blk + "\n; return { parseMidi, midiToWords, DRUM_AXIS, KIND_ON, KIND_OFF, incToHz, midiName, hzToMidi, buildScore, packWord };");
const API = fn(doc, { addEventListener() {} }, { bluetooth: null }, { now: () => 0 },
  console, setTimeout, () => {}, () => 0, () => 0,
  { protocol: "http:", host: "x", search: "" },
  { getItem: () => null, setItem() {} },
  class { constructor() {} get() { return null; } });

const buf = fs.readFileSync(midPath);
const parsed = API.parseMidi(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length));

console.log("=".repeat(76));
console.log("和弦诊断：" + path.basename(midPath));
console.log("=".repeat(76));

// ---- ① 原始 MIDI 层：同一个 tick 上有几个 note_on ----
const perTrack = [];
parsed.tracks.forEach((tr, ti) => {
  const byTick = new Map();
  for (const n of tr.notes) {
    if (!n.on) continue;
    if (!byTick.has(n.tick)) byTick.set(n.tick, []);
    byTick.get(n.tick).push(n.midi);
  }
  let chords = 0, maxN = 0, sample = null;
  for (const [t, ms] of byTick) {
    if (ms.length >= 2) {
      chords++;
      if (ms.length > maxN) { maxN = ms.length; sample = { t, ms: ms.slice() }; }
    }
  }
  const totalOn = [...byTick.values()].reduce((s, a) => s + a.length, 0);
  perTrack.push({ ti, name: tr.name, chords, maxN, sample, totalOn, uniqTicks: byTick.size });
  console.log(`  轨${ti} ${JSON.stringify(tr.name).padEnd(14)} note_on ${String(totalOn).padStart(6)} 个, ` +
              `分布在 ${String(byTick.size).padStart(6)} 个 tick 上`);
  console.log(`        同 tick >=2 个音的（和弦）: ${String(chords).padStart(5)} 处, ` +
              `最大同时 ${maxN} 个音` +
              (sample ? `  例: tick=${sample.t} 音高=[${sample.ms.join(",")}]` : ""));
});

// ---- ② 转换后：同一个 tick 上有几个 note_on ----
const conv = API.midiToWords(parsed);
const evs = [];
conv.words.forEach((w, i) => {
  evs.push({
    tick: Number((w >> 44n) & 0xFFFFFn),
    kind: Number((w >> 9n) & 0x3n),
    axis: Number((w >> 19n) & 0xFn),
    inc: Number((w >> 23n) & 0x1FFFFFn),
    src: conv.evTrack[i],
  });
});
const byTick2 = new Map();
for (const e of evs) {
  if (e.kind !== API.KIND_ON) continue;
  if (!byTick2.has(e.tick)) byTick2.set(e.tick, []);
  byTick2.get(e.tick).push(e);
}
let chords2 = 0, max2 = 0, sample2 = null;
for (const [t, arr] of byTick2) {
  if (arr.length >= 2) {
    chords2++;
    if (arr.length > max2) { max2 = arr.length; sample2 = { t, arr: arr.slice() }; }
  }
}
const totalOn2 = [...byTick2.values()].reduce((s, a) => s + a.length, 0);
console.log();
console.log(`  转换后：note_on ${totalOn2} 个, 分布在 ${byTick2.size} 个 tick 上`);
console.log(`          同 tick >=2 的: ${chords2} 处, 最大同时 ${max2} 个` +
            (sample2 ? `  例: tick=${sample2.t}` : ""));
if (sample2) {
  for (const e of sample2.arr) {
    console.log(`            axis=${String(e.axis).padStart(2)}  inc=${String(e.inc).padStart(9)}` +
                `  ${API.incToHz(e.inc).toFixed(1)} Hz  源轨=${e.src}`);
  }
}

// ---- ③ 逐轨对比 ----
console.log();
console.log("  逐轨：原始和弦数 vs 转换后和弦数");
const srcOf = (s) => (s < 0 ? "公共" : (conv.trackList[s] ? conv.trackList[s].name : "?"));
const perSrc = new Map();
for (const e of evs) {
  if (e.kind !== API.KIND_ON) continue;
  const k = e.src;
  if (!perSrc.has(k)) perSrc.set(k, new Map());
  const m = perSrc.get(k);
  if (!m.has(e.tick)) m.set(e.tick, 0);
  m.set(e.tick, m.get(e.tick) + 1);
}
for (const t of perTrack) {
  const m = perSrc.get(t.ti);
  let ch = 0, mx = 0;
  if (m) for (const v of m.values()) { if (v >= 2) ch++; if (v > mx) mx = v; }
  const flag = (ch === t.chords) ? "一致" : `差 ${ch - t.chords}`;
  console.log(`    轨${t.ti} ${JSON.stringify(t.name).padEnd(14)} 原始 ${String(t.chords).padStart(5)}` +
              `  ->  转换后 ${String(ch).padStart(5)}   ${flag}` +
              (mx < t.maxN ? `  ⚠️ 最大同时 ${t.maxN} -> ${mx}` : ""));
}
