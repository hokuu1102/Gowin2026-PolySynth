// _inspect_midi.js —— 看一份 MIDI 的轨结构与我方的分类结果
// 用法：node _inspect_midi.js <文件路径>
const fs = require("fs");
const path = require("path");

const midPath = process.argv[2];
if (!midPath || !fs.existsSync(midPath)) {
  console.error("用法: node _inspect_midi.js <文件.mid>");
  process.exit(2);
}

const html = fs.readFileSync(path.join(__dirname, "score_studio.html"), "utf8");
const blk = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1])[0];
const fakeCtx = new Proxy({}, {
  get: (t, k) => k === "canvas" ? { width: 1, height: 1 }
    : (k === "measureText" ? () => ({ width: 1 }) : (() => {})), set: () => true });
const fakeEl = () => new Proxy({
  style: {}, classList: { add() {}, remove() {} }, getContext: () => fakeCtx,
  querySelectorAll: () => [], addEventListener() {}, appendChild() {},
  insertAdjacentHTML() {}, getBoundingClientRect: () => ({ left: 0, top: 0, width: 8, height: 6 }),
  textContent: "", innerHTML: "",
}, { get: (t, k) => k in t ? t[k] : (typeof k === "string" ? (() => {}) : undefined),
     set: (t, k, v) => { t[k] = v; return true; } });
const doc = { getElementById: () => fakeEl(), querySelector: () => fakeEl(),
  querySelectorAll: () => [], addEventListener() {}, createElement: () => fakeEl(), body: fakeEl() };
const fn = new Function("document", "window", "navigator", "performance", "console",
  "setTimeout", "clearInterval", "setInterval", "requestAnimationFrame",
  "location", "localStorage", "URLSearchParams",
  blk + "\n; return { parseMidi, midiToWords, isDrumTrack, timbreOfTrack, " +
  "TIMBRE_NAMES, DRUM_HINTS, GM_DRUM_CHANNEL, midiName };");
const API = fn(doc, { addEventListener() {} }, { bluetooth: null }, { now: () => 0 },
  console, setTimeout, () => {}, () => 0, () => 0,
  { protocol: "http:", host: "x", search: "" },
  { getItem: () => null, setItem() {} },
  class { constructor() {} get() { return null; } });

const buf = fs.readFileSync(midPath);
const parsed = API.parseMidi(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length));

console.log("=".repeat(78));
console.log("MIDI: " + path.basename(midPath));
console.log("=".repeat(78));
console.log("  division(PPQN) = " + parsed.division + "   有音符的轨数 = " + parsed.tracks.length);
console.log();
console.log("  轨  | 轨名                  | 通道        | 音符 | 判为鼓 | 音色");
console.log("  ----|----------------------|-------------|------|--------|------");
parsed.tracks.forEach((t, i) => {
  const drum = API.isDrumTrack(t);
  const tb = API.timbreOfTrack(t);
  const chans = [...t.chan].sort((a, b) => a - b).join(",") || "-";
  console.log("  " + String(i).padEnd(4) + "| " +
    JSON.stringify(t.name || "").padEnd(21) + "| " +
    chans.padEnd(12) + "| " +
    String(t.notes.length).padEnd(5) + "| " +
    (drum ? " 是 " : " 否 ").padEnd(7) + "| " +
    API.TIMBRE_NAMES[tb]);
});
console.log();
console.log("  鼓的识别规则：轨名含 " + JSON.stringify(API.DRUM_HINTS) +
            "，或用到通道 " + (API.GM_DRUM_CHANNEL + 1) + "（1-based）");

// 转换结果
const conv = API.midiToWords(parsed);
console.log();
console.log("  转换后：轴分配");
console.log("  axis | 轨名             | 类型   | 音符数");
conv.assign.forEach(a => {
  console.log("  " + String(a.axis).padEnd(5) + "| " + String(a.name).padEnd(17) +
              "| " + String(a.kind).padEnd(7) + "| " + a.notes);
});
console.log();
console.log("  总事件 = " + conv.words.length + "  BPM = " + conv.bpm.toFixed(1) +
            "  tick 最大 = " + conv.tickMax);
const dur = conv.tickMax / 960 / (conv.bpm / 60);
console.log("  时长 ≈ " + dur.toFixed(1) + " 秒");

// ⚠️ 检查：鼓轨走的是哪几条轴？
/* ⭐ 2026-10-15 方案 B：鼓【一件一轴】12/13/14/15 ⇒ assign 里 `axis` 是"用到的轴"列表串
 *   （不再是单个 15）。⚠️ FPGA 侧判鼓的判据 = `axis >= 12`（seq_arb.v:204）。 */
const drumAxes = conv.assign.filter(a => a.kind === "鼓").map(a => a.axis);
if (drumAxes.length) {
  console.log();
  console.log("  鼓轨占用的轴：" + drumAxes.join(",") +
              "（⭐ 方案 B：四件各占 12/13/14/15，判据 axis >= 12 ⇒ 鼓）");
  // 看鼓轨用的音高分布
  parsed.tracks.forEach(t => {
    if (!API.isDrumTrack(t)) return;
    const pitches = new Set(t.notes.map(n => n.midi));
    console.log("     轨 " + JSON.stringify(t.name) + " 用到的 MIDI 音高: " +
                [...pitches].sort((a, b) => a - b).join(","));
  });
}
