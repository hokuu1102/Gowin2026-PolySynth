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
const midPath = process.argv[2] || path.join(HERE, "四音色鼓机变速-funk-演示卡.mid");
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
  "KIND_TEMPO, DRUM_INC, TIMBRE_NAMES, midiName, PAD, unpackWord, draw, __setScore, " +
  "pickHover, overviewScrollFor, tickToSec, secToTick, __getView: () => lastView };");
const API = fn(doc, { addEventListener() {} }, { bluetooth: null }, { now: () => 0 },
  { log: () => {} }, setTimeout, () => {}, () => 0, () => 0,
  { protocol: "http:", host: "x", search: "" },
  { getItem: () => null, setItem() {} },
  class { constructor() {} get() { return null; } });

const buf = fs.readFileSync(midPath);
const parsed = API.parseMidi(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length));
const conv = API.midiToWords(parsed);
const score = API.buildScore(conv.words, path.basename(midPath));
/* ⭐ 先把谱面交给页面并画一帧：pickHover 依赖 draw() 留下的 lastView
 *   （悬停 = 光标落在哪个格子里，必须用【画的时候】那套坐标，⛔ 不能另算一份）。 */
API.__setScore(score);
API.draw();

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
/* ⚠️ 这里也必须是 FIFO 队列 —— 原来写成单槽（open.set 覆盖），
 *    与刚修掉的页面 bug 一模一样：同音高重叠时会配错。
 *    （这条是"核对器自己也踩同一个坑"的活例子。） */
const truth = new Set();
{
  const open = new Map();
  for (const e of evs) {
    if (e.kind === API.KIND_TEMPO) continue;
    const k = e.axis * 0x2000000 + e.inc;
    if (e.kind === API.KIND_ON) {
      if (!open.has(k)) open.set(k, []);
      open.get(k).push(e.tick);
    } else {
      const q = open.get(k);
      if (q && q.length) {
        truth.add(q.shift() + "|" + e.tick + "|" + e.inc);
        if (!q.length) open.delete(k);
      }
    }
  }
}
const badPair = score.noteSegs.filter(s => !truth.has(s.t0 + "|" + s.t1 + "|" + s.inc));
const badDrum = score.drumSegs.filter(s => !truth.has(s.t0 + "|" + s.t1 + "|" + s.inc));
/* ⚠️ 配不上的段要看清是"配错"还是"被兜底拉到全曲末"——
 *    buildScore 用的是【单槽】open（`open.set(key, seg)` 覆盖），
 *    同轴同音高的 on 若【重叠】（前一个还没 off 就又来一个 on），
 *    前一个 seg 就永远拿不到 t1 ⇒ 被兜底成 endTick ⇒ 画出一根【到曲末的长条】。
 *    这与用户报过的"时值过长、重叠"是同一族，必须量出来。 */
/* 判据要精确：t1 正好落在【全曲末】且又不是真的一对 (on,off) ⇒ 是兜底拉出来的。
 * ⚠️ 不能只看"长度 > 全曲 25%"—— 6.世界悲 那根只有 65280 tick（≈68 s）会漏掉。 */
const stretched = score.segs.filter(s => s.t1 === Math.max(score.tickMax, 1) &&
                                        !truth.has(s.t0 + "|" + s.t1 + "|" + s.inc));
const showSeg = s => "t0=" + s.t0 + " t1=" + s.t1 + " 长 " + (s.t1 - s.t0) +
                     " axis=" + s.axis + " midi=" + (s.midi != null ? s.midi.toFixed(1) : "-");
if (badDrum.length) {
  console.log("  鼓段对不上的前 3 个：" + badDrum.slice(0, 3).map(showSeg).join(" | "));
}
if (badPair.length) {
  console.log("  乐音段对不上的前 3 个：" + badPair.slice(0, 3).map(showSeg).join(" | "));
}
if (stretched.length) {
  console.log("  🔴 被兜底拉到全曲末的长条 = " + stretched.length + " 根：" +
              stretched.slice(0, 3).map(showSeg).join(" | "));
}

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
chk("③ 没有兜底长条（重叠 on 被单槽 open 覆盖）+ 未闭合 on = 0",
    stretched.length === 0 && score.danglingOn === 0,
    "长条 " + stretched.length + " 根 · orphanOff " + score.orphanOff + "（只报告）· danglingOn " + score.danglingOn);
// 全曲 1/400 的"最小长度"兜底会造出一个恒定的大段长（实测 1814）
const span = score.tickMax - score.tickMin;
const clampLike = pct(durs, 0.5) === Math.max(1, Math.round(span / 400)) ||
                  pct(durs, 0.9) === Math.max(1, Math.round(span / 400));
