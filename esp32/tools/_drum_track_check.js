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
  blk + "\n; return { DRUM_VEL, drumNameOfInc, midiToWords, parseMidi, DRUM_INC, " +
  "isDrumAxis, DRUM_AXIS_OF, DRUM_AXIS_BASE, MELODY_AXIS_MAX, GM_DRUM_MAP, " +
  "gmToDrum, wordsForSelected, buildPayload, TIMBRE_NAMES, midiName, KIND_ON, KIND_OFF, " +
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
/* ⭐ 2026-10-14 口径更正（FPGA 侧第 3 版答复）：
 *   下行 inc 字段的语义是 `phase_inc >> 10`（高 21 位），⛔ 不是 `& 0x1FFFFF`。
 *   => ⭐ 四个鼓 >> 10 后【全部放得下】（5243/41943/167772/17476，上限 2097151）。
 *   🔴 我方原先那套"21 位装不下"的判据【整张作废】（前提错了）。
 *   真因另有其物：曲谱事件被打成 SRC_SCORE，而鼓池只认 SRC_AUX/SRC_KDRUM
 *   => 被当乐音 ⇒ 推成音高。⭐ 那要 FPGA 侧改（seq_arb 约 5 个 LUT）。 */
const FPGA_DRUM_TABLE = { kick: 5243, snare: 41943, hihat: 167772, tom: 17476 };
chk("⭐ 四个鼓的字段值与他们表格的 >>10 列一致",
    Object.entries(FPGA_DRUM_TABLE).every(([k, v]) => API.DRUM_INC[k] === v),
    JSON.stringify(API.DRUM_INC));
chk("⭐ 四个鼓的字段值全部放得进 21 位",
    Object.values(API.DRUM_INC).every(v => v <= 0x1FFFFF),
    Object.values(API.DRUM_INC).join(","));
/* ⭐ 2026-10-15 方案 B：四件鼓【各占一条轴】12/13/14/15（原为四件共用 15）。
 *   判据与 FPGA seq_arb.v:204 一致：axis >= 12 ⇒ 鼓。 */
chk("方案 B 口径：isDrumAxis(12) 真、isDrumAxis(11) 假",
    API.isDrumAxis(12) === true && API.isDrumAxis(11) === false);
chk("方案 B 口径：四件的轴 = 12/13/14/15",
    API.DRUM_AXIS_OF.kick === 12 && API.DRUM_AXIS_OF.snare === 13 &&
    API.DRUM_AXIS_OF.hihat === 14 && API.DRUM_AXIS_OF.tom === 15,
    JSON.stringify(API.DRUM_AXIS_OF));

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
/* ⭐ 2026-10-14 口径更正后：鼓事件里读回的 inc 应【正好等于】DRUM_INC 的值。
 *   （原判据假设"会被 21 位截断" —— 那是错的前提，已作废。） */
const wantIncs = new Set(Object.values(API.DRUM_INC));
chk("⭐ 鼓事件读回的 inc 正好是 DRUM_INC 的值（⛔ 没有被截断）",
    [...drumIncs].every(v => wantIncs.has(v)),
    [...drumIncs].join(",") + " vs " + [...wantIncs].join(","));
chk("⭐ 鼓事件的轴全部落在 12..15（方案 B：一件一轴）",
    drumAxes.size > 0 && [...drumAxes].every(a => API.isDrumAxis(a)),
    [...drumAxes].join(","));
/* ⭐ 非空洞性（比"落在 12..15"强得多）：**逐事件验"件 ↔ 轴"一一对应**。
 *   ⛔ 只验范围的话，"四件都塞到 12"也能通过 —— 那正是方案 B 要修掉的形态。
 *   ⚠️ 期望值必须钉【协议字面值】，⛔ 不能取 `API.DRUM_AXIS_OF`
 *      （那会和被测对象一起变 ⇒ 判据空转；同族 C88「真契约 vs 派生常量」）。 */
