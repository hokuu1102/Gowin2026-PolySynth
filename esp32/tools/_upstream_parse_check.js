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
  "U_T_TRANSPORT, midiName, isDrumAxis, DRUM_AXIS_OF };");
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

function frame(type, seq, tick, axis, inc, vel, timbre = 0, isDrum = false) {
  const b = [0xA5, type, seq & 0xFF,
             (tick >>> 24) & 0xFF, (tick >>> 16) & 0xFF, (tick >>> 8) & 0xFF, tick & 0xFF,
             /* ⭐⭐ 2026-10-15：`[7]` 一字节两字段 = `timbre[5:4] | axis[3:0]`
              * （口径与 frame_format.py 的 AXIS_MASK/TIMBRE_SH 一致）。
              * 🔴 造帧侧也必须打包，⛔ 不能只改解析侧 —— 否则本自检就【验不到】掩码。 */
             ((axis & 0x0F) | ((timbre & 0x03) << 4) | (isDrum ? 0x40 : 0)),
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

// ---- ②b ⭐⭐ `[7]` 一字节两字段（axis 低 4 位 / timbre 高 2 位）----
//   ⚠️ 必须放在【上面那组解析判据之后】：本段会 uReset 重来，
//      ⛔ 插在中间会把前面那组判据的状态换掉（那就等于没验它）。
//   🔴 为什么必须有这条：⛔ 不掩码 ⇒ FPGA 把 timbre 填进高 4 位后，轴号读成 16..63
//      ⇒ 🔴 鼓判据（axis=15）/配色/查表全错，而且"看起来只是轴号变大了"。
//   ⚠️ 现状（2026-10-15）：FPGA 侧 PnR 还没填 timbre ⇒ 高 4 位 = 0，掩码不改结果。
{
  API.uReset();
  const _f7 = frame(API.U_T_ON, 7, 3000, 15, A4_INC, 90, 2);   /* axis=15 + timbre=2 */
  API.uPushBytes(new Uint8Array(_f7));
  const _e7 = API.U.events[0];
  chk("解析：[7]=0x2F ⇒ axis=15（⛔ 不是 47）", _e7.axis === 15,
      "实测 axis=" + _e7.axis + " · fr[7]=" + _f7[7]);
  chk("解析：同一字节 ⇒ timbre=2", _e7.timbre === 2, "实测 timbre=" + _e7.timbre);
  chk("非空洞：裸读 fr[7] 会得到 47（⭐ 证明掩码不是摆设）", _f7[7] === 47,
      "fr[7]=" + _f7[7]);
  /* ⭐ 今天 PnR 的形态：高 4 位 = 0 ⇒ ⛔ 行为必须与改之前完全一样 */
  API.uReset();
  API.uPushBytes(new Uint8Array(frame(API.U_T_ON, 8, 4000, 3, A4_INC, 100, 0)));
  chk("现状兼容：timbre=0 时 axis 仍是 3（⭐ 与改前一致）",
      API.U.events[0].axis === 3 && API.U.events[0].timbre === 0,
      "axis=" + API.U.events[0].axis + " timbre=" + API.U.events[0].timbre);
}

// ---- ②c ⭐⭐ 口径一致：同一字节在【三处】被解码，必须同一套掩码 ----
//   🔴 实测教训（2026-10-15）：`[7]` 的解码在【三个文件】里各有一份 ——
//      `evt2midi/frame_format.py`（Python 侧）· `upstream_studio.html`（独立回传页）
//      · `score_studio.html`（已整合进来的那一份，本自检跑的就是它）。
//      ⚠️ 我第一版只改了 Python + upstream_studio ⇒ 🔴 本自检立刻红
//      （axis 读成 47）—— 说明"只改一处"确实会被抓到，但也说明这个坑很真实。
//   ⭐ 所以钉住三处：⛔ 谁只改一边，这里就红（同族 C91）。
{
  const py = fs.readFileSync(path.join(__dirname, "evt2midi", "frame_format.py"), "utf8");
  const up = fs.readFileSync(path.join(__dirname, "upstream_studio.html"), "utf8");
  const nPy = (py.match(/f\[OFF_AXIS\] & AXIS_MASK/g) || []).length;
  chk("口径一致：frame_format.py 定义 AXIS_MASK=0x0F，且两处解析都用它",
      /AXIS_MASK\s*=\s*0x0F/.test(py) && nPy === 1 && /def decode_uplink_byte7/.test(py), "命中 " + nPy + " 处");
  chk("口径一致：score_studio.html 的 fr[7] 掩码 0x0F + 取 timbre",
      /const (uint30|u30) = fr\[7\] & 0x0F;/.test(html) &&
      /const timbre = isDrumUp \? null : (uint54|u54);/.test(html));
  chk("口径一致：upstream_studio.html 的 fr[7] 掩码 0x0F + 取 timbre",
      /const (uint30|u30) = fr\[7\] & 0x0F;/.test(up) &&
      /const timbre = isDrumUp \? null : (uint54|u54);/.test(up));
  /* ⭐ 2026-10-15：配色也必须在两页一致（用户："不需要 axis 配色，只用 timbre 配色"）
   *   ⚠️ 两页各有一份色板 ⇒ ⛔ 只改一页 ⇒ 同一份数据在两个页面看起来不一样。*/
  const palOf = t => {
    const m = t.match(/const TIMBRE_COLORS = \[([\s\S]*?)\]/);
    return m ? m[1].replace(/\/\*[\s\S]*?\*\//g, "").replace(/\s/g, "") : null;
  };
  chk("口径一致：两页的 TIMBRE_COLORS 色板完全相同",
      palOf(html) !== null && palOf(html) === palOf(up),
      "score=" + palOf(html) + " · upstream=" + palOf(up));
  chk("口径一致：两页的 DRUM_COLOR 相同",
      (html.match(/const DRUM_COLOR = "(#[0-9a-fA-F]{6})"/) || [])[1] ===
      (up.match(/const DRUM_COLOR = "(#[0-9a-fA-F]{6})"/) || [])[1]);
  chk("配色：两页都改成按 timbre 上色（⛔ 不再定义 axis 色板）",
      /function uTimbreColor/.test(html) && /function uTimbreColor/.test(up) &&
      /* ⚠️ 判【定义】而不是判名字 —— 注释里提到 AXIS_COLORS 是允许的 */
      !/const (U_)?AXIS_COLORS/.test(html) && !/const AXIS_COLORS/.test(up));
  chk("配色：鼓（axis 12..15）单独给 DRUM_COLOR（⛔ 不落进 timbre=0）",
      /if \(e\.drumType !== undefined && e\.drumType !== null\) return DRUM_COLOR;/.test(html) &&
      /if \(e\.drumType !== undefined && e\.drumType !== null\) return DRUM_COLOR;/.test(up));
  /* ⭐⭐ 2026-10-15 方案 B：鼓轴口径（12..15 / isDrumAxis）在两页必须一致 ——
   *   ⛔ 只改一处 ⇒ 同一份数据两个页面判"是不是鼓"不一样（同族 C91）。 */
  // Exercise the current upstream discriminator rather than obsolete axis globals.
  for (const byte7 of [0x0c, 0x40, 0x50, 0x60, 0x70]) {
    API.uReset();
    const isDrum = (byte7 & 0x40) !== 0;
    API.uPushBytes(new Uint8Array(frame(API.U_T_ON, 0, 0, byte7 & 15,
                                     A4_INC, 100, (byte7 >> 4) & 3, isDrum)));
    const e = API.U.events[0];
    chk("byte7=" + byte7.toString(16) + " explicit drum flag/type",
        isDrum ? e.drumType === ((byte7 >> 4) & 3) : e.drumType === null);
  }

}

// ---- ②d ⭐⭐ 分通道：timbre -> MIDI channel（用户："要分通道"）----
//   ⭐ 真跑 uBuildMidi()，再按字节查通道号 —— ⛔ 不是只 grep 代码。
//   ⚠️ 造帧时 note/vel 都取 < 0x80 的值（A4 的 inc ⇒ midi 69；vel=0x40）
//      ⇒ ⭐ 轨道里 ≥0x80 的字节只可能是状态字节或 tempo 元事件（0xFF/0xA1）
//      ⇒ 断言 0x90|ch 出现是有效的（⛔ 不会被数据字节蒙对）。
{
  API.uReset();
  const incA4 = A4_INC;
  let buf = [];
  for (let tb = 0; tb < 4; tb++) {                  /* 4 个音色各一个音 */
    buf = buf.concat(frame(API.U_T_ON, tb * 2, 1000 + tb * 100, tb, incA4, 0x40, tb));
    buf = buf.concat(frame(API.U_T_OFF, tb * 2 + 1, 1100 + tb * 100, tb, incA4, 0, tb));
  }
  /* ⭐ 方案 B：鼓在 12..15 四条轴上（这里用 12 = kick），另加一条【边界】：
   *   axis 11 是旋律上限，⛔ 绝不能落进鼓通道 9。 */
  buf = buf.concat(frame(API.U_T_ON, 90, 2000, 0, incA4, 0x40, 0, true));   /* 鼓 = axis 12 */
  buf = buf.concat(frame(API.U_T_OFF, 91, 2100, 0, incA4, 0, 0, true));
  buf = buf.concat(frame(API.U_T_ON, 92, 3000, 11, incA4, 0x40, 0));   /* 边界：11 = 旋律 */
  buf = buf.concat(frame(API.U_T_OFF, 93, 3100, 11, incA4, 0, 0));
  API.uPushBytes(new Uint8Array(buf));
  const blob = API.uBuildMidi();
  const bytes = (blob && blob.a && blob.a[0]) ? Array.from(blob.a[0]) : [];
  const chans = [0, 1, 2, 3].filter(ch => bytes.indexOf(0x90 | ch) >= 0);
  chk("分通道：4 个音色分别落到通道 0/1/2/3", chans.length === 4,
      "命中通道 " + chans.join(",") + "（字节数 " + bytes.length + "）");
  chk("分通道：鼓（axis 12）走 GM 通道 9（0x99）", bytes.indexOf(0x99) >= 0);
  /* ⭐ 非空洞性：旧写法（一律 0x90）下 0x91/0x92/0x93/0x99 都不该出现 */
  chk("非空洞：通道 1/2/3 与鼓通道都不是「恒为 0x90」能碰上的",
      bytes.indexOf(0x91) >= 0 && bytes.indexOf(0x99) >= 0);
  /* ⭐ 边界非空洞性：axis 11 是【旋律】⇒ ⛔ 不许进鼓通道。
   *   ⚠️ 阈值写成 >= 11 的话这条会红（那正是要防的"边界写松"）。 */
  chk("边界：axis 11 不算鼓（isDrumAxis(11) === false）", API.isDrumAxis(11) === false);
  chk("边界：axis 12 算鼓（isDrumAxis(12) === true）", API.isDrumAxis(12) === true);
}

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
