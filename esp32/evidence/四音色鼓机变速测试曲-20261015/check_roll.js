// check_roll.js —— 核对【卷帘显示层】对不对（解析层 + 绘制层分开验）
//
// 为什么要分开验：buildScore()（解析/配对）与 draw()/drawPiano()（画）是两层。
//   解析错了 = 音符本身错；画错了 = 音符对但看不见/看错位置。两者混在一起谈就查不清。
//
// 用法：
//   node check_roll.js [文件.mid] [主图高 ph] [画布宽 w]
//   ph / w 用 CSS px；缺省按用户那张截图反推（DPR 1.5）
//
// 2026-10-16【鼓与旋律彻底分离 · 回到 4 件】（手册 §二 / §4.1-7 / §7.3；
//   FPGA线回函-第三轮-收回8件鼓-20261016.md 与 ESP32侧回函-第三轮-axis确认与回退-20261016.md）：
//   FPGA 线【收回】了"扩到 8 件"（他们只有 4 件鼓音色，那几个新 inc 是同一纯音引擎的高频音高）
//   ⇒ 判据回到 4 件：
//   鼓件的识别口径 = 【is_drum(bit5) + drum_type = timbre[8:7]（2 位，⛔ 不读 bit19）】：
//     kick=0 · snare=1 · hihat=2 · tom=3（镲族 46/49/51/52/53/55/57/59 全部显式归 hihat）
//   轴号：鼓的 axis = 12 + drum_type（一件一轴）= kick 12 · snare 13 · hihat 14 · tom 15
//     四件互不相同（鼓的 note_off 按 (axis,src) 配对，四件的 src 全是 SRC_KDRUM）。
//   ⛔ 上一轮的 dt 键（((dt&3)<<1)|(dt>>2) = 0/2/4/6/1/3/5/7）与"8..15"两套旧写法都作废。
//   ⛔ 为什么必须按 drum_type 认件：鼓事件的 inc 恒为 0，按 inc 认件会全部认不出
//      （悬停命中原来比 `p.drumInc !== DRUM_INC.kick` ⇒ 实测 485 次全判错）。
//   鼓力度：Kick 230 · Snare 235 · HiHat 175 · Tom 220；鼓的 OFF 写 0。
//   note_off5：可弹（MIDI 45..75）=> MIDI-45；越界 => 31 哨兵（不可弹、不点灯），
//      ⛔ 不许钳到 0（0 = A2 = 真实的键 5，会点亮错误的灯）。
//
// 判据：
//   ① 解析层：每个乐音段 (t0,t1) 必须能在 events.hex 里找到一对 (on,off)
//   ② 解析层：鼓段同样能对上（配对键 = (axis, drum_type)）
//   ③ 解析层：没有兜底长条 + 未闭合 on = 0
//   ④ 解析层：段长分布必须与真实时值一致（p50 不能是"全曲 1/400"那种常数）
//   ⑤ 绘制层：乐音区已让出鼓栏高度
//   ⑥ 绘制层：悬停命中与光标所在【行】一致，且不串到鼓
//   ⑦ 绘制层：鼓栏悬停命中的是那一行的鼓件（Kick 行 -> drum_type=0）
//   ⑧ 秒数：面板时长与真实时长一致
//   ⑨ 秒数：总览条秒数与真实时长一致
//   ⑩ 秒数：游标回退路径不漂
//   ⑪ 绘制层：画出来的乐音块没有一个落在鼓栏区域
//   ⑫ 总览条：点击处落在视口中点附近
//   ⑬ 鼓事件（is_drum=1）inc 全 0；旋律事件（is_drum=0 且排除 kind=2）inc 全非 0
//   ⑭ is_drum=0 的事件里，轴号落 12..15 的必须 0 条（§7.3 第 1 条，回到 12..15 原始口径）
//   ⑮ 鼓 ON/OFF 按 (axis,drum_type) 配对，OFF 也带 is_drum=1 与同一 drum_type；鼓 note_off5=0
//   ⑯ 鼓段/乐音段的来源口径：drumSegs 全部来自 is_drum=1、noteSegs 全部来自 is_drum=0
//   ⑰ 页面 unpackWord 与独立位提取一致（⛔ 不拿被验者验自己）
//   ⑱ 旋律 note_off5：可弹(45..75) => MIDI-45 · 越界 => 31 哨兵 · 鼓恒 0
//   ⑲ 鼓的 axis = 12 + drum_type（axis-12 == dt）· 两条 dt 读取路径一致（重写）
//   ⑳（新）镲族 8 个音高必须【显式列出】指向 hihat（⛔ 不靠表外兜底 -> tom）

const fs = require("fs");
const path = require("path");

const HERE = __dirname;
const midPath = process.argv[2] || path.join(HERE, "StJamesInfirmary-funk-测试曲.mid");
/* ⚠️ 画布高 / 底部留白必须与 score_studio.html 的 PAD 一致 ——
 * 🔴 原来把主图高写死成 677（= 717 - PAD.t 14 - PAD.b 26），
 *    2026-10-15 底部条带加高（PAD.b 26 → 60，为时间刻度轴+读数行让位）
 *    ⇒ 写死的值就【静默对不上】了：模拟出来的几何比真实主图高 34px，
 *      判据 ④⑤ 的"有没有被鼓栏盖住"会算错。
 * ⭐ 所以这里只留一个【截图反推的画布高】，主图高由 PAD 反推；
 *    ⛔ 不写死主图高，并且下面有判据（几何自洽）守着，再改也会立刻变红。 */
/* 2026-10-16 第三轮：鼓件对照表 —— 【独立写死】，⛔ 不拿页面的 DRUM_TYPE_OF 当期望值
 *   （那是"拿页面的表验页面的表"，假绿）。
 *   件名口径（4 件）：kick=0 · snare=1 · hihat=2 · tom=3（镲族显式归 hihat）。
 *   轴口径：鼓的 axis = 12 + drum_type（一件一轴）。 */
