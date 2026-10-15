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
//   ③ 鼓轨全部落在 axis 15，且四件都出现（kick/snare/hihat/tom）
//   ④ 旋律峰值并发 <= 15（可用轴 0..14）
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
if (!midPath) midPath = path.join(HERE, "四音色鼓机变速-house-funk-测试曲.mid");
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
  blk + "\n; return { parseMidi, midiToWords, isDrumTrack, timbreOfTrack, " +
  "TIMBRE_NAMES, DRUM_AXIS, KIND_ON, KIND_OFF, KIND_TEMPO, DRUM_INC };");
const API = fn(doc, { addEventListener() {} }, { bluetooth: null }, { now: () => 0 },
  { log: () => {} }, setTimeout, () => {}, () => 0, () => 0,
  { protocol: "http:", host: "x", search: "" },
  { getItem: () => null, setItem() {} },
  class { constructor() {} get() { return null; } });

const buf = fs.readFileSync(midPath);
const parsed = API.parseMidi(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length));
const conv = API.midiToWords(parsed);

// ---- 解码事件字 ----
const evs = conv.words.map((w, i) => ({
  i, tick: Number((w >> 44n) & 0xFFFFFn), kind: Number((w >> 9n) & 0x3n),
  axis: Number((w >> 19n) & 0xFn), vel: Number((w >> 11n) & 0xFFn),
  timbre: Number((w >> 7n) & 0x3n), inc: Number((w >> 23n) & 0x1FFFFFn),
}));

let red = 0;
const chk = (name, cond, extra) => {
  console.log("  " + (cond ? "[OK] " : "[RED]") + name.padEnd(52) + (extra || ""));
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
const mel = evs.filter(e => e.axis !== API.DRUM_AXIS)
  .sort((a, b) => (a.tick - b.tick) || (b.kind - a.kind));
let cur = 0, peak = 0;
for (const e of mel) {
  if (e.kind === API.KIND_OFF) { if (cur > 0) cur--; }
  else if (e.kind === API.KIND_ON) { cur++; if (cur > peak) peak = cur; }
}
const axUsed = [...new Set(mel.map(e => e.axis))].sort((a, b) => a - b);

// ---- 鼓 ----
const dr = evs.filter(e => e.axis === API.DRUM_AXIS);
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
chk("② 三个 tempo 点全部转成 kind=2", kinds.tempo === 3 && parsed.allTempos.length === 3,
    "kind=2 " + kinds.tempo + " 个 / 文件里 " + parsed.allTempos.length + " 个");
chk("③ 鼓全在 axis 15，且四件都出现", conv.drumTracks === 1 &&
    dr.every(e => e.axis === API.DRUM_AXIS) &&
    ["kick", "snare", "hihat", "tom"].every(k => drumCount[k] > 0),
    JSON.stringify(drumCount));
chk("④ 旋律峰值并发 <= 15（可用轴 0..14）", peak <= 15, "峰值 " + peak);
chk("⑤ 没用到 axis 14（节拍器轴）", !axUsed.includes(14));
chk("⑥ 同 tick 同音高的重击，off 排在 on 前（反向 0 处）",
    restrikeTicks.length >= 1 && badOrder === 0,
    "重击 " + restrikeTicks.length + " 处（tick " + restrikeTicks.join(",") + "）· 顺序错 " + badOrder + " 处");
chk("⑦ 鼓同 tick 多件 = 1 处（第 8 小节第 4 拍那个故意的探针）", drumSimul.length === 1,
    drumSimul.length ? ("tick " + drumSimul[0].tick + " 敲 " + drumSimul[0].n + " 件") : "没有");
chk("⑧ 鼓没有走音高分区兜底（全部来自映射表）", conv.drumFuzzy === 0,
    "兜底 " + conv.drumFuzzy + " 个");

// ---- 导出 events.hex（与 mid2evt.py 的写法一致：每行 16 位十六进制）----
if (hexOut) {
  const lines = conv.words.map(w => w.toString(16).padStart(16, "0"));
  fs.writeFileSync(hexOut, lines.join("\n") + "\n", "utf8");
  console.log();
  console.log("  已写出 events.hex：" + hexOut + "（" + lines.length + " 行）");
}

console.log();
console.log("  结论：" + (red === 0 ? "全部通过（" + 8 + " 项）" : ("有 " + red + " 项 RED")));
process.exit(red === 0 ? 0 : 1);
