// verify_piece.js —— 用【上位机自己的解析器】核对测试曲，并顺手导出 events.hex
//
// 为什么必须用网页的解析器（而不是另写一个 Python 版）：
//   真正灌谱时跑的就是 score_studio.html 里那段 JS。
//   另写一份"我认为应该怎么转"的实现 = 探针假绿。
//   => 这里直接把 <script> 块抠出来在 node 里跑，与浏览器同源。
//
// 用法：
//   node verify_piece.js [文件.mid] [--hex 输出.hex]
//   缺省文件 = 同目录的「四音色鼓机变速-测试曲.mid」
//
// 2026-10-16【鼓与旋律彻底分离】第三轮（手册：files/20-代码/ESP32侧修改手册-鼓与旋律分离-最终版-20261016.md
//   §二 新位域 / §4.1-7 校验器 / §7.3 上板前机械检查；
//   另见 files/20-代码/FPGA线回函-第三轮-收回8件鼓-20261016.md 与
//        files/20-代码/ESP32侧回函-第三轮-axis确认与回退-20261016.md）：
//   FPGA 线【收回】了上一轮的"扩到 8 件"（他们只有 4 件鼓音色，那 4 个新 inc 是同一纯音引擎的
//   高频音高，不是新音色）=> 判据回到 4 件。
//   鼓件的识别口径：is_drum(bit5) + drum_type = timbre[8:7]（2 位，⛔ 不读 bit19）。
//   对照表：
//     0 Kick 35,36 · 1 Snare 38,40 · 2 HiHat 42,44 + 【镲族全部】 · 3 Tom 41,43,45,47,48,50
//     镲族 46/49/51/52/53/55/57/59 => HiHat(2)（显式列出，⛔ 不靠表外兜底）；表外 -> Tom
//   ⛔ 为什么必须按 drum_type 认件：鼓事件的 inc 恒为 0（FPGA 按 drum_type 从 drum_gen
//      的表里自己取；21 位装不下 INC_SNARE(26)/INC_HIHAT(28)，写 DRUM_INC 会发出电子音）
//      ⇒ 按 inc 反查件名会全部认不出。
//   轴号：鼓的 axis = 12 + drum_type（一件一轴，方案 B）：
//     kick 12 · snare 13 · hihat 14 · tom 15
//     四件互不相同 = 一件一轴（note_off 按 (axis, src) 配对，四件鼓的 src 全是 SRC_KDRUM）。
//     ⛔ 上一轮的 dt 键（((dt&3)<<1)|(dt>>2) = 0/2/4/6/1/3/5/7）整条作废；
//     ⛔ 上一轮的"axis & 1 == dt>>2"也作废（2 位没有高位可对）。
//     旋律仍用 0..11，与鼓的 12..15 分开（§7.3-1）。
//   鼓力度：Kick 230 · Snare 235 · HiHat 175 · Tom 220（上一轮给扩位新增的四件力度已删）；鼓的 OFF 写 0。
//   note_off5：合法 0..30（MIDI 45..75）；31 = 哨兵（键盘上没有这个键 ⇒ 不点灯）。
//     越界音高（<45 或 >75）必须写 31，⛔ 不许钳到 0（0 = A2 = 真实的键 5，会点亮错误的灯）。
//     口径边界：哨兵只作用于【旋律】事件；鼓的 note_off5 恒为 0（判据⑯，本轮不回退）。
//
// 判据（不符合会打 RED）：
//   ① 四个音色 BASS/GUITAR/PIANO/PAD 全部出现
//   ② 文件里的 tempo 点全部转成 kind=2 事件（且 >= 2 个才算测到变速）
//   ③ 鼓件按 drum_type 认件：基础四件齐全 + 出现的件各占一条互不相同的轴（一件一轴，轴落 12..15）
//   ③b 非空洞：每条鼓事件的轴 = 12 + 该 dt（axis-12 == drum_type，dt↔axis 一一对应）
//   ③c 页面自己的鼓件表（DRUM_TYPE_OF / DRUM_AXIS_OF）与手册【独立写死的表】一致（含 12+dt）
//   ③d 页面 GM 音高->鼓件表与定稿一致；镲族 8 个音高必须【显式列出】且指向 hihat
//   ④ 旋律峰值并发 <= 12（可用轴 0..11，口径不变）
//   ⑤ 旋律【不占】鼓轴段 12..15（回到四件时代的 12..15 原始口径）
//   ⑥ 同一 tick 的"先关后开"重击：off 必须排在 on 前（旋律按 inc 配对、鼓按 (axis,drum_type)）
//   ⑦ 鼓同 tick 敲多件【允许】—— 且至少要有 1 处探针
//   ⑧ 鼓没有走音高分区兜底（全部来自映射表）
//   ⑨ 没有跨音色同音高同时响（相位干涉）
//   ⑩ 同一件鼓的相邻落点间隔 >= 鼓长（跨件不限）
//   ⑪ 伴奏声部每小节 >= 2 个共同落点
//   ⑫ 鼓事件（is_drum=1）的 inc 必须全 0（硬检查②）
//   ⑬ 旋律事件（is_drum=0 且排除 kind=2 tempo）的 inc 必须全非 0
//   ⑭ is_drum=0 的事件里，轴号落 12..15 的必须 0 条（§7.3 第 1 条）
//   ⑮ 鼓的每个 kind=0 都有配对 kind=1，且 OFF 也带 is_drum=1 与同一 drum_type（漏了会挂音）
//   ⑯ is_drum=1 时 note_off5 必须为 0（鼓没有音高）
//   ⑰ 页面 unpackWord 的 bit5 / bits[4:0] / bits[8:7] 与独立位提取一致（⛔ 不拿被验者验自己）
//   ⑱（重写）鼓的轴 = 12 + drum_type（axis-12 == dt）；两条件号读取路径一致
//   ⑲ note_off5 口径：可弹(45..75) => MIDI-45；越界 => 31 哨兵；⛔ 不许钳到 0
//   ③e（新）鼓力度 = 件定值（230/235/175/220），鼓的 OFF 写 0

const fs = require("fs");
const path = require("path");

const HERE = __dirname;
const args = process.argv.slice(2);
let midPath = null, hexOut = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--hex") hexOut = args[++i];
  else midPath = args[i];
}
if (!midPath) midPath = path.join(HERE, "StJamesInfirmary-funk-测试曲.mid");
if (!fs.existsSync(midPath)) {
  console.error("找不到 MIDI：" + midPath);
  process.exit(2);
}

// ---- 把 score_studio.html 的脚本块抠出来，在假 DOM 里跑 ----
const TOOLS = path.join(HERE, "..", "..", "tools");
const html = fs.readFileSync(path.join(TOOLS, "score_studio.html"), "utf8");
const blk = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1])[0];
const fakeCtx = new Proxy({}, {
  get: (t, k) => k === "canvas" ? { width: 1, height: 1 }
    : (k === "measureText" ? () => ({ width: 1 }) : (() => {})), set: () => true });
const fakeEl = () => new Proxy({
  style: {}, classList: { add() {}, remove() {} }, getContext: () => fakeCtx,
  querySelectorAll: () => [], querySelector: () => null, addEventListener() {},
  appendChild() {}, insertAdjacentHTML() {},
  getBoundingClientRect: () => ({ left: 0, top: 0, width: 8, height: 6 }),
  textContent: "", innerHTML: "", checked: false,
}, { get: (t, k) => k in t ? t[k] : (typeof k === "string" ? (() => {}) : undefined),
     set: (t, k, v) => { t[k] = v; return true; } });
const doc = { getElementById: () => fakeEl(), querySelector: () => fakeEl(),
  querySelectorAll: () => [], addEventListener() {}, createElement: () => fakeEl(), body: fakeEl() };
/* ⭐ 2026-10-16：额外带出 unpackWord（解码口径 = 页面自己的解码器，与真正灌谱时同一套）
 *   与页面自己的鼓件表 DRUM_TYPE_OF —— 判据③c 要拿它与手册 §二/§4.3【独立写死的表】对照
 *   （⛔ 不是拿页面的表验页面的表）。
 * ⚠️ 用 typeof 保护：页面还没写出来时导出 null ⇒ 下面【明确报缺】，⛔ 不是静默假绿。 */
const fn = new Function("document", "window", "navigator", "performance", "console",
  "setTimeout", "clearInterval", "setInterval", "requestAnimationFrame",
  "location", "localStorage", "URLSearchParams",
  blk + "\n; return { parseMidi, midiToWords, buildScore, isDrumTrack, timbreOfTrack, " +
  "TIMBRE_NAMES, isDrumAxis, DRUM_AXIS_OF, " +
  /* ⚠️ DRUM_AXIS_BASE：页面在 2026-10-16 扩位时【删掉了】它（鼓不再占 12..15）。
   *   typeof 保护：页面没有它时导出 null，本判据的口径不受影响
   *   （§7.3-1 的期望值 12 由本文件独立写死 MELODY_BAN_AXIS_MIN）。 */
  "DRUM_AXIS_BASE: (typeof DRUM_AXIS_BASE === 'number') ? DRUM_AXIS_BASE : null, " +
  "KIND_ON, KIND_OFF, " +
  "KIND_TEMPO, DRUM_INC, " +
  "GM_DRUM_MAP: (typeof GM_DRUM_MAP === 'object') ? GM_DRUM_MAP : null, " +
  "unpackWord: (typeof unpackWord === 'function') ? unpackWord : null, " +
  "DRUM_TYPE_OF: (typeof DRUM_TYPE_OF === 'object') ? DRUM_TYPE_OF : null };");
