// check_roll.js —— 核对【卷帘显示层】对不对（解析层 + 绘制层分开验）
//
// 为什么要分开验：buildScore()（解析/配对）与 draw()/drawPiano()（画）是两层。
//   解析错了 = 音符本身错；画错了 = 音符对但看不见/看错位置。两者混在一起谈就查不清。
//
// 用法：
//   node check_roll.js [文件.mid] [主图高 ph] [画布宽 w]
//   ph / w 用 CSS px；缺省按用户那张截图反推（DPR 1.5）
//
// 判据：
//   ① 解析层：每个乐音段 (t0,t1) 必须能在 events.hex 里找到一对 (on,off)
//   ② 解析层：orphanOff / danglingOn 都应为 0
//   ③ 解析层：段长分布必须与真实时值一致（p50 不能是"全曲 1/400"那种常数）
//   ④ 绘制层：有没有音符被鼓栏盖住（Y(m) 落到 noDrawBelow 以下）
//   ⑤ 绘制层：悬停命中是不是只看时间不看音高

const fs = require("fs");
const path = require("path");

const HERE = __dirname;
const midPath = process.argv[2] || path.join(HERE, "四音色鼓机变速-测试曲.mid");
const PH = Number(process.argv[3] || 677);     // 主图高（截图反推：717 - PAD.t 14 - PAD.b 26）
const W = Number(process.argv[4] || 1071);     // 画布宽（截图 1607 / DPR 1.5）

const src = fs.readFileSync(path.join(HERE, "..", "..", "tools", "score_studio.html"), "utf8");
const blk = [...src.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1])[0];

// ⚠️ 鼓栏高度不自己写死 —— 从源码里把三个常数抠出来（源码改了这里会立刻对不上）
const mLane = blk.match(/function drumLaneHeight\(ph\)\s*\{[\s\S]*?return Math\.max\((\d+),\s*Math\.min\((\d+),\s*ph \* ([\d.]+)\)\);/);
if (!mLane) { console.error("RED: 没从源码里认出 drumLaneHeight 的公式"); process.exit(2); }
const LANE_MIN = +mLane[1], LANE_MAX = +mLane[2], LANE_FRAC = +mLane[3];
const laneH = Math.max(LANE_MIN, Math.min(LANE_MAX, PH * LANE_FRAC));

const fakeCtx = new Proxy({}, {
  get: (t, k) => k === "canvas" ? { width: 1, height: 1 }
    : (k === "measureText" ? () => ({ width: 1 }) : (() => {})), set: () => true });
const fakeEl = () => new Proxy({
  style: {}, classList: { add() {}, remove() {} }, getContext: () => fakeCtx,
  querySelectorAll: () => [], querySelector: () => null, addEventListener() {},
  appendChild() {}, insertAdjacentHTML() {},
  getBoundingClientRect: () => ({ left: 0, top: 0, width: 8, height: 6 }),
  textContent: "", innerHTML: "", checked: false,
}, { get: (t, k) => k in t ? t[k] : (typeof k === "string" ? (() => {}) : undefined),
     set: (t, k, v) => { t[k] = v; return true; } });
const doc = { getElementById: () => fakeEl(), querySelector: () => fakeEl(),
  querySelectorAll: () => [], addEventListener() {}, createElement: () => fakeEl(), body: fakeEl() };
const fn = new Function("document", "window", "navigator", "performance", "console",
  "setTimeout", "clearInterval", "setInterval", "requestAnimationFrame",
  "location", "localStorage", "URLSearchParams",
  blk + "\n; return { parseMidi, midiToWords, buildScore, DRUM_AXIS, KIND_ON, KIND_OFF, " +
  "KIND_TEMPO, DRUM_INC, TIMBRE_NAMES, midiName, PAD, unpackWord };");
const API = fn(doc, { addEventListener() {} }, { bluetooth: null }, { now: () => 0 },
  { log: () => {} }, setTimeout, () => {}, () => 0, () => 0,
  { protocol: "http:", host: "x", search: "" },
  { getItem: () => null, setItem() {} },
  class { constructor() {} get() { return null; } });

const buf = fs.readFileSync(midPath);
const parsed = API.parseMidi(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length));
const conv = API.midiToWords(parsed);
const score = API.buildScore(conv.words, path.basename(midPath));

let red = 0;
const chk = (name, cond, extra) => {
  console.log("  " + (cond ? "[OK] " : "[RED]") + name.padEnd(56) + (extra || ""));
  if (!cond) red++;
};
const pct = (a, p) => a.length ? a.slice().sort((x, y) => x - y)[Math.min(a.length - 1, Math.floor(a.length * p))] : 0;

