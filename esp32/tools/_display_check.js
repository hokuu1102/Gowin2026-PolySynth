// _display_check.js —— 离线自检：网页【显示层】的两个真实错误
//
// ═══ 为什么要有它 ═══
// 用户实测反馈两件"看不懂"的东西，查证都是真 bug：
//   ① 图例把【鼓】显示成 `BASS`（轴15）
//   ② 屏幕上出现 `C10` —— 一个【不存在的音】（MIDI > 127）
//
// ⭐ 这两个都是"算错但没报错"的类型（显示层没人验），所以固化判据。
//
// 用法：node _display_check.js

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
  blk + "\n; return { midiName, incToHz, F_CLK, midiToPhaseInc, DRUM_INC, DRUM_AXIS, " +
  "parseMidi, midiToWords, hzToMidi, setScore: (x) => { score = x; }, axisLabel };");
let API;
try {
  API = fn(doc, { addEventListener() {} }, { bluetooth: null }, { now: () => 0 },
    console, setTimeout, () => {}, () => 0, () => 0,
    { protocol: "http:", host: "x", search: "" },
    { getItem: () => null, setItem() {} },
    class { constructor() {} get() { return null; } });
} catch (e) {
  console.error("RED: 求值失败：" + e.message);
  process.exit(1);
}

let bad = 0;
function chk(name, cond, extra) {
  console.log("  " + name.padEnd(58) + (cond ? "OK" : "RED") + (extra ? "   " + extra : ""));
  if (!cond) bad++;
}

console.log("=".repeat(78));
console.log("网页显示层自检（用户报告的 C10 与 鼓显示成 BASS）");
console.log("=".repeat(78));

// ---- ① 采样时钟 ----
// FPGA 合成时钟 = 48 828.125 Hz（50 MHz / 1024）。用错会算出高约 1000 倍的频率。
chk("⭐ F_CLK = 48828.125（⛔ 不是 50 000 000）",
    Math.abs(API.F_CLK - 48828.125) < 1e-6, "F_CLK = " + API.F_CLK);

// ⭐ 用权威值验：A4 的 phase_inc = 38702840 应反算成 440 Hz
chk("A4 的 inc(38702840) 反算 = 440 Hz",
    Math.abs(API.incToHz(38702840) - 440) < 0.5,
    API.incToHz(38702840).toFixed(3) + " Hz");

// ⭐ 乐音 A4 的曲谱 inc 用本页公式算出来应≈37796
chk("A4 的曲谱 inc ≈ 37796", Math.abs(API.midiToPhaseInc(69) - 37796) < 2,
    String(API.midiToPhaseInc(69)));

// ---- ② C10 的根因：鼓的截断值 + 错时钟 => 越界音高 ----
// 鼓 inc 是 32 位，塞进 21 位会被截断；截断值很小，
// 用【正确】时钟算是低音（正常），用【错】时钟算就飞到 midi>127。
const kickTrunc = API.DRUM_INC.kick & 0x1FFFFF;
const hzOK = API.incToHz(kickTrunc);
const midiOK = API.hzToMidi(hzOK);
chk("用正确时钟算 kick 的截断值 => midi 在 0..127 内（正常低音）",
    midiOK >= 0 && midiOK <= 127, "midi = " + midiOK.toFixed(1));
// 用错时钟（50MHz）会怎样 —— 手工复算一遍，证明这就是 C10 的来源
const hzBad = kickTrunc * 50000000 / 4294967296;
const midiBad = 69 + 12 * Math.log2(hzBad / 440);
chk("非空洞：用 50 MHz 算同一个值 => midi > 127（⭐ 这就是 C10）",
    midiBad > 127, "midi = " + midiBad.toFixed(1));

// ---- ③ 越界音高必须标出来 ----
chk("midiName(132) 会标出越界（⛔ 不是静静显示 C10）",
    /越界/.test(API.midiName(132)), API.midiName(132));
chk("非空洞：正常音高【不】标越界",
    !/越界/.test(API.midiName(60)), API.midiName(60));

// ---- ④ 鼓轴显示"鼓"，⛔ 不是 BASS ----
// 造一个含鼓的 score 场景
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
const trDrum = track([[0, nm("Drum")], [0, [0x99, 36, 120]], [240, [0x89, 36, 0]]]);
const trBass = track([[0, nm("Bass")], [0, [0x90, 48, 100]], [960, [0x80, 48, 0]]]);
const mid = new Uint8Array([...str("MThd"), ...u32(6), ...u16(1), ...u16(2), ...u16(480),
                            ...trDrum, ...trBass]);
const parsed = API.parseMidi(mid.buffer);
const conv = API.midiToWords(parsed);
// 模拟 buildScore 后的 score（axisLabel 需要 score.notes 与 score.conv）
API.setScore({
  notes: conv.words.map(w => ({
    axis: Number((w >> 19n) & 0xFn),
    timbre: Number((w >> 7n) & 0x3n),
  })),
  conv: conv,
});
const label15 = API.axisLabel(15);
chk("⭐ 轴 15 显示'鼓'（⛔ 不是 BASS）", /鼓/.test(label15), label15);
chk("非空洞：轴的标签里【不】出现 'BASS · 轴15'",
    !/BASS\s*·\s*轴15/.test(label15), label15);
// 鼓的件数应出现在标签里（用户能看出打了哪些鼓）
chk("轴 15 的标签带件数（kick/snare/...）", /kick|snare|hihat|tom/.test(label15), label15);

console.log();
console.log("结论：" + (bad === 0 ? "全部通过" : "有 " + bad + " 项不符"));
process.exit(bad === 0 ? 0 : 1);
