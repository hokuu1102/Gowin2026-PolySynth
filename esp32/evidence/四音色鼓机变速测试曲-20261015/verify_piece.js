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
// 判据（不符合会打 RED）：
//   ① 四个音色 BASS/GUITAR/PIANO/PAD 全部出现
//   ② 三个 tempo 点全部转成 kind=2 事件
//   ③ 鼓轨各占 axis 12/13/14/15（方案 B：一件一轴），且四件都出现（kick/snare/hihat/tom）
//   ④ 旋律峰值并发 <= 12（可用轴 0..11）
//   ⑤ 没用到 axis 14（节拍器轴）
//   ⑥ 存在"同一 tick 同音高先关后开"的重击（off 必须排在 on 前）
//   ⑦ 同 tick 敲多件鼓的地方 = 1 处（第 12 小节那个【故意】的探针）

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
const fn = new Function("document", "window", "navigator", "performance", "console",
  "setTimeout", "clearInterval", "setInterval", "requestAnimationFrame",
  "location", "localStorage", "URLSearchParams",
  blk + "\n; return { parseMidi, midiToWords, buildScore, isDrumTrack, timbreOfTrack, " +
  "TIMBRE_NAMES, isDrumAxis, DRUM_AXIS_OF, DRUM_AXIS_BASE, KIND_ON, KIND_OFF, " +
  "KIND_TEMPO, DRUM_INC };");
const API = fn(doc, { addEventListener() {} }, { bluetooth: null }, { now: () => 0 },
  { log: () => {} }, setTimeout, () => {}, () => 0, () => 0,
  { protocol: "http:", host: "x", search: "" },
  { getItem: () => null, setItem() {} },
  class { constructor() {} get() { return null; } });

const buf = fs.readFileSync(midPath);
const parsed = API.parseMidi(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length));
const conv = API.midiToWords(parsed);
/* ⭐ 判据 ⑨ 要按"段"看跨音色重叠，所以也要 buildScore（配对 + 分栏那一步）。 */
const score = API.buildScore(conv.words, path.basename(midPath));

// ---- 解码事件字 ----
const evs = conv.words.map((w, i) => ({
  i, tick: Number((w >> 44n) & 0xFFFFFn), kind: Number((w >> 9n) & 0x3n),
  axis: Number((w >> 19n) & 0xFn), vel: Number((w >> 11n) & 0xFFn),
  timbre: Number((w >> 7n) & 0x3n), inc: Number((w >> 23n) & 0x1FFFFFn),
}));

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
/* ⭐ 2026-10-15 方案 B：鼓在 12..15 四条轴上 ⇒ 判据一律用 isDrumAxis（axis >= 12）。 */
const mel = evs.filter(e => !API.isDrumAxis(e.axis))
  .sort((a, b) => (a.tick - b.tick) || (b.kind - a.kind));
let cur = 0, peak = 0;
for (const e of mel) {
  if (e.kind === API.KIND_OFF) { if (cur > 0) cur--; }
  else if (e.kind === API.KIND_ON) { cur++; if (cur > peak) peak = cur; }
}
const axUsed = [...new Set(mel.map(e => e.axis))].sort((a, b) => a - b);

// ---- 鼓 ----
const dr = evs.filter(e => API.isDrumAxis(e.axis));
const nameOfInc = {};
for (const k of Object.keys(API.DRUM_INC)) nameOfInc[API.DRUM_INC[k]] = k;
const drumCount = {};
const drumTickOn = {};
for (const e of dr) {
  if (e.kind !== API.KIND_ON) continue;
  const nm = nameOfInc[e.inc] || ("未知inc" + e.inc);
  drumCount[nm] = (drumCount[nm] || 0) + 1;
  drumTickOn[e.tick] = (drumTickOn[e.tick] || 0) + 1;
}
const drumSimul = Object.entries(drumTickOn).filter(([, n]) => n >= 2)
  .map(([t, n]) => ({ tick: Number(t), n }));

// ---- 重击（同 tick 同音高：off 必须排在 on 之前）----
// ⚠️ 判据不是"相邻"，而是"同一 tick 内，同 inc 的 off 下标 < on 下标"：
//    同一个 tick 上还有别的音在起（和弦、鼓），它们会插在中间。
// ⚠️ 也不要求同 axis —— 上位机的分轴算法贪心取"最低的空闲轴"，
//    前后两个段可能分到不同的轴，那是正常行为。
const byTick = new Map();
evs.forEach((e, i) => {
  if (!byTick.has(e.tick)) byTick.set(e.tick, []);
  byTick.get(e.tick).push({ e, i });
});
const restrikeTicks = [];
let badOrder = 0;
for (const [tick, list] of byTick) {
  const offAt = new Map(), onAt = new Map();
  for (const { e, i } of list) {
    if (e.kind === API.KIND_OFF && !offAt.has(e.inc)) offAt.set(e.inc, i);
    if (e.kind === API.KIND_ON && !onAt.has(e.inc)) onAt.set(e.inc, i);
  }
  for (const [inc, oi] of offAt) {
    if (!onAt.has(inc)) continue;          // 只有关或只有开，不是重击
    restrikeTicks.push(tick);
    if (onAt.get(inc) < oi) badOrder++;    // 开在关前面 = 顺序错
  }
}

