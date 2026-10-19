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
                        "isDrumAxis, DRUM_AXIS_OF, DRUM_AXIS_BASE, MELODY_AXIS_MAX, DRUM_INC, " +
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
/* 期望（2026-10-15 方案 B）：
 *   ⭐ 鼓【一件一轴】12/13/14/15（FPGA `seq_arb.v:204`：`axis >= 12` ⇒ 鼓）
 *   ⭐ 旋律轨从 axis 0 起，只用 0..11
 * ⚠️ `assign` 里鼓那一条的 `axis` 现在是"用到的轴列表"字符串（如 "12/13"），
 *    ⛔ 不再是一条轴 —— 所以下面按类型分开判。 */
const byAxis = {};
for (const a of conv.assign) if (typeof a.axis === "number") byAxis[a.axis] = a;
const drumAssign = conv.assign.filter(a => a.kind === "鼓");
chk("轴分配：鼓轨用到的轴全部落在 12..15",
    drumAssign.length > 0 && drumAssign.every(a =>
      String(a.axis).split("/").every(x => API.isDrumAxis(Number(x)))),
    JSON.stringify(drumAssign.map(a => a.axis)));
/* ⭐⭐ 非空洞（2026-10-15 补，改了两次才对）：
 *   🔴 第一版只验"鼓轴落在 12..15" —— 把四件全改成 15 也照样绿。
 *   🔴 第二版拿 `DRUM_AXIS_OF` 当期望值 —— ⛔ 被测对象一改、期望跟着改，判据照样绿（空转）。
 *   ⭐ 正解：钉【协议字面值】（FPGA 侧答复 §1.1 / `seq_arb.v:204`），
 *      ⛔ 不引用被测代码里的任何常量 —— 这才是"真契约 vs 派生常量"（同族 C88）。 */
const DRUM_AXIS_PROTO = { kick: 12, snare: 13, hihat: 14, tom: 15 };
{
  chk("协议值：四件的轴 = 12/13/14/15（⛔ 不引用被测常量）",
      DRUM_AXIS_PROTO.kick === 12 && DRUM_AXIS_PROTO.snare === 13 &&
      DRUM_AXIS_PROTO.hihat === 14 && DRUM_AXIS_PROTO.tom === 15);
  chk("且被测代码的 DRUM_AXIS_OF 与协议值逐字相同",
      JSON.stringify(API.DRUM_AXIS_OF) === JSON.stringify(DRUM_AXIS_PROTO),
      JSON.stringify(API.DRUM_AXIS_OF) + " vs " + JSON.stringify(DRUM_AXIS_PROTO));
  /* 逐事件：轴必须等于【协议表】里该件的轴 */
  const nameOfInc = {};
  for (const [k, v] of Object.entries(API.DRUM_INC)) nameOfInc[v] = k;
  const badAx = [];
  conv.words.forEach(w => {
    const k = Number((w >> 9n) & 0x3n);
    if (k !== API.KIND_ON && k !== API.KIND_OFF) return;
    const ax = Number((w >> 19n) & 0xFn);
    if (!API.isDrumAxis(ax)) return;
    const inc = Number((w >> 23n) & 0x1FFFFFn);
    const want = DRUM_AXIS_PROTO[nameOfInc[inc]];
    if (want !== ax) badAx.push((nameOfInc[inc] || inc) + "→轴" + ax + "(应 " + want + ")");
  });
  chk("非空洞：每条鼓事件的轴 = 协议表里该件的轴",
      badAx.length === 0, badAx.join(",") || "全部对");
}
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
/* ⭐ 方案 B：鼓不在一根轴上 ⇒ 收集时要覆盖 12..15 四条（本夹具是 kick+snare ⇒ 12/13） */
const ticksOfDrum = (words, kind) => {
  const out = [];
  for (const ax of [12, 13, 14, 15]) out.push(...ticksOf(words, ax, kind));
  return out.sort((a, b) => a - b);
};
chk("缩放：鼓 on 的 tick = 0,480（240×2，⭐ 轴 12/13）",
    ticksOfDrum(conv.words, API.KIND_ON).join(",") === "0,480",
    ticksOfDrum(conv.words, API.KIND_ON).join(","));
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
/* ⚠️ 2026-10-14 起 axis 是【动态分配】的（为了避开 FPGA 的 same_hit 顶音），
 * 所以⛔ 不能按"axis == N"找音 —— ⭐ 改成按 inc 找。 */
const allInc2 = c2.words.map(w => Number((w >> 23n) & 0x1FFFFFn));
const onInc2 = c2.words.filter(w => Number((w >> 9n) & 0x3n) === API.KIND_ON)
                       .map(w => Number((w >> 23n) & 0x1FFFFFn));
chk("非空洞：把 C4 改成 D4 => 输出里出现 D4 的 inc",
    onInc2.includes(expectInc(62)), "期望 " + expectInc(62));
chk("非空洞：且【不再】出现 C4 的 inc（⭐ 证明改的确实是那个音）",
    !onInc2.includes(expectInc(60)), "C4 inc = " + expectInc(60));