const API = fn(doc, { addEventListener() {} }, { bluetooth: null }, { now: () => 0 },
  { log: () => {} }, setTimeout, () => {}, () => 0, () => 0,
  { protocol: "http:", host: "x", search: "" },
  { getItem: () => null, setItem() {} },
  class { constructor() {} get() { return null; } });
if (typeof API.unpackWord !== "function") {
  console.error("RED: 页面还没有 unpackWord() —— 手册 §二 的新位域（bit5 is_drum / bits[4:0] note_off5）" +
                "没有解码口径，鼓与旋律分离无法核对。");
  process.exit(2);
}

const buf = fs.readFileSync(midPath);
const parsed = API.parseMidi(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length));
const conv = API.midiToWords(parsed);
/* ⭐ 判据 ⑨ 要按"段"看跨音色重叠，所以也要 buildScore（配对 + 分栏那一步）。 */
const score = API.buildScore(conv.words, path.basename(midPath));

// ---- 解码事件字 ----
/* ⭐⭐ 2026-10-16（手册 §二）：鼓件的识别口径 = is_drum(bit5) + drum_type(timbre[8:7])，
 *   解码一律走页面自己的 unpackWord（与真正灌谱时同一套）。
 * ⚠️ 同时留一份【独立位提取】—— 判据⑰ 用它交叉验页面的解码器，
 *    ⛔ 不是"直接信页面 unpackWord"（拿被验者验自己 = 假绿，经验库 C83）。 */
const rawOf = w => ({
  tick: Number((w >> 44n) & 0xFFFFFn), inc: Number((w >> 23n) & 0x1FFFFFn),
  axis: Number((w >> 19n) & 0xFn), vel: Number((w >> 11n) & 0xFFn),
  kind: Number((w >> 9n) & 0x3n), timbre: Number((w >> 7n) & 0x3n),
  guide: Number((w >> 6n) & 0x1n),
  /* 2026-10-16 第三轮：bit19 【不再】是 drum_type 的 MSB —— 它只是 axis 字段的 bit0。
   * ⛔ 这里不再单独提取 bit19（上一轮的"共享位"读法已随"扩到 8 件"一起作废）。 */
  isDrum: Number((w >> 5n) & 0x1n),                    /* bit5：显式鼓标志 */
  note5: Number(w & 0x1Fn),                            /* bits[4:0]：音符号偏移 */
});
/* drum_type 两位读取的两条【独立】路径（判据⑱ 拿它们互证）：
 *   DT_OF  —— 走页面 unpackWord 自己给出的 drumType（被验者的解码结果）；
 *   DT_RAW —— 走本文件的独立位提取（原始位 bit 8..7）。
 * 两条给出不同的件号 => 页面解码器与本核对器对不上，必须查。 */
const DT_OF  = o => (o.timbre & 3);
const DT_RAW = o => (o.timbre & 3);
/* 上一轮（8 件）的三位读法 {bit19, timbre[8:7]}：只用来做判据⑱ 的【反控】——
 *   证明"少读/多读一位"这件事在本产物上是能被抓到的（轴 13/15 的事件 bit19=1）。 */
const DT_LEGACY3 = o => (((o.axis & 1) << 2) | (o.timbre & 3));
/* ⭐ 独立编码器（⛔ 不用页面的 packWord）：判据⑰ 用它往返验"独立提取没漏任何位域"。
 *   覆盖全部 64 位：tick20 + inc21 + axis4 + vel8 + kind2 + timbre2 + guide1 + isDrum1 + note5 5 = 64 */
const encWord = o =>
  ((BigInt(o.tick || 0) & 0xFFFFFn) << 44n) | ((BigInt(o.inc || 0) & 0x1FFFFFn) << 23n) |
  ((BigInt(o.axis || 0) & 0xFn) << 19n)     | ((BigInt(o.vel || 0) & 0xFFn) << 11n) |
  ((BigInt(o.kind || 0) & 0x3n) << 9n)      | ((BigInt(o.timbre || 0) & 0x3n) << 7n) |
  ((BigInt(o.guide || 0) & 0x1n) << 6n)     | ((BigInt(o.isDrum || 0) & 0x1n) << 5n) |
  (BigInt(o.note5 || 0) & 0x1Fn);
const evs = conv.words.map((w, i) => {
  const d = API.unpackWord(w);
  const rw = rawOf(w);
  return { i, w, tick: d.tick, kind: d.kind, axis: d.axis, vel: d.vel,
           timbre: d.timbre, inc: d.inc, guide: d.guide, isDrum: d.isDrum, note5: d.note5,
           raw: rw,
           /* 鼓件 = drum_type = timbre[8:7]（2 位，⛔ 不读 bit19）——
            * ⛔ 不再按 inc 认件（鼓的 inc 恒为 0），也不再按"3 位 {bit19,timbre}"认件。 */
           type: DT_OF(d), rawType: DT_RAW(rw) };
});

let red = 0, nChk = 0;
const chk = (name, cond, extra) => {
  console.log("  " + (cond ? "[OK] " : "[RED]") + name.padEnd(52) + (extra || ""));
  nChk++;
  if (!cond) red++;
};

console.log("=".repeat(78));
console.log("测试曲核对：" + path.basename(midPath));
console.log("=".repeat(78));
console.log("  PPQN = " + parsed.division + "   轨数(有音符) = " + parsed.tracks.length +
            "   tempo 点(全局) = " + parsed.allTempos.length);
console.log();
console.log("  轨  | 轨名        | 通道 | 音符 | 判为鼓 | 音色(按轨名猜)");
console.log("  ----|-------------|------|------|--------|---------------");
parsed.tracks.forEach((t, i) => {
  const drum = API.isDrumTrack(t);
  console.log("  " + String(i).padEnd(4) + "| " + String(t.name || "(无名)").padEnd(12) +
    "| " + ([...t.chan].map(c => c + 1).join(",") || "-").padEnd(5) +
    "| " + String(t.notes.length).padEnd(5) +
    "| " + (drum ? " 是 " : " 否 ").padEnd(7) +
    "| " + (drum ? "鼓" : API.TIMBRE_NAMES[API.timbreOfTrack(t)]));
});
console.log();
console.log("  转换后轴分配（axis 只是标签；和弦会被摊到多条轴）");
conv.assign.forEach(a => {
  console.log("    axis " + (String(a.axis) + " ").padEnd(10) + String(a.name).padEnd(10) +
              " " + String(a.kind).padEnd(8) + a.notes + " 个音符");
});

// ---- tempo ----
console.log();
console.log("  变速表（MIDI 里的 set_tempo -> kind=2 事件）");
const tEv = evs.filter(e => e.kind === API.KIND_TEMPO).sort((a, b) => a.tick - b.tick);
tEv.forEach(e => {
  const bpm = (e.inc * 50e6 / 4294967296.0) / parsed.division * 60;
  console.log("    tick " + String(e.tick).padEnd(8) + bpm.toFixed(2) + " BPM   (tick_inc " + e.inc + ")");
});

// ---- 分类型统计 ----
const kinds = { on: 0, off: 0, tempo: 0 };
for (const e of evs) {
  if (e.kind === API.KIND_ON) kinds.on++;
  else if (e.kind === API.KIND_OFF) kinds.off++;
  else if (e.kind === API.KIND_TEMPO) kinds.tempo++;
}
const tickMax = evs.reduce((m, e) => Math.max(m, e.tick), 0);

// 时长：按 tempo 分段积分（tick 是音乐时间，速度变了时长就变）
let secs = 0;
for (let i = 0; i < tEv.length; i++) {
  const t0 = tEv[i].tick;
  const t1 = (i + 1 < tEv.length) ? tEv[i + 1].tick : tickMax;
  const bpm = (tEv[i].inc * 50e6 / 4294967296.0) / parsed.division * 60;
  secs += Math.max(0, t1 - t0) / parsed.division * 60 / bpm;
}

// ---- 并发与轴 ----
/* ⭐⭐ 2026-10-16（手册 §二）：旋律 = is_drum=0 且【不是】kind=2 tempo
 *   ⛔ 不再用 isDrumAxis 当判据 —— 轴号只是标签，鼓的身份由 bit5 显式给出。
 *   （tempo 事件用 inc 装速度值，必须排除，否则会被当成"inc 非 0 的旋律"。） */