const DRUM_TYPE_NAME = { 0: "kick", 1: "snare", 2: "hihat", 3: "tom" };
const WANT_AXIS_OF_TYPE = { 0: 12, 1: 13, 2: 14, 3: 15 };   /* 独立写死的"12 + dt" */
const MELODY_BAN_AXIS_MIN = 12;                /* §7.3-1：旋律不许占 12..15（独立写死） */
const DRUM_AXIS_BASE = 12, DRUM_AXIS_MAX = 15; /* 鼓轴段（独立写死） */
const DRUM_VEL_WANT = { 0: 230, 1: 235, 2: 175, 3: 220 };   /* 鼓力度定值（独立写死） */
const KICK_TYPE = 0;                           /* kick 的 drum_type = 0 */
/* 镲族：必须【显式列出】指向 hihat（判据⑳；⛔ 不靠表外兜底 -> tom） */
const CYMBAL_GMS = [46, 49, 51, 52, 53, 55, 57, 59];
const nameOfType = t => DRUM_TYPE_NAME[t & 3] || ("type" + (t & 3));
const AXIS_KEY_TXT = [0, 1, 2, 3].map(t => t + "->" + WANT_AXIS_OF_TYPE[t]).join(" ");

const CANVAS_H = 717;                          /* 用户那张截图的画布高（CSS px）*/
const PAD_T = 14, PAD_B = 60;                  /* 与 score_studio.html 的 PAD 对齐 */
const PH = Number(process.argv[3] || (CANVAS_H - PAD_T - PAD_B));   // 主图高
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
const rollEl = mkEl(recCtx, W, PH + PAD_T + PAD_B);   // 画布高 = ph + PAD.t + PAD.b
const fakeEl = () => mkEl(fakeCtx, 800, 600);
const doc = { getElementById: id => (id === "roll" ? rollEl : fakeEl()),
  querySelector: () => fakeEl(),
  querySelectorAll: () => [], addEventListener() {}, createElement: () => fakeEl(), body: fakeEl() };
const fn = new Function("document", "window", "navigator", "performance", "console",
  "setTimeout", "clearInterval", "setInterval", "requestAnimationFrame",
  "location", "localStorage", "URLSearchParams",
  blk + "\n; function __setScore(s){ score = s; }" +
  "\n; return { parseMidi, midiToWords, buildScore, isDrumAxis, DRUM_AXIS_OF, " +
  "MELODY_AXIS_MAX, KIND_ON, KIND_OFF, " +
  "KIND_TEMPO, DRUM_INC, TIMBRE_NAMES, midiName, PAD, unpackWord, draw, __setScore, " +
  "pickHover, overviewScrollFor, tickToSec, secToTick, __getView: () => lastView, " +
  /* 2026-10-16 第三轮：把页面自己的鼓件表与 GM 映射表带出来，判据⑳/⑲ 拿它们与
   *   本文件【独立写死的表】对照（⛔ 不是拿页面的表验页面的表）。
   *   typeof 保护：页面没写出来时导出 null，判据会明确报缺，⛔ 不抛 ReferenceError。 */
  "DRUM_TYPE_OF: (typeof DRUM_TYPE_OF === 'object') ? DRUM_TYPE_OF : null, " +
  "GM_DRUM_MAP: (typeof GM_DRUM_MAP === 'object') ? GM_DRUM_MAP : null };");
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

let red = 0, nChk = 0;
const chk = (name, cond, extra) => {
  console.log("  " + (cond ? "[OK] " : "[RED]") + name.padEnd(56) + (extra || ""));
  nChk++;
  if (!cond) red++;
};
const pct = (a, p) => a.length ? a.slice().sort((x, y) => x - y)[Math.min(a.length - 1, Math.floor(a.length * p))] : 0;

console.log("=".repeat(84));
console.log("卷帘核对：" + path.basename(midPath) + "   （主图高 " + PH + "px · 画布宽 " + W + "px）");
console.log("=".repeat(84));

/* ⭐ 几何自洽（2026-10-15 新增）：本脚本模拟的 PAD 必须与页面源码一致。
 * 🔴 为什么必须有：主图高原来写死 677，页面把 PAD.b 从 26 改成 60 后
 *    这里【静默算错 34px】而判据照样全绿 —— 属于"判据在错前提上通过"。
 * ⭐ 现在对不上立刻红，⛔ 不用人肉记得同步。 */
chk("几何自洽：PAD.t/PAD.b 与源码一致", PAD_T === API.PAD.t && PAD_B === API.PAD.b,
    "脚本 " + PAD_T + "/" + PAD_B + " · 源码 " + API.PAD.t + "/" + API.PAD.b);
chk("几何自洽：主图高 + PAD.t + PAD.b = 画布高",
    PH + API.PAD.t + API.PAD.b === CANVAS_H,
    PH + " + " + API.PAD.t + " + " + API.PAD.b + " vs " + CANVAS_H);

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
/* ⭐⭐ 2026-10-16（手册 §二）：事件解码走页面自己的 unpackWord，另留一份【独立位提取】
 *   给判据⑰ 交叉验页面的解码器（⛔ 不是"直接信页面 unpackWord"）。 */
const rawOf = w => ({
  tick: Number((w >> 44n) & 0xFFFFFn), inc: Number((w >> 23n) & 0x1FFFFFn),
  axis: Number((w >> 19n) & 0xFn), vel: Number((w >> 11n) & 0xFFn),
  kind: Number((w >> 9n) & 0x3n), timbre: Number((w >> 7n) & 0x3n),
  guide: Number((w >> 6n) & 0x1n),
  bit19: Number((w >> 19n) & 0x1n),                    /* bit19：本轮只是 axis 的 bit0（⛔ 不是 dt 的 MSB） */
  isDrum: Number((w >> 5n) & 0x1n),                    /* bit5：显式鼓标志 */
  note5: Number(w & 0x1Fn),                            /* bits[4:0]：音符号偏移（31 = 不可弹哨兵） */
});
/* drum_type 两位读取的两条【独立】路径（判据⑲ 拿它们互证）：
 *   DT_OF  —— 走页面 unpackWord 给出的 drumType（被验者的解码结果）；
 *   DT_RAW —— 走本文件的独立位提取（原始位 bit 8..7）。
 * ⚠️ 上一轮的"dt 键/bit19 共享位"读法已随 8 件扩位一起作废。 */
const DT_OF  = o => (o.timbre & 3);
const DT_RAW = o => (o.timbre & 3);
/* 上一轮（8 件）的三位读法 {bit19, timbre[8:7]}：只用来做判据⑲ 的【反控】——
 *   证明"多读一位"在本产物上是能被抓到的（轴 13/15 的事件 bit19=1）。 */
