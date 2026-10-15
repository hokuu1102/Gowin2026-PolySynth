// _dur_check.js —— 查"时值过长/重叠"是转换器的问题还是显示层的问题
// 用法：node _dur_check.js "<文件.mid>"
const fs = require("fs");
const path = require("path");
const midPath = process.argv[2];
const html = fs.readFileSync(path.join(__dirname, "score_studio.html"), "utf8");
const blk = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1])[0];
const fakeCtx = { canvas: { width: 800, height: 400 }, measureText: () => ({ width: 10 }),
  fillText() {}, fillRect() {}, strokeRect() {}, beginPath() {}, moveTo() {}, lineTo() {},
  stroke() {}, fill() {}, save() {}, restore() {}, setLineDash() {}, clearRect() {},
  closePath() {}, roundRect() {} };
const el = () => ({ style: {}, classList: { add() {}, remove() {} }, getContext: () => fakeCtx,
  querySelectorAll: () => [], querySelector: () => null, addEventListener() {},
  appendChild() {}, insertAdjacentHTML() {},
  getBoundingClientRect: () => ({ left: 0, top: 0, width: 800, height: 400 }),
  textContent: "", innerHTML: "", checked: false, width: 800, height: 400,
  clientWidth: 800, clientHeight: 400,
  parentElement: { getBoundingClientRect: () => ({ width: 800, height: 400 }) } });
const doc = { getElementById: () => el(), querySelector: () => el(), querySelectorAll: () => [],
  addEventListener() {}, createElement: () => el(), body: el() };
const fn = new Function("document", "window", "navigator", "performance", "console",
  "setTimeout", "clearInterval", "setInterval", "requestAnimationFrame",
  "location", "localStorage", "URLSearchParams",
  blk + "; return { parseMidi, midiToWords, buildScore, KIND_ON, KIND_OFF, isDrumAxis, " +
  "MIDI_PPQN };");
const API = fn(doc, { addEventListener() {} }, { bluetooth: null }, { now: () => 0 },
  console, setTimeout, () => {}, () => 0, () => 0,
  { protocol: "http:", host: "x", search: "" },
  { getItem: () => null, setItem() {} },
  class { constructor() {} get() { return null; } });

const buf = fs.readFileSync(midPath);
const parsed = API.parseMidi(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length));
const SCALE = API.MIDI_PPQN / parsed.division;

console.log("=".repeat(78));
console.log("时值诊断：" + path.basename(midPath));
console.log("=".repeat(78));
console.log("  division=" + parsed.division + "  scale=" + SCALE);

/* ---- ① 原始 MIDI 的时值（按音高 FIFO 配对）---- */
const rawDurs = [];
let rawOpen = 0;
parsed.tracks.forEach((tr) => {
  const q = new Map();
  const notes = tr.notes.slice().sort((a, b) => a.tick - b.tick);
  for (const n of notes) {
    if (n.on) {
      if (!q.has(n.midi)) q.set(n.midi, []);
      q.get(n.midi).push(n.tick);
      rawOpen++;
    } else {
      const a = q.get(n.midi);
      if (a && a.length) { rawDurs.push(n.tick - a.shift()); rawOpen--; }
    }
  }
});

/* ---- ② 转换后的时值（按 axis+inc 配对）---- */
const conv = API.midiToWords(parsed);
const evs = conv.words.map((w, i) => ({
  tick: Number((w >> 44n) & 0xFFFFFn), kind: Number((w >> 9n) & 0x3n),
  axis: Number((w >> 19n) & 0xFn), inc: Number((w >> 23n) & 0x1FFFFFn),
}));
const convDurs = [];
{
  const q = new Map();
  for (const e of evs.slice().sort((a, b) => (a.tick - b.tick) || (b.kind - a.kind))) {
    const k = e.axis + "|" + e.inc;
    if (e.kind === API.KIND_ON) { if (!q.has(k)) q.set(k, []); q.get(k).push(e.tick); }
    else if (e.kind === API.KIND_OFF) {
      const a = q.get(k);
      if (a && a.length) convDurs.push(e.tick - a.shift());
    }
  }
}

/* ---- ③ 显示层：buildScore 出来的段（这才是画出来的）---- */
const sc = API.buildScore(conv.words, "x");
const segs = (sc.noteSegs || []).concat(sc.drumSegs || []);
const segDurs = segs.filter(s => s.t1 != null).map(s => s.t1 - s.t0);
const segUnclosed = segs.filter(s => s.t1 == null).length;

function stat(name, arr, unit) {
  if (!arr.length) { console.log("  " + name + "：无样本"); return; }
  const a = arr.slice().sort((x, y) => x - y);
  const q = p => a[Math.floor(a.length * p)];
  console.log("  " + name.padEnd(22) + " n=" + String(a.length).padStart(6) +
    "  p10=" + String(q(0.1)).padStart(6) + " p50=" + String(q(0.5)).padStart(6) +
    " p90=" + String(q(0.9)).padStart(6) + " max=" + String(a[a.length - 1]).padStart(7) +
    "  (" + unit + ")");
}

console.log();
console.log("① 时值分布对比（tick）");
stat("原始 MIDI", rawDurs.map(d => d * SCALE), "已缩放到 960PPQN");
stat("转换器输出", convDurs, "tick");
stat("显示层段", segDurs, "tick");

console.log();
console.log("② 未闭合的段（时值会被兜底拉长）");
console.log("  转换器：未闭合 on 的队列长度合计 = " +
  (convDurs.length === evs.filter(e => e.kind === API.KIND_ON).length ? "0" : "非 0"));
console.log("  显示层：t1==null 的段 = " + segUnclosed + " / " + segs.length);

console.log();
console.log("③ 重叠检查（同一 axis 上时间重叠的段）");
{
  const byAxis = new Map();
  for (const s of segs) {
    if (s.t1 == null) continue;
    if (!byAxis.has(s.axis)) byAxis.set(s.axis, []);
    byAxis.get(s.axis).push(s);
  }
  let overlapPairs = 0;
  for (const [ax, arr] of byAxis) {
    arr.sort((a, b) => a.t0 - b.t0);
    for (let i = 1; i < arr.length; i++) {
      if (arr[i].t0 < arr[i - 1].t1) overlapPairs++;
    }
  }
  console.log("  同轴重叠的相邻段数 = " + overlapPairs +
    (overlapPairs > 0 ? "  <= 🔴 会被 FPGA 的 same_hit 顶掉" : "  <= ✅ 无重叠"));
}

console.log();
console.log("④ 可疑长音（超过 p99 的段）");
{
  const a = segDurs.slice().sort((x, y) => x - y);
  const p99 = a.length ? a[Math.floor(a.length * 0.99)] : 0;
  const long = segs.filter(s => s.t1 != null && (s.t1 - s.t0) > p99);
  console.log("  p99 = " + p99 + " tick；超过它的段 = " + long.length);
  long.slice(0, 5).forEach(s => console.log("    axis=" + s.axis +
    " t0=" + s.t0 + " t1=" + s.t1 + " 时长=" + (s.t1 - s.t0) +
    " inc=" + s.inc + (s.dangling ? "  <== dangling（兜底拉长）" : "")));
}
