// _midi_parse_check.js —— 离线自检：网页的 MIDI 解析器对不对
//
// ═══ 为什么要有它 ═══
// 网页里新加了"直接上传 .mid"的功能。如果只靠"拖进去看着没报错"，
// ⚠️ 那是【探针假绿】—— 解析错了也可能不报错（画出来一堆乱七八糟的东西）。
// ⭐ 判据必须能【失败】：所以这里自己造 MIDI，答案是人算出来的。
//
// ═══ 做法 ═══
//   · 用代码【构造】一个 MIDI（每个字节、每个 delta 都是已知的）
//   · 调网页里的 parseMidi() / midiToWords()
//   · 逐项比对：音符数、tick、音高、力度、on/off、轴分配、音色
//   · 非空洞性：故意改坏一处，必须判出来
//
// 用法：node _midi_parse_check.js

const fs = require("fs");
const path = require("path");

// ---- 从 HTML 里抽出内联 <script> 并求值（拿到要测的函数）----
const html = fs.readFileSync(path.join(__dirname, "score_studio.html"), "utf8");
const blocks = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
if (!blocks.length) { console.error("RED: HTML 里没有 <script> 块"); process.exit(1); }

// ⚠️ 页面脚本里有 DOM 调用（$("...") 等）—— 用一个假的 document 兜住，
//    只取我们要测的纯函数。
//    ⚠️ 页面在【加载时就会画一次图】（拿 canvas 2d context）——
//       所以假 element 必须能返回一个"什么都能调"的 context，
//       否则会在求值阶段就崩（踩过）。
const fakeCtx = new Proxy({}, {
  get: (t, k) => {
    if (k === "canvas") return { width: 800, height: 600 };
    if (k === "measureText") return () => ({ width: 10 });
    return typeof k === "string" ? (() => {}) : undefined;
  },
  set: () => true,
});
const fakeEl = () => new Proxy({
  style: {}, classList: { add() {}, remove() {}, toggle() {} },
  appendChild() {}, insertAdjacentHTML() {}, addEventListener() {},
  removeEventListener() {}, getContext: () => fakeCtx,
  getBoundingClientRect: () => ({ left: 0, top: 0, width: 800, height: 600 }),
  querySelectorAll: () => [], focus() {}, click() {},
  textContent: "", innerHTML: "", value: "", checked: false,
  disabled: false, scrollTop: 0, scrollHeight: 0, width: 800, height: 600,
}, {
  get: (t, k) => (k in t ? t[k] : (typeof k === "string" ? (() => {}) : undefined)),
  set: (t, k, v) => { t[k] = v; return true; },
});
const sandbox = {
  document: {
    getElementById: () => fakeEl(), querySelector: () => fakeEl(),
    querySelectorAll: () => [], addEventListener: () => {},
    createElement: () => fakeEl(), body: fakeEl(),
  },
  window: { addEventListener: () => {} },
  navigator: { bluetooth: null },
  performance: { now: () => 0 },
  console: console, setTimeout: setTimeout,
  clearInterval: () => {}, setInterval: () => 0,
  requestAnimationFrame: () => 0,
  // ⚠️ 页面 boot 时会读 location / localStorage / URLSearchParams —— 假一个，
  //    否则求值阶段就崩（踩过：ReferenceError: location is not defined）
  location: { protocol: "http:", host: "localhost", search: "" },
  localStorage: { getItem: () => null, setItem: () => {}, removeItem: () => {} },
  URLSearchParams: class { constructor() {} get() { return null; } },
  addEventListener: () => {},
};
const fn = new Function("document", "window", "navigator", "performance", "console",
                        "setTimeout", "clearInterval", "setInterval", "requestAnimationFrame",
                        "location", "localStorage", "URLSearchParams",
                        blocks[0] + "\n; return { parseMidi, midiToWords, packWord, " +
                        "midiToPhaseInc, bpmToTickInc, isDrumTrack, timbreOfTrack, " +
                        "MIDI_PPQN, TIMBRE_NAMES, KIND_ON, KIND_OFF, KIND_TEMPO };");
let API;
try {
  API = fn(sandbox.document, sandbox.window, sandbox.navigator, sandbox.performance,
           sandbox.console, sandbox.setTimeout, sandbox.clearInterval,
           sandbox.setInterval, sandbox.requestAnimationFrame,
           sandbox.location, sandbox.localStorage, sandbox.URLSearchParams);
} catch (e) {
  console.error("RED: 求值页面脚本失败：" + e.message);
  process.exit(1);
}

