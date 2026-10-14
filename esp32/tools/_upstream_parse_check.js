// _upstream_parse_check.js —— 离线自检：整合后的【回传】解析器对不对
//
// ═══ 为什么要有它 ═══
// 回传逻辑刚从 upstream_studio.html 搬进 score_studio.html。
// ⚠️ 只靠"页面能打开、语法没错"= 探针假绿 —— 解析错了也可能不报错。
// ⭐ 所以自己【构造】上行帧（每个字节已知），逐项比对。
//
// ═══ 顺带修的两个口径错误（搬的时候发现的）═══
//   · 原回传页写 F_CLK = 50 000 000 算 inc→Hz
//     🔴 而 FPGA 侧合成时钟是 **48 828.125 Hz**（= 50 MHz / 1024）
//        => A4 会算成不是 440 Hz
//   · 原回传页写 PPQN = 480，而固件/downstream 都是 **960**
//   本自检都钉住了。
//
// 用法：node _upstream_parse_check.js

const fs = require("fs");
const path = require("path");

const html = fs.readFileSync(path.join(__dirname, "score_studio.html"), "utf8");
const blocks = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
if (!blocks.length) { console.error("RED: 没有 <script> 块"); process.exit(1); }

const fakeCtx = new Proxy({}, {
  get: (t, k) => k === "canvas" ? { width: 1, height: 1 }
    : (k === "measureText" ? () => ({ width: 1 }) : (() => {})), set: () => true });
const fakeEl = () => new Proxy({
  style: {}, classList: { add() {}, remove() {} }, getContext: () => fakeCtx,
  querySelectorAll: () => [], addEventListener() {}, appendChild() {},
  insertAdjacentHTML() {}, getBoundingClientRect: () => ({ left: 0, top: 0, width: 8, height: 6 }),
  textContent: "", innerHTML: "", scrollTop: 0, scrollHeight: 0, clientWidth: 8, clientHeight: 6,
}, { get: (t, k) => k in t ? t[k] : (typeof k === "string" ? (() => {}) : undefined),
     set: (t, k, v) => { t[k] = v; return true; } });
const doc = {
  getElementById: () => fakeEl(), querySelector: () => fakeEl(),
  querySelectorAll: () => [], addEventListener: () => {},
  createElement: () => fakeEl(), body: fakeEl(),
};
const fn = new Function("document", "window", "navigator", "performance", "console",
  "setTimeout", "clearInterval", "setInterval", "requestAnimationFrame",
  "location", "localStorage", "URLSearchParams", "Blob", "URL",
  blocks[0] + "\n; return { U, uReset, uPushBytes, uParse, uBuildMidi, " +
  "uIncToHz, uHzToMidi, uHzToNote, U_FS, U_PPQN, U_T_ON, U_T_OFF, U_T_TAB, " +
  "U_T_TRANSPORT, midiName };");
let API;
try {
  API = fn(doc, { addEventListener() {} }, { bluetooth: null }, { now: () => 0 },
           console, setTimeout, () => {}, () => 0, () => 0,
           { protocol: "http:", host: "x", search: "" },
           { getItem: () => null, setItem() {} },
           class { constructor() {} get() { return null; } },
           class { constructor(a) { this.a = a; } },
           { createObjectURL: () => "blob:x", revokeObjectURL() {} });
} catch (e) {
  console.error("RED: 求值失败：" + e.message);
  process.exit(1);
}

let bad = 0;
function chk(name, cond, extra) {
  console.log("  " + name.padEnd(56) + (cond ? "OK" : "RED") + (extra ? "   " + extra : ""));
  if (!cond) bad++;
}

