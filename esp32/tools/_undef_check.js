
const fs = require("fs");
const path = require("path");

let bad = 0;
function chk(name, cond, extra) {
  console.log("  " + name.padEnd(50) + (cond ? "OK" : "RED") + (extra ? "   " + extra : ""));
  if (!cond) bad++;
}

/* JS 关键字 + 语法形近词（上一版误报源，⛔ 全排掉）*/
const KEYWORDS = new Set(("if for while switch catch return typeof new function do else " +
  "await async of in var let const class delete void throw try finally yield import " +
  "export default case break continue this super extends instanceof").split(" "));
/* JS + 浏览器 + node 内置（按名字白名单，⛔ 不精确到签名）*/
const BUILTIN = new Set(("console window document navigator location performance fetch URL " +  "URLSearchParams Blob TextDecoder TextEncoder ArrayBuffer DataView Uint8Array Int8Array " +
  "Uint16Array Uint32Array Float32Array BigInt64Array Object Array Set Map WeakMap WeakSet " +
  "Math JSON Number String Boolean Symbol Date RegExp Error TypeError RangeError Promise " +
  "isNaN parseInt parseFloat encodeURIComponent decodeURIComponent structuredClone " +
  "BigInt isFinite Number.parseFloat Number.isFinite Number.isNaN " +
  "requestAnimationFrame cancelAnimationFrame setTimeout clearTimeout setInterval " +
  "clearInterval alert confirm prompt atob btoa escape unescape eval Intl").split(" "));

const FILES = ["score_studio.html", "upstream_studio.html", "link_test.html"];

console.log("=".repeat(76));
console.log("未定义函数引用自查（静态 + 精准：本轮 axisSwatchColor/gattSerial 那类）");
console.log("=".repeat(76));