let bad = 0;
function chk(name, cond, extra) {
  console.log("  " + name.padEnd(54) + (cond ? "OK" : "RED") + (extra ? "   " + extra : ""));
  if (!cond) bad++;
}

// ===========================================================================
// 构造一个【答案已知】的 MIDI
// ===========================================================================
function vlq(n) {                       // 变长量编码
  const out = [n & 0x7f]; n >>= 7;
  while (n > 0) { out.unshift((n & 0x7f) | 0x80); n >>= 7; }
  return out;
}
function u32(n) { return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]; }
function u16(n) { return [(n >> 8) & 255, n & 255]; }
function str(s) { return [...s].map(c => c.charCodeAt(0)); }
function track(events) {
  const body = [];
  for (const e of events) body.push(...vlq(e[0]), ...e[1]);
  body.push(...vlq(0), 0xff, 0x2f, 0x00);          // end of track
  return [...str("MTrk"), ...u32(body.length), ...body];
}
function midiFile(division, tracks) {
  return new Uint8Array([
    ...str("MThd"), ...u32(6), ...u16(1), ...u16(tracks.length), ...u16(division),
    ...tracks.flat(),
  ]);
}

const DIV = 480;                        // ⚠️ 故意不用 960，验证缩放
/* ⚠️ 轨名 meta 的长度字节必须【等于字符数】——
 *    我第一版写死成 5 而 "Bass" 只有 4 个字符 => 多声明 1 字节 =>
 *    解析器多吃一个字节 => 越位 => 那条轨被丢弃。
 *    🔴 这正是"判据要能失败"的价值：它抓到的是【我测试数据】的错，不是解析器的。
 *    ⭐ 所以这里用 nameMeta() 由字符串长度自动算，⛔ 不再手写数字。 */
function nameMeta(s) { return [0xff, 0x03, s.length, ...str(s)]; }
// 轨 0：BASS —— 两个音 C3(48) D3(50)，各 480 tick
const trBass = track([
  [0,  nameMeta("Bass")],
  [0,  [0x90, 48, 100]], [480, [0x80, 48, 0]],
  [0,  [0x90, 50, 90]],  [480, [0x80, 50, 0]],
]);
// 轨 1：DRUM —— 通道 10（0-based 9），音 36/38
const trDrum = track([
  [0,  nameMeta("Drum")],
  [0,  [0x99, 36, 120]], [240, [0x89, 36, 0]],
  [0,  [0x99, 38, 110]], [240, [0x89, 38, 0]],
]);
// 轨 2：PIANO —— 音 60
const trPiano = track([
  [0,  nameMeta("Piano")],
  [0,  [0xff, 0x51, 3, 0x07, 0xA1, 0x20]],        // tempo 500000 us/qn = 120 BPM
  [0,  [0x90, 60, 80]],  [960, [0x80, 60, 0]],
]);
const mid = midiFile(DIV, [trBass, trDrum, trPiano]);

console.log("=".repeat(72));
console.log("MIDI 解析自检（答案由人工按 MIDI 规范算出）");
console.log("=".repeat(72));

// ---- ① 解析层 ----
const parsed = API.parseMidi(mid.buffer.slice(mid.byteOffset, mid.byteOffset + mid.length));
chk("解析：division = 480", parsed.division === 480, "实测 " + parsed.division);
chk("解析：3 条有音符的轨", parsed.tracks.length === 3, "实测 " + parsed.tracks.length);
chk("解析：轨名分别 Bass/Drum/Piano",
    parsed.tracks.map(t => t.name).join(",") === "Bass,Drum,Piano",
    parsed.tracks.map(t => t.name).join(","));
chk("解析：Bass 轨 4 个事件（2 on + 2 off）", parsed.tracks[0].notes.length === 4);
chk("解析：Drum 轨用了通道 9",
    parsed.tracks[1].chan.has(9), "chan=" + [...parsed.tracks[1].chan]);
chk("解析：tempo 被读到（500000us ⇒ 120BPM）",
    parsed.tracks[2].tempos.length === 1 && parsed.tracks[2].tempos[0].usPerQuarter === 500000);
chk("解析：Bass 音符 tick 序列 = 0,480,480,960",
    parsed.tracks[0].notes.map(n => n.tick).join(",") === "0,480,480,960",
    parsed.tracks[0].notes.map(n => n.tick).join(","));
chk("解析：Bass 第 1 个是 on、vel=100",
    parsed.tracks[0].notes[0].on === true && parsed.tracks[0].notes[0].vel === 100);

