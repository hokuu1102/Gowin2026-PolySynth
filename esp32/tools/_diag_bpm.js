// _diag_bpm.js —— 查一份 MIDI 的 tempo 到底被转成什么
const fs = require("fs");
const path = require("path");
const midPath = process.argv[2];
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
  blk + "\n; return { parseMidi, midiToWords, bpmToTickInc, MIDI_PPQN, MIDI_FS, " +
  "KIND_TEMPO, KIND_ON, KIND_OFF, incToHz };");
const API = fn(doc, { addEventListener() {} }, { bluetooth: null }, { now: () => 0 },
  console, setTimeout, () => {}, () => 0, () => 0,
  { protocol: "http:", host: "x", search: "" },
  { getItem: () => null, setItem() {} },
  class { constructor() {} get() { return null; } });

const buf = fs.readFileSync(midPath);
const parsed = API.parseMidi(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length));

console.log("=".repeat(76));
console.log("tempo 诊断：" + path.basename(midPath));
console.log("=".repeat(76));
console.log("  division（原 PPQN） = " + parsed.division);
console.log("  scale（->960 的倍数） = " + (960 / parsed.division));

const tempos = (parsed.allTempos || []).map(t => ({ tick: t.tick, us: t.usPerQuarter }));
console.log("  文件里的 tempo 事件 = " + tempos.length + " 个");
tempos.forEach((t, i) => {
  const bpm = 60000000 / t.us;
  console.log("    #" + i + "  轨" + t.ti + "  tick=" + t.tick +
              "  us/四分音符=" + t.us + "  => BPM " + bpm.toFixed(3));
});

console.log();
console.log("  换算：bpmToTickInc(bpm) = round((bpm/60)*960 * 2^32 / 50e6)");
for (const bpm of [120, 168, 357143 > 0 ? 60000000 / 357143 : 0]) {
  console.log("    BPM %s -> tick_inc = %s（21 位上限 2097151 %s）"
    % (bpm.toFixed(3), API.bpmToTickInc(bpm),
       API.bpmToTickInc(bpm) <= 2097151 ? "✅" : "🔴"));
}

const conv = API.midiToWords(parsed);
const tempoEvs = [];
conv.words.forEach((w, i) => {
  const kind = Number((w >> 9n) & 0x3n);
  if (kind !== API.KIND_TEMPO) return;
  tempoEvs.push({
    tick: Number((w >> 44n) & 0xFFFFFn),
    inc: Number((w >> 23n) & 0x1FFFFFn),
    axis: Number((w >> 19n) & 0xFn),
  });
});
console.log();
console.log("  我方实际发出的 kind=2 事件 = " + tempoEvs.length + " 个");
tempoEvs.forEach((e, i) => {
  const bpm = (e.inc / 4294967296 * 50000000) / (960 / 60);
  console.log("    #" + i + "  tick=" + e.tick + "  inc=" + e.inc +
              "  => 反算 BPM = " + bpm.toFixed(2));
});
console.log("  conv.bpm（报告值） = " + conv.bpm.toFixed(3) +
            "  tempoCount = " + conv.tempoCount);

// 与 FPGA 的默认值对照
console.log();
console.log("  FPGA 复位默认 tick_inc = 164927（120 BPM）");
console.log("  ⇒ " + (tempoEvs.length === 0
      ? "🔴 一个 tempo 都没发 => FPGA 永远用 120"
      : (tempoEvs[0].inc === 164927
          ? "🔴 发的就是 120 的 tick_inc => 说明 BPM 取错了"
          : "✅ 发的不是 120 => 若听感仍是 120，问题在【送达】环节")));