console.log();
console.log("  事件总数 = " + evs.length + "（on " + kinds.on + " · off " + kinds.off +
            " · tempo " + kinds.tempo + "）");
console.log("  tick 最大 = " + tickMax + "   时长 ≈ " + secs.toFixed(1) + " 秒（按变速分段算）");
console.log("  整包 = " + evs.length * 9 + " 字节（每事件 9 字节帧）+ 1 个总数帧");
console.log("  旋律峰值并发 = " + peak + "   用到的轴 = " + axUsed.join(","));
console.log("  鼓：共 " + (dr.length / 2) + " 下 · " +
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
/* ③ ⭐ 方案 B（2026-10-15）：四件鼓【各占一条轴】12/13/14/15（原为四件共用 15）。
 *   判据与 FPGA `seq_arb.v:204` 一致：`axis >= 12` ⇒ 鼓。 */
const drumAxesUsed = [...new Set(dr.map(e => e.axis))].sort((a, b) => a - b);
chk("③ 鼓各占 12..15 且四件都出现（方案 B：一件一轴）", conv.drumTracks === 1 &&
    dr.every(e => API.isDrumAxis(e.axis)) &&
    ["kick", "snare", "hihat", "tom"].every(k => drumCount[k] > 0),
    "用到的鼓轴 " + drumAxesUsed.join(",") + " · " + JSON.stringify(drumCount));
/* ⭐ 非空洞：每条鼓事件的轴 = 该件应有的轴（⛔ 只验范围的话"四件都塞 12"也能过） */
{
  const want = {};
  for (const [k, ax] of Object.entries(API.DRUM_AXIS_OF)) want[API.DRUM_INC[k]] = ax;
  const badAx = dr.filter(e => want[e.inc] !== e.axis);
  chk("③b 非空洞：每条鼓事件的轴 = 该件的轴（inc↔axis 一一对应）",
      badAx.length === 0, badAx.length ? (badAx.length + " 条对不上") : "全部对");
}
chk("④ 旋律峰值并发 <= 12（方案 B：可用轴只剩 0..11）", peak <= 12, "峰值 " + peak);
chk("⑤ 旋律【不占】鼓轴段 12..15", !axUsed.some(a => a >= API.DRUM_AXIS_BASE),
    "旋律用到 " + axUsed.join(","));
chk("⑥ 同 tick 同音高的重击，off 排在 on 前（反向 0 处）",
    restrikeTicks.length >= 1 && badOrder === 0,
    "重击 " + restrikeTicks.length + " 处（tick " + restrikeTicks.join(",") + "）· 顺序错 " + badOrder + " 处");
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
 * ⚠️ 480 要与 gen_test_piece.py 的 DRUM_DUR 一致；改了那边这里也要改。 */
const DRUM_DUR = 480;
let tooClose = 0, minGap = Infinity;
const closeEx = [];
const drumAxesAll = [...new Set(evs.filter(e => API.isDrumAxis(e.axis)).map(e => e.axis))];
let drumHits = 0;
for (const ax of drumAxesAll) {
  /* ⚠️ 先【去重 tick】再量间隔：同一 tick 上敲多件由判据 ⑦ 单独管 */
  const on = [...new Set(evs.filter(e => e.axis === ax && e.kind === API.KIND_ON)
                             .map(e => e.tick))].sort((a, b) => a - b);
  drumHits += on.length;
  for (let i = 1; i < on.length; i++) {
    const g = on[i] - on[i - 1];
    if (g < minGap) minGap = g;
    if (g < DRUM_DUR) {
      tooClose++;
      if (closeEx.length < 3) {
        closeEx.push("轴" + ax + " " + on[i - 1] + "→" + on[i] + "（间隔 " + g + "）");
      }
    }
  }
}
console.log();
console.log("  鼓落点：" + drumHits + " 下（分 " + drumAxesAll.length + " 条轴）· 同一件最小间隔 " +
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
  if (e.kind !== API.KIND_ON || API.isDrumAxis(e.axis)) continue;
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
