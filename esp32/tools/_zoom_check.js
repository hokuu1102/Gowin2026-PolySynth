// _zoom_check.js —— 验图谱缩放的视口数学（放大/平移/锚点/裁剪）
// 用法：node _zoom_check.js "<文件.mi>"（可选）
const fs = require("fs");
const path = require("path");

let bad = 0;
function chk(name, cond, extra) {
  console.log("  " + name.padEnd(56) + (cond ? "OK" : "RED") + (extra ? "   " + extra : ""));
  if (!cond) bad++;
}

const html = fs.readFileSync(path.join(__dirname, "score_studio.html"), "utf8");
const blk = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1])[0];
const code = blk.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, " ")
                .replace(/"(?:\\.|[^"\\\n])*"/g, 'S');

const draws = [];      /* ⭐ 记录 draw() 真正画出去的图元（用来验"有没有画到画布外"）*/
const fakeCtx = {
  canvas: { width: 800, height: 400 },
  measureText: () => ({ width: 30 }),
  fillText(t, x, y) { draws.push({ k: "text", t: String(t), x: x, y: y }); },
  fillRect(x, y, w, h) { draws.push({ k: "rect", x: x, y: y, w: w, h: h }); },
  strokeRect() {}, beginPath() {}, moveTo() {},
  lineTo() {}, stroke() {}, fill() {}, save() {}, restore() {}, setLineDash() {},
  clearRect() {}, closePath() {}, roundRect() {}, rect() {},
};
const fakeEl = () => ({
  style: {}, classList: { add() {}, remove() {} }, getContext: () => fakeCtx,
  querySelectorAll: () => [], querySelector: () => null, addEventListener() {},
  appendChild() {}, insertAdjacentHTML() {},
  getBoundingClientRect: () => ({ left: 0, top: 0, width: 800, height: 400 }),
  textContent: "", innerHTML: "", checked: false,
  width: 800, height: 400, clientWidth: 800, clientHeight: 400,
  parentElement: { getBoundingClientRect: () => ({ width: 800, height: 400 }) },
});
const doc = { getElementById: () => fakeEl(), querySelector: () => fakeEl(),
  querySelectorAll: () => [], addEventListener() {}, createElement: () => fakeEl(),
  body: fakeEl() };
const fn = new Function("document", "window", "navigator", "performance", "console",
  "setTimeout", "clearInterval", "setInterval", "requestAnimationFrame",
  "location", "localStorage", "URLSearchParams",
  blk + "; return { parseMidi, midiToWords, buildScore, viewWindow, zoomAt, " +
  "tickToX, playheadX, dragScrollDelta, timeTickStep, tickToSec, secToTick, FOOT, " +
  "draw, setPlayFrac: (v) => { playFrac = v; }, " +
  "PAD, setScore: (x) => { score = x; }, setZoom: (z) => { viewZoom = z; }, " +
  "setScroll: (s) => { viewScroll = s; }, getZoom: () => viewZoom, " +
  "getScroll: () => viewScroll, ZMAX: VIEW_ZOOM_MAX };");const API = fn(doc, { addEventListener() {} }, { bluetooth: null }, { now: () => 0 },
  console, setTimeout, () => {}, () => 0, () => 0,
  { protocol: "http:", host: "x", search: "" },
  { getItem: () => null, setItem() {} },
  class { constructor() {} get() { return null; } });

console.log("=".repeat(78));
console.log("图谱缩放 视口数学自检");
console.log("=".repeat(78));

const midPath = process.argv[2];
let sc;
if (midPath && fs.existsSync(midPath)) {
  const buf = fs.readFileSync(midPath);
  const conv = API.midiToWords(API.parseMidi(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length)));
  sc = API.buildScore(conv.words, "x");
  console.log("  用真实谱面：tickMax = " + sc.tickMax);
} else {
  /* 造一个简单谱面：10 秒 @960PPQN */
  const words = [];
  for (let t = 0; t <= 9600; t += 960) {
    words.push((BigInt(t) << 44n) | (BigInt(22473) << 23n) | (BigInt(0) << 19n) |
               (BigInt(100) << 11n) | (BigInt(0) << 9n) | (BigInt(1) << 7n));
  }
  sc = API.buildScore(words, "test");
  console.log("  用合成谱面：tickMax = " + sc.tickMax);
}
API.setScore(sc);

