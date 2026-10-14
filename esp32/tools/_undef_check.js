
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
const BUILTIN = new Set(("console window document navigator location performance fetch URL " +
  "URLSearchParams Blob TextDecoder TextEncoder ArrayBuffer DataView Uint8Array Int8Array " +
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
  const missing = new Map();     /* name -> 第一次出现的上下文 */
  for (const m of stripped.matchAll(/([A-Za-z_$][\w$]*)\s*\(/g)) {
    const name = m[1];
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
}

console.log();
console.log("结论：" + (bad === 0 ? "全部通过" : "有 " + bad + " 项不符"));
process.exit(bad === 0 ? 0 : 1);
