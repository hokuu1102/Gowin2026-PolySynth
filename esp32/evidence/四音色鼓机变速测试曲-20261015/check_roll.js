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

/* 记录 draw() 真正发出的每个 fillRect —— 用来【证明】"音符被鼓栏盖掉"，
 * 而不是靠读代码猜。假 canvas 的 fillStyle 也要记（靠它认出鼓栏底色）。 */
const rects = [];
let curStyle = null;
const recCtx = new Proxy({}, {
  get: (t, k) => {
    if (k === "canvas") return { width: 1, height: 1 };
    if (k === "measureText") return () => ({ width: 10 });
    return (...a) => {
      if (k === "fillRect") rects.push({ style: curStyle, x: a[0], y: a[1], w: a[2], h: a[3] });
    };
  },
  set: (t, k, v) => { if (k === "fillStyle") curStyle = v; return true; },
});
const fakeCtx = new Proxy({}, {
  get: (t, k) => k === "canvas" ? { width: 1, height: 1 }
    : (k === "measureText" ? () => ({ width: 1 }) : (() => {})), set: () => true });
const mkEl = (ctx, cw, ch) => new Proxy({
  style: {}, classList: { add() {}, remove() {} }, getContext: () => ctx,
  clientWidth: cw, clientHeight: ch, width: cw, height: ch,
  parentElement: { getBoundingClientRect: () => ({ width: cw, height: ch }) },
  querySelectorAll: () => [], querySelector: () => null, addEventListener() {},
  appendChild() {}, insertAdjacentHTML() {},
  getBoundingClientRect: () => ({ left: 0, top: 0, width: cw, height: ch }),
  textContent: "", innerHTML: "", checked: false,
}, { get: (t, k) => k in t ? t[k] : (typeof k === "string" ? (() => {}) : undefined),
     set: (t, k, v) => { t[k] = v; return true; } });
const rollEl = mkEl(recCtx, W, PH + 40);          // 画布高 = ph + PAD.t + PAD.b
const fakeEl = () => mkEl(fakeCtx, 800, 600);
const doc = { getElementById: id => (id === "roll" ? rollEl : fakeEl()),
  querySelector: () => fakeEl(),
  querySelectorAll: () => [], addEventListener() {}, createElement: () => fakeEl(), body: fakeEl() };
const fn = new Function("document", "window", "navigator", "performance", "console",
  "setTimeout", "clearInterval", "setInterval", "requestAnimationFrame",
  "location", "localStorage", "URLSearchParams",
  blk + "\n; function __setScore(s){ score = s; }" +
  "\n; return { parseMidi, midiToWords, buildScore, DRUM_AXIS, KIND_ON, KIND_OFF, " +
  "KIND_TEMPO, DRUM_INC, TIMBRE_NAMES, midiName, PAD, unpackWord, draw, __setScore };");
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

// ============================ 三、秒数换算 ============================
// tick -> 秒【必须按 tempo 表分段积分】。页面里有三处偷懒用固定速度：
//   buildScore 的 duration = (tickMax-tickMin)/首个 tempo 的 hz
//   总览条的 "s" 标签      = tick/960（写死 120 BPM）
//   游标回退路径           = 用 duration/tickMax 当常数 secPerTick
console.log();
console.log("【三】秒数换算（tick -> 秒）");
const tps = score.tempos.slice().sort((a, b) => a.tick - b.tick);
let trueSec = 0;
for (let i = 0; i < tps.length; i++) {
  const t0 = tps[i].tick;
  const t1 = (i + 1 < tps.length) ? tps[i + 1].tick : score.tickMax;
  trueSec += Math.max(0, t1 - t0) / (tps[i].hz || 1);
}
const hz0 = tps.length ? tps[0].hz : 1920.003;
const panelSec = (score.tickMax - score.tickMin) / hz0;
const barSec = score.tickMax / 960;
const relErr = (a, b) => (100 * (a - b) / b).toFixed(1) + "%";
console.log("  tempo 表：" + tps.map(t => "tick " + t.tick + " = " +
            (t.hz / 1920.003 * 120).toFixed(0) + " BPM").join(" · "));
console.log("  真实时长（分段积分）              = " + trueSec.toFixed(2) + " s");
console.log("  面板「时长」（只用首个 tempo）     = " + panelSec.toFixed(2) + " s  -> 面板显示 " + panelSec.toFixed(1) + " s");
console.log("  总览条「全长」（tick/960 写死 120BPM）= " + barSec.toFixed(2) + " s");
console.log("  误差：面板 " + relErr(panelSec, trueSec) + " · 总览条 " + relErr(barSec, trueSec));
/* 游标回退路径的漂移：真实播到 T 秒时，它算出的 tick 偏多少 */
const secPerTick = panelSec / Math.max(1, score.tickMax);
let tickAtTrueSec = 0, acc = 0;
for (const t of tps) {
  const t1 = (tps.indexOf(t) + 1 < tps.length) ? tps[tps.indexOf(t) + 1].tick : score.tickMax;
  const segSec = (t1 - t.tick) / (t.hz || 1);
  if (acc + segSec >= trueSec) { tickAtTrueSec = t.tick + (trueSec - acc) * t.hz; break; }
  acc += segSec;
}
const guessedTick = trueSec / secPerTick;
console.log("  游标回退路径：真实播完时它算出的 tick = " + guessedTick.toFixed(0) +
            "，真值 " + score.tickMax + "（偏 " + (100 * (guessedTick - score.tickMax) / score.tickMax).toFixed(1) + "%）");
console.log("  提前量显示：代码写 d.lead/1920（假定 120BPM）—— 本曲 1920 tick 实际是 " +
            (1920 / hz0).toFixed(2) + " s，不是 1.00 s");