const mel = evs.filter(e => e.isDrum === 0 && e.kind !== API.KIND_TEMPO)
  .sort((a, b) => (a.tick - b.tick) || (b.kind - a.kind));
let cur = 0, peak = 0;
for (const e of mel) {
  if (e.kind === API.KIND_OFF) { if (cur > 0) cur--; }
  else if (e.kind === API.KIND_ON) { cur++; if (cur > peak) peak = cur; }
}
const axUsed = [...new Set(mel.map(e => e.axis))].sort((a, b) => a - b);

// ---- 鼓 ----
/* 2026-10-16 第三轮（FPGA 线收回 8 件）：鼓件【按 drum_type 认件】= timbre[8:7]（2 位），
 * 对照表 4 件（kick=0 · snare=1 · hihat=2 · tom=3；镲族全部归 hihat）。
 * 轴号：鼓的 axis = 12 + drum_type（一件一轴）= kick 12 · snare 13 · hihat 14 · tom 15。
 * ⛔ 上一轮的 dt 键（((dt&3)<<1)|(dt>>2) = 0/2/4/6/1/3/5/7）与"axis&1 == dt>>2"整条作废。
 * ⛔ 按 inc 认件的旧口径也早已删除（鼓的 inc 恒为 0）。 */
const DRUM_TYPE_NAME = { 0: "kick", 1: "snare", 2: "hihat", 3: "tom" };
const DRUM_TYPE_AXIS = { 0: 12, 1: 13, 2: 14, 3: 15 };   /* 独立写死的"12 + drum_type" */
const DRUM_AXIS_BASE = 12;                              /* 鼓轴段起点（独立写死） */
const DRUM_AXIS_MAX = 15;                               /* 鼓轴段终点（独立写死） */
const DRUM_VEL_WANT = { 0: 230, 1: 235, 2: 175, 3: 220 };   /* 鼓力度定值（独立写死） */
/* 镲族：必须【显式列出】指向 hihat（判据③d 的重点；⛔ 不靠表外兜底 -> tom） */
const CYMBAL_GMS = [46, 49, 51, 52, 53, 55, 57, 59];
const CYMBAL_TYPE_WANT = 2;
const BASE_TYPES = [0, 1, 2, 3];                        /* §7.3-3 要求四件都有 */
const BASE_NAMES = ["kick", "snare", "hihat", "tom"];
const TYPE_OF_NAME = { kick: 0, snare: 1, hihat: 2, tom: 3 };
const MELODY_BAN_AXIS_MIN = 12;                         /* §7.3-1：旋律不许占 12..15（独立写死） */
const nameOfType = t => DRUM_TYPE_NAME[t & 3] || ("未知drum_type" + (t & 3));
const drumTypeOf = nm => TYPE_OF_NAME[nm];
const AXIS_KEY_TXT = [0, 1, 2, 3].map(t => t + "->" + DRUM_TYPE_AXIS[t]).join(" ");
const dr = evs.filter(e => e.isDrum === 1);
const drumCount = {};
const drumTickOn = {};
for (const e of dr) {
  if (e.kind !== API.KIND_ON) continue;
  const nm = nameOfType(e.type);
  drumCount[nm] = (drumCount[nm] || 0) + 1;
  drumTickOn[e.tick] = (drumTickOn[e.tick] || 0) + 1;
}
const drumSimul = Object.entries(drumTickOn).filter(([, n]) => n >= 2)
  .map(([t, n]) => ({ tick: Number(t), n }));

// ---- 重击（同一 tick 的"先关后开"：off 必须排在 on 之前）----
// ⚠️ 判据不是"相邻"，而是"同一 tick 内，同一个【配对键】的 off 下标 < on 下标"：
//    同一个 tick 上还有别的音在起（和弦、鼓），它们会插在中间。
// ⚠️ 也不要求同 axis —— 上位机的分轴算法贪心取"最低的空闲轴"，
//    前后两个段可能分到不同的轴，那是正常行为。
// ⭐⭐ 2026-10-16（手册 §二）：配对键必须分两套 ——
//    旋律按 inc（音高）；鼓按 (axis, drum_type)（手册点名的 (axis,src) 配对）。
//    ⛔ 鼓不能按 inc：新位域下鼓的 inc 恒为 0 ⇒ 四件会挤进同一个键，
//       一个 tick 上"A 件关、B 件开"会被误判成重击（假红）。
const pairKeyOf = e => (e.isDrum === 1) ? ("d" + e.axis + ":" + e.type) : ("m" + e.inc);
const byTick = new Map();
evs.forEach((e, i) => {
  if (!byTick.has(e.tick)) byTick.set(e.tick, []);
  byTick.get(e.tick).push({ e, i });
});
const restrikeTicks = [];
let badOrder = 0, drumRestrike = 0;
for (const [tick, list] of byTick) {
  const offAt = new Map(), onAt = new Map();
  for (const { e, i } of list) {
    const k = pairKeyOf(e);
    if (e.kind === API.KIND_OFF && !offAt.has(k)) offAt.set(k, i);
    if (e.kind === API.KIND_ON && !onAt.has(k)) onAt.set(k, i);
  }
  for (const [k, oi] of offAt) {
    if (!onAt.has(k)) continue;            // 只有关或只有开，不是重击
    restrikeTicks.push(tick);
    if (k.charAt(0) === "d") drumRestrike++;
    if (onAt.get(k) < oi) badOrder++;      // 开在关前面 = 顺序错
  }
}

console.log();
console.log("  事件总数 = " + evs.length + "（on " + kinds.on + " · off " + kinds.off +
            " · tempo " + kinds.tempo + "）");
console.log("  tick 最大 = " + tickMax + "   时长 ≈ " + secs.toFixed(1) + " 秒（按变速分段算）");
console.log("  整包 = " + evs.length * 9 + " 字节（每事件 9 字节帧）+ 1 个总数帧");
console.log("  旋律峰值并发 = " + peak + "   用到的轴 = " + axUsed.join(","));
console.log("  鼓：共 " + dr.filter(e => e.kind === API.KIND_ON).length + " 下（件名按 drum_type 认）· " +
            Object.entries(drumCount).map(([k, v]) => k + " " + v).join(" · "));
console.log("  鼓同 tick 敲 >=2 件的地方 = " + drumSimul.length +
            (drumSimul.length ? "（tick " + drumSimul.map(d => d.tick + "×" + d.n).join(", ") + "）" : ""));
console.log();

// ---- 判据 ----
console.log("  判据：");
const tbs = new Set(parsed.tracks.filter(t => !API.isDrumTrack(t)).map(t => API.timbreOfTrack(t)));
const wantTb = [0, 1, 2, 3].every(v => tbs.has(v));
chk("① 四个音色全部出现（BASS/GUITAR/PIANO/PAD）", wantTb,
    "实际 = " + [...tbs].sort().map(v => API.TIMBRE_NAMES[v]).join("/"));
chk("② 文件里的 tempo 点全部转成 kind=2（且 >= 2 个才算测到变速）",
    kinds.tempo === parsed.allTempos.length && kinds.tempo >= 2,
    "kind=2 " + kinds.tempo + " 个 / 文件里 " + parsed.allTempos.length + " 个");
/* ③ 2026-10-16 第三轮：鼓件【按 drum_type 认件】= timbre[8:7]（2 位，4 件）——
 *   基础四件都出现，且出现的每一件各占一条互不相同的轴（一件一轴：鼓的 note_off 按
 *   (axis,src) 配对，四件的 src 全是 SRC_KDRUM ⇒ 同轴一件的 OFF 会清掉另一件的 voice）。
 *   本轮鼓轴回到 12..15（kick 12 · snare 13 · hihat 14 · tom 15）。
 *   ⛔ 不再用 `axis >= 12` 认鼓：鼓的身份由 bit5（is_drum）显式给出（轴号只是 voice 的定位键）。 */
const drumAxesUsed = [...new Set(dr.map(e => e.axis))].sort((a, b) => a - b);
const drumTypesUsed = [...new Set(dr.map(e => e.type))].sort((a, b) => a - b);
chk("③ 鼓件按 drum_type 认件（4 件表）：基础四件齐全 + 出现的件各占一条互不相同的轴",
    conv.drumTracks === 1 &&
    BASE_NAMES.every(k => drumCount[k] > 0) &&
    drumTypesUsed.length >= BASE_TYPES.length &&
    drumTypesUsed.length === drumAxesUsed.length &&
    drumAxesUsed.every(a => a >= DRUM_AXIS_BASE && a <= DRUM_AXIS_MAX),
    "drum_type " + drumTypesUsed.join(",") + " · 用到的鼓轴 " + drumAxesUsed.join(",") +
    "（合法段 " + DRUM_AXIS_BASE + ".." + DRUM_AXIS_MAX + "） · " + JSON.stringify(drumCount));