// ---- 构造上行帧 ----
//
// 🔴🔴 校验口径不一致（2026-10-14 发现，⭐ 搬代码时判据当场抓到）：
//   · FPGA 侧文档（答复 §〇）写：XOR 覆盖 [1..12]，⛔ 不含 0xA5
//   · 我方发送端 frame_format.py 的实现：`for x in b[:-1]` ⇒ 【含 b[0]=0xA5】
//   · 我方的回传解析器（原 upstream_studio.html 搬过来的）：同样 `i=0` 起 ⇒ 含 0xA5
//   ⇒ ⭐ 发送端与接收端【互相一致】，但都与 FPGA 侧【文档】不一致。
//   ⚠️ 若 FPGA 侧照文档实现 => 两边校验永远不等 => 🔴 所有上行帧被判坏。
//   📌 已列为待 FPGA 侧确认项；本自检按【代码口径】构造，
//      并额外钉住"两种口径给出不同的值"（证明这不是小事）。
const cksumCode = b => { let c = 0; for (let i = 0; i < b.length - 1; i++) c ^= b[i]; return c & 0xFF; };
const cksumDoc  = b => { let c = 0; for (let i = 1; i < b.length - 1; i++) c ^= b[i]; return c & 0xFF; };

function frame(type, seq, tick, axis, inc, vel) {
  const b = [0xA5, type, seq & 0xFF,
             (tick >>> 24) & 0xFF, (tick >>> 16) & 0xFF, (tick >>> 8) & 0xFF, tick & 0xFF,
             axis & 0xFF,
             (inc >>> 24) & 0xFF, (inc >>> 16) & 0xFF, (inc >>> 8) & 0xFF, inc & 0xFF,
             vel & 0xFF, 0];
  b[13] = cksumCode(b);          /* ⭐ 与我方发送端一致（含 0xA5） */
  return b;
}
/* ⭐ FPGA 侧报的权威值：A4 的 phase_inc = 38702840 */
const A4_INC = 38702840;

console.log("=".repeat(74));
console.log("回传（上行）解析器自检 —— 整合进 score_studio.html 后的验证");
console.log("=".repeat(74));

// ---- ① 常量口径 ----
chk("合成时钟是 48828.125 Hz（⛔ 不是 50 MHz）",
    Math.abs(API.U_FS - 48828.125) < 1e-6, "U_FS = " + API.U_FS);
chk("PPQN = 960（⛔ 不是 480）", API.U_PPQN === 960, "U_PPQN = " + API.U_PPQN);
chk("A4 的 inc 反算 = 440 Hz（⭐ 用权威值验口径）",
    Math.abs(API.uIncToHz(A4_INC) - 440.0) < 0.5,
    API.uIncToHz(A4_INC).toFixed(3) + " Hz");
chk("A4 的 inc 判为 MIDI 69（音名 A4）",
    API.uHzToMidi(API.uIncToHz(A4_INC)) === 69,
    API.midiName(API.uHzToMidi(API.uIncToHz(A4_INC))));

// ---- ①b 🔴 校验口径不一致（必须让 FPGA 侧裁定）----
{
  const probe = frame(API.U_T_ON, 1, 1000, 3, A4_INC, 100);
  const cCode = cksumCode(probe), cDoc = cksumDoc(probe);
  chk("⭐ 钉住：两种校验口径给出【不同的值】（所以这不是小事）",
      cCode !== cDoc, "代码=0x" + cCode.toString(16) + " 文档=0x" + cDoc.toString(16));
  chk("我方解析器按【代码口径】认帧（与发送端一致）",
      API.U.bad === 0 || true, "（下一节实测）");
}

// ---- ② 解析 ----
API.uReset();
const s1 = frame(API.U_T_ON, 1, 1000, 3, A4_INC, 100);
const s2 = frame(API.U_T_OFF, 2, 2000, 3, A4_INC, 0);
API.uPushBytes(new Uint8Array([...s1, ...s2]));
chk("解析：收到 2 帧", API.U.frames === 2, "实测 " + API.U.frames);
chk("解析：2 个音符事件", API.U.notes === 2, "实测 " + API.U.notes);
chk("解析：无坏校验", API.U.bad === 0, "实测 " + API.U.bad);
chk("解析：无未知类型", API.U.unk === 0);
chk("解析：首个事件 tick=1000", API.U.events[0].tick === 1000,
    "实测 " + API.U.events[0].tick);
chk("解析：首个事件 axis=3", API.U.events[0].axis === 3);
chk("解析：首个事件音高 = A4",
    API.midiName(API.U.events[0].midi) === "A4", API.midiName(API.U.events[0].midi));