// ---- ② 分类层 ----
chk("分类：Drum 轨被判为鼓", API.isDrumTrack(parsed.tracks[1]) === true);
chk("分类：Bass 轨【不】被判为鼓", API.isDrumTrack(parsed.tracks[0]) === false);
chk("音色：Bass 轨 -> BASS(0)", API.timbreOfTrack(parsed.tracks[0]) === 0);
chk("音色：Piano 轨 -> PIANO(2)", API.timbreOfTrack(parsed.tracks[2]) === 2);
chk("非空洞：一条无名轨 => 默认 GUITAR(1)（⭐ 证明上面不是恒真）",
    API.timbreOfTrack({ name: "", chan: new Set([0]) }) === 1);

// ---- ③ 音高换算（与 mid2evt.py 对齐）----
// 公式：inc = round(440*2^((m-69)/12) * 2^32 / 50e6)
function expectInc(m) {
  return Math.max(0, Math.min(0x1fffff,
    Math.round(440 * Math.pow(2, (m - 69) / 12) * 4294967296 / 50000000)));
}
chk("音高：A4(69) 的 inc = round(440*2^32/50e6) = 37796",
    API.midiToPhaseInc(69) === expectInc(69),
    "实测 " + API.midiToPhaseInc(69) + " 期望 " + expectInc(69));
chk("音高：C4(60) 与手算一致", API.midiToPhaseInc(60) === expectInc(60),
    "实测 " + API.midiToPhaseInc(60));
chk("非空洞：A5 的 inc 恰是 A4 的 2 倍（±1 取整）",
    Math.abs(API.midiToPhaseInc(81) - 2 * API.midiToPhaseInc(69)) <= 1,
    API.midiToPhaseInc(81) + " vs " + (2 * API.midiToPhaseInc(69)));
chk("换速：120BPM 的 tick_inc = 164927（与 tb_beat_gen 的常量一致）",
    API.bpmToTickInc(120) === 164927, "实测 " + API.bpmToTickInc(120));
chk("换速：60BPM 的 tick_inc = 82463",
    API.bpmToTickInc(60) === 82463, "实测 " + API.bpmToTickInc(60));

// ---- ④ 转换层：轴分配 ----
const conv = API.midiToWords(parsed);
chk("转换：产生了事件", conv.words.length > 0, conv.words.length + " 个");
/* 期望（2026-10-14 改）：
 *   ⭐ 鼓【全部】走 axis 15（FPGA 侧口径：鼓机四件共用 axis 15，靠 inc 区分）
 *   ⭐ 其余轨从 axis 0 起，按音色类型归组
 * ⚠️ 改这里的原因：原来鼓占 axis 0、其余从 1 起；现在鼓不占普通轴了。
 *    ⛔ 不是缺陷，是设计变更 —— 判据要跟着设计走。 */
const byAxis = {};
for (const a of conv.assign) byAxis[a.axis] = a;
chk("轴分配：鼓在 axis 15（⭐ 四件共用）",
    byAxis[15] && byAxis[15].kind === "鼓", JSON.stringify(byAxis[15]));
chk("轴分配：BASS 在 axis 0", byAxis[0] && byAxis[0].timbre === "BASS", JSON.stringify(byAxis[0]));
chk("轴分配：PIANO 在 axis 1", byAxis[1] && byAxis[1].timbre === "PIANO", JSON.stringify(byAxis[1]));

// 缩放：480 PPQN -> 960 PPQN，所以 tick 翻倍
// 期望：鼓的 on 在 tick 0 和 480(=240*2)；bass 在 0/960；piano 在 0/1920
function ticksOf(words, axis, kind) {
  const out = [];
  for (const w of words) {
    const d = {
      tick: Number((w >> 44n) & 0xFFFFFn), axis: Number((w >> 19n) & 0xFn),
      kind: Number((w >> 9n) & 0x3n),
    };
    if (d.axis === axis && d.kind === kind) out.push(d.tick);
  }
  return out;
}
chk("缩放：鼓 on 的 tick = 0,480（240×2，⭐ 轴 15）",
    ticksOf(conv.words, 15, API.KIND_ON).join(",") === "0,480",
    ticksOf(conv.words, 15, API.KIND_ON).join(","));
chk("缩放：BASS on 的 tick = 0,960（480×2，⭐ 轴 0）",
    ticksOf(conv.words, 0, API.KIND_ON).join(",") === "0,960",
    ticksOf(conv.words, 0, API.KIND_ON).join(","));