/* 非空洞：每条鼓事件的轴 = 12 + 该 dt（axis-12 == drum_type）
 *   （⛔ 只验"轴落在某一段里"的话，多件全塞同一条轴也能过）。 */
{
  const badAx = dr.filter(e => DRUM_TYPE_AXIS[e.type] !== e.axis);
  chk("③b 非空洞：每条鼓事件的轴 = 12 + 该 dt（axis-12 == drum_type，dt↔axis 一一对应）",
      badAx.length === 0,
      badAx.length ? (badAx.length + " 条对不上（例 drum_type " + badAx[0].type + "(" +
                      nameOfType(badAx[0].type) + ") 落在轴 " + badAx[0].axis + "，应为 " +
                      DRUM_TYPE_AXIS[badAx[0].type] + "）12+dt = " + AXIS_KEY_TXT)
                   : ("全部对 · 12+dt = " + AXIS_KEY_TXT));
}
/* ③c 页面自己的鼓件表必须与手册【独立写死的表】一致 ——
 *   ⛔ 不是"拿页面的表验页面的表"：上面两张表是照手册抄的，页面改了这里立刻红。
 *   本轮是 4 件，页面表也必须是 4 件（上一轮那 4 个假件必须消失）。 */
{
  const bad = [];
  const note = [];
  if (!API.DRUM_TYPE_OF) bad.push("页面没有 DRUM_TYPE_OF（鼓件口径表缺失）");
  else {
    for (const k of BASE_NAMES) {
      if (API.DRUM_TYPE_OF[k] !== drumTypeOf(k)) {
        bad.push("DRUM_TYPE_OF." + k + " = " + API.DRUM_TYPE_OF[k] + " != " + drumTypeOf(k));
      }
      if (API.DRUM_AXIS_OF && API.DRUM_AXIS_OF[k] !== DRUM_TYPE_AXIS[drumTypeOf(k)]) {
        bad.push("DRUM_AXIS_OF." + k + " = " + API.DRUM_AXIS_OF[k] +
                 " != " + DRUM_TYPE_AXIS[drumTypeOf(k)] + "（12+dt）");
      }
    }
    const nameByType = {};
    for (const [nm, dt] of Object.entries(API.DRUM_TYPE_OF)) nameByType[dt] = nm;
    for (const dt of drumTypesUsed) {
      const nm = nameByType[dt];
      if (nm === undefined) {
        bad.push("产物用到的 drum_type " + dt + "(" + nameOfType(dt) + ") 在页面表里没有对应项");
        continue;
      }
      if (API.DRUM_AXIS_OF && API.DRUM_AXIS_OF[nm] !== DRUM_TYPE_AXIS[dt]) {
        bad.push("页面 " + nm + " 的轴 = " + API.DRUM_AXIS_OF[nm] + " != 12+dt = " + DRUM_TYPE_AXIS[dt]);
      }
    }
    const n = Object.keys(API.DRUM_TYPE_OF).length;
    note.push("页面表 " + n + " 件");
    if (n !== BASE_TYPES.length) {
      bad.push("页面 DRUM_TYPE_OF 有 " + n + " 件，本轮应当正好 4 件（上一轮的 4 个假件必须删掉）");
    }
    const vals = Object.values(API.DRUM_TYPE_OF).slice().sort((a, b) => a - b);
    if (vals.some((v, i) => v !== i)) {
      bad.push("页面 DRUM_TYPE_OF 的值域不是 0..3：[" + vals.join(",") + "]");
    }
  }
  chk("③c 页面鼓件表（DRUM_TYPE_OF / DRUM_AXIS_OF）与手册独立表一致（4 件 · 轴 = 12+dt）",
      bad.length === 0,
      bad.length ? bad.join(" | ")
                 : ("kick 0/轴12 · snare 1/轴13 · hihat 2/轴14 · tom 3/轴15 · " + note.join("")));
}
/* ③d 页面 GM 音高 -> 鼓件名的表必须与第三轮的【定稿映射】一致。
 *   本轮重点：镲族 8 个音高（46/49/51/52/53/55/57/59）必须【显式列出】且指向 hihat
 *   （⛔ 不靠表外兜底 -> tom；兜底与"有意归类"必须能在报告里区分开）。
 *   ⚠️ 这份测试曲里【一个镲族音高都没有】⇒ 产物上验不到，只能直接核对这张表
 *      （否则"镲归谁"在本机永远没有判据）。 */
{
  const GM_WANT_NAME = { 35: "kick", 36: "kick", 38: "snare", 40: "snare",
                         42: "hihat", 44: "hihat",
                         41: "tom", 43: "tom", 45: "tom", 47: "tom", 48: "tom", 50: "tom",
                         /* 镲族：显式归 hihat（第三轮定稿） */
                         46: "hihat", 49: "hihat", 51: "hihat", 52: "hihat",
                         53: "hihat", 55: "hihat", 57: "hihat", 59: "hihat" };
  const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
  const bad = [];
  let ctlNote = "";
  if (!API.GM_DRUM_MAP) bad.push("页面没有 GM_DRUM_MAP（GM 音高 -> 鼓件名的表缺失）");
  else {
    for (const gm of Object.keys(GM_WANT_NAME).map(Number).sort((a, b) => a - b)) {
      if (API.GM_DRUM_MAP[gm] !== GM_WANT_NAME[gm]) {
        bad.push("GM" + gm + " = " + JSON.stringify(API.GM_DRUM_MAP[gm]) +
                 " != " + GM_WANT_NAME[gm]);
      }
    }
    /* ⛔ 必须【显式列出】，⛔ 不是"查不到就走兜底 -> tom"：
     *   表外兜底对镲族来说就是"镲变嗵鼓"，正是本轮要禁的。 */
    const notListed = CYMBAL_GMS.filter(g => !has(API.GM_DRUM_MAP, g));
    if (notListed.length) {
      bad.push("镲族 " + notListed.join("/") + " 在页面表里【没有显式列出】" +
               "（会走表外兜底 -> tom，等于镲变嗵鼓）");
    }
    const notHat = CYMBAL_GMS.filter(g => has(API.GM_DRUM_MAP, g) &&
                                          API.GM_DRUM_MAP[g] !== "hihat");
    if (notHat.length) {
      bad.push("镲族 " + notHat.join("/") + " 没有指向 hihat，实际 = " +
               notHat.map(g => "GM" + g + "->" + API.GM_DRUM_MAP[g]).join(" "));
    }
    if (API.GM_DRUM_MAP[46] !== undefined && API.GM_DRUM_MAP[46] === "tom") {
      bad.push("GM46 归了 tom —— 46 是开镲（Open Hi-Hat），本轮定稿归 hihat");
    }
    /* 反控（静态）：把镲族从表里拿掉、或把某一条指到 tom —— 检查器必须认出来，
     *   证明这条判据不是恒真的假绿（与 check_guide.js 判据⑲ 同一手法）。 */
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
    ctlNote = "反控：拿掉镲族 -> 认出 " + ctlDrop.length + " 个；GM51->tom -> 认出 [" + ctlTom.join(",") + "]";
  }
  chk("③d 页面 GM 音高->鼓件表与定稿一致（镲族 8 个显式->hihat；55 不再是 splash/crash）",
      bad.length === 0, bad.length ? bad.join(" | ")
        : ("19 个音高逐条一致；镲族 " + CYMBAL_GMS.join("/") + " 全部【显式列出】->hihat · " + ctlNote));
}
/* ③e 2026-10-16 第三轮新增：鼓力度 = 件定值（Kick 230 · Snare 235 · HiHat 175 · Tom 220），
 *   鼓的 OFF 写 0。上一轮给"扩到 8 件"新增的那四件力度必须随扩位一起删掉。
 *   ⚠️ 旋律力度不在这里判（它是 MIDI 真实力度，必须靠 events.csv 才能核）。 */
{
  const bad = [];
  const seen = {};
  let offBad = 0;
  for (const e of dr) {
    if (e.vel === undefined) continue;
    if (e.kind === API.KIND_OFF) { if (e.vel !== 0) offBad++; }
    else if (e.kind === API.KIND_ON) {
      (seen[e.type] = seen[e.type] || {})[e.vel] = (seen[e.type][e.vel] || 0) + 1;
      if (e.vel !== DRUM_VEL_WANT[e.type]) {
        bad.push(nameOfType(e.type) + " 的 ON 力度 = " + e.vel + " != " + DRUM_VEL_WANT[e.type]);
      }
    }
  }
  if (offBad) bad.push("鼓的 OFF 有 " + offBad + " 条力度非 0（口径：OFF 写 0）");
  for (const dt of BASE_TYPES) {
    if (!seen[dt]) bad.push(nameOfType(dt) + " 一条 ON 都没有（力度判据空洞）");
  }
  const uniq = bad.filter((v, i) => bad.indexOf(v) === i);
  chk("③e 鼓力度 = 件定值（230/235/175/220），鼓的 OFF 写 0",
      uniq.length === 0,
      uniq.length ? uniq.slice(0, 3).join(" | ")
        : ([0, 1, 2, 3].map(dt => nameOfType(dt) + "=" + Object.keys(seen[dt] || {}).join("/"))
                    .join(" · ") + " · OFF 力度非 0 的 0 条"));
}
chk("④ 旋律峰值并发 <= 12（方案 B：可用轴只剩 0..11）", peak <= 12, "峰值 " + peak);
/* ⑤ 口径：旋律 = is_drum=0 且非 tempo（见上面 mel 的定义）⇒ 它的轴号【一个都不许】落进
 *   鼓轴段 12..15（本轮鼓就占这一段）。这正是手册 §7.3 第 1 条的"还有没有依赖轴号的路径"
 *   的机械检查（⑭ 再做一次全事件版）。
 *   ⚠️ 期望值 12 在本文件【独立写死】（MELODY_BAN_AXIS_MIN），⛔ 不取页面的 isDrumAxis
 *      —— 那是"拿被验者的表当期望值"。页面值只作报告，便于发现口径分叉。 */