const DT_LEGACY3 = o => (((o.axis & 1) << 2) | (o.timbre & 3));
const evs = conv.words.map(w => {
  const d = API.unpackWord(w);
  const rw = rawOf(w);
  return { tick: d.tick, kind: d.kind, axis: d.axis, inc: d.inc, vel: d.vel,
           timbre: d.timbre, guide: d.guide, isDrum: d.isDrum, note5: d.note5,
           raw: rw,
           /* 鼓件 = drum_type = timbre[8:7]（2 位）—— ⛔ 不按 inc 认件 */
           type: DT_OF(d), rawType: DT_RAW(rw) };
});
/* ⚠️ 这里也必须是 FIFO 队列 —— 原来写成单槽（open.set 覆盖），
 *    与刚修掉的页面 bug 一模一样：同音高重叠时会配错。
 *    （这条是"核对器自己也踩同一个坑"的活例子。） */
const truth = new Set();
{
  const open = new Map();
  for (const e of evs) {
    if (e.kind === API.KIND_TEMPO) continue;
    /* ⭐⭐ 2026-10-16：配对键必须按新口径分两套 ——
     *   旋律：按 (axis, inc)（页面是 (axis, midi)，而 midi 由 inc 算出 ⇒ 两者等价）；
     *   鼓：按 (axis, drum_type)。
     *   ⛔ 鼓不能按 inc 配对：新位域下鼓的 inc 恒为 0 ⇒ 四件会全挤进同一个键。 */
    const k = (e.isDrum === 1) ? ("d" + e.axis + ":" + e.type) : ("m" + e.axis + ":" + e.inc);
    if (e.kind === API.KIND_ON) {
      if (!open.has(k)) open.set(k, []);
      open.get(k).push(e.tick);
    } else {
      const q = open.get(k);
      if (q && q.length) {
        truth.add(q.shift() + "|" + e.tick + "|" + e.inc + "|" + k);
        if (!q.length) open.delete(k);
      }
    }
  }
}
/* 段的配对键（必须与上面 truth 的键【逐字一致】，否则核对器会自己造出假红）：
 *   鼓段 -> (axis, drum_type)；乐音段 -> (axis, inc)。
 * ⚠️ 页面 buildScore 现在也是这个口径（鼓走 (axis,drum_type)、旋律走 (axis,midi)）；
 *    旧版按 (axis,midi) 配鼓 ⇒ 鼓的 inc=0 让四件的 midi 全成垃圾值 ⇒ 挤进同一个键 ⇒ 一堆兜底长条。 */
const segKey = s => (s.drumType != null) ? ("d" + s.axis + ":" + (s.drumType & 3))
                                         : ("m" + s.axis + ":" + s.inc);
const badPair = score.noteSegs.filter(s => !truth.has(s.t0 + "|" + s.t1 + "|" + s.inc + "|" + segKey(s)));
/* ⭐⭐ 2026-10-16（用户裁定 + 手册 §二）：鼓段的判据改成【可机械判定】的三条 ——
 *   ① 能对上真配对（配对键 = (axis, drum_type)，与页面 buildScore 同口径）；
 *   ② t1 非空（闭合，⛔ 不是被兜底拉到曲末）；
 *   ③ 段长 == DRUM_DUR_TICK（鼓的 ON/OFF 由同一次生成出来，时长恒定）。
 *   ⛔ 不再用"兜底长条"这种模糊阈值去管鼓段（实测那会把它自己算出的长条当页面 bug）。
 * ⚠️ 鼓段长必须与页面 DRUM_DUR_TICK 一致 —— 从源码里抠出来，⛔ 不写死
 *    （源码改了这里立刻对不上，与上面 drumLaneHeight 同一手法）。 */
const mDur = src.match(/const DRUM_DUR_TICK = (\d+);/);
if (!mDur) { console.error("RED: 没从源码里认出 DRUM_DUR_TICK 的赋值"); process.exit(2); }
const DRUM_DUR_TICK = +mDur[1];
const drumSegBad = segs => segs.filter(s => s.t1 == null ||
  (s.t1 - s.t0) !== DRUM_DUR_TICK ||
  !truth.has(s.t0 + "|" + s.t1 + "|" + s.inc + "|" + segKey(s)));
const badDrum = drumSegBad(score.drumSegs);
/* ⚠️ 配不上的段要看清是"配错"还是"被兜底拉到全曲末"——
 *    buildScore 用的是【单槽】open（`open.set(key, seg)` 覆盖），
 *    同轴同音高的 on 若【重叠】（前一个还没 off 就又来一个 on），
 *    前一个 seg 就永远拿不到 t1 ⇒ 被兜底成 endTick ⇒ 画出一根【到曲末的长条】。
 *    这与用户报过的"时值过长、重叠"是同一族，必须量出来。 */
/* 判据要精确：t1 正好落在【全曲末】且又不是真的一对 (on,off) ⇒ 是兜底拉出来的。
 * ⚠️ 不能只看"长度 > 全曲 25%"—— 6.世界悲 那根只有 65280 tick（≈68 s）会漏掉。
 * ⭐⭐ 2026-10-16（用户裁定）：这一条只管【乐音段】；鼓段另有专项判据②（闭合 + 段长 == 480），
 *   ⛔ 不用"长条"这种模糊阈值去管鼓段 —— 那会把核对器自己的口径错当成页面 bug。 */
const stretched = score.noteSegs.filter(s => s.t1 === Math.max(score.tickMax, 1) &&
                                             !truth.has(s.t0 + "|" + s.t1 + "|" + s.inc + "|" + segKey(s)));
const showSeg = s => "t0=" + s.t0 + " t1=" + s.t1 + " 长 " + (s.t1 - s.t0) +
                     " axis=" + s.axis + " midi=" + (s.midi != null ? s.midi.toFixed(1) : "-");
if (badDrum.length) {
  console.log("  鼓段不合格的前 3 个（判据②：闭合 + 段长 == " + DRUM_DUR_TICK + " + 真配对）：" +
              badDrum.slice(0, 3).map(showSeg).join(" | "));
}
if (badPair.length) {
  console.log("  乐音段对不上的前 3 个：" + badPair.slice(0, 3).map(showSeg).join(" | "));
}
if (stretched.length) {
  console.log("  🔴 乐音段里被兜底拉到全曲末的长条 = " + stretched.length + " 根：" +
              stretched.slice(0, 3).map(showSeg).join(" | "));
}

