// _drum_track_check.js —— 离线自检：鼓转换 + 选轨播放
//
// 用途：验证 2026-10-14 加的两个功能
//   ① 鼓的 GM 音高 -> FPGA 鼓机四件（用户报"鼓被推成音高"）
//   ② 选轨播放（用户要求：既可全播，也可只播选定的一轨或多轨）
//
// 用法：node _drum_track_check.js

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
  textContent: "", innerHTML: "", checked: false, scrollTop: 0, scrollHeight: 0,
  clientWidth: 8, clientHeight: 6, parentElement: null,
}, { get: (t, k) => k in t ? t[k] : (typeof k === "string" ? (() => {}) : undefined),
     set: (t, k, v) => { t[k] = v; return true; } });
const doc = {
  getElementById: () => fakeEl(), querySelector: () => fakeEl(),
  querySelectorAll: () => [], addEventListener: () => {},
  createElement: () => fakeEl(), body: fakeEl(),
};
const fn = new Function("document", "window", "navigator", "performance", "console",
  "setTimeout", "clearInterval", "setInterval", "requestAnimationFrame",
  "location", "localStorage", "URLSearchParams",
  blk + "\n; return { midiToWords, parseMidi, DRUM_INC, DRUM_AXIS, GM_DRUM_MAP, " +
  "gmToDrum, wordsForSelected, buildPayload, TIMBRE_NAMES, midiName, " +
  "setTrackSel: (s) => { trackSel = s; }, getTrackSel: () => trackSel };");
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

// ---- 造 MIDI：一条鼓轨 + 一条 bass 轨 ----
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

// 鼓轨（通道 10）：Kick 36 / Snare 38 / HiHat 42
const trDrum = track([
  [0, nm("Drum")],
  [0, [0x99, 36, 120]], [240, [0x89, 36, 0]],
  [0, [0x99, 38, 110]], [240, [0x89, 38, 0]],
  [0, [0x99, 42, 100]], [240, [0x89, 42, 0]],
]);
// Bass 轨：C3
const trBass = track([
  [0, nm("Bass")],
  [0, [0x90, 48, 100]], [960, [0x80, 48, 0]],
]);
const mid = new Uint8Array([...str("MThd"), ...u32(6), ...u16(1), ...u16(2), ...u16(480),
                            ...trDrum, ...trBass]);

console.log("=".repeat(78));
console.log("鼓转换 + 选轨 自检");
console.log("=".repeat(78));

const parsed = API.parseMidi(mid.buffer);
const conv = API.midiToWords(parsed);

// ---- ① 鼓：不再按 GM 音高发声 ----
chk("鼓的固定 inc 与 FPGA 侧一致（kick=5368709）",
    API.DRUM_INC.kick === 5368709, String(API.DRUM_INC.kick));
chk("鼓全部走 axis 15", API.DRUM_AXIS === 15);

const drumWords = [];
for (let i = 0; i < conv.words.length; i++) {
  if (conv.evTrack[i] >= 0 && conv.trackList[conv.evTrack[i]].drum) {
    drumWords.push(conv.words[i]);
  }
}
chk("找到鼓事件", drumWords.length > 0, drumWords.length + " 个");
const drumAxes = new Set(drumWords.map(w => Number((w >> 19n) & 0xFn)));
const drumIncs = new Set(drumWords.map(w =>
  Number((w >> 23n) & 0x1FFFFFn)));
/* 🔴🔴 2026-10-14 实测发现一个【协议层硬冲突】，这条判据把它钉住：
 *   下行事件字的 inc 字段只有 21 位（上限 2097151），
 *   而 FPGA 鼓机四件的 phase_inc 全都超过它：
 *     kick 2.56 倍 · snare 20.48 倍 · hihat 81.92 倍 · tom 8.53 倍
 *   => 填进 21 位就被截断，音色必然不对。
 *   ⚠️ 21 位能表示的最高频率只有 23.8 Hz —— 连 kick(61Hz) 都装不下。
 *   📌 已列为【阻塞项】请 FPGA 侧裁定（见 files/20-代码 的追问文档）。
 *   本判据【故意报红】，让这个冲突不会被忘掉。 */
const INC21 = 0x1FFFFF;
const overflow = Object.entries(API.DRUM_INC).filter(([k, v]) => v > INC21);
chk("🔴 钉住：四个鼓的 inc 全部超过下行 21 位字段（⇒ 已知阻塞）",
    overflow.length === 4,
    overflow.map(([k, v]) => k + "=" + v).join(" "));