chk("⑤ 旋律（is_drum=0）【不占】鼓轴段 12..15（§7.3-1 原始口径）",
    !axUsed.some(a => a >= MELODY_BAN_AXIS_MIN),
    "旋律用到 " + axUsed.join(",") + "（鼓轴段起点 " + MELODY_BAN_AXIS_MIN + " 独立写死；" +
    "页面 DRUM_AXIS_BASE = " + (API.DRUM_AXIS_BASE === null ? "本页面没有这个常量（期望值由本文件写死）"
                                                            : API.DRUM_AXIS_BASE) + "）");
chk("⑥ 同一 tick 的重击：off 排在 on 前（旋律按 inc、鼓按 (axis,drum_type) 配对；反向 0 处）",
    restrikeTicks.length >= 1 && badOrder === 0,
    "重击 " + restrikeTicks.length + " 处（tick " + restrikeTicks.join(",") + "；其中鼓 " + drumRestrike +
    " 处）· 顺序错 " + badOrder + " 处");
/* ⑦ ⭐ 2026-10-15 方案 B：同 tick 敲多件【本来就该支持】——
 *   四件各占一条轴 ⇒ FPGA 侧 `same_hit`（axis+src 都相同才命中）不会把它们当同一次敲击
 *   ⇒ ⭐ 这条从"只许 1 处（故意的探针）"改成【允许任意多处】。
 *   ⚠️ 非空洞：必须【至少有一处】同 tick 多件，否则这条判据等于没测（探针没了也看不出来）。 */
chk("⑦ 鼓同 tick 多件【允许】（方案 B 的目的）—— 且至少要有 1 处探针",
    drumSimul.length >= 1,
    drumSimul.length ? (drumSimul.length + " 处，最多 " +
      Math.max(...drumSimul.map(s => s.n)) + " 件同时")
      : "🔴 一处都没有 ⇒ 测不到方案 B 要修的场景");
chk("⑧ 鼓没有走音高分区兜底（全部来自映射表）", conv.drumFuzzy === 0,
    "兜底 " + conv.drumFuzzy + " 个");

/* ⑨ ⭐ 跨音色【同音高同时响】—— 这是"两个音色没对上"的根因候选。
 * 为什么是缺陷：两个音色发同一个频率 => 两个 voice 的相位干涉
 *   （mid2evt.py 的文件头写过：可能变响、变薄、或起音处打拍子，听起来像被敲了两次）。
 * 用户实测反馈："第一次变速之后怪怪的，好像两个音色没对上"。
 * => 判据：同一 inc 的两个段若【音色不同】且时间重叠，就是一处。 */
const segByInc = new Map();
for (const s of score.noteSegs) {
  if (!segByInc.has(s.inc)) segByInc.set(s.inc, []);
  segByInc.get(s.inc).push(s);
}
let clash = 0;
const clashEx = [];
const clashAt = {};
for (const [, list] of segByInc) {
  for (let i = 0; i < list.length; i++) {
    for (let j = i + 1; j < list.length; j++) {
      const a = list[i], b = list[j];
      if (a.timbre === b.timbre) continue;
      if (Math.min(a.t1, b.t1) <= Math.max(a.t0, b.t0)) continue;   // 不重叠
      clash++;
      const bar = Math.floor(Math.min(a.t0, b.t0) / 3840) + 1;
      clashAt[bar] = (clashAt[bar] || 0) + 1;
      if (clashEx.length < 4) {
        clashEx.push(API.TIMBRE_NAMES[a.timbre] + "+" + API.TIMBRE_NAMES[b.timbre] +
                     " 音高" + (a.midi != null ? Math.round(a.midi) : "?") +
                     " tick " + Math.min(a.t0, b.t0) + "~" + Math.min(a.t1, b.t1));
      }
    }
  }
}
console.log();
console.log("  跨音色同音高同时响：" + clash + " 处" +
            (clash ? "（按小节：" + Object.entries(clashAt).map(([k, v]) => "第" + k + "小节 " + v).join(" · ") + "）" : ""));
if (clashEx.length) console.log("    例：" + clashEx.join(" | "));
chk("⑨ 没有跨音色同音高同时响（相位干涉 => 听起来像两个音色没对上）", clash === 0,
    clash ? (clash + " 处") : "");

/* ⑩ ⭐ 2026-10-15 方案 B：约束从「全体 >= 480」放宽成「【同一件】 >= 480」。
 *   ⭐ 为什么跨件可以解除：四件各占一条轴 ⇒ `same_hit` / `note_off` 的判据都是
 *      `(axis_r[i]==cur_axis) && (src_r[i]==cur_src)`（note_manager.v:720-722 / :1317-1320）
 *      ⇒ 不同件（不同轴）互不掐。
 *   ⚠️ 仍存在的限制：**同一件**相邻两次若 < 鼓长，后一下会被前一下的 off 噎掉
 *      （方案 B 只隔离了跨件，见 FPGA 侧答复 §6.1）。
 *   ⭐⭐ 2026-10-16（手册 §二）："同一件"必须按【drum_type】分组 ——
 *      新位域下鼓的 inc 恒为 0，按 inc 分组会把四件当成同一件（假红）。
 * ⚠️ 480 要与 gen_test_piece.py 的 DRUM_DUR 一致；改了那边这里也要改。 */
const DRUM_DUR = 480;
let tooClose = 0, minGap = Infinity;
const closeEx = [];
const drumTypesAll = [...new Set(dr.map(e => e.type))].sort((a, b) => a - b);
let drumHits = 0;
for (const ty of drumTypesAll) {
  /* ⚠️ 先【去重 tick】再量间隔：同一 tick 上敲多件由判据 ⑦ 单独管 */
  const on = [...new Set(dr.filter(e => e.type === ty && e.kind === API.KIND_ON)
                           .map(e => e.tick))].sort((a, b) => a - b);
  drumHits += on.length;
  for (let i = 1; i < on.length; i++) {
    const g = on[i] - on[i - 1];
    if (g < minGap) minGap = g;
    if (g < DRUM_DUR) {
      tooClose++;
      if (closeEx.length < 3) {
        closeEx.push(nameOfType(ty) + "（轴" + DRUM_TYPE_AXIS[ty] + "） " + on[i - 1] + "→" + on[i] +
                     "（间隔 " + g + "）");
      }
    }
  }
}
console.log();
console.log("  鼓落点：" + drumHits + " 下（分 " + drumTypesAll.length + " 件 / " +
            drumTypesAll.map(t => nameOfType(t)).join(",") + "）· 同一件最小间隔 " +
            (minGap === Infinity ? "-" : minGap) + " tick（要求 >= " + DRUM_DUR + "）");
if (closeEx.length) console.log("    太近的：" + closeEx.join(" | "));
chk("⑩ 同一件鼓的相邻落点间隔 >= 鼓长（⭐ 方案 B：跨件已解除此约束）",
    tooClose === 0, tooClose ? (tooClose + " 处太近") : "");

/* ⑪ ⭐ 节奏骨架：**伴奏声部**要锁在同一个网格上（旋律自由）。
 * 为什么：用户实测反馈"器乐之间各演各的，听感很混乱" ——
 *   每件乐器一套自己的节奏型，几条线互不相干。
 * ⚠️ 但【主旋律】本来就该跳出来 ⇒ 把平均音区最高的那一件当主旋律【豁免】，
 *    只要求其余伴奏声部（除 PAD 长音）：每小节 >= 2 个共同落点（= 锁在同一骨架上）。
 * 🔴 上一版这条判据要求"所有音色落点一致"，那等于【禁止写旋律】—— 判据本身错了。 */