console.log();
console.log("  判据：");
chk("⑧ 面板时长与真实时长一致（误差 < 1%）", Math.abs(panelSec - trueSec) / trueSec < 0.01,
    "面板 " + panelSec.toFixed(2) + "s vs 真值 " + trueSec.toFixed(2) + "s（" + relErr(panelSec, trueSec) + "）");
chk("⑨ 总览条秒数与真实时长一致（误差 < 1%）", Math.abs(barSec - trueSec) / trueSec < 0.01,
    "总览条 " + barSec.toFixed(2) + "s vs 真值 " + trueSec.toFixed(2) + "s（" + relErr(barSec, trueSec) + "）");
chk("⑩ 游标回退路径不漂（偏差 < 1%）",
    Math.abs(guessedTick - score.tickMax) / score.tickMax < 0.01,
    "偏 " + (100 * (guessedTick - score.tickMax) / score.tickMax).toFixed(1) + "%");

// ============================ 四、绘制仿真 ============================
// 真的调一次 draw()，把每个 fillRect 记下来。判据：
//   乐音块（按音色上色）有没有落在鼓栏底色矩形【下面】—— 那就会被后画的鼓栏擦掉。
console.log();
console.log("【四】绘制仿真（真跑 draw()，记录每个 fillRect）");
let drawErr = null;
try {
  API.__setScore(score);
  rects.length = 0;
  API.draw();
} catch (e) { drawErr = e; }
if (drawErr) {
  console.log("  RED: draw() 抛异常：" + drawErr.message);
  red++;
} else {
  const NOTE_COLORS = ["#fb923c", "#4ea1ff", "#3ddc84", "#ff7ab2", "#8695ab"];
  const laneBg = rects.find(r => r.style === "#12181f");           // 鼓栏底色
  const laneTop = laneBg ? laneBg.y : (API.PAD.t + PH);
  const plotBottom = API.PAD.t + PH;
  /* ⚠️ 不要按宽度过滤：长谱子里大多数音块就是最小宽度 1.6px（`Math.max(1.6, x1-x0)`），
   *    按 w>1.7 滤会把它们全丢掉（实测 円.mid 只剩 348/9319）。图例色块靠 y 过滤排除。 */
  const noteBlocks = rects.filter(r => NOTE_COLORS.indexOf(r.style) >= 0 && r.y < plotBottom - 0.5);
  const drumBlocks = rects.filter(r => r.style === "#00d5c8" && r.y < plotBottom - 0.5);
  const covered = noteBlocks.filter(r => r.y + r.h > laneTop + 0.5);
  console.log("  本次 draw() 共发出 " + rects.length + " 个 fillRect");
  console.log("  鼓栏底色矩形：y=" + laneTop.toFixed(0) + " 高 " + (laneBg ? laneBg.h.toFixed(0) : "-") +
              "（画布底 " + plotBottom.toFixed(0) + "）");
  console.log("  画出来的乐音块 " + noteBlocks.length + " 个 · 鼓块 " + drumBlocks.length + " 个");
  console.log("  其中落在鼓栏区域（会被底色擦掉）的乐音块 = " + covered.length +
              "（占 " + (100 * covered.length / Math.max(1, noteBlocks.length)).toFixed(0) + "%）");
  if (covered.length) {
    const ys = covered.map(r => r.y.toFixed(0));
    console.log("  它们的 y 范围：" + Math.min(...covered.map(r => r.y)).toFixed(0) + " ~ " +
                Math.max(...covered.map(r => r.y + r.h)).toFixed(0) +
                "（全部 >= 鼓栏顶 " + laneTop.toFixed(0) + "）");
  }
  console.log();
  console.log("  判据：");
  chk("⑪ 画出来的乐音块没有一个落在鼓栏区域", covered.length === 0,
      covered.length ? (covered.length + " 个乐音块被鼓栏底色盖掉") : "");
}

// ============================ 五、总览条跳转 ============================
// 代码自己的注释（:1661）写的是"让点击处成为视口【中点】"。
// 实现：theo = frac - 0.5/viewZoom；而 viewWindow 里 off = viewScroll*(total-span)
//   => 要让点击处落在中点，viewScroll 应是 (frac*total - span/2)/(total-span)
//      = (frac*z - 0.5)/(z - 1)
console.log();
console.log("【五】总览条点击跳转（缩放后导航）");
console.log("  代码注释的意图：点击处成为视口【中点】");
let worstJump = 0, worstCase = "";
for (const z of [2, 4, 8, 20]) {
  const span = score.tickMax / z;
  const maxOff = score.tickMax - span;
  for (const frac of [0.25, 0.5, 0.75]) {
    const theo = Math.max(0, Math.min(1, frac - 0.5 / z));      // 页面算法
    const off = theo * maxOff;
    const centerTick = off + span / 2;
    const errSpan = Math.abs(centerTick - frac * score.tickMax) / span;  // 以视口宽为单位
    if (errSpan > worstJump) { worstJump = errSpan; worstCase = "zoom " + z + " · 点击 " + (frac * 100) + "% 处"; }
  }
}
console.log("  点击处偏离视口中点最坏 = " + (worstJump * 100).toFixed(0) + "% 视口宽（" + worstCase + "）");
console.log("  即：放大 20 倍时点总览条正中，落点跑到视口【最右边缘】附近，而不是中间");
console.log();
console.log("  判据：");
chk("⑫ 总览条点击后，点击处落在视口中点附近（偏差 < 25% 视口宽）", worstJump < 0.25,
    "最坏偏 " + (worstJump * 100).toFixed(0) + "%（" + worstCase + "）");

console.log();
console.log("  结论：" + (red === 0 ? "全部通过" : ("有 " + red + " 项 RED")));
process.exit(red === 0 ? 0 : 1);
