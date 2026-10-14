// _check_user_midi.js —— 用用户的真实 MIDI 验证鼓转换 + 选轨
// 用法：node _check_user_midi.js "<文件.mid>"
const fs = require("fs");
const path = require("path");

const midPath = process.argv[2];
if (!midPath || !fs.existsSync(midPath)) { console.error("用法: node _check_user_midi.js <文件.mid>"); process.exit(2); }

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
  blk + "\n; return { parseMidi, midiToWords, DRUM_INC, DRUM_AXIS, TIMBRE_NAMES, " +
  "wordsForSelected, buildPayload, setSel: (s) => { trackSel = s; } };");
const API = fn(doc, { addEventListener() {} }, { bluetooth: null }, { now: () => 0 },
  console, setTimeout, () => {}, () => 0, () => 0,
  { protocol: "http:", host: "x", search: "" },
  { getItem: () => null, setItem() {} },
  class { constructor() {} get() { return null; } });

const buf = fs.readFileSync(midPath);
const p = API.parseMidi(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length));
const c = API.midiToWords(p);

console.log("=".repeat(78));
console.log("用户 MIDI: " + path.basename(midPath));
console.log("=".repeat(78));
console.log("  轨分配：");
c.trackList.forEach(t => {
  console.log("    轨" + t.idx + "  " + JSON.stringify(t.name).padEnd(14) +
              (t.drum ? "【鼓】" : "      ") +
              " 音色=" + String(t.timbre).padEnd(7) + " 轴=" + String(t.axis).padEnd(4) +
              " 音符=" + t.notes);
});
console.log();
console.log("  事件总数 = " + c.words.length + "  BPM = " + c.bpm.toFixed(1) +
            "  时长≈" + (c.tickMax / 960 / (c.bpm / 60)).toFixed(1) + " 秒");

// 鼓事件用的 inc
const drumInc = new Map();
c.words.forEach((w, i) => {
  const src = c.evTrack[i];
  if (src >= 0 && c.trackList[src].drum) {
    const v = Number((w >> 23n) & 0x1FFFFFn);
    drumInc.set(v, (drumInc.get(v) || 0) + 1);
  }
});
console.log();
console.log("  鼓事件用到的 inc（⚠️ 21 位截断后的）：");
for (const [v, n] of [...drumInc].sort((a, b) => b[1] - a[1])) {
  console.log("    " + String(v).padEnd(10) + " x" + n);
}
console.log("  应填的原始值（32 位，装不进 21 位）：");
Object.entries(API.DRUM_INC).forEach(([k, v]) => {
  console.log("    " + k.padEnd(6) + " " + String(v).padEnd(12) +
              " 截断后 = " + (v & 0x1FFFFF));
});

console.log();
console.log("  选轨演示：");
const allIds = c.trackList.map(t => t.idx);
API.setSel(new Set(allIds));
const allW = API.wordsForSelected(c.words, c);
const drumId = c.trackList.find(t => t.drum);
const tunedIds = allIds.filter(i => !drumId || i !== drumId.idx);
API.setSel(new Set(drumId ? [drumId.idx] : []));
const onlyDrum = API.wordsForSelected(c.words, c);
API.setSel(new Set(tunedIds));
const onlyTuned = API.wordsForSelected(c.words, c);

const row = (label, ws) =>
  console.log("    " + label.padEnd(16) + String(ws.length).padStart(6) + " 事件  ->  payload " +
              String(API.buildPayload(ws).length).padStart(7) + " B");
row("全部", allW);
row("只鼓", onlyDrum);
row("只旋律轨（去鼓）", onlyTuned);
console.log();
console.log("  ⭐ 换速事件在任何选择下都保留（每个选择都含 1 个 kind=2）");
[["全部", allW], ["只鼓", onlyDrum], ["只旋律", onlyTuned]].forEach(([lab, ws]) => {
  const n = ws.filter(w => Number((w >> 9n) & 0x3n) === 2).length;
  console.log("    " + lab.padEnd(10) + " kind=2 事件数 = " + n);
});