const BAR_T = 3840;
const perBar = new Map();        // bar -> timbre -> Set(offset)
const pitchOf = new Map();       // timbre -> [inc...]（用来判谁是主旋律）
for (const e of evs) {
  if (e.kind !== API.KIND_ON || e.isDrum === 1) continue;   /* ⭐ 鼓按 is_drum 认，⛔ 不按轴号 */
  const tb = API.TIMBRE_NAMES[e.timbre] || ("T" + e.timbre);
  const b = Math.floor(e.tick / BAR_T);
  if (!perBar.has(b)) perBar.set(b, new Map());
  const m = perBar.get(b);
  if (!m.has(tb)) m.set(tb, new Set());
  m.get(tb).add(e.tick - b * BAR_T);
  if (!pitchOf.has(tb)) pitchOf.set(tb, []);
  pitchOf.get(tb).push(e.inc);
}
const avgInc = tb => pitchOf.get(tb).reduce((a, c) => a + c, 0) / pitchOf.get(tb).length;
const lead = [...pitchOf.keys()].filter(t => t !== "PAD")
                                .sort((a, b) => avgInc(b) - avgInc(a))[0];
let misaligned = 0;
const barLines = [];
for (const b of [...perBar.keys()].sort((x, y) => x - y)) {
  const m = perBar.get(b);
  const sets = [...m.entries()].map(([k, s]) => [k, [...s].sort((x, y) => x - y)]);
  const acc = sets.filter(([k]) => k !== lead && k !== "PAD");   // 伴奏（PAD 是长音，不算节奏）
  let common = null;
  if (acc.length >= 2) {
    common = acc[0][1].filter(o => acc.every(([, s]) => s.indexOf(o) >= 0));
    if (common.length < 2) misaligned++;
  }
  barLines.push("    第" + (b + 1) + "小节 " +
    sets.map(([k, s]) => k + (k === lead ? "(旋律)" : "") + "[" + s.join(",") + "]").join(" ") +
    (acc.length >= 2 ? ("  共同落点 " + common.length + " 个" + (common.length < 2 ? " ⚠️" : " ✅"))
                     : "  （伴奏单件）"));
}
console.log();
console.log("  节奏骨架（主旋律 = " + lead + "，豁免对齐；PAD 是长音铺底不算）");
barLines.forEach(l => console.log(l));
chk("⑪ 伴奏声部每小节 >= 2 个共同落点（最多允许 1 小节例外 = 复音阶梯那节）",
    misaligned <= 1, misaligned ? (misaligned + " 小节不齐") : "");

/* ===========================================================================
   2026-10-16 新增判据（手册 §4.1-7 校验器 / §7.3 上板前机械检查）：
   鼓与旋律的【机械分离】—— 不靠"轴号不会撞上"这种运气（手册 §〇 第 1 条原话）。
   口径（第三轮 = 4 件）：鼓 = is_drum(bit5)=1，件号 = drum_type = timbre[8:7]（2 位）；
        旋律 = is_drum=0 且【排除 kind=2】（tempo 用 inc 装速度值）。
   ⚠️ 判据收成一个纯函数 splitViolations()：真产物与"手造坏字"喂进【同一个谓词】，
      "判据能红"才是机械证明的（⛔ 不是靠人眼说"这应该能红"）。
   =========================================================================== */
function splitViolations(words) {
  const per = {}; for (let t = 0; t < 4; t++) per[t] = { on: 0, off: 0 };
  const r = { drumIncBad: 0, melInc0: 0, melOnDrumAxis: 0, on: 0, off: 0, unclosed: 0,
              orphan: 0, offNoFlag: 0, note5Bad: 0, nDrum: 0, nMel: 0, unbal: [],
              keyBad: 0, rawTypeBad: 0, firstKey: "", per: per };
  const open = new Map();
  for (const w of words) {
    const d = API.unpackWord(w);
    if (d.kind === API.KIND_TEMPO) continue;          /* ⚠️ tempo 用 inc 装速度值，必须排除 */
    if (d.isDrum === 1) {
      r.nDrum++;
      if (d.inc !== 0) r.drumIncBad++;
      if (d.note5 !== 0) r.note5Bad++;
      const t = DT_OF(d);                             /* drum_type = timbre[8:7]（2 位，4 件） */
      /* 判据⑱：鼓的轴必须 = 12 + dt */
      if (d.axis !== DRUM_TYPE_AXIS[t]) {
        r.keyBad++;
        if (!r.firstKey) r.firstKey = ("dt=" + t + "(" + nameOfType(t) + ") 落在轴 " + d.axis +
                                       "，应为 " + DRUM_TYPE_AXIS[t]);
      }
      /* 两条【独立】读取路径（页面 unpackWord 的 drumType / 本文件的位提取）必须给出同一个件号 */
      if (t !== DT_RAW(rawOf(w))) r.rawTypeBad++;
      const k = d.axis + ":" + t;                     /* 配对键 = (axis, drum_type)（手册口径） */
      if (d.kind === API.KIND_ON) { r.on++; r.per[t].on++; open.set(k, (open.get(k) || 0) + 1); }
      else { r.off++; r.per[t].off++; open.set(k, (open.get(k) || 0) - 1); }
    } else {
      r.nMel++;
      if (d.inc === 0) r.melInc0++;
      /* §7.3-1：鼓轴段 12..15（期望值在本文件独立写死，⛔ 不取页面的 isDrumAxis）。
       * 本轮鼓就占这一段 ⇒ 这一段上出现 is_drum=0 的事件 = 老路径回潮的直接指纹。 */
      if (d.axis >= MELODY_BAN_AXIS_MIN) r.melOnDrumAxis++;
      /* 鼓轴段上却不是鼓 = 典型的"鼓 OFF 漏标 is_drum"（会把鼓 voice 永久 held）。 */
      if (d.kind === API.KIND_OFF && d.axis >= MELODY_BAN_AXIS_MIN) r.offNoFlag++;
    }
  }
  for (const v of open.values()) { if (v > 0) r.unclosed += v; else if (v < 0) r.orphan += -v; }
  r.unbal = [];
  for (let t = 0; t < 4; t++) {
    if (r.per[t].on !== r.per[t].off) r.unbal.push(nameOfType(t) + " " + r.per[t].on + "/" + r.per[t].off);
  }
  return r;
}
const V = splitViolations(conv.words);

console.log();
console.log("  鼓与旋律分离（新增判据 —— 手册 §二 / §4.1-7 / §7.3）");
console.log("    鼓 " + V.nDrum + " 条（" +
            [0, 1, 2, 3].map(t => nameOfType(t) + " " + V.per[t].on + "起/" + V.per[t].off + "止").join(" · ") +
            "）· 旋律 " + V.nMel + " 条 · 鼓的 inc ≠0 " + V.drumIncBad +
            " 条 · 旋律 inc=0 " + V.melInc0 + " 条 · 落鼓轴段(12..15)的旋律字 " + V.melOnDrumAxis + " 条");
console.log("    鼓轴 = 12 + drum_type（4 件）：" + AXIS_KEY_TXT +
            " · 轴≠12+dt " + V.keyBad + " 条 · 两条件号读取路径不一致 " + V.rawTypeBad + " 条");
console.log();
chk("⑫ 鼓事件（is_drum=1）的 inc 必须全 0（硬检查②：FPGA 按 drum_type 自己取表）",
    V.drumIncBad === 0, V.drumIncBad ? (V.drumIncBad + " 条 inc≠0") : "全部为 0");
chk("⑬ 旋律事件（is_drum=0 且排除 kind=2）的 inc 必须全非 0（inc=0 = 被当成鼓/静音的指纹）",
    V.melInc0 === 0, V.melInc0 ? (V.melInc0 + " 条 inc=0") : (V.nMel + " 条全部非 0"));
chk("⑭ is_drum=0 的事件里，轴号落 12..15 的必须 0 条（§7.3 第 1 条）",
    V.melOnDrumAxis === 0,
    V.melOnDrumAxis ? (V.melOnDrumAxis + " 条（说明还有依赖轴号的路径，必须查清）")
                    : ("0 条（本轮鼓占 12..15 ⇒ 这四条轴只有 is_drum=1 的事件能占；起点 " +
                       MELODY_BAN_AXIS_MIN + " 在脚本里独立写死）"));
chk("⑮ 鼓的每个 kind=0 都有配对 kind=1（按 (axis,drum_type)），OFF 也带 is_drum=1 与同一 drum_type",
    V.on > 0 && V.on === V.off && V.unclosed === 0 && V.orphan === 0 &&
    V.offNoFlag === 0 && V.unbal.length === 0,
    "ON " + V.on + " / OFF " + V.off + " · 未闭合 " + V.unclosed + " · 无主 OFF " + V.orphan +
    " · 鼓段上漏标 is_drum 的 OFF " + V.offNoFlag + " 条" +
    (V.unbal.length ? (" · 逐件不守恒：" + V.unbal.join(" ")) : ""));
chk("⑯ is_drum=1 时 note_off5 必须为 0（鼓没有音高）",
    V.note5Bad === 0, V.note5Bad ? (V.note5Bad + " 条 note_off5≠0") : "全部为 0");
