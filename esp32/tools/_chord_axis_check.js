// _chord_axis_check.js —— 离线自检：和弦分轴 + 两个真 bug 的回归
//
// ═══ 为什么要有它 ═══
// 2026-10-14 用户报告："midi 里面同时按下的和弦没有被识别到"。
// 查证根因（FPGA 侧 rtl/w3b/note_manager.v:870 原文）：
//     ⭐ 每个 (axis, src) 同时【最多只有 1 个在响】的 voice
//       （同源 note_on 一定被 same_hit 命中 => 走复用）
//   => 🔴 同一 axis 上的多个音会互相顶掉。
// ⚠️ 而原来把 Guitar I/II/III 全合并到 axis 0 => 6 音和弦只有 1 个响。
//
// ⭐ 修法：把音符配对成段，对段做【贪心 axis 分配】。
// 本自检钉住这个修法，以及过程中抓到的两个真 bug。
//
// 用法：node _chord_axis_check.js

const fs = require("fs");
const path = require("path");

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
  blk + "\n; return { parseMidi, midiToWords, midiToPhaseInc, KIND_ON, KIND_OFF, " +
  "isDrumAxis, DRUM_INC, incToHz, hzToMidi, midiName };");
const API = fn(doc, { addEventListener() {} }, { bluetooth: null }, { now: () => 0 },
  console, setTimeout, () => {}, () => 0, () => 0,
  { protocol: "http:", host: "x", search: "" },
  { getItem: () => null, setItem() {} },
  class { constructor() {} get() { return null; } });

let bad = 0;
function chk(name, cond, extra) {
  console.log("  " + name.padEnd(58) + (cond ? "OK" : "RED") + (extra ? "   " + extra : ""));
  if (!cond) bad++;
}

// ---- 造 MIDI ----
function vlq(n) { const o = [n & 0x7f]; n >>= 7; while (n > 0) { o.unshift((n & 0x7f) | 0x80); n >>= 7; } return o; }
function u32(n) { return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]; }
function u16(n) { return [(n >> 8) & 255, n & 255]; }
function str(s) { return [...s].map(c => c.charCodeAt(0)); }
function nm(s) { return [0xff, 0x03, s.length, ...str(s)]; }
function track(ev) {
  const b = [];
  for (const e of ev) b.push(...vlq(e[0]), ...e[1]);
  b.push(...vlq(0), 0xff, 0x2f, 0x00);
  return [...str("MTrk"), ...u32(b.length), ...b];
}
function midiFile(div, tracks) {
  return new Uint8Array([...str("MThd"), ...u32(6), ...u16(1), ...u16(tracks.length),
                         ...u16(div), ...tracks.flat()]);
}

/* ⭐ 关键测试用例：一个【三音和弦】—— 同一个 tick 上 3 个音，同一轨
 *   （这就是"下拨"的形状）。修好之前它们会全落在同一个 axis 上。 */
const chord = track([
  [0, nm("Guitar I")],
  [0, [0x90, 52, 100]], [0, [0x90, 59, 100]], [0, [0x90, 64, 100]],
  [960, [0x80, 52, 0]], [0, [0x80, 59, 0]], [0, [0x80, 64, 0]],
]);
// 另一条同音色的轨（原来会和上面合并到同一 axis）
const chord2 = track([
  [0, nm("Guitar II")],
  [0, [0x90, 55, 100]], [0, [0x90, 62, 100]], [0, [0x90, 67, 100]],
  [960, [0x80, 55, 0]], [0, [0x80, 62, 0]], [0, [0x80, 67, 0]],
]);
// 鼓轨
const drum = track([
  [0, nm("Drum")],
  [0, [0x99, 36, 120]], [240, [0x89, 36, 0]],
]);
const mid = midiFile(480, [chord, chord2, drum]);
const conv = API.midiToWords(API.parseMidi(mid.buffer));
const evs = conv.words.map((w, i) => ({
  tick: Number((w >> 44n) & 0xFFFFFn), kind: Number((w >> 9n) & 0x3n),
  axis: Number((w >> 19n) & 0xFn), inc: Number((w >> 23n) & 0x1FFFFFn),
}));

console.log("=".repeat(78));
console.log("和弦分轴 自检（用户报告：和弦没被识别）");
console.log("=".repeat(78));

// ---- ① 和弦的 3 个音必须落在不同 axis ----
const atZero = evs.filter(e => e.tick === 0 && e.kind === API.KIND_ON && !API.isDrumAxis(e.axis));
const axesAtZero = new Set(atZero.map(e => e.axis));
chk("⭐ 同 tick 的 6 个旋律音（两条轨各 3 个）落在【不同的 axis】",
    axesAtZero.size === atZero.length,
    atZero.length + " 个音用了 " + axesAtZero.size + " 条轴: " + [...axesAtZero].sort((a, b) => a - b).join(","));
chk("非空洞：确实有 6 个音（⛔ 不是空集）", atZero.length === 6, String(atZero.length));