const TOTAL = Math.max(1, sc.tickMax);
const PW = 600;

console.log("\n① 初始状态（zoom=1）应看整首");
{
  const v = API.viewWindow();
  chk("zoom 初始 = 1", API.getZoom() === 1, "zoom=" + API.getZoom());
  chk("scroll 初始 = 0", API.getScroll() === 0, "scroll=" + API.getScroll());
  chk("span = 全长", Math.abs(v.span - TOTAL) < 1e-6, "span=" + v.span.toFixed(0));
  chk("t0 = 0", v.t0 === 0);
  chk("t1 = 全长", Math.abs(v.t1 - TOTAL) < 1e-6);
}

console.log("\n② 放大：span 应变小，且不超过上限");
for (const z of [2, 5, 10, 20]) {
  API.setZoom(z);
  const v = API.viewWindow();
  chk("zoom=" + z + " => span = 全长/" + z,
      Math.abs(v.span - TOTAL / z) < 1e-6, "span=" + v.span.toFixed(0));
}
/* ⭐ 夹取只能经 zoomAt（真实交互都走它）—— setZoom 是裸赋值，⛔ 不夹。*/
API.zoomAt(300, PW, 999);
chk("放大因子巨大 => zoom 被夹到上限 20", API.getZoom() === 20, "zoom=" + API.getZoom());
API.setZoom(1);
API.zoomAt(300, PW, 0.0001);
chk("缩小因子极小 => zoom 被夹到下限 1", API.getZoom() === 1, "zoom=" + API.getZoom());

console.log("\n③ 放大后到边界：scroll 夹在 0..1");
API.setZoom(4);
API.setScroll(0);
chk("scroll=0 => t0=0", API.viewWindow().t0 === 0);
API.setScroll(1);
const vEnd = API.viewWindow();
chk("scroll=1 => 视口右边缘贴全长",
    Math.abs(vEnd.t1 - TOTAL) < 1e-6, "t1=" + vEnd.t1.toFixed(0) + " vs " + TOTAL);
API.setScroll(0.5);
const vMid = API.viewWindow();
chk("scroll=0.5 => 视口中点在整首中间",
    Math.abs((vMid.t0 + vMid.t1) / 2 - TOTAL / 2) < 1e-6);
/* ⭐ viewWindow 内部夹取 —— 即使 scroll 是脏值也不会算出视口外 */
API.setScroll(-3);
const vNeg = API.viewWindow();
chk("scroll=-3 => viewWindow 内夹到 t0=0", vNeg.t0 === 0, "t0=" + vNeg.t0.toFixed(0));
API.setScroll(99);
const vBig = API.viewWindow();
chk("scroll=99 => viewWindow 内夹到 t1=全长",
    Math.abs(vBig.t1 - TOTAL) < 1e-6, "t1=" + vBig.t1.toFixed(0));

console.log("\n④ zoomAt：锚点 tick 应保持在同一屏幕位置");
{
  API.setZoom(1); API.setScroll(0);
  /* ⭐ 锚点与屏幕位置必须【同一个 frac】——
   * 🔴 我第一版用"视口中点"当锚点、却把屏幕位置传给 zoomAt，
   *    两者位置不同 ⇒ 锚点当然没保持（假红）。*/
  const FRAC = 0.6;
  const v0 = API.viewWindow();
  const anchor = v0.t0 + FRAC * v0.span;
  const screenX = API.PAD.l + PW * FRAC;
  API.zoomAt(screenX, PW, 2);       // 放大 2 倍
  const v1 = API.viewWindow();
  /* 反算：screenX 这个屏幕位置现在对应的 tick */
  const nowTick = v1.t0 + ((screenX - API.PAD.l) / PW) * v1.span;
  chk("放大 2 倍后，同一屏幕位置的 tick 基本不变",
      Math.abs(nowTick - anchor) < v0.span * 0.02,
      "锚点=" + anchor.toFixed(0) + " 现在=" + nowTick.toFixed(0));
  chk("且 zoom 确实变 2", API.getZoom() === 2, "zoom=" + API.getZoom());
  /* 缩小回 1，锚点应回到原处 */
  API.zoomAt(screenX, PW, 0.5);
  const v2 = API.viewWindow();
  const nowTick2 = v2.t0 + ((screenX - API.PAD.l) / PW) * v2.span;
  chk("缩回 1 倍后仍在同一 tick",
      Math.abs(nowTick2 - anchor) < v0.span * 0.02,
      "锚点=" + anchor.toFixed(0) + " 现在=" + nowTick2.toFixed(0));
  API.setZoom(1); API.setScroll(0);
}