/* ⑰ 页面解码器 vs 独立位提取（bit5 / bits[4:0] / bits[8:7] 都要认） */
{
  const FLD = ["tick", "inc", "axis", "vel", "kind", "timbre", "guide", "isDrum", "note5"];
  let bad = 0, ex = "";
  for (const e of evs) {
    const d = API.unpackWord(e.w);
    const df = FLD.filter(f => d[f] !== e.raw[f]);
    if (df.length) { bad++; if (!ex) ex = "字段 " + df.join(","); }
    else if (encWord(e.raw) !== e.w) { bad++; if (!ex) ex = "独立编码器往返不等（独立提取漏了位域）"; }
  }
  chk("⑰ 页面 unpackWord 的 bit5/bits[4:0]/bits[8:7] 与独立位提取一致（⛔ 不拿被验者验自己）",
      bad === 0, bad ? (bad + " 条不一致（" + ex + "）")
                     : (evs.length + " 条逐字段一致 + 独立编码器往返一致（64 位全覆盖）"));
}
/* ---- 反控：手造坏字，喂进【同一个谓词】splitViolations()，要求对应判据变红 ---- */
{
  const words = conv.words;
  const a = splitViolations(words.concat([encWord({ tick: 0, inc: 37796, axis: 12, vel: 230,
                                                    kind: API.KIND_ON, timbre: 0, isDrum: 1, note5: 0 })]));
  chk("⑫反控 手造一条 is_drum=1 且 inc≠0 的字 ⇒ 必须报 inc≠0",
      a.drumIncBad > 0, "鼓 inc≠0 " + a.drumIncBad + " 条 ⇒ " +
      (a.drumIncBad > 0 ? "抓住（符合预期）" : "没抓住（判据失效）"));
  const b = splitViolations(words.concat([encWord({ tick: 0, inc: 0, axis: 2, vel: 100,
                                                    kind: API.KIND_ON, timbre: 1, isDrum: 0, note5: 3 })]));
  chk("⑬反控 手造一条 is_drum=0 且 inc=0 的旋律字 ⇒ 必须报 inc=0",
      b.melInc0 > 0, "旋律 inc=0 " + b.melInc0 + " 条 ⇒ " +
      (b.melInc0 > 0 ? "抓住（符合预期）" : "没抓住（判据失效）"));
  const c = splitViolations(words.concat([encWord({ tick: 0, inc: 37796, axis: 13, vel: 100,
                                                    kind: API.KIND_ON, timbre: 1, isDrum: 0, note5: 3 })]));
  chk("⑭反控 手造一条 is_drum=0 且轴=13 的字 ⇒ 必须报落鼓轴",
      c.melOnDrumAxis > 0, "落鼓轴的旋律字 " + c.melOnDrumAxis + " 条 ⇒ " +
      (c.melOnDrumAxis > 0 ? "抓住（符合预期）" : "没抓住（判据失效）"));
  /* 反控要【替换】那条鼓 OFF，⛔ 不是另加一条 ——
   *   手册点名的漏点是"一条 ON 与它自己的 OFF 不同步"：另加一条漏标 OFF
   *   并不会让原来那条 ON 变成未闭合（实测：漏标 1 条、未闭合 0 条 ⇒ 期望本身写错了）。
   * 2026-10-16 第三轮：鼓回到轴 12..15 ⇒ 清掉 is_drum 的那条 OFF 就落回【旋律且轴 12..15】
   *   ⇒ 除了未闭合，offNoFlag（鼓轴段上没带 is_drum 的 OFF）与 melInc0 也会一起涨 —— 三条指纹同时抓。 */
  let offAt = -1;
  for (let i = 0; i < words.length; i++) {
    const dd = API.unpackWord(words[i]);
    if (dd.isDrum === 1 && dd.kind === API.KIND_OFF) { offAt = i; break; }
  }
  const d = offAt < 0 ? null : splitViolations(
    words.slice(0, offAt).concat([words[offAt] & ~(1n << 5n)]).concat(words.slice(offAt + 1)));
  chk("⑮反控 把一条鼓 OFF 的 is_drum 位清 0（ON/OFF 不同步 ⇒ 挂音）⇒ 必须报未闭合 + 该 OFF 变 inc=0 的旋律字",
      !!d && d.unclosed > 0 && d.melInc0 > 0,
      d ? ("未闭合 ON " + d.unclosed + " 条 · 被当成 inc=0 旋律字的 " + d.melInc0 +
           " 条（鼓轴段上漏标 is_drum 的 offNoFlag " + d.offNoFlag + "）⇒ " +
           ((d.unclosed > 0 && d.melInc0 > 0) ? "抓住（符合预期）" : "没抓住（判据失效）"))
        : "找不到可改的鼓 OFF（无法构造）");
  let cutAt = -1;
  for (let i = 0; i < words.length; i++) {
    const dd = API.unpackWord(words[i]);
    if (dd.isDrum === 1 && dd.kind === API.KIND_OFF) { cutAt = i; break; }
  }
  const e = cutAt < 0 ? null : splitViolations(words.slice(0, cutAt).concat(words.slice(cutAt + 1)));
  chk("⑮反控 拔掉一条鼓 OFF 字 ⇒ 未闭合 ON 必须 > 0",
      !!e && e.unclosed > 0, e ? ("未闭合 ON " + e.unclosed + " 条 ⇒ " +
      (e.unclosed > 0 ? "抓住（符合预期）" : "没抓住（判据失效）")) : "找不到可拔的鼓 OFF（无法构造）");
  const f = splitViolations(words.concat([encWord({ tick: 0, inc: 0, axis: 14, vel: 175,
                                                    kind: API.KIND_ON, timbre: 2, isDrum: 1, note5: 7 })]));
  chk("⑯反控 手造一条 is_drum=1 且 note_off5=7 的字 ⇒ 必须报 note_off5≠0",
      f.note5Bad > 0, "鼓 note_off5≠0 " + f.note5Bad + " 条 ⇒ " +
      (f.note5Bad > 0 ? "抓住（符合预期）" : "没抓住（判据失效）"));
  /* ⑰反控：比对器自检 —— 把独立提取的 bit5 / bits[4:0] 改错，必须报不一致 */
  const FLD = ["tick", "inc", "axis", "vel", "kind", "timbre", "guide", "isDrum", "note5"];
  const w0 = conv.words[0], raw0 = rawOf(w0);
  const wrong = Object.assign({}, raw0, { isDrum: raw0.isDrum ^ 1, note5: (raw0.note5 + 1) & 0x1F });
  const df0 = FLD.filter(x => API.unpackWord(w0)[x] !== wrong[x]);
  chk("⑰反控 把独立提取的 bit5 / bits[4:0] 改错 ⇒ 比对器必须报出这两个字段",
      df0.indexOf("isDrum") >= 0 && df0.indexOf("note5") >= 0,
      "报出 [" + df0.join(",") + "] ⇒ " +
      ((df0.indexOf("isDrum") >= 0 && df0.indexOf("note5") >= 0) ? "抓住（符合预期）" : "比对器恒真，失效"));
}

/* ===========================================================================
   ⑱⑲（2026-10-16 第三轮口径）：鼓轴 = 12 + drum_type + note_off5 哨兵
   =========================================================================== */
/* ⑱ 鼓的轴 = 12 + drum_type（axis-12 == dt）—— 本轮的【核心硬判据】。
 *   为什么必须有：四件鼓的 src 全是 SRC_KDRUM，note_off 按 (axis, src) 配对
 *   ⇒ 轴号就是件的定位键，轴与件一旦错配，一件的 OFF 会清掉另一件的 voice。
 *   历史错法（都能被这条抓住）：
 *     · 上一轮的 dt 键 axis = ((dt&3)<<1)|(dt>>2) = 0/2/4/6/1/3/5/7（轴 <12）
 *     · 更早的"8 + dt"（轴 8..11）
 *     · 件号改了、轴没跟着改（共享位写错那一类）
 *   ⛔ 上一轮的"axis&1 == dt>>2"读数已删除：drum_type 只有 2 位，没有高位可对，那条式子恒真且无意义。
 *   两条【独立】读取路径：页面 unpackWord 的 drumType vs 本文件的位提取（rawOf 的 bit 8..7）。 */