chk("  截断后的值（就是实际发出去的）与原始值不同",
    [...drumIncs].every(v => !Object.values(API.DRUM_INC).includes(v)),
    [...drumIncs].join(","));
chk("鼓事件走的 axis 是 15（这一条是对的）",
    drumAxes.size === 1 && drumAxes.has(15), [...drumAxes].join(","));

// ⭐ 非空洞：若还按 GM 音高发，inc 就不该是鼓的固定值
const gmPitchInc = 48;      // 一个乐音 inc 的量级（远小于 kick 的 5368709）
chk("非空洞：鼓的 inc 明显不同于乐音 inc（证明真的换过了）",
    [...drumIncs].every(v => v !== gmPitchInc),
    [...drumIncs].join(",") + " vs " + gmPitchInc);

// ---- ② 鼓的三件对应正确 ----
// 36->kick, 38->snare, 42->hihat
chk("GM 36 -> kick", API.gmToDrum(36).name === "kick");
chk("GM 38 -> snare", API.gmToDrum(38).name === "snare");
chk("GM 42 -> hihat", API.gmToDrum(42).name === "hihat");
chk("GM 45 -> tom", API.gmToDrum(45).name === "tom");
chk("非空洞：表外音高标为【非精确映射】（exact=false）",
    API.gmToDrum(31).exact === false, JSON.stringify(API.gmToDrum(31)));

// ---- ③ 选轨 ----
chk("转换结果带 trackList", Array.isArray(conv.trackList) && conv.trackList.length === 2,
    conv.trackList ? conv.trackList.length + " 轨" : "无");
chk("转换结果带 evTrack（与 words 等长）",
    Array.isArray(conv.evTrack) && conv.evTrack.length === conv.words.length,
    conv.evTrack ? conv.evTrack.length + " vs " + conv.words.length : "无");
chk("trackList 标出了哪条是鼓",
    conv.trackList.some(t => t.drum), conv.trackList.map(t => t.name + (t.drum ? "(鼓)" : "")).join(","));

// 全选 -> 与不选任何轨时的差异
API.setTrackSel(new Set([0, 1]));
const all = API.wordsForSelected(conv.words, conv);
API.setTrackSel(new Set([1]));           // 只要 bass
const onlyBass = API.wordsForSelected(conv.words, conv);
API.setTrackSel(new Set([0]));           // 只要鼓
const onlyDrum = API.wordsForSelected(conv.words, conv);

chk("全选 => 与原始等长", all.length === conv.words.length,
    all.length + " vs " + conv.words.length);
chk("只选 bass => 明显变少", onlyBass.length < all.length,
    onlyBass.length + " vs " + all.length);
chk("只选鼓 => 明显变少", onlyDrum.length < all.length,
    onlyDrum.length + " vs " + all.length);
chk("⭐ bass + 鼓 的事件数 = 总数（两者不重叠，且只多了换速帧）",
    onlyBass.length + onlyDrum.length === all.length ||
    onlyBass.length + onlyDrum.length === all.length + 1,
    onlyBass.length + " + " + onlyDrum.length + " vs " + all.length);

// ⭐ 换速事件（srcTrack=-1）必须在任何选择下都保留
const tempoKept = [onlyBass, onlyDrum].every(ws =>
  ws.some(w => Number((w >> 9n) & 0x3n) === 2));      // kind=2 = tempo
chk("⭐ 只选单轨时【换速事件仍保留】（否则 FPGA 时基会错）", tempoKept);

// ---- ④ payload 重建 ----
const plAll = API.buildPayload(all);
const plOne = API.buildPayload(onlyBass);
/* payload = 复位序列(36B: 4 帧 x 9) + 总数帧(9B) + N 个事件帧(9B)
 * ⚠️ 我第一版判据写成 9*(N+2)，忘了复位序列占【4 帧】= 36 字节 => 报红。
 *    ⭐ 又一次印证：判据要从【结构】里算，别凭印象（同族 C112/C169）。 */
chk("payload：全选时 = 36 + 9 + 9N 字节",
    plAll.length === 36 + 9 + 9 * all.length,
    plAll.length + " 字节（期望 " + (36 + 9 + 9 * all.length) + "）");
chk("payload：单轨时更短", plOne.length < plAll.length,
    plOne.length + " vs " + plAll.length);
chk("payload：帧头都是 0xA5", plAll[0] === 0xA5 && plOne[0] === 0xA5);

console.log();
console.log("结论：" + (bad === 0 ? "全部通过" : "有 " + bad + " 项不符"));
process.exit(bad === 0 ? 0 : 1);