chk("④ 段长分布不是被'最小长度'兜底拉平的常数", !clampLike,
    "p50=" + pct(durs, 0.5) + " p90=" + pct(durs, 0.9) + "（全曲 1/400 = " + Math.round(span / 400) + "）");

// ============================ 二、绘制层 ============================
console.log();
console.log("【二】绘制层几何（用页面 draw() 留下的 lastView，⛔ 不是我自己算一份）");
const LV = API.__getView();
const mids = score.notes.filter(n => n.axis !== API.DRUM_AXIS).map(n => n.midi).filter(m => m > 0);
const lo = LV.lo, hi = LV.hi;
const rowH = LV.melPh / (hi - lo);
console.log("  音高范围 lo=" + lo.toFixed(0) + "(" + API.midiName(Math.round(lo)) + ") .. hi=" +
            hi.toFixed(0) + "(" + API.midiName(Math.round(hi)) + ")  共 " + (hi - lo).toFixed(0) +
            " 行 · 行高 " + rowH.toFixed(1) + "px");
console.log("  乐音区高 melPh = " + LV.melPh.toFixed(0) + "px · 鼓栏高 = " + LV.laneH.toFixed(0) +
            "px（源码常数 " + LANE_MIN + "/" + LANE_MAX + "/" + LANE_FRAC + "）");
console.log("  鼓栏顶 laneTop = " + LV.laneTop.toFixed(0) + "px（= PAD.t + melPh = " +
            (API.PAD.t + LV.melPh).toFixed(0) + "）");
/* 对照：按【旧几何】（音域铺满 ph、鼓栏叠在底部）本来会盖住哪些音高 */
const oldY = m => API.PAD.t + PH - ((m - lo) / (hi - lo)) * PH;
const oldBottom = API.PAD.t + PH - laneH;
const oldHidden = [];
for (let m = Math.ceil(lo); m <= Math.floor(hi); m++) if (oldY(m) >= oldBottom) oldHidden.push(m);
console.log("  对照（旧几何会盖住的音高）：" +
            (oldHidden.length ? oldHidden.map(m => API.midiName(m)).join(",") : "无") +
            "（" + oldHidden.length + " 个半音）");
/* ⚠️ 这个数是"如果还用旧几何会看不见多少根音"—— 修复前的实测值就是它 */
const oldCovered = score.noteSegs.filter(s => oldY(s.midi) >= oldBottom).length;
console.log("  对照（旧几何会盖住的乐音块）：" + oldCovered + " / " + score.noteSegs.length +
            "（" + (100 * oldCovered / Math.max(1, score.noteSegs.length)).toFixed(0) + "%）");
console.log();
console.log("  判据：");
chk("⑤ 乐音区已让出鼓栏高度（melPh+laneH=绘图区高，且 laneTop=PAD.t+melPh）",
    Math.abs(LV.melPh + LV.laneH - PH) < 1.5 &&
    Math.abs(LV.laneTop - (API.PAD.t + LV.melPh)) < 0.01,
    "melPh " + LV.melPh.toFixed(0) + " + laneH " + LV.laneH.toFixed(0) + " = " +
    (LV.melPh + LV.laneH).toFixed(0) + "（绘图区 " + PH + "）");

// ---- 悬停命中：直接调页面里的 pickHover()（⛔ 不是复刻一份）----
const pw = W - API.PAD.l - 14;
const Yof = m => API.PAD.t + LV.melPh - ((m - LV.lo) / (LV.hi - LV.lo)) * LV.melPh;
const pctOf = (n, d) => (100 * n / Math.max(1, d)).toFixed(0) + "%";

/* 乐音行扫描：取一根真实存在的最高音行 */
const topMidi = Math.max(...score.noteSegs.map(s => s.midi));
const yMel = Yof(topMidi);
let mHit = 0, mNone = 0, mDrum = 0, mWrongRow = 0;
for (let px = API.PAD.l + 1; px < API.PAD.l + pw; px += 2) {
  const p = API.pickHover(px, yMel);
  if (!p) { mNone++; continue; }
  mHit++;
  if (p.drumInc != null) mDrum++;
  if (Math.abs(p.midi - topMidi) > 0.5) mWrongRow++;
}
/* 鼓栏扫描：光标放在 Kick 行中心 */
const yKick = LV.laneTop + LV.laneH * (0.5 / 4);
let dHit = 0, dWrong = 0, dNone = 0;
for (let px = API.PAD.l + 1; px < API.PAD.l + pw; px += 2) {
  const p = API.pickHover(px, yKick);
  if (!p) { dNone++; continue; }
  dHit++;
  if (p.drumInc !== API.DRUM_INC.kick) dWrong++;
}
console.log();
console.log("  悬停扫描（沿时间轴每 2px 一个光标位置，直接调页面的 pickHover）：");
console.log("    光标放在 " + API.midiName(Math.round(topMidi)) + " 行：" +
            mHit + " 命中 · " + mNone + " 没命中 · 串到别的行 " + mWrongRow + " · 命中鼓 " + mDrum);