const tbCount = {};
for (const s of score.noteSegs) {
  const n = API.TIMBRE_NAMES[s.timbre] || ("T" + s.timbre);
  tbCount[n] = (tbCount[n] || 0) + 1;
}
console.log("  音色分布：" + Object.entries(tbCount).map(([k, v]) => k + " " + v).join(" · "));
{
  const dl = score.drumSegs.map(s => s.t1 - s.t0);
  console.log("  鼓段：" + score.drumSegs.length + " 根 · 段长 min/max = " +
              (dl.length ? Math.min(...dl) : "-") + "/" + (dl.length ? Math.max(...dl) : "-") +
              " · 件分布 {" + [0, 1, 2, 3].map(t =>
                t + ":" + score.drumSegs.filter(s => (s.drumType & 3) === t).length).join(",") +
              "}（键=drum_type（2 位，timbre[8:7]），⛔ 不是 inc）· t1 落在曲末的 " +
              score.drumSegs.filter(s => s.t1 === Math.max(score.tickMax, 1)).length +
              " 根（仍满足段长 " + DRUM_DUR_TICK + " + 真配对 ⇒ 正常，⛔ 不是兜底）· orphanOff " +
              score.orphanOff + " · danglingOn " + score.danglingOn);
}
console.log();
console.log("  判据：");
chk("① 乐音段全部能在 hex 里找到对应的 (on,off) 对", badPair.length === 0,
    badPair.length ? (badPair.length + " 段对不上，例 " + JSON.stringify(badPair[0])) : "");
chk("② 鼓段全部闭合、段长 == " + DRUM_DUR_TICK + " tick、且能对上真配对（键 = (axis,drum_type)）",
    score.drumSegs.length > 0 && badDrum.length === 0,
    score.drumSegs.length + " 根 · 不合格 " + badDrum.length +
    "（口径 = t1 非空 + 段长 == " + DRUM_DUR_TICK + " + 字表里有 (axis,drum_type) 真配对）");
chk("③ 乐音段没有兜底长条 + 未闭合 on = 0",
    stretched.length === 0 && score.danglingOn === 0,
    "长条 " + stretched.length + " 根 · orphanOff " + score.orphanOff + "（只报告）· danglingOn " + score.danglingOn);
{
  /* ---- 反控：判据② 必须能红（⛔ 不是恒真的假绿） ---- */
  const fake1 = score.drumSegs.map((s, i) => i === 0 ? Object.assign({}, s, { t1: Math.max(score.tickMax, 1) }) : s);
  const r1 = drumSegBad(fake1);
  chk("②反控 把一根鼓段的 t1 拉到曲末（兜底长条）⇒ 必须红", r1.length > 0,
      "不合格 " + r1.length + " 根 ⇒ " + (r1.length > 0 ? "抓住（符合预期）" : "没抓住（判据恒真）"));
  const fake2 = score.drumSegs.map((s, i) => i === 0 ? Object.assign({}, s, { t1: s.t0 + 240 }) : s);
  const r2 = drumSegBad(fake2);
  chk("②反控 把一根鼓段的段长改成 240（≠ " + DRUM_DUR_TICK + "）⇒ 必须红", r2.length > 0,
      "不合格 " + r2.length + " 根 ⇒ " + (r2.length > 0 ? "抓住（符合预期）" : "没抓住（判据恒真）"));
  const fake3 = score.drumSegs.map((s, i) => i === 0 ? Object.assign({}, s, { t1: null }) : s);
  const r3 = drumSegBad(fake3);
  chk("②反控 把一根鼓段的 t1 置空（未闭合）⇒ 必须红", r3.length > 0,
      "不合格 " + r3.length + " 根 ⇒ " + (r3.length > 0 ? "抓住（符合预期）" : "没抓住（判据恒真）"));
}
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
/* ⭐⭐ 2026-10-16（手册 §二）：乐音（旋律）一律按 is_drum=0 认 ——
 *   ⛔ 不再靠"轴号 < 12"猜（轴号只是标签，鼓的身份由 bit5 显式给出）。 */