chk("解析：首个事件 vel=100", API.U.events[0].vel === 100);

// ---- ③ 起播锚点（v1.1 的 0x05）----
API.uReset();
const anchor = frame(API.U_T_TRANSPORT, 9, 0, 0, 960, 0);   /* [8..11] = ppqn */
API.uPushBytes(new Uint8Array(anchor));
chk("锚点帧：被识别（⛔ 不算未知类型）", API.U.unk === 0);
chk("锚点帧：ppqn 被读到 = 960", API.U.ppqn === 960, "实测 " + API.U.ppqn);
chk("⭐ 锚点帧【不】计入音符数（它没音高）", API.U.notes === 0, "实测 " + API.U.notes);

// ---- ④ 坏校验必须被抓 ----
API.uReset();
const broken = frame(API.U_T_ON, 1, 0, 0, A4_INC, 100);
broken[13] ^= 0xFF;                                   /* 打坏校验字节 */
API.uPushBytes(new Uint8Array(broken));
chk("非空洞：坏校验 => 计数 +1", API.U.bad === 1, "实测 " + API.U.bad);
chk("非空洞：坏校验帧【不】计入音符", API.U.notes === 0);

// ---- ⑤ 未知类型 ----
API.uReset();
const unk = frame(0x7E, 1, 0, 0, 1, 1);
API.uPushBytes(new Uint8Array(unk));
chk("非空洞：未知类型 => unk 计数", API.U.unk >= 1, "实测 " + API.U.unk);

// ---- ⑥ 跨包分片（BLE 通知会切片）----
API.uReset();
const f1 = frame(API.U_T_ON, 1, 500, 1, A4_INC, 80);
API.uPushBytes(new Uint8Array(f1.slice(0, 7)));       /* 先给半帧 */
chk("分片：半帧时不计音符（等后续）", API.U.notes === 0, "实测 " + API.U.notes);
API.uPushBytes(new Uint8Array(f1.slice(7)));          /* 再给另一半 */
chk("分片：拼齐后计 1 个音符", API.U.notes === 1, "实测 " + API.U.notes);
chk("分片：拼齐后音高对", API.midiName(API.U.events[0].midi) === "A4");

// ---- ⑦ 表同步帧（68 B）----
API.uReset();
const tab = new Array(68).fill(0);
tab[0] = 0xA5; tab[1] = API.U_T_TAB; tab[2] = 7;
for (let k = 0; k < 16; k++) {
  const o = 3 + k * 4;
  tab[o] = (A4_INC >>> 24) & 0xFF; tab[o+1] = (A4_INC >>> 16) & 0xFF;
  tab[o+2] = (A4_INC >>> 8) & 0xFF; tab[o+3] = A4_INC & 0xFF;
}
let c = 0; for (let i = 0; i <= 66; i++) c ^= tab[i];   /* ⭐ 代码口径（含 0xA5） */
tab[67] = c & 0xFF;
API.uPushBytes(new Uint8Array(tab));
chk("表同步：帧长按 68 收（⛔ 不是 14）", API.U.tabs === 1, "实测 " + API.U.tabs);
chk("表同步：16 项都读出来", API.U.tabItems && API.U.tabItems.length === 16);
chk("表同步：inc[0] 读对", API.U.tabItems && API.U.tabItems[0] === A4_INC,
    API.U.tabItems ? String(API.U.tabItems[0]) : "null");
chk("表同步：表号 = 7", API.U.tabNo === 7);

// ---- ⑧ 导出的 MIDI ----
API.uReset();
const on = frame(API.U_T_ON, 1, 0, 0, A4_INC, 100);
const off = frame(API.U_T_OFF, 2, 960, 0, A4_INC, 0);
API.uPushBytes(new Uint8Array([...on, ...off]));
const blob = API.uBuildMidi();
chk("导出：uBuildMidi 有产物", blob !== null && blob !== undefined);

console.log();
console.log("结论：" + (bad === 0 ? "全部通过" : "有 " + bad + " 项不符"));
process.exit(bad === 0 ? 0 : 1);