// ⚠️ Piano 轨【只有一个音】（tick 0 的 on + tick 960 的 off）
//    => 它的 on 只有一个，就是 tick 0。
//    🔴 我第一版判据写成 "0,1920" —— 那是把【off 的 tick】当成了第二个 on。
//    ⭐ 又一次印证：判据必须从【数据】里量，⛔ 不能凭印象写（同族 C112/C169）。
chk("缩放：PIANO 只有一个 on，tick = 0（off 在 1920，⭐ 轴 1）",
    ticksOf(conv.words, 1, API.KIND_ON).join(",") === "0",
    ticksOf(conv.words, 1, API.KIND_ON).join(","));
chk("非空洞：PIANO 的 off 在 1920（⭐ 证明上一条不是恒真——它确实有两个事件）",
    ticksOf(conv.words, 1, API.KIND_OFF).join(",") === "1920",
    ticksOf(conv.words, 1, API.KIND_OFF).join(","));
chk("转换：BPM = 120", Math.abs(conv.bpm - 120) < 0.01, conv.bpm);

// tempo 事件存在且 inc 是 tick_inc（不是 phase_inc）
let tempoOk = false;
for (const w of conv.words) {
  const kind = Number((w >> 9n) & 0x3n);
  if (kind === API.KIND_TEMPO) {
    const inc = Number((w >> 23n) & 0x1FFFFFn);
    tempoOk = (inc === 164927);
    break;
  }
}
chk("转换：tempo 事件的 inc = 164927（tick_inc 口径）", tempoOk);

// 音高：piano 的 C4(60) 应对应 expectInc(60)
let pianoInc = null;
for (const w of conv.words) {
  const axis = Number((w >> 19n) & 0xFn), kind = Number((w >> 9n) & 0x3n);
  if (axis === 1 && kind === API.KIND_ON) { pianoInc = Number((w >> 23n) & 0x1FFFFFn); break; }
}
chk("转换：PIANO 第一个音的 inc = C4 的 inc", pianoInc === expectInc(60),
    "实测 " + pianoInc + " 期望 " + expectInc(60));

// ---- ⑤ 非空洞性：坏输入必须被判出来 ----
// A. 不是 MIDI（缺 MThd）
let threw = false;
try { API.parseMidi(new Uint8Array([1,2,3,4,5,6,7,8,9,10,11,12,13,14]).buffer); }
catch (e) { threw = true; }
chk("非空洞：非 MIDI 文件 => 抛错", threw);

// B. 变长量坏（5 个字节都带续位）
const badVlq = new Uint8Array([
  ...str("MThd"), ...u32(6), ...u16(0), ...u16(1), ...u16(480),
  ...str("MTrk"), ...u32(9), 0x81, 0x81, 0x81, 0x81, 0x81, 0x00, 0x90, 0x3c, 0x40,
]);
threw = false;
try { API.parseMidi(badVlq.buffer); } catch (e) { threw = true; }
chk("非空洞：变长量超 4 字节 => 抛错", threw);

// C. 改一个音高字节 => 解出来的音高必须跟着变
const mid2 = new Uint8Array(mid);
for (let i = 0; i < mid2.length - 3; i++) {
  if (mid2[i] === 0x90 && mid2[i+1] === 60) { mid2[i+1] = 62; break; }
}
const p2 = API.parseMidi(mid2.buffer);
const c2 = API.midiToWords(p2);
let pianoInc2 = null;
for (const w of c2.words) {
  const axis = Number((w >> 19n) & 0xFn), kind = Number((w >> 9n) & 0x3n);
  if (axis === 1 && kind === API.KIND_ON) { pianoInc2 = Number((w >> 23n) & 0x1FFFFFn); break; }
}
chk("非空洞：把 C4 改成 D4 => inc 必须变成 D4 的",
    pianoInc2 === expectInc(62), "实测 " + pianoInc2 + " 期望 " + expectInc(62));

// D. 只有鼓的 MIDI => 只占 axis 0，不占别的
const drumOnly = midiFile(DIV, [trDrum]);
const dOnly = API.midiToWords(API.parseMidi(drumOnly.buffer));
chk("非空洞：只有鼓 => 只用 axis 15", dOnly.assign.length === 1 && dOnly.assign[0].axis === 15,
    JSON.stringify(dOnly.assign));

console.log();
console.log("结论：" + (bad === 0 ? "全部通过" : "有 " + bad + " 项不符"));
process.exit(bad === 0 ? 0 : 1);