const melOns = evs.filter(e => e.isDrum === 0 && e.kind === API.KIND_ON);
const midiOfInc = inc => { const hz = inc * 50000000 / 4294967296; return hz > 0 ? 69 + 12 * Math.log2(hz / 440) : 0; };
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
  /* ⭐ 2026-10-16：鼓段带的是 drumType（不再是 drumInc）—— 件名口径换成 drum_type */
  if (p.drumType != null) mDrum++;
  if (Math.abs(p.midi - topMidi) > 0.5) mWrongRow++;
}
/* 鼓栏扫描：光标放在 Kick 行中心（Kick 的 drum_type = 0，手册 §二） */
const yKick = LV.laneTop + LV.laneH * (0.5 / 4);
let dHit = 0, dWrong = 0, dNone = 0;
for (let px = API.PAD.l + 1; px < API.PAD.l + pw; px += 2) {
  const p = API.pickHover(px, yKick);
  if (!p) { dNone++; continue; }
  dHit++;
  /* ⛔ 原来比的是 `p.drumInc !== API.DRUM_INC.kick` —— 新位域下鼓的 inc 恒为 0，
   *    那个判据实测 485 次全判错。现在比 drum_type（kick = 0）。 */
  if (p.drumType == null || (p.drumType & 3) !== KICK_TYPE) dWrong++;
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

// ================== 六、鼓与旋律分离（2026-10-16 手册 §二 / §4.1-7 / §7.3） ==================
/* 口径：鼓 = is_drum(bit5)=1，件名 = drum_type = timbre[8:7] & 3（kick0 · snare1 · hihat2 · tom3）
 *      旋律 = is_drum=0 且【排除 kind=2】（tempo 用 inc 装速度值）
 * ⛔ 全程不用"轴号 12..15"当鼓的标志 —— 那正是本次要拆掉的老口径。
 * ⚠️ 下面这一节同时是【反控】：每条判据都拿"手造的坏字"喂进同一个谓词，要求它变红。 */
const encWord = o =>
  ((BigInt(o.tick || 0) & 0xFFFFFn) << 44n) | ((BigInt(o.inc || 0) & 0x1FFFFFn) << 23n) |
  ((BigInt(o.axis || 0) & 0xFn) << 19n)     | ((BigInt(o.vel || 0) & 0xFFn) << 11n) |
  ((BigInt(o.kind || 0) & 0x3n) << 9n)      | ((BigInt(o.timbre || 0) & 0x3n) << 7n) |
  ((BigInt(o.guide || 0) & 0x1n) << 6n)     | ((BigInt(o.isDrum || 0) & 0x1n) << 5n) |
  (BigInt(o.note5 || 0) & 0x1Fn);
const DEC_FIELDS = ["tick", "inc", "axis", "vel", "kind", "timbre", "guide", "isDrum", "note5"];
function splitCheck(words) {
  const per = {}; for (let t = 0; t < 8; t++) per[t] = { on: 0, off: 0 };
  const r = { nDrum: 0, nMel: 0, nTempo: 0, drumIncBad: 0, melInc0: 0, melOnDrumAxis: 0,
              drumOn: 0, drumOff: 0, unclosed: 0, orphan: 0, offNoFlag: 0, note5Bad: 0,
              unbal: [], decodeDiff: 0, encDiff: 0, firstEx: "",
              keyBad: 0, rawTypeBad: 0, firstKey: "", per: per };
  const open = new Map();
  for (const w of words) {
    const d = API.unpackWord(w);
    const raw = rawOf(w);
    const df = DEC_FIELDS.filter(f => d[f] !== raw[f]);
    if (df.length) { r.decodeDiff++; if (!r.firstEx) r.firstEx = "字段不一致 " + df.join(","); }
    else if (encWord(raw) !== w) { r.encDiff++; if (!r.firstEx) r.firstEx = "独立编码器往返不等"; }
    if (d.kind === API.KIND_TEMPO) { r.nTempo++; continue; }
    if (d.isDrum === 1) {
      r.nDrum++;
      if (d.inc !== 0) r.drumIncBad++;
      if (d.note5 !== 0) r.note5Bad++;
      const t = DT_OF(d);                                /* drum_type = timbre[8:7]（2 位，4 件） */
      /* 判据⑲：鼓的轴必须 = 12 + dt */
      if (d.axis !== WANT_AXIS_OF_TYPE[t]) {
        r.keyBad++;
        if (!r.firstKey) r.firstKey = ("dt=" + t + "(" + nameOfType(t) + ") 落在轴 " + d.axis +
                                       "，应为 " + WANT_AXIS_OF_TYPE[t]);
      }
      if (t !== DT_RAW(raw)) r.rawTypeBad++;              /* 两条独立读取路径必须给出同一个件号 */
      const k = d.axis + ":" + t;                       /* 配对键 = (axis, drum_type)，手册口径 */
      if (d.kind === API.KIND_ON) { r.drumOn++; r.per[t].on++; open.set(k, (open.get(k) || 0) + 1); }
      else { r.drumOff++; r.per[t].off++; open.set(k, (open.get(k) || 0) - 1); }
    } else {
      r.nMel++;
      if (d.inc === 0) r.melInc0++;
      /* §7.3-1：保留段 12..15（期望值独立写死，⛔ 不取页面的 DRUM_AXIS_BASE/isDrumAxis） */
      if (d.axis >= MELODY_BAN_AXIS_MIN) r.melOnDrumAxis++;
      /* 保留段上却不是鼓 = 典型的"鼓 OFF 漏标 is_drum"。
       * ⚠️ 新口径下鼓占 0..7，与旋律数值重叠 ⇒ 主指纹变成【旋律且 inc=0】（melInc0）。 */
      if (d.kind === API.KIND_OFF && d.axis >= MELODY_BAN_AXIS_MIN) r.offNoFlag++;
    }
  }
  for (const v of open.values()) { if (v > 0) r.unclosed += v; else if (v < 0) r.orphan += -v; }
  r.unbal = [];
  for (let t = 0; t < 8; t++) {
    if (r.per[t].on !== r.per[t].off) r.unbal.push(nameOfType(t) + " " + r.per[t].on + "/" + r.per[t].off);
  }
  return r;
}

console.log();
console.log("【六】鼓与旋律分离（手册 §二 / §4.1-7 / §7.3 —— 鼓 = is_drum + drum_type）");
const sp = splitCheck(conv.words);
console.log("  鼓事件 " + sp.nDrum + " 条（" +
            [0, 1, 2, 3].map(t => nameOfType(t) + " " + sp.per[t].on + "起/" + sp.per[t].off + "止").join(" · ") +
            "）· 旋律事件 " + sp.nMel + " 条（其中 ON " + melOns.length + "）· tempo " + sp.nTempo + " 条");
console.log("  下面七条判据 = 「鼓与旋律有没有真的分开」的机械证据（§4.1-7 硬检查② + §7.3 三条）");
console.log();
console.log("  判据：");
chk("⑬ 鼓事件（is_drum=1）inc 全 0 · 旋律事件（is_drum=0 且非 tempo）inc 全非 0",
    sp.drumIncBad === 0 && sp.melInc0 === 0,
    "鼓 inc≠0 " + sp.drumIncBad + " 条 · 旋律 inc=0 " + sp.melInc0 + " 条");
chk("⑭ is_drum=0 的事件里，轴号落 12..15 的必须 0 条（§7.3-1）",
    sp.melOnDrumAxis === 0,
    sp.melOnDrumAxis ? (sp.melOnDrumAxis + " 条（说明还有依赖轴号的路径）")
                     : ("0 条（本轮鼓占 12..15 ⇒ 这四条轴只有 is_drum=1 的事件能占；起点 " +
                        MELODY_BAN_AXIS_MIN + " 独立写死）"));
chk("⑮ 鼓 ON/OFF 按 (axis,drum_type) 全配对，OFF 也带 is_drum=1 与同一 drum_type",
    sp.drumOn > 0 && sp.drumOn === sp.drumOff && sp.unclosed === 0 && sp.orphan === 0 &&
    sp.offNoFlag === 0 && sp.unbal.length === 0,
    "ON " + sp.drumOn + " / OFF " + sp.drumOff + " · 未闭合 " + sp.unclosed + " · 无主 OFF " + sp.orphan +
    " · 鼓段上漏标 is_drum 的 OFF " + sp.offNoFlag + " 条" +
    (sp.unbal.length ? (" · 逐件不守恒：" + sp.unbal.join(" ")) : ""));
chk("⑯ is_drum=1 时 note_off5 必须为 0（鼓没有音高）", sp.note5Bad === 0,
    sp.note5Bad ? (sp.note5Bad + " 条 note_off5≠0") : "全部为 0");
chk("⑰ 页面 unpackWord 与独立位提取一致（含 bit5 is_drum / bits[4:0] note_off5）",
    sp.decodeDiff === 0 && sp.encDiff === 0,
    (sp.decodeDiff || sp.encDiff) ? ((sp.decodeDiff + sp.encDiff) + " 条不一致（" + sp.firstEx + "）")
      : (conv.words.length + " 条逐字段一致 + 独立编码器往返一致（64 位全覆盖）"));
/* ⑲ 鼓的 axis = 12 + drum_type（axis-12 == dt）—— 本轮的核心硬判据。
 *    为什么必须有：四件鼓的 src 全是 SRC_KDRUM，note_off 按 (axis, src) 配对
 *    ⇒ 轴号就是件的定位键，轴与件错配 => 一件的 OFF 会清掉另一件的 voice。
 *    历史错法（都能被抓住）：上一轮的 dt 键（0/2/4/6/1/3/5/7，轴 <12）、更早的 8+dt、
 *    以及"件号改了轴没跟着改"。
 *    ⛔ 上一轮的"axis&1 == dt>>2"读数已删除：drum_type 只有 2 位，没有高位可对。
 *    两条【独立】读取路径：页面 unpackWord 的 drumType vs 本文件的位提取（bit 8..7）。 */
chk("⑲ 鼓的 axis = 12 + drum_type（axis-12 == dt）· 两条件号读取路径一致 · 鼓轴全落 12..15",
    sp.nDrum > 0 && sp.keyBad === 0 && sp.rawTypeBad === 0 &&
    !evs.some(e => e.isDrum === 1 &&
                   (e.axis < DRUM_AXIS_BASE || e.axis > DRUM_AXIS_MAX)),
    "轴≠12+dt " + sp.keyBad + " 条" + (sp.firstKey ? ("（例 " + sp.firstKey + "）") : "") +
    " · 两条路径不一致 " + sp.rawTypeBad + " 条 · 12+dt = " + AXIS_KEY_TXT);
/* ⑳（2026-10-16 第三轮新增）镲族必须归 hihat：页面 GM_DRUM_MAP 里这 8 个音高
 *    必须【显式列出】且指向 hihat（⛔ 不靠表外兜底 -> tom，那等于"镲变嗵鼓"）。
 *    ⚠️ 这份测试曲一个镲族音高都没有 ⇒ 产物上验不到，只能核对这张表。 */
{
  const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
  const bad = [];
  if (!API.GM_DRUM_MAP) bad.push("页面没有 GM_DRUM_MAP（GM 音高 -> 鼓件名的表缺失）");
  else {
    const notListed = CYMBAL_GMS.filter(g => !has(API.GM_DRUM_MAP, g));
    if (notListed.length) {
      bad.push("镲族 " + notListed.join("/") + " 没有【显式列出】（会走表外兜底 -> tom）");
    }
    const notHat = CYMBAL_GMS.filter(g => has(API.GM_DRUM_MAP, g) && API.GM_DRUM_MAP[g] !== "hihat");
    if (notHat.length) {
      bad.push("镲族 " + notHat.map(g => "GM" + g + "->" + API.GM_DRUM_MAP[g]).join(" ") + " 没指向 hihat");
    }
  }
  if (API.DRUM_TYPE_OF) {
    const n = Object.keys(API.DRUM_TYPE_OF).length;
    if (n !== 4) bad.push("页面 DRUM_TYPE_OF 有 " + n + " 件（本轮应当正好 4 件）");
  }
  /* 反控（静态）：把镲族从表里拿掉、或把某一条指到 tom —— 检查器必须认出来，
   *   证明这条判据不是恒真的假绿（与 check_guide.js 判据⑲ 同一手法）。 */
  let ctlNote = "";
  if (API.GM_DRUM_MAP) {
    const fakeDrop = {};
    for (const k of Object.keys(API.GM_DRUM_MAP)) {
      if (CYMBAL_GMS.indexOf(Number(k)) < 0) fakeDrop[k] = API.GM_DRUM_MAP[k];
    }
    const ctlDrop = CYMBAL_GMS.filter(g => !has(fakeDrop, g));
    const fakeTom = Object.assign({}, API.GM_DRUM_MAP);
    fakeTom[51] = "tom";
    const ctlTom = CYMBAL_GMS.filter(g => has(fakeTom, g) && fakeTom[g] !== "hihat");
    if (ctlDrop.length !== CYMBAL_GMS.length) {
      bad.push("反控失效：把镲族从表里拿掉后只认出 " + ctlDrop.length + "/" + CYMBAL_GMS.length + " 个");
    }
    if (!(ctlTom.length === 1 && ctlTom[0] === 51)) {
      bad.push("反控失效：把 GM51 改成 tom 后认出的集合 = [" + ctlTom.join(",") + "]（应只认 51）");
    }
    ctlNote = " · 反控：拿掉镲族 -> 认出 " + ctlDrop.length + " 个；GM51->tom -> 认出 [" + ctlTom.join(",") + "]";
  }
  chk("⑳ 镲族 8 个音高在页面表里【显式列出】-> hihat（⛔ 不靠兜底 -> tom）",
      bad.length === 0,
      bad.length ? bad.join(" | ")
                 : (CYMBAL_GMS.join("/") + " 全部显式 ->hihat · 页面表 4 件" + ctlNote));
}
/* ⑱ note_off5 新口径（FPGA 线回函 §三）：可弹（MIDI 45..75）=> MIDI-45；
 *    越界 => 31 哨兵（键盘上没有这个键 ⇒ 不点灯）；⛔ 不许钳到 0（0 = A2 = 真实的键 5，会点错灯）。
 *    ⚠️ MIDI 只从【事件里带的 inc】反推（⛔ 不读页面的 midi 中间量，那是被验者自己的东西）。
 *    ⚠️ inc 只有 21 位 ⇒ inc->Hz->MIDI 有量化误差：允许 ±1 半音；边界（45±0.5 / 75±0.5）留死区。
 *    ⚠️ 口径边界：哨兵只作用于旋律；鼓的 note_off5 恒 0（判据⑯，本轮不回退）。 */
function note5Scan(list) {
  const SENT = 31, LO = 45, HI = 75;
  const res = { play: 0, unplay: 0, edge: 0, skip: 0, badVal: 0, badSent: 0, badUse: 0, badClamp: 0, ex: [] };
  for (const e of list) {
    if (e.isDrum === 1 || e.kind === API.KIND_TEMPO) continue;
    const m = (e.inc === 0) ? null : midiOfInc(e.inc);
    if (m == null) { res.skip++; continue; }
    if (m < LO - 0.5 || m > HI + 0.5) {
      res.unplay++;
      if (e.note5 !== SENT) {
        res.badSent++;
        if (e.note5 === 0) res.badClamp++;
        if (res.ex.length < 3) res.ex.push("tick " + e.tick + " 音高 " + m.toFixed(1) + " 却写 note5=" + e.note5);
      }
    } else if (m < LO || m > HI) {
      res.edge++;
    } else {
      res.play++;
      const want = Math.round(m) - LO;
      if (e.note5 === SENT) {
        res.badUse++;
        if (res.ex.length < 3) res.ex.push("tick " + e.tick + " 音高 " + m.toFixed(1) + " 可弹却写哨兵 31");
      } else if (Math.abs(e.note5 - want) > 1) {
        res.badVal++;
        if (res.ex.length < 3) res.ex.push("tick " + e.tick + " note5=" + e.note5 + " 期望 " + want);
      }
    }
  }
  return res;
}
const N5 = note5Scan(evs);
chk("⑱ 旋律 note_off5：可弹(45..75) => MIDI-45 · 越界 => 31 哨兵（⛔ 不许钳到 0）",
    N5.badVal === 0 && N5.badSent === 0 && N5.badUse === 0,
    "可弹 " + N5.play + " · 越界 " + N5.unplay + "（应写 31）· 边界死区 " + N5.edge +
    " · 值不对 " + N5.badVal + " · 越界没写哨兵 " + N5.badSent + "（其中钳到 0 的 " + N5.badClamp +
    "）· 可弹误写哨兵 " + N5.badUse + (N5.ex.length ? ("（例 " + N5.ex.join(" | ") + "）") : ""));
{
  /* ---- 反控：手造坏字，喂进【同一个】谓词，要求判据变红 ---- */
  const base = conv.words;
  /* a 鼓事件 inc≠0（手册 §4.1-7 硬检查②） */
  const ra = splitCheck(base.concat([encWord({ tick: 0, inc: 37796, axis: 12, vel: 230,
                                               kind: API.KIND_ON, timbre: 0, isDrum: 1, note5: 0 })]));
  chk("⑬反控 手造一条 is_drum=1 且 inc≠0 的字 ⇒ 判据必须红",
      ra.drumIncBad > 0, "鼓 inc≠0 " + ra.drumIncBad + " 条 ⇒ " + (ra.drumIncBad > 0 ? "抓住（符合预期）" : "没抓住（判据失效）"));
  /* b 旋律事件 inc=0（= 被当成鼓/静音的指纹） */
  const rb = splitCheck(base.concat([encWord({ tick: 0, inc: 0, axis: 2, vel: 100,
                                               kind: API.KIND_ON, timbre: 1, isDrum: 0, note5: 3 })]));
  chk("⑬反控 手造一条 is_drum=0 且 inc=0 的旋律字 ⇒ 判据必须红",
      rb.melInc0 > 0, "旋律 inc=0 " + rb.melInc0 + " 条 ⇒ " + (rb.melInc0 > 0 ? "抓住（符合预期）" : "没抓住（判据失效）"));
  /* c is_drum=0 却占鼓轴（§7.3-1 要抓的正是这个） */
  const rc = splitCheck(base.concat([encWord({ tick: 0, inc: 37796, axis: 13, vel: 100,
                                               kind: API.KIND_ON, timbre: 1, isDrum: 0, note5: 3 })]));
  chk("⑭反控 手造一条 is_drum=0 且轴=13 的字 ⇒ 判据必须红",
      rc.melOnDrumAxis > 0, "落鼓轴的旋律字 " + rc.melOnDrumAxis + " 条 ⇒ " +
      (rc.melOnDrumAxis > 0 ? "抓住（符合预期）" : "没抓住（判据失效）"));
  /* d 把一条【真实存在】的鼓 OFF 的 is_drum 位清 0（= ON/OFF 不同步，手册点名的挂音点）。
   *   ⚠️ 必须"替换"那条 OFF，⛔ 不是另加一条漏标 OFF —— 另加不会让原来那条 ON 变成未闭合
   *   （实测：漏标 1 条、未闭合 0 条 ⇒ 期望写错，判据本身是对的）。
   *   2026-10-16 第三轮：鼓回到轴 12..15 ⇒ 清掉 is_drum 的那条 OFF 落回【旋律且轴 12..15】
   *      ⇒ 未闭合、melInc0、offNoFlag（鼓轴段上没带 is_drum 的 OFF）三条指纹一起涨。 */
  let offAt = -1;
  for (let i = 0; i < base.length; i++) {
    const dd = API.unpackWord(base[i]);
    if (dd.isDrum === 1 && dd.kind === API.KIND_OFF) { offAt = i; break; }
  }
  const rd = offAt < 0 ? null : splitCheck(base.slice(0, offAt).concat([base[offAt] & ~(1n << 5n)])
                                               .concat(base.slice(offAt + 1)));
  chk("⑮反控 把一条鼓 OFF 的 is_drum 位清 0（ON/OFF 不同步 ⇒ 挂音）⇒ 判据必须红",
      !!rd && rd.unclosed > 0 && rd.melInc0 > 0,
      rd ? ("未闭合 ON " + rd.unclosed + " 条 · 被当成 inc=0 旋律字的 " + rd.melInc0 +
            " 条（鼓轴段上漏标 is_drum 的 offNoFlag " + rd.offNoFlag + "）⇒ " +
            ((rd.unclosed > 0 && rd.melInc0 > 0) ? "抓住（符合预期）" : "没抓住（判据失效）"))
         : "找不到可改的鼓 OFF（无法构造）");
  /* e 鼓 ON 没有配对 OFF（拔掉一条 OFF 字） */
  let cutAt = -1;
  for (let i = 0; i < base.length; i++) {
    const d = API.unpackWord(base[i]);
    if (d.isDrum === 1 && d.kind === API.KIND_OFF) { cutAt = i; break; }
  }
  const re = cutAt < 0 ? null : splitCheck(base.slice(0, cutAt).concat(base.slice(cutAt + 1)));
  chk("⑮反控 拔掉一条鼓 OFF 字 ⇒ 未闭合 ON 必须 > 0",
      !!re && re.unclosed > 0, re ? ("未闭合 ON " + re.unclosed + " ⇒ " +
      (re.unclosed > 0 ? "抓住（符合预期）" : "没抓住（判据失效）")) : "找不到可拔的鼓 OFF（无法构造）");
  /* f 鼓事件 note_off5≠0（鼓没有音高） */
  const rf = splitCheck(base.concat([encWord({ tick: 0, inc: 0, axis: 14, vel: 175,
                                               kind: API.KIND_ON, timbre: 2, isDrum: 1, note5: 7 })]));
  chk("⑯反控 手造一条 is_drum=1 且 note_off5=7 的字 ⇒ 判据必须红",
      rf.note5Bad > 0, "鼓 note_off5≠0 " + rf.note5Bad + " 条 ⇒ " +
      (rf.note5Bad > 0 ? "抓住（符合预期）" : "没抓住（判据失效）"));
  /* g 比对器自检：把独立提取的一个字段改错 ⇒ 必须报不一致（证明⑰不是恒真） */
  {
    const w0 = base[0], raw = rawOf(w0);
    const wrong = Object.assign({}, raw, { isDrum: raw.isDrum ^ 1, note5: (raw.note5 + 1) & 0x1F });
    const diff = DEC_FIELDS.filter(f => API.unpackWord(w0)[f] !== wrong[f]);
    chk("⑰反控 把独立提取的 bit5 / bits[4:0] 改错 ⇒ 比对器必须报不一致",
        diff.indexOf("isDrum") >= 0 && diff.indexOf("note5") >= 0,
        "报出字段 [" + diff.join(",") + "] ⇒ " +
        ((diff.indexOf("isDrum") >= 0 && diff.indexOf("note5") >= 0) ? "抓住（符合预期）" : "比对器恒真，失效"));
  }
  /* h ⑲反控 1：手造一条 snare(dt=1) 却落在 axis=0（上一轮的 dt 键）的鼓字 ⇒ keyBad 必须涨 */
  {
    const rh = splitCheck(base.concat([encWord({ tick: 0, inc: 0, axis: 0, vel: 235,
                                                 kind: API.KIND_ON, timbre: 1, isDrum: 1, note5: 0 })]));
    chk("⑲反控 手造一条 snare(dt=1) 落在 axis=0（上一轮 dt 键）的字 ⇒ 必须报轴≠12+dt",
        rh.keyBad > 0, "轴≠12+dt " + rh.keyBad + " 条 ⇒ " +
        (rh.keyBad > 0 ? "抓住（符合预期）" : "没抓住（判据失效）"));
  }
  /* i ⑲反控 2：手造一条 axis=8 的鼓字（更早的 8..15 口径）⇒ 必须报轴≠12+dt */
  {
    const ri = splitCheck(base.concat([encWord({ tick: 0, inc: 0, axis: 8, vel: 230,
                                                 kind: API.KIND_ON, timbre: 0, isDrum: 1, note5: 0 })]));
    chk("⑲反控 手造一条鼓字落在 axis=8（更早的 8..15 口径）⇒ 必须报轴≠12+dt",
        ri.keyBad > 0, "轴≠12+dt " + ri.keyBad + " 条 ⇒ " +
        (ri.keyBad > 0 ? "抓住（符合预期）" : "没抓住（判据失效）"));
  }
  /* j ⑲反控 3：把一条真实鼓字的 timbre 低位 +1（件号变了、轴没跟着变）⇒ 必须报轴≠12+dt */
  {
    let at = -1;
    for (let i = 0; i < base.length; i++) if (API.unpackWord(base[i]).isDrum === 1) { at = i; break; }
    const rj = at < 0 ? null : splitCheck(base.slice(0, at)
      .concat([(base[at] & ~(3n << 7n)) | ((((base[at] >> 7n) & 3n) + 1n & 3n) << 7n)])
      .concat(base.slice(at + 1)));
    chk("⑲反控 把一条真实鼓字的 timbre 低位 +1（件号变、轴没变）⇒ 必须报轴≠12+dt",
        !!rj && rj.keyBad > 0,
        rj ? ("轴≠12+dt " + rj.keyBad + " 条 ⇒ " +
              (rj.keyBad > 0 ? "抓住（符合预期）" : "没抓住（判据失效）"))
           : "找不到可改的鼓字（无法构造）");
  }
  /* l ⑲反控 4（非空洞）：证明"只读 timbre[8:7]（2 位）"在本产物上有鉴别力 ——
   *   若代码还按上一轮的 3 位 {bit19, timbre[8:7]} 读，件号会在多少条上不同。
   *   本产物有落在轴 13/15（bit19=1）的鼓 ⇒ 这个数必然 > 0；等于 0 才说明测不到东西。 */
  {
    let legacyDiff = 0;
    for (const w of base) {
      const d = API.unpackWord(w);
      if (d.isDrum !== 1) continue;
      if (DT_LEGACY3(rawOf(w)) !== DT_RAW(rawOf(w))) legacyDiff++;
    }
    chk("⑲反控 上一轮的 3 位读法 {bit19,timbre} 与 2 位读法在本产物上必须【不同】（否则测不到）",
        legacyDiff > 0, "3 位读法会算错 " + legacyDiff + " 条鼓事件的件号 ⇒ " +
        (legacyDiff > 0 ? "2 位读法的鉴别力非空洞（符合预期）" : "两种读法结果相同，本条检查空洞"));
  }
  /* k ⑱反控：note_off5 三种坏法，喂进【同一个】note5Scan() */
  {
    const mkE = (midi, n5) => ({ isDrum: 0, kind: API.KIND_ON, tick: 0,
                                 inc: Math.round(440 * Math.pow(2, (midi - 69) / 12) * 4294967296 / 50000000),
                                 note5: n5 });
    const ra2 = note5Scan(evs.concat([mkE(40, 0)]));
    chk("⑱反控 手造一条音高 40（越界）却写 note5=0 的字 ⇒ 必须报越界没写哨兵 + 钳到 0",
        ra2.badSent > 0 && ra2.badClamp > 0,
        "越界未写哨兵 " + ra2.badSent + " · 其中钳到 0 的 " + ra2.badClamp + " ⇒ " +
        ((ra2.badSent > 0 && ra2.badClamp > 0) ? "抓住（符合预期）" : "没抓住（判据失效）"));
    const rb2 = note5Scan(evs.concat([mkE(60, 31)]));
    chk("⑱反控 手造一条音高 60（可弹）却写哨兵 31 的字 ⇒ 必须报可弹误写哨兵",
        rb2.badUse > 0, "可弹误写哨兵 " + rb2.badUse + " 条 ⇒ " +
        (rb2.badUse > 0 ? "抓住（符合预期）" : "没抓住（判据失效）"));
    const rc2 = note5Scan(evs.concat([mkE(60, 3)]));
    chk("⑱反控 手造一条音高 60 却写 note5=3（应为 15）的字 ⇒ 必须报值不对",
        rc2.badVal > 0, "值不对 " + rc2.badVal + " 条 ⇒ " +
        (rc2.badVal > 0 ? "抓住（符合预期）" : "没抓住（判据失效）"));
  }
}

console.log();
console.log("  结论：" + (red === 0 ? ("全部通过（" + nChk + " 项）") : ("有 " + red + " 项 RED")));
process.exit(red === 0 ? 0 : 1);