// D. 只有鼓的 MIDI => 只占 12..15，⛔ 不占旋律段 0..11
const drumOnly = midiFile(DIV, [trDrum]);
const dOnly = API.midiToWords(API.parseMidi(drumOnly.buffer));
/* ⚠️ 只统计【音符类】事件 —— tempo 元事件的 axis 字段是 0（不是音符），
 *   ⛔ 不排除它就会看到"鼓占了轴 0"的假象（本判据第一版就踩了）。 */
const dAxes = new Set(dOnly.words
  .map(w => ({ ax: Number((w >> 19n) & 0xFn), k: Number((w >> 9n) & 0x3n) }))
  .filter(e => e.k === API.KIND_ON || e.k === API.KIND_OFF)
  .map(e => e.ax));
chk("非空洞：只有鼓 => 只占 12..15（⛔ 不占旋律 0..11）",
    dAxes.size > 0 && [...dAxes].every(a => API.isDrumAxis(a)), [...dAxes].join(","));


/* ---- ⑤⭐ 多 tempo 必须全部发出（2026-10-14 补，双向验证抓到的漏洞）----
 * 🔴 上一版没有这条 ⇒ 把"每个 tempo 都发"改回"只发第一个"后本自检仍全绿
 *    ⇒ 那一组修复等于没判据保护。⚠️ 用户真实文件有 7 个 tempo，
 *    只发一个 ⇒ 中段变速丢失，而现有判据看不出来。
 * ⚠️ 非空洞性：_bidir_check.py 已验（改回旧写法 ⇒ 本项必须红）。 */
console.log();
console.log("---- 多 tempo 全部发出（kind=2 事件数 == tempo 点数）----");
function tempoMidi(us) {
  /* us = [微秒/四分音符, ...] —— 每个都会变成一个 tempo 事件
   * ⭐ 每组单独写清 [delta, 0xFF, 0x51, 0x03, b0, b1, b2]，⛔ 不摊平
   *   （我第一版摊平了 => 字节流错位 => 一个 tempo 都读不到，实测 allTempos=0）。 */
  const groups = [];
  us.forEach((u, i) => {
    groups.push([i === 0 ? 0 : 480, 0xFF, 0x51, 0x03,
                 (u >> 16) & 255, (u >> 8) & 255, u & 255]);
  });
  /* 配一个音，确保这条轨不会被当成空轨丢掉 */
  groups.push([0, 0x90, 60, 100]);
  groups.push([960, 0x80, 60, 0]);
  const body = [];
  for (const g of groups) body.push(...vlq(g[0]), ...g.slice(1));
  body.push(...vlq(0), 0xFF, 0x2F, 0x00);
  return new Uint8Array([...str("MThd"), ...u32(6), ...u16(1), ...u16(1), ...u16(480),
                         ...str("MTrk"), ...u32(body.length), ...body]);
}

{
  const T = [500000, 600000, 400000];     /* 120 / 100 / 150 BPM */
  const cT = API.midiToWords(API.parseMidi(tempoMidi(T).buffer));
  const tempoEvs = [];
  cT.words.forEach(w => {
    if (Number((w >> 9n) & 0x3n) === API.KIND_TEMPO) {
      tempoEvs.push({ tick: Number((w >> 44n) & 0xFFFFFn),
                      inc: Number((w >> 23n) & 0x1FFFFFn) });
    }
  });
  chk("⭐ 3 个 tempo => 发出 3 个 kind=2 事件（⛔ 不是 1 个）",
      tempoEvs.length === 3, "实测 " + tempoEvs.length + " 个");
  chk("⭐ 且它们的 tick 分别是 0 / 960 / 1920（480 PPQN -> 960 已缩放）",
      tempoEvs.map(e => e.tick).join(",") === "0,960,1920",
      tempoEvs.map(e => e.tick).join(","));
  const want = T.map(us => {
    const bpm = 60000000 / us;
    return Math.round((bpm / 60) * 960 * 4294967296 / 50000000);
  });
  chk("⭐ 且 inc 与三个 tempo 的 tick_inc 一一对应",
      want.every((v, i) => Math.abs(tempoEvs[i].inc - v) <= 1),
      "实测 " + tempoEvs.map(e => e.inc).join(",") + " 期望 " + want.join(","));

  /* 非空洞：恒定 BPM（只 1 个 tempo）也要只发 1 个，⛔ 不能变成多发 */
  const cT1 = API.midiToWords(API.parseMidi(tempoMidi([500000]).buffer));
  const n1 = cT1.words.filter(w => Number((w >> 9n) & 0x3n) === API.KIND_TEMPO).length;
  chk("非空洞：只 1 个 tempo => 只发 1 个（⛔ 不能无脑多发）", n1 === 1, "实测 " + n1);
}