const DRUM_AXIS_PROTO = { kick: 12, snare: 13, hihat: 14, tom: 15 };
const incToAxis = {};
for (const [k, ax] of Object.entries(DRUM_AXIS_PROTO)) incToAxis[API.DRUM_INC[k]] = ax;
const badMap = [];
for (const w of drumWords) {
  const inc = Number((w >> 23n) & 0x1FFFFFn);
  const ax = Number((w >> 19n) & 0xFn);
  if (incToAxis[inc] !== ax) badMap.push(inc + "→轴" + ax + "(应 " + incToAxis[inc] + ")");
}
chk("非空洞：每条鼓事件的轴 = 协议表里该件的轴（inc↔axis 一一对应）",
    badMap.length === 0, badMap.join(",") || "全部对");
chk("非空洞：本测试曲用到的 3 件各占一条轴（12/13/14）",
    drumAxes.size === 3 && [12, 13, 14].every(a => drumAxes.has(a)), [...drumAxes].join(","));
chk("非空洞：鼓轴【不占】旋律段 0..11",
    [...drumAxes].every(a => a > API.MELODY_AXIS_MAX), [...drumAxes].join(","));

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

/* ---- ⭐ 鼓力度必须是【鼓机的固定力度】（2026-10-14 用户要求）----
 * 🔴 原来发 MIDI 原始力度（0..127），而鼓机生效值是 175..235
 *   ⇒ 灌谱的鼓只有鼓机的一半响，听着"没劲"。
 * ⚠️ 生效值 = drum_gen.v 默认 + top.v 实例化覆盖：
 *     KICK 230（未覆盖）· SNARE 235 · HIHAT 175 · TOM 220 */
console.log();
console.log("---- 鼓力度（必须与鼓机一致，⛔ 不是 MIDI 原始力度）----");
{
  const drumVels = new Set();
  drumWords.forEach((w, i) => {
    if (Number((w >> 9n) & 0x3n) !== API.KIND_ON) return;
    drumVels.add(Number((w >> 11n) & 0xFFn));
  });
  const want = Object.values(API.DRUM_VEL);
  /* ⚠️ 非空洞守卫：空集时 .every() 恒真 ⇒ 必须显式判"有样本"。
   * 🔴 我第一版就栽在这里：API.KIND_ON 没导出 ⇒ undefined ⇒ 全部事件被跳过
   *   ⇒ drumVels 空 ⇒ 判据假绿（"最小 Infinity" 就是破绽）。*/
  chk("非空洞：确实取到了鼓的 note_on 样本", drumVels.size > 0,
      drumVels.size + " 种力度值");
  chk("⭐ 鼓 note_on 的 vel 全部是鼓机的那四个常数",
      drumVels.size > 0 && [...drumVels].every(v => want.includes(v)),
      [...drumVels].sort((a, b) => a - b).join(",") + "  期望 " + want.join(","));
  chk("非空洞：鼓力度【高于】MIDI 原始力度上限 127（证明确实抬过）",
      drumVels.size > 0 && [...drumVels].every(v => v > 127),
      "最小 " + Math.min(...drumVels));
  chk("DRUM_VEL 四个值与 FPGA 生效值一致（230/235/175/220）",
      API.DRUM_VEL.kick === 230 && API.DRUM_VEL.snare === 235 &&
      API.DRUM_VEL.hihat === 175 && API.DRUM_VEL.tom === 220,
      JSON.stringify(API.DRUM_VEL));
  /* ⭐ 按件对应：kick 的事件必须是 230，hihat 必须是 175（⛔ 不能串）*/
  const byPiece = new Map();
  drumWords.forEach(w => {
    if (Number((w >> 9n) & 0x3n) !== API.KIND_ON) return;
    const k = API.drumNameOfInc(Number((w >> 23n) & 0x1FFFFFn));
    const v = Number((w >> 11n) & 0xFFn);
    if (k) { if (!byPiece.has(k)) byPiece.set(k, new Set()); byPiece.get(k).add(v); }
  });
  let pieceOk = true, detail = [];
  for (const [k, vs] of byPiece) {
    const okOne = vs.size === 1 && vs.has(API.DRUM_VEL[k]);
    if (!okOne) pieceOk = false;
    detail.push(k + "=" + [...vs].join("/"));
  }
  chk("⭐ 每件用的正是【它自己】的力度（⛔ 不串）", pieceOk, detail.join(" "));
}

console.log();
console.log("结论：" + (bad === 0 ? "全部通过" : "有 " + bad + " 项不符"));
process.exit(bad === 0 ? 0 : 1);
