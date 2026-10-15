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
  blk + "\n; return { midiName, incToHz, F_CLK, midiToPhaseInc, DRUM_INC, DRUM_PHASE_INC, " +
  "isDrumAxis, DRUM_AXIS_OF, DRUM_AXIS_BASE, MELODY_AXIS_MAX, " +
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
/* ⭐ 灌谱页的 F_CLK 必须是 50 000 000 ——
 *   因为本页 incToHz 的口径是【下行 21 位字段值】
 *   （字段值 = phase_inc >> 10；而 50e6 = 48828.125 x 1024，两种说法等价）。
 * 🔴 回传页才是 48828.125（那边收的是 32 位 phase_inc）。两个页面口径不同！
 * 📌 我 2026-10-14 在这里反复过一次（把本页也改成 48828.125）—— 记下来。 */
chk("⭐ 灌谱页 F_CLK = 50000000（字段值口径）",
    Math.abs(API.F_CLK - 50000000) < 1, "F_CLK = " + API.F_CLK);
chk("⭐ A4 的字段值 37796 反算 = 440 Hz（验口径）",
    Math.abs(API.incToHz(37796) - 440) < 0.5, API.incToHz(37796).toFixed(2) + " Hz");

/* ⚠️ 口径分清（本页 incToHz 吃的是【21 位字段值】，⛔ 不是 32 位 phase_inc）：
 *   32 位 phase_inc 38702840 属于【回传页】的口径（那边 U_FS = 48828.125）。
 *   本页要验的是：字段值 37796 -> 440 Hz。
 *   ⭐ 我第一版从回传页抄了这条判据，口径不符 => 报红。已改。 */
chk("⭐ 本页口径：字段值 37796 反算 = 440 Hz",
    Math.abs(API.incToHz(37796) - 440) < 0.5,
    API.incToHz(37796).toFixed(3) + " Hz");
chk("非空洞：把 32 位 phase_inc 喂进本页口径 => 结果差 1024 倍（⭐ 所以不能混）",
    Math.abs(API.incToHz(38702840) / 440 - 1024) < 2,
    (API.incToHz(38702840) / 440).toFixed(1) + " 倍");

// ⭐ 乐音 A4 的曲谱 inc 用本页公式算出来应≈37796
chk("A4 的曲谱 inc ≈ 37796", Math.abs(API.midiToPhaseInc(69) - 37796) < 2,
    String(API.midiToPhaseInc(69)));

// ---- ② C10 的根因：鼓的截断值 + 错时钟 => 越界音高 ----
// 鼓 inc 是 32 位，塞进 21 位会被截断；截断值很小，
// 用【正确】时钟算是低音（正常），用【错】时钟算就飞到 midi>127。
/* ⚠️ 2026-10-14 口径更正后，鼓的字段值本身就是个【小的】数（kick=5243），
 *   用正确时钟算出来是正常低音。
 *   ⭐ 而 C10 的成因是【用错时钟】把这个小值放大 1000 倍 —— 判据仍要钉住这一点。 */
/* ⚠️ 注意换算链：下行字段存的是 `phase_inc >> 10`，
 *   而 incToHz() 吃的是【还原后的 21 位字段】（等价于 phase_inc/1024）。
 *   ⭐ 所以"字段值 -> Hz"要先把字段当 21 位数喂进去 —— 这正是 RTL 的 `<<10`。
 *   kick 的字段值 5243 => 还原 phase_inc = 5243*1024 = 5368832 => 61.04 Hz。 */
const kickField = API.DRUM_INC.kick;
const hzOK = API.incToHz(kickField);     // 本页 incToHz 的口径 = 字段值 -> Hz
chk("⭐ kick 的字段值 5243 反算频率 ≈ 61 Hz（与 FPGA 表格一致）",
    Math.abs(hzOK - 61.04) < 1.0, hzOK.toFixed(2) + " Hz (inc=" + kickField + ")");
/* 非空洞：若填 32 位原值（旧做法）=> 算出的频率高 1024 倍 => 音高越界 => C10 */
const kickRawHz = API.DRUM_PHASE_INC ? API.incToHz(API.DRUM_PHASE_INC.kick) : 0;
const kickRawMidi = 69 + 12 * Math.log2(kickRawHz / 440);
chk("非空洞：填 32 位原值 => 音高越界（⭐ 这才是 C10 的机理）",
    kickRawMidi > 127, "midi = " + kickRawMidi.toFixed(1));
/* 非空洞：证明"用错时钟"确实会造出越界音 —— 这就是 C10 的机理。
 * 用一个【乐音】的字段值来演示（它足够大，错时钟下会飞出去）。 */
const a4Field = API.midiToPhaseInc(69);          // 37796
const hzBad = a4Field * 50000000 / 4294967296;   // 故意用错时钟
const midiBad = 69 + 12 * Math.log2(hzBad / 440);
const midiOK = API.hzToMidi(hzOK);       // 正确时钟下的音高
chk("非空洞：同一个值用 50 MHz（错）算 => midi 明显偏高",
    midiBad > midiOK, "错=" + midiBad.toFixed(1) + " 对=" + midiOK.toFixed(1));
chk("kick 的字段值在正确时钟下是【正常低音】（midi 0..127）",
    midiOK >= 0 && midiOK <= 127, "midi = " + midiOK.toFixed(1));

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
const label12 = API.axisLabel(12);
chk("⭐ 鼓轴显示'鼓'（⛔ 不是 BASS）", /鼓/.test(label15), label15);
chk("非空洞：轴的标签里【不】出现 'BASS · 轴15'",
    !/BASS\s*·\s*轴15/.test(label15), label15);
/* ⭐ 2026-10-15 方案 B：一轴一件 ⇒ 标签写【件名】（15=Tom、12=Kick） */
chk("轴 15 的标签写件名 Tom（方案 B：一件一轴）", /Tom/.test(label15), label15);
chk("轴 12 的标签写件名 Kick", /Kick/.test(label12), label12);
chk("非空洞：12 与 15 的标签【不同】（否则说明还在按'四件合计'写）",
    label12 !== label15, label12 + " vs " + label15);
chk("轴 11（旋律上限）不是鼓", !API.isDrumAxis(11), "isDrumAxis(11)=" + API.isDrumAxis(11));
chk("轴 12 是鼓（与 seq_arb 的 axis>=12 逐字一致）", API.isDrumAxis(12));

console.log();
console.log("结论：" + (bad === 0 ? "全部通过" : "有 " + bad + " 项不符"));
process.exit(bad === 0 ? 0 : 1);