/* ---- ⑦⭐⭐ 方案 B（2026-10-15）：齐奏去重 + 抢轴上报 ----
 *
 * 背景：方案 B 让鼓占掉 axis 12..15 ⇒ 旋律只剩 12 条轴（原 15 条）。
 *   实测三份真实谱面峰值并发 13/13/10 ⇒ 12 条轴会有 3/20 次抢轴。
 *   去重（同音高+同时值+同音色只发一次）后峰值 13→11 ⇒ 12 条够。
 * ⚠️ 去重的 key **必须含音色**：跨音色齐奏是两件乐器，⛔ 去掉就丢一件。
 *   ⇒ 下面用【两组】测试把这个区分钉死（这是本组判据的非空洞性所在）。
 */
function onCount(words, midi) {
  const want = API.midiToPhaseInc(midi);
  let n = 0;
  for (const w of words) {
    const kind = Number((w >> 9n) & 0x3n);
    const inc = Number((w >> 23n) & 0x1FFFFFn);
    if (kind === API.KIND_ON && inc === want) n++;
  }
  return n;
}
{
  /* (a) 同音色齐奏（两把 Guitar 同 tick 同音高同时值）⇒ 必须去重成 1 个音 */
  const sameTb = midiFile(DIV, [
    track([[0, nameMeta("Guitar 1")], [0, [0x90, 60, 100]], [480, [0x80, 60, 0]]]),
    track([[0, nameMeta("Guitar 2")], [0, [0x90, 60, 100]], [480, [0x80, 60, 0]]]),
  ]);
  const cS = API.midiToWords(API.parseMidi(sameTb.buffer));
  chk("去重：同音色齐奏 ⇒ 只剩 1 个 on（⭐ 方案 B 靠它省轴）",
      onCount(cS.words, 60) === 1, "on=" + onCount(cS.words, 60));
  chk("去重：账要报出来（dupRemoved = 1）", cS.dupRemoved === 1,
      "dupRemoved=" + cS.dupRemoved);

  /* (b) 跨音色齐奏（Guitar + Piano 同 tick 同音高同时值）⇒ ⛔ 必须保留两个 */
  const diffTb = midiFile(DIV, [
    track([[0, nameMeta("Guitar")], [0, [0x90, 60, 100]], [480, [0x80, 60, 0]]]),
    track([[0, nameMeta("Piano")], [0, [0x90, 60, 100]], [480, [0x80, 60, 0]]]),
  ]);
  const cD = API.midiToWords(API.parseMidi(diffTb.buffer));
  chk("⭐ 去重【必须含音色】：跨音色齐奏保留 2 个 on（⛔ 不能丢一件乐器）",
      onCount(cD.words, 60) === 2, "on=" + onCount(cD.words, 60));
  chk("非空洞：跨音色时 dupRemoved = 0（⭐ 证明 key 里确实带了音色）",
      cD.dupRemoved === 0, "dupRemoved=" + cD.dupRemoved);

  /* (c) 轴够用时必须【不抢轴】（本自检的小谱面） */
  chk("抢轴上报：小谱面 axisClash = 0（⭐ 够用就要说够用）",
      conv.axisClash === 0, "axisClash=" + conv.axisClash);
  chk("方案 B 口径：melodyAxisMax = 11 · drumAxisBase = 12",
      conv.melodyAxisMax === 11 && conv.drumAxisBase === 12,
      "melodyMax=" + conv.melodyAxisMax + " drumBase=" + conv.drumAxisBase);

  /* (d) 非空洞性：13 个音同时响 ⇒ 12 条轴不够 ⇒ 必须报出抢轴
   *   ⚠️ 长度必须给足：off 的 delta 若也是 0 ⇒ 音符长度 0 ⇒ 根本不重叠（我第一版就踩了）。 */
  const evs13 = [[0, nameMeta("Piano")]];
  for (let m = 60; m < 73; m++) evs13.push([0, [0x90, m, 100]]);
  evs13.push([480, [0x80, 60, 0]]);                  /* ⭐ 第一个 off 推后 480 */
  for (let m = 61; m < 73; m++) evs13.push([0, [0x80, m, 0]]);
  const wide = API.midiToWords(API.parseMidi(midiFile(DIV, [track(evs13)]).buffer));
  chk("⭐ 非空洞：13 个同时音 > 12 条轴 ⇒ axisClash > 0（抢轴确实会被报出来）",
      wide.axisClash > 0, "axisClash=" + wide.axisClash);
  /* 边界不写松：正好 12 个同时音 ⇒ 必须 0 抢轴 */
  const e12 = [[0, nameMeta("Piano")]];
  for (let m = 60; m < 72; m++) e12.push([0, [0x90, m, 100]]);
  e12.push([480, [0x80, 60, 0]]);
  for (let m = 61; m < 72; m++) e12.push([0, [0x80, m, 0]]);
  const just12 = API.midiToWords(API.parseMidi(midiFile(DIV, [track(e12)]).buffer));
  chk("非空洞：正好 12 个同时音 ⇒ axisClash = 0（⭐ 边界不写松）",
      just12.axisClash === 0, "axisClash=" + just12.axisClash);
}

console.log();
console.log("结论：" + (bad === 0 ? "全部通过" : "有 " + bad + " 项不符"));
process.exit(bad === 0 ? 0 : 1);