console.log("=".repeat(84));
console.log("卷帘核对：" + path.basename(midPath) + "   （主图高 " + PH + "px · 画布宽 " + W + "px）");
console.log("=".repeat(84));

// ============================ 一、解析层 ============================
console.log();
console.log("【一】解析层（buildScore：配对 + 分栏）");
console.log("  字 " + score.words.length + " · 事件 " + score.notes.length +
            " · 段 " + score.segs.length + "（乐音 " + score.noteSegs.length +
            " + 鼓 " + score.drumSegs.length + "）");
console.log("  配不上的 off = " + score.orphanOff + " · 没闭合的 on = " + score.danglingOn);
const durs = score.noteSegs.map(s => s.t1 - s.t0);
console.log("  乐音段长 tick：p10 " + pct(durs, 0.1) + " · p50 " + pct(durs, 0.5) +
            " · p90 " + pct(durs, 0.9) + " · max " + Math.max(...durs));

// 真值：从 events.hex 里取所有 (tick_on, tick_off, inc, axis) 对
const evs = conv.words.map(w => {
  const d = API.unpackWord(w);
  return { tick: d.tick, kind: d.kind, axis: d.axis, inc: d.inc, vel: d.vel };
});
const truth = new Set();
{
  const open = new Map();
  for (const e of evs) {
    if (e.kind === API.KIND_TEMPO) continue;
    const k = e.axis * 0x2000000 + e.inc;
    if (e.kind === API.KIND_ON) open.set(k, e.tick);
    else if (open.has(k)) { truth.add(open.get(k) + "|" + e.tick + "|" + e.inc); open.delete(k); }
  }
}
const badPair = score.noteSegs.filter(s => !truth.has(s.t0 + "|" + s.t1 + "|" + s.inc));
const badDrum = score.drumSegs.filter(s => !truth.has(s.t0 + "|" + s.t1 + "|" + s.inc));

const tbCount = {};
for (const s of score.noteSegs) {
  const n = API.TIMBRE_NAMES[s.timbre] || ("T" + s.timbre);
  tbCount[n] = (tbCount[n] || 0) + 1;
}
console.log("  音色分布：" + Object.entries(tbCount).map(([k, v]) => k + " " + v).join(" · "));
console.log();
console.log("  判据：");
chk("① 乐音段全部能在 hex 里找到对应的 (on,off) 对", badPair.length === 0,
    badPair.length ? (badPair.length + " 段对不上，例 " + JSON.stringify(badPair[0])) : "");
chk("② 鼓段同样能对上", badDrum.length === 0, badDrum.length + " 段对不上");
chk("③ orphanOff = 0 且 danglingOn = 0",
    score.orphanOff === 0 && score.danglingOn === 0,
    "orphan " + score.orphanOff + " · dangling " + score.danglingOn);
// 全曲 1/400 的"最小长度"兜底会造出一个恒定的大段长（实测 1814）
const span = score.tickMax - score.tickMin;
const clampLike = pct(durs, 0.5) === Math.max(1, Math.round(span / 400)) ||
                  pct(durs, 0.9) === Math.max(1, Math.round(span / 400));
chk("④ 段长分布不是被'最小长度'兜底拉平的常数", !clampLike,
    "p50=" + pct(durs, 0.5) + " p90=" + pct(durs, 0.9) + "（全曲 1/400 = " + Math.round(span / 400) + "）");

// ============================ 二、绘制层 ============================
console.log();
console.log("【二】绘制层（draw / drawPiano / drawDrumLane）");
const mids = score.notes.filter(n => n.axis !== API.DRUM_AXIS).map(n => n.midi).filter(m => m > 0);
let lo = Math.round(Math.min(...mids)) - 1, hi = Math.round(Math.max(...mids)) + 1;
if (hi - lo < 6) { lo -= 3; hi += 3; }
const Y = m => API.PAD.t + PH - ((m - lo) / (hi - lo)) * PH;
const noDrawBelow = API.PAD.t + PH - laneH;
const rowH = PH / (hi - lo);
console.log("  音高范围 lo=" + lo + "(" + API.midiName(lo) + ") .. hi=" + hi + "(" + API.midiName(hi) + ")" +
            "  共 " + (hi - lo) + " 行 · 行高 " + rowH.toFixed(1) + "px");
console.log("  鼓栏高 " + laneH.toFixed(0) + "px（源码常数 " + LANE_MIN + "/" + LANE_MAX + "/" + LANE_FRAC +
            "）=> noDrawBelow = " + noDrawBelow.toFixed(0) + "px");