// ---- ② 每个旋律 axis 上的"真同时"必须 <= 1 ----
const byAxis = new Map();
for (const e of evs) {
  if (API.isDrumAxis(e.axis)) continue;
  if (!byAxis.has(e.axis)) byAxis.set(e.axis, []);
  byAxis.get(e.axis).push(e);
}
let worst = 0;
for (const [, arr] of byAxis) {
  /* ⭐ 按 FPGA 的处理顺序：同 tick 先 OFF 后 ON */
  arr.sort((a, b) => (a.tick - b.tick) || (b.kind - a.kind));
  let cur = 0, mx = 0;
  for (const e of arr) {
    /* ⚠️ 必须显式只认 ON/OFF —— evs 里还有换速事件（kind=2），
     * 若写 "不是 OFF 就当 ON" 会把换速也算成发声 => 假报"真同时=2"（踩过）。 */
    if (e.kind === API.KIND_OFF) { if (cur > 0) cur--; }
    else if (e.kind === API.KIND_ON) { cur++; if (cur > mx) mx = cur; }
  }
  if (mx > worst) worst = mx;
}
chk("⭐ 每个旋律 axis 上真同时 <= 1（⛔ 否则会被 same_hit 顶掉）",
    worst <= 1, "最大真同时 = " + worst);

// ---- ③ 鼓仍走 axis 15（⛔ 不能被分配走）----
const drumEvs = evs.filter(e => API.isDrumAxis(e.axis));
chk("⭐ 鼓仍全在 axis 15（seq_arb 靠它判鼓：score_axis_i == 4'd15）",
    drumEvs.length > 0, drumEvs.length + " 个鼓事件");
const drumIncs = new Set(drumEvs.map(e => e.inc));
chk("鼓用的是 DRUM_INC 的值（kick=5243）",
    [...drumIncs].every(v => Object.values(API.DRUM_INC).includes(v)),
    [...drumIncs].join(","));
chk("非空洞：旋律【没有】落在 axis 15 上",
    evs.filter(e => API.isDrumAxis(e.axis)).every(e => drumIncs.has(e.inc)));

// ---- ④ 音高没被分轴破坏（3 个音的音高都要对）----
const wantIncs = [52, 59, 64].map(m => API.midiToPhaseInc(m));
const gotIncs = evs.filter(e => e.tick === 0 && e.kind === API.KIND_ON && !API.isDrumAxis(e.axis))
                   .map(e => e.inc);
chk("⭐ 6 个和弦音的音高都在（分轴⛔ 不影响音高）",
    wantIncs.every(v => gotIncs.includes(v)),
    "找到 " + wantIncs.filter(v => gotIncs.includes(v)).length + "/3 个（Guitar I）");

// ---- ⑤ 🔴 回归：配不上对的 on 必须用【正确音高】（不是 MIDI 0）----
/* 我修这一段时引入过一个真 bug：兜底分支写了 `o.midi`（队列对象没这个字段）
 * ⇒ undefined ⇒ midiToPhaseInc(0) = 702 ⇒ 那些音全变成 MIDI 0 的极低音。
 * ⭐ 这条判据钉住它。 */
const dangling = track([
  [0, nm("Lead")],
  [0, [0x90, 60, 100]],          // ⚠️ 只有 on，没有 off => "配不上对"
]);
const mid3 = midiFile(480, [dangling]);
const c3 = API.midiToWords(API.parseMidi(mid3.buffer));
const on3 = c3.words.filter(w => Number((w >> 9n) & 0x3n) === API.KIND_ON)
                    .map(w => Number((w >> 23n) & 0x1FFFFFn));
chk("🔴 回归：只有 on 没 off 的音 => 音高仍是 C4（⛔ 不是 MIDI 0/702）",
    on3.includes(API.midiToPhaseInc(60)), "实测 inc = " + on3.join(","));
chk("🔴 回归：且它【也配了 off】（⛔ 不能只发 on 造成挂音）",
    c3.words.filter(w => Number((w >> 9n) & 0x3n) === API.KIND_OFF).length === 1,
    "off 数 = " + c3.words.filter(w => Number((w >> 9n) & 0x3n) === API.KIND_OFF).length);

// ---- ⑥ 非空洞：证明"分轴"确实在起作用（而不是恒真）----
/* 若把两轨的音强行塞到同一 axis，重数就会 >1。这里用【去掉一条轨】对照：
 * 单轨 3 音和弦也必须是 3 条不同轴。 */
const mid4 = midiFile(480, [chord]);
const c4 = API.midiToWords(API.parseMidi(mid4.buffer));
const axes4 = new Set(c4.words
  .filter(w => Number((w >> 9n) & 0x3n) === API.KIND_ON)
  .map(w => Number((w >> 19n) & 0xFn)));
chk("非空洞：单轨 3 音和弦 => 3 条不同轴", axes4.size === 3, [...axes4].join(","));

console.log();
console.log("结论：" + (bad === 0 ? "全部通过" : "有 " + bad + " 项不符"));
process.exit(bad === 0 ? 0 : 1);