console.log("    光标放在 Kick 行：" + dHit + " 命中 · " + dNone + " 没命中 · 不是 kick 的 " + dWrong);
console.log("    ⚠️ 判定阈值 = 视口宽 2%，且长音中间也算命中（段覆盖该 tick）");
console.log();
console.log("  判据：");
chk("⑥ 悬停命中与光标所在【行】一致，且不串到鼓",
    mWrongRow === 0 && mDrum === 0,
    "串行 " + mWrongRow + "（" + pctOf(mWrongRow, mHit) + "）· 命中鼓 " + mDrum);
chk("⑦ 鼓栏悬停命中的是那一行的鼓件（Kick 行 -> kick）",
    dHit > 0 && dWrong === 0, "命中 " + dHit + " 次，其中不是 kick 的 " + dWrong);

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
const panelSec = score.duration;                 // ← 页面实际给面板的值
const barSec = API.tickToSec(score.tickMax);     // ← 页面总览条实际用的算法
const relErr = (a, b) => (100 * (a - b) / b).toFixed(1) + "%";
console.log("  tempo 表：" + tps.map(t => "tick " + t.tick + " = " +
            (t.hz / 1920.003 * 120).toFixed(0) + " BPM").join(" · "));
console.log("  真实时长（本核对器自己分段积分，作参照）= " + trueSec.toFixed(2) + " s");
console.log("  面板「时长」（页面 score.duration）    = " + panelSec.toFixed(2) + " s  -> 面板显示 " + panelSec.toFixed(1) + " s");
console.log("  总览条「全长」（页面 tickToSec）       = " + barSec.toFixed(2) + " s");
console.log("  误差：面板 " + relErr(panelSec, trueSec) + " · 总览条 " + relErr(barSec, trueSec));
/* 游标回退路径的漂移：真实播到末尾时，它算出的 tick 偏多少 */
const guessedTick = API.secToTick(trueSec);      // ← 页面游标回退实际用的算法
console.log("  游标回退路径：真实播完时它算出的 tick = " + guessedTick.toFixed(0) +
            "，真值 " + score.tickMax + "（偏 " + (100 * (guessedTick - score.tickMax) / score.tickMax).toFixed(1) + "%）");
console.log("  提前量：固件给 1920 tick，页面 tickToSec(1920) = " +
            API.tickToSec(1920).toFixed(2) + " s（⛔ 原来写死 /1920 = 1.00 s）");
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
// 直接调页面里的 overviewScrollFor()（⛔ 不是复刻一份公式）。
// 判据：点击处应落在视口【中点】（页面注释自己写的意图）。
console.log();
console.log("【五】总览条点击跳转（缩放后导航）");
console.log("  代码注释的意图：点击处成为视口【中点】");
let worstJump = 0, worstCase = "";
for (const z of [2, 4, 8, 20]) {
  const span = score.tickMax / z;
  const maxOff = score.tickMax - span;
  for (const frac of [0.25, 0.5, 0.75]) {
    const theo = API.overviewScrollFor(frac, z);                // ← 页面算法
    const off = theo * maxOff;
    const centerTick = off + span / 2;
    const errSpan = Math.abs(centerTick - frac * score.tickMax) / span;  // 以视口宽为单位
    if (errSpan > worstJump) { worstJump = errSpan; worstCase = "zoom " + z + " · 点击 " + (frac * 100) + "% 处"; }
  }
}
console.log("  点击处偏离视口中点最坏 = " + (worstJump * 100).toFixed(0) + "% 视口宽" +
            (worstCase ? "（" + worstCase + "）" : ""));
console.log();
console.log("  判据：");
chk("⑫ 总览条点击后，点击处落在视口中点附近（偏差 < 25% 视口宽）", worstJump < 0.25,
    "最坏偏 " + (worstJump * 100).toFixed(0) + "%（" + worstCase + "）");

console.log();
console.log("  结论：" + (red === 0 ? "全部通过" : ("有 " + red + " 项 RED")));
process.exit(red === 0 ? 0 : 1);
