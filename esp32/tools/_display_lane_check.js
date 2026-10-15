
const fs = require("fs"), path = require("path");

let bad = 0;
function chk(name, cond, extra) {
  console.log("  " + name.padEnd(52) + (cond ? "OK" : "RED") + (extra ? "   " + extra : ""));
  if (!cond) bad++;
}

const html = fs.readFileSync(path.join(__dirname, "score_studio.html"), "utf8");
const blk = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1])[0];
/* 剥注释与字符串再判 —— 否则注释里的字样会误报（第一版踩过）*/
const code = blk.replace(/\/\*[\s\S]*?\*\//g, " ")
                .replace(/\/\/[^\n]*/g, " ")
                .replace(/`(?:\\.|[^`\\])*`/g, " ")
                .replace(/"(?:\\.|[^"\\\n])*"/g, '""');

const midPath = process.argv[2];
console.log("=".repeat(78));
console.log("鼓栏 / 图例 显示自检：" + path.basename(midPath));
console.log("=".repeat(78));

console.log("\n[静态]");chk("drumLaneHeight 已定义（鼓栏高度唯一算法）", /function drumLaneHeight\(ph\)/.test(code));
chk("drawPiano 调用 drumLaneHeight", /drumLaneHeight\(ph\)/.test(code));
chk("drawDrumLane 也调用 drumLaneHeight", /const laneH = drumLaneHeight\(ph\)/.test(code));
chk("TIMBRE_NAMES_ARR 已定义", /const TIMBRE_NAMES_ARR\s*=/.test(code));
chk("没有对 TIMBRE_NAMES（对象）用 .map/.length",
    !/TIMBRE_NAMES\s*\.\s*(map|length|forEach)/.test(code));
/* ⚠️ 用 blk ⛔ 不用 code —— code 为了判据剥过字符串，
 *   `"#00d5c8"` 会被换成 `""` ⇒ 永远找不到（白红一场，踩过）。
 *   ⚠️ 但注释里的字样仍是干扰源 ⇒ 用【行首 + const】双重限定。 */
chk("DRUM_COLOR 是青色（⛔ 不是 #ffb020 黄）",
    /^const DRUM_COLOR\s*=\s*"#00d5c8";/m.test(blk));

console.log("\n[动态] 直接调 drawPiano / drawDrumLane");
/* ⭐ canvas 方法一次性建好 —— 用 Proxy 每次返回新函数会把实参吞掉（y=NaN，踩过）*/
const texts = [];
const realCtx = {
  canvas: { width: 800, height: 400 },
  measureText: () => ({ width: 24 }),
  fillText(t, x, y) { texts.push({ t: String(t), x: x, y: y }); },
  fillRect() {}, strokeRect() {}, beginPath() {}, moveTo() {}, lineTo() {},
  stroke() {}, fill() {}, save() {}, restore() {}, setLineDash() {},
  clearRect() {}, closePath() {}, roundRect() {}, rect() {},
};
/* 🔴 geom() 读的是 cv.clientWidth / clientHeight —— ⛔ 不是 width/height。
 *   我第一版只给了 width/height ⇒ 拿到 undefined ⇒ ph=NaN ⇒ 所有 y=NaN（白红一场）。*/
const fakeEl = () => ({
  style: {}, classList: { add() {}, remove() {} }, getContext: () => realCtx,
  querySelectorAll: () => [], querySelector: () => null, addEventListener() {},
  appendChild() {}, insertAdjacentHTML() {},
  getBoundingClientRect: () => ({ left: 0, top: 0, width: 800, height: 400 }),
  textContent: "", innerHTML: "", checked: false,
  width: 800, height: 400,
  clientWidth: 800, clientHeight: 400,
  parentElement: { getBoundingClientRect: () => ({ width: 800, height: 400 }) },
});
const doc = { getElementById: () => fakeEl(), querySelector: () => fakeEl(),
  querySelectorAll: () => [], addEventListener() {}, createElement: () => fakeEl(),
  body: fakeEl() };
const fn = new Function("document", "window", "navigator", "performance", "console",
  "setTimeout", "clearInterval", "setInterval", "requestAnimationFrame",
  "location", "localStorage", "URLSearchParams",
  blk + "; return { parseMidi, midiToWords, buildScore, drawPiano, drawDrumLane, " +
  "drumLaneHeight, geom, PAD, DRUM_LANE_NAME, KIND_ON, KIND_OFF, " +
  "setScore: (x) => { score = x; } };");
const API = fn(doc, { addEventListener() {} }, { bluetooth: null }, { now: () => 0 },
  console, setTimeout, () => {}, () => 0, () => 0,
  { protocol: "http:", host: "x", search: "" },
  { getItem: () => null, setItem() {} },
  class { constructor() {} get() { return null; } });

const buf = fs.readFileSync(midPath);
const conv = API.midiToWords(API.parseMidi(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length)));
const sc = API.buildScore(conv.words, "x");
API.setScore(sc);
console.log("  鼓段 " + (sc.drumSegs || []).length + " / 旋律段 " + (sc.noteSegs || []).length);

texts.length = 0;
const ph = API.geom().ph;
const mids = sc.noteSegs.map(s => s.midi);
const lo = Math.min.apply(null, mids) - 1, hi = Math.max.apply(null, mids) + 1;
const X = t => 100 + t / 1000;
const Y = m => API.PAD.t + ph - ((m - lo) / (hi - lo)) * ph;
API.drawPiano(lo, hi, Y, ph);
const nPiano = texts.length;
API.drawDrumLane(X, 600);
console.log("  drawPiano fillText=%d，drawDrumLane fillText=%d", nPiano, texts.length - nPiano);

const laneNames = Object.keys(API.DRUM_LANE_NAME).map(k => API.DRUM_LANE_NAME[k]);
const lanes = texts.filter(c => laneNames.indexOf(c.t) >= 0);
chk("鼓栏画出 4 个件名", lanes.length >= 4,
    lanes.map(c => c.t + "@y" + c.y.toFixed(0)).join(" "));

const pitches = texts.filter(c => /^[A-G][#b]?-?\d+$/.test(c.t));
chk("图例 / 标题里不写轴号",
    texts.filter(c => /轴\s*\d/.test(c.t)).length === 0,
    texts.filter(c => /轴\s*\d/.test(c.t)).map(c => c.t).join(" "));

const minLaneY = Math.min.apply(null, lanes.map(c => c.y));
const maxPitchY = pitches.length ? Math.max.apply(null, pitches.map(c => c.y)) : -1e9;
chk("音名都不落在鼓栏那一带", maxPitchY < minLaneY,
    "音名最大 y=" + maxPitchY.toFixed(0) + "（鼓栏件名最小 y=" +
    minLaneY.toFixed(0) + (pitches.length ? "" : "，本谱无音名被画") + "）");

/* ---- ⭐ 时值必须与转换器一致（2026-10-14 用户报"时值过长、重叠"）----
 * 🔴 曾经有个"最小可见长度"兜底：minLen = (endTick - tickMin)/400
 *   => 对长曲子 minLen 高达 1814 tick（1.9 秒）=> 每根音被拉到至少那么长
 *   => 显示层 p50 从 480 变成 1814，大量重叠。
 * ⭐ 修法：删掉那个兜底（绘制层已有 Math.max(1.6, x1-x0) 保证可见）。
 * ⚠️ 判据：显示层的中位时值必须等于转换器的中位时值。 */
{
  const convDurs = [];
  {
    const q = new Map();
    const evs = conv.words.map((w) => ({
      tick: Number((w >> 44n) & 0xFFFFFn), kind: Number((w >> 9n) & 0x3n),
      axis: Number((w >> 19n) & 0xFn), inc: Number((w >> 23n) & 0x1FFFFFn),
    }));
    for (const e of evs.slice().sort((a, b) => (a.tick - b.tick) || (b.kind - a.kind))) {
      const k = e.axis + "|" + e.inc;
      if (e.kind === API.KIND_ON) { if (!q.has(k)) q.set(k, []); q.get(k).push(e.tick); }
      else if (e.kind === API.KIND_OFF) {
        const a = q.get(k);
        if (a && a.length) convDurs.push(e.tick - a.shift());
      }
    }
  }
  const segDurs = (sc.noteSegs || []).concat(sc.drumSegs || [])
                    .filter(s => s.t1 != null).map(s => s.t1 - s.t0);
  const med = (a) => { const b = a.slice().sort((x, y) => x - y); return b[Math.floor(b.length / 2)]; };
  chk("⭐ 显示层的中位时值 == 转换器的中位时值（没有被兜底拉长）",
      segDurs.length > 0 && med(segDurs) === med(convDurs),
      "显示层 " + med(segDurs) + " vs 转换器 " + med(convDurs));
  chk("非空洞：转换器确实有样本", convDurs.length > 0, convDurs.length + " 个");
}

console.log();
console.log("结论：" + (bad === 0 ? "全部通过" : "有 " + bad + " 项不符"));
process.exit(bad === 0 ? 0 : 1);