for (const f of FILES) {
  const full = path.join(__dirname, f);
  if (!fs.existsSync(full)) { chk(f + " 存在", false); continue; }
  const html = fs.readFileSync(full, "utf8");
  const blocks = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
  if (!blocks.length) { chk(f + " 有 script 块", false); continue; }
  let code = blocks[0];

  /* ① 剥掉注释和字符串 —— ⛔ 不然注释里的词会被当成调用（误报源）*/
  const stripped = code
    .replace(/\/\*[\s\S]*?\*\//g, " ")
    .replace(/\/\/[^\n]*/g, " ")
    .replace(/`(?:\\.|[^`\\])*`/g, " `` ")
    .replace(/"(?:\\.|[^"\\\n])*"/g, ' "" ')
    .replace(/'(?:\\.|[^'\\\n])*'/g, " '' ");

  /* ② 收集本文件定义的顶层名字 */
  const defined = new Set();
  for (const m of stripped.matchAll(/\bfunction\s+([A-Za-z_$][\w$]*)/g)) defined.add(m[1]);
  /* ⚠️ 所有 const/let/var 声明都算已定义 —— ⛔ 不分顶层还是局部。
   * 🔴 上一版只收顶层，结果 link_test 里 `for (const rx of ...)` 的 rx 被误报。
   * ⭐ 代价是"深层局部量被当全局"（极少见），⛔ 不会造成恒红 —— 比恒红好。 */
  for (const m of stripped.matchAll(/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)/g)) defined.add(m[1]);
  for (const m of stripped.matchAll(/\bclass\s+([A-Za-z_$][\w$]*)/g)) defined.add(m[1]);
  /* 函数参数/解构的兜底：把这些也算"已定义"避免误报 */
  for (const m of stripped.matchAll(/\(([^)]*)\)\s*=>/g)) {
    for (const p of m[1].split(",")) {
      const t = p.trim().split("=")[0].trim();
      if (/^[A-Za-z_$][\w$]*$/.test(t)) defined.add(t);
    }
  }
  for (const m of stripped.matchAll(/function\s*[A-Za-z_$\w]*\s*\(([^)]*)\)/g)) {
    for (const p of m[1].split(",")) {
      const t = p.trim().split("=")[0].trim();
      if (/^[A-Za-z_$][\w$]*$/.test(t)) defined.add(t);
    }
  }

  /* ②b 对象字面量的键名 —— ⛔ 不是调用，加进 defined 避免误报
   * （上版把 link_test 的 `rx: bm ? +bm[1] : null` 里的 rx 误报成未定义）*/
  for (const m of stripped.matchAll(/([A-Za-z_$][\w$]*)\s*:/g)) defined.add(m[1]);

  /* ③ 找顶层调用 foo( ... ) */
  /* ⚠️ 只在【正则字面量里】出现、被误当成函数调用的名字（见下方过滤处的说明）*/
  const REGEX_WORDS = new Set(["rx", "tx", "drop", "pool", "sent", "ovf", "ring"]);
  const missing = new Map();     /* name -> 第一次出现的上下文 */
  for (const m of stripped.matchAll(/([A-Za-z_$][\w$]*)\s*\(/g)) {
    const name = m[1];
    /* ⚠️ 只在【正则字面量里】出现、被误当成函数调用的名字。
     * 2026-10-15：STAT 解析里有 /ble=rx(\d+)/ ⇒ `rx(` 被误报成未定义函数。
     * 🔴 为什么不改成"剥正则字面量"：试过 —— 剥得太激进会把真代码也吃掉
     *   ⇒ **判据失去非空洞性**（把 axisSwatchColor 改名后不再变红 = 判据废掉）。
     * ⭐ 教训：**"能失败"比"不误报"重要** ⇒ 宁可误报，不可失效。
     * ⚠️ 往这里加名字前必须确认它【只】出现在正则里，
     *   ⛔ 别把它当成"消除误报"的垃圾桶（那会悄悄降低覆盖率）。 */
    if (REGEX_WORDS.has(name)) continue;
    if (KEYWORDS.has(name) || BUILTIN.has(name) || defined.has(name)) continue;
    /* 前一个非空字符是 . 或 ?. 或 new => 成员/构造，跳过 */
    const before = stripped.slice(Math.max(0, m.index - 20), m.index);
    if (/\.\s*$/.test(before) || /\?\.\s*$/.test(before)) continue;
    if (/\bnew\s+$/.test(before)) continue;
    /* 前面是 function / async function => 声明自身 */
    if (/\bfunction\s+$/.test(before) || /\basync\s+function\s+$/.test(before)) continue;
    if (!missing.has(name)) missing.set(name, before.trim());
  }

  chk(f + " 无未定义的顶层函数引用", missing.size === 0,
      [...missing.keys()].slice(0, 6).join(","));

  /* ④ ⭐ 本轮那两类坑的专项 */
  const hasSerial = /function\s+gattSerial/.test(stripped);
  const nested = [];
  if (hasSerial) {
    for (const fn of ["async function sendCmd", "async function readStat"]) {
      const i = stripped.indexOf(fn);
      if (i < 0) continue;
      const j = stripped.indexOf("\n}", i);
      const body = stripped.slice(i, j < 0 ? i + 1200 : j);
      if (body.includes("gattSerial")) nested.push(fn.split(" ")[2]);
    }
  }
  chk(f + " sendCmd/readStat 不自嵌套", nested.length === 0, nested.join(","));

  /* ⑤ ⭐⭐ 2026-10-15 新增：处理器【越作用域】引用别的处理器的局部量。
   * 🔴 实测踩到（用户："缩放了之后好像不能拖动"）：mousemove 的拖动分支里写了
   *    `dx = px - dragX`，而 px 只在 wheel / click 处理器的局部声明过
   *    ⇒ 一按住拖动就 `ReferenceError: px is not defined` ⇒ 拖动【完全失效】。
   * ⚠️ 为什么 ①②③ 抓不到：它们只查【函数调用】，而且把全文件所有 const/let
   *    一律当成"已定义"（⛔ 不分作用域）⇒ "变量越作用域"是盲区。
   * ⭐ 本检查只比【顶层处理器的局部量】：模块级名字不受限（闭包正常用法），
   *    ⛔ 不做通用作用域分析（那会误报成灾）。
   * ⚠️ "顶层"用【语句顶格】判定：处理器的行首到匹配点之间 ⛔ 不允许出现空白
   *    （有缩进 = 嵌在函数里，那时用外层函数的局部量是合法闭包）。
   *    缩进的那些只是不查（宁可漏报，不可误报）。
   * ⚠️ 名字从 `stripped` 取 —— 它把字符串换成了 `""`，所以事件名只剩空串，
   *    处理器只能用序号标注（⛔ 别去用 raw 的偏移量对齐：剥注释后位置已经变了）。*/
  const hs = [];
  const HPATS = [
    /addEventListener\(\s*""\s*,\s*(?:async\s*)?(?:\(([^)]*)\)|([A-Za-z_$][\w$]*))\s*=>\s*\{/g,
    /\.onclick\s*=\s*(?:async\s*)?(?:\(([^)]*)\)|([A-Za-z_$][\w$]*))\s*=>\s*\{/g,
  ];
  for (const reH of HPATS) {
    let hm;
    while ((hm = reH.exec(stripped))) {
      const lineStart = stripped.lastIndexOf("\n", hm.index) + 1;
      /* 🔴 第一版写成 `hm.index !== lineStart` ⇒ 因为都写作 `cv.addEventListener`
       *    而把【全部】处理器跳过 ⇒ 判据空转恒绿（差点当成"通过"收工）。*/
      if (/^\s/.test(stripped.slice(lineStart, hm.index))) continue;
      const bodyStart = hm.index + hm[0].length;
      let depth = 1, i = bodyStart;
      while (i < stripped.length && depth > 0) {
        const c = stripped[i];
        if (c === "{") depth++;
        else if (c === "}") depth--;
        i++;
      }
      const body = stripped.slice(bodyStart, i - 1);
      const locals = new Set();
      for (const m of body.matchAll(/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)/g)) locals.add(m[1]);
      /* catch (e) 的 e 也是局部量 —— ⛔ 漏掉它就会把 catch 参数误报成"越作用域" */
      for (const m of body.matchAll(/\bcatch\s*\(\s*([A-Za-z_$][\w$]*)/g)) locals.add(m[1]);
      if (hm[1]) for (const p of hm[1].split(",")) {
        const t = p.trim().split("=")[0].trim();
        if (/^[A-Za-z_$][\w$]*$/.test(t)) locals.add(t);
      }
      if (hm[2]) locals.add(hm[2]);
      hs.push({ label: "处理器#" + (hs.length + 1), locals, body, start: hm.index, end: i });
    }
  }
  /* 模块级（不在任何顶层处理器区间内）声明的名字 —— 闭包用它合法 */
  const modLevel = new Set();
  for (const m of stripped.matchAll(/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)/g)) {
    if (!hs.some(h => m.index > h.start && m.index < h.end)) modLevel.add(m[1]);
  }
  const leaks = [];
  for (const H of hs) {
    for (const O of hs) {
      if (O === H) continue;
      for (const name of O.locals) {
        if (H.locals.has(name) || modLevel.has(name)) continue;
        const reUse = new RegExp("(?<![.\\w$])" + name + "\\b(?!\\s*:)");
        if (reUse.test(H.body)) leaks.push(H.label + " 用了 " + O.label + " 的局部量 " + name);
      }
    }
  }
  /* ⭐ 防空转：采集不到处理器 ⇒ 下面的判据是恒绿的（这正是第一版踩的坑：
   *    采集正则写错 ⇒ 一个都没收到 ⇒ 判据报 OK ⇒ 差点当成"通过"收工）。
   * ⚠️ 期望值按文件写死（下界）：link_test.html 的处理器全都嵌在函数里（缩进）
   *    ⇒ 按设计就是 0 个，⛔ 不能要求它 ≥1（否则恒红）。
   * ⛔ 若这里变红：先怀疑【采集逻辑坏了】，别急着调低期望值。*/
  const EXPECT_H = { "score_studio.html": 8, "upstream_studio.html": 2, "link_test.html": 0 };
  chk(f + " 顶层处理器采集数 " + hs.length + "（期望 ≥ " + (EXPECT_H[f] || 0) + "）",
      hs.length >= (EXPECT_H[f] || 0));
  chk(f + " 处理器不越作用域引用别的处理器的局部量", leaks.length === 0,
      leaks.slice(0, 3).join(" | "));
}

console.log();
console.log("结论：" + (bad === 0 ? "全部通过" : "有 " + bad + " 项不符"));
process.exit(bad === 0 ? 0 : 1);