console.log("\n⑤ 裁剪判据：视口外的段应被跳过");
{
  /* 造一个明确在视口外的段 */
  const far = API.viewWindow();
  const segs = sc.noteSegs || sc.segs || [];
  let inView = 0, outView = 0;
  for (const s of segs) {
    const v = API.viewWindow();
    if (s.t1 < v.t0 || s.t0 > v.t1) outView++; else inView++;
  }
  chk("zoom=1 时几乎所有段都在视口内", inView > 0);
  API.setZoom(20);
  /* 重算 */
  let in2 = 0, out2 = 0;
  for (const s of segs) {
    const v = API.viewWindow();
    if (s.t1 < v.t0 || s.t0 > v.t1) out2++; else in2++;
  }
  chk("zoom=20 时大部分段落在视口外（裁剪才有意义）",
      out2 > in2, "视口内 " + in2 + " / 外 " + out2);
  API.setZoom(1);
}

console.log("\n⑥ 结构：换谱面重置视口 / 有滚轮与拖动 / 有总览条");
/* ⚠️ 这里用【原始 blk】⛔ 不用 code —— code 为了判据把双引号内容剥成了 S，
 * 于是 addEventListener("wheel") 变成 addEventListener(S) ⇒ 匹配不到（白红）。*/
chk("buildScore 内部重置 viewZoom/viewScroll",
    /buildScore\(words, name\) \{[\s\S]{0,400}?viewZoom = 1; viewScroll = 0;/.test(blk));
chk("绑定了 wheel（滚轮缩放）", /addEventListener\("wheel"/.test(blk));
chk("preventDefault（不然滚轮会带着整个页面滚）",
    /preventDefault\(\)/.test(blk));
chk("绑定了 mousedown（拖动平移）", /addEventListener\("mousedown"/.test(blk));
chk("绑定了 mouseup（结束拖动）", /addEventListener\("mouseup"/.test(blk));
chk("画了总览条（overviewBar）", /overviewBar\s*=/.test(blk));
chk("点总览条可跳转", /overviewBar/.test(blk));
chk("X() 走 tickToX（换算只此一份）", /const X = t => tickToX\(t, vw, pw\)/.test(blk));
chk("tickToX 用视口而不是整首",
    /function tickToX\(t, vw, pw\)[\s\S]{0,120}vw\.t0/.test(blk));
chk("音符段有视口裁剪", /s\.t1 < vw\.t0 \|\| s\.t0 > vw\.t1/.test(blk));
chk("悬停判定也用视口（不然放大后提示错位）",
    /vw\.span \* 0\.02/.test(blk));
/* ⭐ 2026-10-15 新增：播放游标也必须走视口。
 * 🔴 漏了这一条 ⇒ 放大后游标画在"默认缩放的位置"上（用户实测反馈）。*/
chk("播放游标走 playheadX（⛔ 不是 PAD.l + playFrac*pw）",
    /playheadX\(playFrac, tm, vw, pw\)/.test(blk) &&
    !/PAD\.l \+ Math\.min\(1, Math\.max\(0, playFrac\)\) \* pw/.test(blk));
chk("游标画在图区之外时要跳过（⛔ 不画到琴键上）",
    /if \(x >= PAD\.l - 1 && x <= PAD\.l \+ pw \+ 1\)/.test(blk));
/* ⭐ 2026-10-15：拖动平移（用户："缩放了之后好像不能拖动"）。
 * 🔴 根因：mousemove 里用了 px，而 px 只在 wheel/click 处理器的局部声明过
 *    ⇒ 一拖就 ReferenceError ⇒ 完全拖不动。*/
chk("拖动：mousemove 内自己算 px/py（⛔ 否则 px is not defined）",
    /addEventListener\("mousemove", ev => \{[\s\S]{0,400}?const px = ev\.clientX - r\.left, py = ev\.clientY - r\.top;/.test(blk));
chk("拖动：位移走 dragScrollDelta（⛔ 不内联 / viewZoom）",
    /dragScrollDelta\(px - dragX, pw, viewZoom\)/.test(blk) &&
    !/viewScroll - \(dx \/ pwNow\) \/ viewZoom/.test(blk));
/* ⭐ 2026-10-15：底部条带（时间刻度轴 + 读数行）。*/
chk("底部有时间刻度轴（走 secToTick + 视口）",
    /X\(secToTick\(s\)\)/.test(blk) && /timeTickStep\(span, pw\)/.test(blk));
chk("底部有游标时间读数（⛔ 不是 tick/960）",
    /游标 " \+ tickToSec\(Math\.min\(1, Math\.max\(0, playFrac\)\) \* tm\)/.test(blk));
chk("起播时重置“已出声”基线（⛔ 不累计整个页面）",
    /btnPlay"\)\.onclick[\s\S]{0,900}?playStartWall = performance\.now\(\)/.test(blk));

console.log("\n⑦ 拖动平移必须【跟手】（2026-10-15 用户：缩放了之后不能拖动）");
{
  /* 判据：拖动 dx 像素后，原本在光标下的 tick 必须跟到新光标位置（1:1）。 */
  const PWd = 600, DX = 60, X0 = 200;
  let worst = 0, worstZ = 0;
  for (const z of [2, 4, 20]) {
    API.setZoom(z); API.setScroll(0.5);
    const v0 = API.viewWindow();
    const before = v0.t0 + ((X0 - API.PAD.l) / PWd) * v0.span;
    /* 应用一次拖动增量（与页面里同一套算式）*/
    const d = API.dragScrollDelta(DX, PWd, z);
    API.setScroll(Math.max(0, Math.min(1, API.getScroll() + d)));
    const v1 = API.viewWindow();
    const after = v1.t0 + (((X0 + DX) - API.PAD.l) / PWd) * v1.span;
    const err = Math.abs(after - before);
    if (err > worst) { worst = err; worstZ = z; }
  }
  chk("拖 60px 后光标下的 tick 不变（误差 < 1 tick）", worst < 1,
      "最坏 zoom=" + worstZ + " 偏差 " + worst.toFixed(1) + " tick");
  /* 非空洞性：旧的 /viewZoom 写法必须能被这条判据抓到 */
  {
    API.setZoom(4); API.setScroll(0.5);
    const v0 = API.viewWindow();
    const before = v0.t0 + ((X0 - API.PAD.l) / PWd) * v0.span;
    API.setScroll(Math.max(0, Math.min(1, API.getScroll() - (DX / PWd) / 4)));
    const v1 = API.viewWindow();
    const after = v1.t0 + (((X0 + DX) - API.PAD.l) / PWd) * v1.span;
    chk("旧的 /viewZoom 写法会偏（证明这条判据非空洞）",
        Math.abs(after - before) > 1,
        "旧写法偏差 " + Math.abs(after - before).toFixed(1) + " tick");
  }
  API.setZoom(1); API.setScroll(0);
}

console.log("\n⑧ 底部时间刻度：步长要“好看”且不糊");
{
  const PWd = 600;
  for (const z of [1, 4, 20]) {
    API.setZoom(z); API.setScroll(0);
    const v = API.viewWindow();
    const span = API.tickToSec(v.t1) - API.tickToSec(v.t0);
    const st = API.timeTickStep(span, PWd);
    const n = span / st;
    chk("zoom=" + z + "（视口 " + span.toFixed(2) + "s）步长 " + st + "s ⇒ " +
        n.toFixed(1) + " 个刻度",
        n >= 2 && n <= PWd / 64 + 1, "");
  }
  API.setZoom(1); API.setScroll(0);
}

console.log("\n⑨ 底部条带必须【整条落在画布内】（魔数把它顶出去过）");
{
  /* 🔴 上一版读数行画在 plot底 + 30，而 PAD.b 只有 26 ⇒ 永远看不见。*/
  chk("PAD.b ≥ FOOT.total（否则底部被顶出画布）",
      API.PAD.b >= API.FOOT.total, "PAD.b=" + API.PAD.b + " FOOT.total=" + API.FOOT.total);
  const rows = [["刻度标签", API.FOOT.label + 11], ["图例", API.FOOT.legend + 8],
                ["总览条", API.FOOT.bar + API.FOOT.barH], ["读数行", API.FOOT.text + 11]];
  for (const [name, bottom] of rows) {
    chk(name + " 的底边 " + bottom + " ≤ FOOT.total", bottom <= API.FOOT.total, "");
  }
  chk("四行互不重叠（按顺序递增）",
      API.FOOT.label < API.FOOT.legend && API.FOOT.legend < API.FOOT.bar &&
      API.FOOT.bar < API.FOOT.text, "");
}

console.log("\n⑩ 底部条带【实测坐标】必须落在画布内（原 bug 就是画到画布外）");
{
  const H = 400;                                  /* fakeEl.clientHeight */
  const footTop = H - API.PAD.b;                  /* 底部条带 = 画布最下面 PAD.b 像素 */
  let bad = [], foot = [], texts = [];
  for (const z of [1, 4, 20]) {
    API.setZoom(z); API.setScroll(0.3); API.setPlayFrac(0.5);
    draws.length = 0;
    API.draw();
    texts = texts.concat(draws.filter(d => d.k === "text").map(d => d.t));
    foot = draws.filter(d => d.y >= footTop);
    bad = bad.concat(foot.filter(d => d.y + (d.k === "rect" ? d.h : 11) > H)
                          .map(d => (d.t || "rect") + "@y=" + d.y));
  }
  chk("底部条带画了 " + foot.length + " 个图元（0 个 = 判据空转）", foot.length >= 3);
  chk("底部条带没有图元落到画布外", bad.length === 0, bad.slice(0, 3).join(" , "));
  chk("底部画出了时间刻度标签（形如 1s / 0.5s）",
      texts.some(t => /^\d+(\.\d+)?s$/.test(t)),
      texts.filter(t => /^\d+(\.\d+)?s$/.test(t)).slice(0, 4).join(","));
  chk("底部画出了游标时间读数（含“游标”）",
      texts.some(t => t.indexOf("游标") >= 0),
      texts.filter(t => t.indexOf("游标") >= 0)[0] || "");
  API.setPlayFrac(null); API.setZoom(1); API.setScroll(0);
}

console.log("\n⑪ 播放游标必须随缩放走到【真正的相对位置】（2026-10-15 用户反馈）");
{
  API.setZoom(1); API.setScroll(0);
  const v1 = API.viewWindow();
  const FR = 0.6;
  const xOld = API.PAD.l + FR * PW;          // 🔴 旧写法：整首铺满、完全不看视口
  const x1 = API.playheadX(FR, TOTAL, v1, PW);
  chk("zoom=1 时与旧写法相同（⛔ 不改变原有观感）",
      Math.abs(x1 - xOld) < 1e-6, "x=" + x1.toFixed(1));
  /* 放大 4 倍 + 平移到中间：游标必须落在 tickToX(0.6*全长) 上 */
  API.setZoom(4); API.setScroll(0.5);
  const v4 = API.viewWindow();
  const x4 = API.playheadX(FR, TOTAL, v4, PW);
  const want = API.tickToX(FR * TOTAL, v4, PW);
  chk("zoom=4 时游标 = 该 tick 的视口位置", Math.abs(x4 - want) < 1e-6,
      "游标=" + x4.toFixed(1) + " 应为=" + want.toFixed(1));
  chk("zoom=4 时旧写法会偏（证明这条判据非空洞）",
      Math.abs(xOld - x4) > PW * 0.1,
      "偏差=" + Math.abs(xOld - x4).toFixed(0) + "px");
  /* 视口外的游标 => x 落在图区左界之外（draw 据此跳过）*/
  chk("视口外的游标 x 落在图区左界之外（draw 会跳过）",
      API.playheadX(0, TOTAL, v4, PW) < API.PAD.l,
      "x=" + API.playheadX(0, TOTAL, v4, PW).toFixed(1));
  API.setZoom(1); API.setScroll(0);
}

console.log();
console.log("结论：" + (bad === 0 ? "全部通过" : "有 " + bad + " 项不符"));
process.exit(bad === 0 ? 0 : 1);