chk("⑱ 鼓的轴 = 12 + drum_type（axis-12 == dt）· 两条件号读取路径一致 · 鼓轴全落 12..15",
    V.keyBad === 0 && V.rawTypeBad === 0 &&
    drumAxesUsed.every(a => a >= DRUM_AXIS_BASE && a <= DRUM_AXIS_MAX),
    "轴≠12+dt " + V.keyBad + " 条" + (V.firstKey ? ("（例 " + V.firstKey + "）") : "") +
    " · 两条路径不一致 " + V.rawTypeBad + " 条 · 12+dt = " + AXIS_KEY_TXT +
    " · 产物用到的鼓轴 " + drumAxesUsed.join(","));
{
  /* 反控 a：手造一条 snare(dt=1) 却落在 axis=0（上一轮 dt 键的写法）的鼓字 ⇒ keyBad 必须涨 */
  const a = splitViolations(conv.words.concat([encWord({ tick: 0, inc: 0, axis: 0, vel: 235,
                                                          kind: API.KIND_ON, timbre: 1, isDrum: 1, note5: 0 })]));
  chk("⑱反控 手造一条 snare(dt=1) 落在 axis=0（上一轮 dt 键）的字 ⇒ 必须报轴≠12+dt",
      a.keyBad > 0, "轴≠12+dt " + a.keyBad + " 条 ⇒ " +
      (a.keyBad > 0 ? "抓住（符合预期）" : "没抓住（判据失效）"));
  /* 反控 b：手造一条 axis=8 的鼓字（更早的 8..15 口径）⇒ 轴必然不等于 12+dt */
  const b = splitViolations(conv.words.concat([encWord({ tick: 0, inc: 0, axis: 8, vel: 230,
                                                          kind: API.KIND_ON, timbre: 0, isDrum: 1, note5: 0 })]));
  chk("⑱反控 手造一条鼓字落在 axis=8（更早的 8..15 口径）⇒ 必须报轴≠12+dt",
      b.keyBad > 0, "轴≠12+dt " + b.keyBad + " 条 ⇒ " +
      (b.keyBad > 0 ? "抓住（符合预期）" : "没抓住（判据失效）"));
  /* 反控 c：把一条真实鼓字的 timbre 低位 +1（件号变了、轴没跟着变）⇒ 必须报轴≠12+dt */
  let at = -1;
  for (let i = 0; i < conv.words.length; i++) if (API.unpackWord(conv.words[i]).isDrum === 1) { at = i; break; }
  const c = at < 0 ? null : splitViolations(conv.words.slice(0, at)
    .concat([(conv.words[at] & ~(3n << 7n)) | ((((conv.words[at] >> 7n) & 3n) + 1n & 3n) << 7n)])
    .concat(conv.words.slice(at + 1)));
  chk("⑱反控 把一条真实鼓字的 timbre 低位 +1（件号变、轴没变）⇒ 必须报轴≠12+dt",
      !!c && c.keyBad > 0,
      c ? ("轴≠12+dt " + c.keyBad + " 条 ⇒ " +
           (c.keyBad > 0 ? "抓住（符合预期）" : "没抓住（判据失效）"))
        : "找不到可改的鼓字（无法构造）");
  /* 反控 d（非空洞）：证明"只读 timbre[8:7]（2 位）"这件事在【本产物】上是有鉴别力的 ——
   *   若代码还按上一轮的 3 位 {bit19, timbre[8:7]} 读，件号会在多少条上不同。
   *   本产物有落在轴 13/15（bit19=1）的鼓 ⇒ 这个数必然 > 0；等于 0 才说明这条检查测不到东西。 */
  let legacyDiff = 0;
  for (const w of conv.words) {
    const d = API.unpackWord(w);
    if (d.isDrum !== 1) continue;
    if (DT_LEGACY3(rawOf(w)) !== DT_RAW(rawOf(w))) legacyDiff++;
  }
  chk("⑱反控 上一轮的 3 位读法 {bit19,timbre} 与 2 位读法在本产物上必须【不同】（否则测不到）",
      legacyDiff > 0, "3 位读法会算错 " + legacyDiff + " 条鼓事件的件号 ⇒ " +
      (legacyDiff > 0 ? "2 位读法的鉴别力非空洞（符合预期）" : "两种读法结果相同，本条检查空洞"));
}
/* ⑲ note_off5 新口径：可弹（MIDI 45..75）=> MIDI-45；越界 => 31 哨兵（不点灯）；
 *   ⛔ 不许钳到 0（0 = A2 = 真实的键 5，会点亮错误的灯）。
 *   音高从【事件里的 inc】反推（⛔ 不读页面的 midi 中间量）；inc 只有 21 位 ⇒ 允许 ±1 半音，
 *   边界（45±0.5 / 75±0.5）留死区不判。
 *   口径边界：哨兵只作用于旋律；鼓的 note_off5 恒 0（判据⑯，本轮不回退）。 */
const n5MidiOfInc = inc => { const hz = inc * 50000000 / 4294967296; return hz > 0 ? 69 + 12 * Math.log2(hz / 440) : null; };
const n5IncOfMidi = m => Math.round(440 * Math.pow(2, (m - 69) / 12) * 4294967296 / 50000000);
function note5Scan(list) {
  const SENT = 31, LO = 45, HI = 75;
  const res = { play: 0, unplay: 0, edge: 0, skip: 0, badVal: 0, badSent: 0, badUse: 0, badClamp: 0, ex: [] };
  for (const e of list) {
    if (e.isDrum === 1 || e.kind === API.KIND_TEMPO) continue;
    const m = e.inc === 0 ? null : n5MidiOfInc(e.inc);
    if (m == null) { res.skip++; continue; }
    const t = e.note5;
    if (m < LO - 0.5 || m > HI + 0.5) {
      res.unplay++;
      if (t !== SENT) {
        res.badSent++;
        if (t === 0) res.badClamp++;
        if (res.ex.length < 3) res.ex.push("tick " + e.tick + " 音高 " + m.toFixed(1) + " 却写 note5=" + t);
      }
    } else if (m < LO || m > HI) {
      res.edge++;
    } else {
      res.play++;
      const want = Math.round(m) - LO;
      if (t === SENT) {
        res.badUse++;
        if (res.ex.length < 3) res.ex.push("tick " + e.tick + " 音高 " + m.toFixed(1) + " 可弹却写哨兵 31");
      } else if (Math.abs(t - want) > 1) {
        res.badVal++;
        if (res.ex.length < 3) res.ex.push("tick " + e.tick + " note5=" + t + " 期望 " + want);
      }
    }
  }
  return res;
}
const N5 = note5Scan(evs);
chk("⑲ 旋律 note_off5：可弹(45..75) => MIDI-45 · 越界 => 31 哨兵（⛔ 不许钳到 0）· 鼓恒 0",
    N5.badVal === 0 && N5.badSent === 0 && N5.badUse === 0 && V.note5Bad === 0,
    "可弹 " + N5.play + " · 越界 " + N5.unplay + "（应写 31）· 边界死区 " + N5.edge +
    " · 值不对 " + N5.badVal + " · 越界没写哨兵 " + N5.badSent + "（其中钳到 0 的 " + N5.badClamp +
    "）· 可弹误写哨兵 " + N5.badUse + " · 鼓 note_off5≠0 " + V.note5Bad +
    (N5.ex.length ? ("（例 " + N5.ex.join(" | ") + "）") : ""));
{
  /* 反控 a：越界音高（MIDI 40）却写 0（钳位回潮）⇒ 必须报"越界没写哨兵"+"钳到 0" */
  const a = note5Scan(evs.concat([{ isDrum: 0, kind: API.KIND_ON, tick: 0, inc: n5IncOfMidi(40), note5: 0 }]));
  chk("⑲反控 手造一条音高 40（越界）却写 note5=0 的字 ⇒ 必须报越界没写哨兵 + 钳到 0",
      a.badSent > 0 && a.badClamp > 0,
      "越界未写哨兵 " + a.badSent + " · 其中钳到 0 的 " + a.badClamp + " ⇒ " +
      ((a.badSent > 0 && a.badClamp > 0) ? "抓住（符合预期）" : "没抓住（判据失效）"));
  /* 反控 b：可弹音高（MIDI 60）却写哨兵 31 ⇒ 必须报"可弹误写哨兵" */
  const b = note5Scan(evs.concat([{ isDrum: 0, kind: API.KIND_ON, tick: 0, inc: n5IncOfMidi(60), note5: 31 }]));
  chk("⑲反控 手造一条音高 60（可弹）却写哨兵 31 的字 ⇒ 必须报可弹误写哨兵",
      b.badUse > 0, "可弹误写哨兵 " + b.badUse + " 条 ⇒ " +
      (b.badUse > 0 ? "抓住（符合预期）" : "没抓住（判据失效）"));
  /* 反控 c：可弹音高但值写错（MIDI 60 写 3，应为 15）⇒ 必须报值不对 */
  const c = note5Scan(evs.concat([{ isDrum: 0, kind: API.KIND_ON, tick: 0, inc: n5IncOfMidi(60), note5: 3 }]));
  chk("⑲反控 手造一条音高 60 却写 note5=3（应为 15）的字 ⇒ 必须报值不对",
      c.badVal > 0, "值不对 " + c.badVal + " 条 ⇒ " +
      (c.badVal > 0 ? "抓住（符合预期）" : "没抓住（判据失效）"));
}

// ---- 导出 events.hex（与 mid2evt.py 的写法一致：每行 16 位十六进制）----
if (hexOut) {
  const lines = conv.words.map(w => w.toString(16).padStart(16, "0"));
  fs.writeFileSync(hexOut, lines.join("\n") + "\n", "utf8");
  console.log();
  console.log("  已写出 events.hex：" + hexOut + "（" + lines.length + " 行）");
}

console.log();
console.log("  结论：" + (red === 0 ? "全部通过（" + nChk + " 项）" : ("有 " + red + " 项 RED")));
process.exit(red === 0 ? 0 : 1);
