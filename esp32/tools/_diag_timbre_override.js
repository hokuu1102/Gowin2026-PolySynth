// _diag_timbre_override.js —— 验"网页改音色"是否真的生效（端到端）
// 用法：node _diag_timbre_override.js "<文件.mid>"
const fs = require("fs");
const path = require("path");
const midPath = process.argv[2];
const html = fs.readFileSync(path.join(__dirname, "score_studio.html"), "utf8");
const blk = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1])[0];
const fakeCtx = new Proxy({}, {
  get: (t, k) => k === "canvas" ? { width: 800, height: 400 }
    : (k === "measureText" ? () => ({ width: 10 }) : (() => {})), set: () => true });
const fakeEl = () => new Proxy({
  style: {}, classList: { add() {}, remove() {} }, getContext: () => fakeCtx,
  querySelectorAll: () => [], querySelector: () => null,
  addEventListener() {}, appendChild() {}, insertAdjacentHTML() {},
  getBoundingClientRect: () => ({ left: 0, top: 0, width: 800, height: 400 }),
  textContent: "", innerHTML: "", checked: false, width: 800, height: 400,
  parentElement: { getBoundingClientRect: () => ({ width: 800, height: 400 }) },
}, { get: (t, k) => k in t ? t[k] : (() => {}), set: (t, k, v) => { t[k] = v; return true; } });
const doc = { getElementById: () => fakeEl(), querySelector: () => fakeEl(),
  querySelectorAll: () => [], addEventListener() {}, createElement: () => fakeEl(), body: fakeEl() };
const fn = new Function("document", "window", "navigator", "performance", "console",
  "setTimeout", "clearInterval", "setInterval", "requestAnimationFrame",
  "location", "localStorage", "URLSearchParams",
  blk + "\n; return { parseMidi, midiToWords, midiToWordsWithOverride, buildScore, " +
  "TIMBRE_NAMES, DRUM_AXIS, timbreOfTrack, setOverride: (m) => { timbreOverride = m; }, " +
  "getOverride: () => timbreOverride };");
const API = fn(doc, { addEventListener() {} }, { bluetooth: null }, { now: () => 0 },
  console, setTimeout, () => {}, () => 0, () => 0,
  { protocol: "http:", host: "x", search: "" },
  { getItem: () => null, setItem() {} },
  class { constructor() {} get() { return null; } });

let bad = 0;
function chk(name, cond, extra) {
  console.log("  " + name.padEnd(56) + (cond ? "OK" : "RED") + (extra ? "   " + extra : ""));
  if (!cond) bad++;
}

const buf = fs.readFileSync(midPath);
const parsed = API.parseMidi(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length));
const conv0 = API.midiToWords(parsed);

console.log("=".repeat(78));
console.log("音色覆写端到端验证：" + path.basename(midPath));
console.log("=".repeat(78));

// ① assign 带 idx / timbreIdx
const needIdx = conv0.trackList.every(t => typeof t.idx === "number");
const needTb = conv0.trackList.every(t => typeof t.timbreIdx === "number" ||
                                           t.drum === true);
chk("⭐ 每条轨都带 idx（⛔ 少它就点不动下拉）", needIdx);
chk("⭐ 旋律轨都带 timbreIdx", needTb,
    conv0.trackList.map(t => t.idx + ":" + t.timbreIdx).join(" "));

// ② 覆写一条旋律轨 => 事件的 timbre 真的变
const tuned = conv0.trackList.find(t => !t.drum);
if (!tuned) { console.log("  (没有旋律轨，跳过覆写验证)"); }
else {
  const oldTb = tuned.timbreIdx;
  const newTb = (oldTb + 1) % 4;
  API.setOverride(new Map([[tuned.idx, newTb]]));
  const conv1 = API.midiToWordsWithOverride(parsed, conv0.trackList);
  // 从 events 里数 timbre 分布
  const dist = [0, 0, 0, 0];
  conv1.words.forEach(w => { const tb = Number((w >> 7n) & 0x3n); dist[tb]++; });
  const before = [0, 0, 0, 0];
  conv0.words.forEach(w => { const tb = Number((w >> 7n) & 0x3n); before[tb]++; });
  chk("⭐ 覆写后 timbre=" + newTb + " 的事件数明显增加",
      dist[newTb] > before[newTb],
      "before=" + before[newTb] + " after=" + dist[newTb]);
  chk("非空洞：覆写只影响那条轨（总事件数不变）",
      conv1.words.length === conv0.words.length,
      conv0.words.length + " -> " + conv1.words.length);
  chk("⭐ 轨道列表里该轨显示的音色名也变了",
      conv1.trackList.find(t => t.idx === tuned.idx).timbre === API.TIMBRE_NAMES[newTb],
      API.TIMBRE_NAMES[newTb]);
  // ③ 鼓轨不受覆写影响
  const drums = conv0.trackList.filter(t => t.drum);
  if (drums.length) {
    API.setOverride(new Map([[drums[0].idx, 3]]));   // 试着把鼓轨改成 PAD
    const conv2 = API.midiToWordsWithOverride(parsed, conv0.trackList);
    const incs = new Set();
    conv2.words.forEach((w, i) => {
      if (Number((w >> 19n) & 0xFn) === API.DRUM_AXIS) {
        incs.add(Number((w >> 23n) & 0x1FFFFFn));
      }
    });
    chk("⭐ 鼓轨不接受音色覆写（仍走鼓的固定 inc）",
        [...incs].every(v => [5243, 41943, 167772, 17476].includes(v)),
        [...incs].join(","));
  }
  API.setOverride(new Map());
}

// ④ 图例：只显示出现过的音色（⛔ 不写轴号）
const sc = API.buildScore(conv0.words, "x");
console.log();
console.log("  主图音高范围（已排除鼓）：" +
            Math.min(...sc.notes.filter(n => n.axis !== API.DRUM_AXIS)
                     .map(n => n.midi)).toFixed(1) + " .. " +
            Math.max(...sc.notes.filter(n => n.axis !== API.DRUM_AXIS)
                     .map(n => n.midi)).toFixed(1));
console.log("  鼓段数 / 旋律段数：" + (sc.drumSegs || []).length + " / " +
            (sc.noteSegs || []).length);
console.log();
console.log("  出现过的 timbre：" +
            [...new Set(sc.notes.filter(n => n.axis !== API.DRUM_AXIS)
                    .map(n => n.timbre))].sort().join(","));

console.log();
console.log("结论：" + (bad === 0 ? "全部通过" : "有 " + bad + " 项不符"));
process.exit(bad === 0 ? 0 : 1);