const hidden = [];
for (let m = Math.ceil(lo); m <= Math.floor(hi); m++) if (Y(m) >= noDrawBelow) hidden.push(m);
const coveredSegs = score.noteSegs.filter(s => Y(s.midi) >= noDrawBelow);
console.log("  被鼓栏盖住的音高：" + (hidden.length ? hidden.map(m => API.midiName(m)).join(",") : "无") +
            "（" + hidden.length + " 个半音 = 音域的 " + (100 * hidden.length / (hi - lo)).toFixed(0) + "%）");
console.log("  被盖住的乐音段：" + coveredSegs.length + " / " + score.noteSegs.length +
            "（占 " + (100 * coveredSegs.length / score.noteSegs.length).toFixed(0) + "%）");
const byTb = {};
for (const s of coveredSegs) {
  const n = API.TIMBRE_NAMES[s.timbre] || ("T" + s.timbre);
  byTb[n] = (byTb[n] || 0) + 1;
}
if (coveredSegs.length) {
  console.log("  被盖住的是哪些音色：" + Object.entries(byTb).map(([k, v]) => k + " " + v).join(" · "));
}
console.log();
console.log("  判据：");
chk("⑤ 没有乐音段落在鼓栏区域（否则会被鼓栏底色盖掉）", coveredSegs.length === 0,
    coveredSegs.length ? (coveredSegs.length + " 段看不见：" + Object.entries(byTb).map(([k, v]) => k + " " + v).join(" · ")) : "");

// ---- 悬停命中：只看时间不看音高（复刻 mousemove 里的那段）----
const pw = W - API.PAD.l - 14;
const X = t => API.PAD.l + (t / Math.max(1, score.tickMax)) * pw;
const tickAt = px => ((px - API.PAD.l) / pw) * Math.max(1, score.tickMax);
function hoverPick(px) {                       // ← 与 mousemove 里的循环逐行一致
  const t = tickAt(px);
  let best = null, bd = Infinity;
  for (const n of score.notes) { const d = Math.abs(n.tick - t); if (d < bd) { bd = d; best = n; } }
  return (best && bd < Math.max(1, score.tickMax) * 0.02) ? { best, t, bd } : null;
}
/* ⭐ 扫描：沿 x 横扫一遍，看悬停会选中什么。
 *   mousemove 里【只比较 n.tick】—— 完全没用 y ⇒ 同一条竖线上，
 *   光标在 C5 行还是在 A2 行，提示【一模一样】。这是"看行"这件事做不到的直接证据。 */
let nHit = 0, nOff = 0, nDrum = 0, nNone = 0;
const samples = [];
for (let px = API.PAD.l + 1; px < API.PAD.l + pw; px += 2) {
  const p = hoverPick(px);
  if (!p) { nNone++; continue; }
  nHit++;
  if (p.best.kind === API.KIND_OFF) nOff++;
  if (p.best.axis === API.DRUM_AXIS) nDrum++;
  if (samples.length < 6 && p.best.axis === API.DRUM_AXIS) {
    samples.push("x=" + px.toFixed(0) + " → 轴15(" + (API.TIMBRE_NAMES[p.best.timbre] || "?") +
                 ") tick " + p.best.tick + " " + (p.best.kind === API.KIND_OFF ? "off" : "on"));
  }
}
const pctOf = n => (100 * n / Math.max(1, nHit)).toFixed(0) + "%";
console.log();
console.log("  悬停扫描（沿时间轴每 2px 取一个光标位置，共 " + (nHit + nNone) + " 个点）：");
console.log("    命中 off 事件（提示会写「力度 0 · off」）：" + nOff + " / " + nHit + " = " + pctOf(nOff));
console.log("    命中鼓事件（提示会写「轴 15」）：" + nDrum + " / " + nHit + " = " + pctOf(nDrum));
console.log("    一个都没命中（超出 2% 阈值）：" + nNone);
if (samples.length) console.log("    在乐音区横扫时命中鼓的例子：" + samples.join(" · "));
console.log("    ⚠️ 提示与光标的【音高行】无关：mousemove 只比较 n.tick，⛔ 不比较 y");
console.log();
console.log("  判据：");
chk("⑥ 悬停命中的是 note_on（⛔ 不是 off，否则提示写「力度 0 · off」）",
    nOff === 0, "命中 off 的比例 " + pctOf(nOff));
chk("⑦ 在乐音区悬停不会命中鼓事件（鼓有自己的栏）",
    nDrum === 0, "命中鼓的比例 " + pctOf(nDrum));

console.log();
console.log("  结论：" + (red === 0 ? "全部通过" : ("有 " + red + " 项 RED")));
process.exit(red === 0 ? 0 : 1);
