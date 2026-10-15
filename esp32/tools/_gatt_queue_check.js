// _gatt_queue_check.js —— 枚举所有 GATT 出口，确认都走了串行队列
// ═══ 为什么必须有 ═══
// 🔴 用户实测（2026-10-14）：上传完点起播【第一次无日志、第二次报
//   `GATT operation already in progress`，两次都没真正起播】。
//   根因：起播/停止/清池三个按钮【直接 sendCmd，⛔ 没走 gattSerial】，
//   与 1.2 s 的轮询撞在同一瞬间 ⇒ 命令被丢弃。
// ⭐ 本自检枚举【所有】GATT 原语调用点（chXxx.write/read），
//   逐个判断前方 5 行内有没有 gattSerial —— ⛔ 漏一个就红。
const fs = require("fs");
const path = require("path");

let bad = 0;
function chk(name, cond, extra) {
  console.log("  " + name.padEnd(54) + (cond ? "OK" : "RED") + (extra ? "   " + extra : ""));
  if (!cond) bad++;
}

const FILES = ["score_studio.html", "upstream_studio.html", "link_test.html"];
/* GATT 原语（写/读/订阅）—— 这些是真正会与蓝牙栈交互的调用 */
const PRIM = /(chCmd|chStat|chRecv|chNotif|chNotify)\s*\.\s*(writeValueWithoutResponse|writeValue|readValue|startNotifications|stopNotifications)\s*\(/;

/* ⭐ 叶子函数：设计上【故意不自己入队】（否则与调用方自嵌套死锁）——
 * 由调用方包 gattSerial。判据要认这一点，⛔ 不能要求叶子自己入队。*/
/* ⚠️ 名字【按页面各不相同】：score_studio 用 readStat，link_test 用 stat
 *   ⇒ 白名单要含两者（⛔ 只列 readStat 会把 link_test 的 stat 误判成漏网）。*/
const LEAF = ["sendCmd", "readStat", "stat"];

for (const f of FILES) {
  const p2 = path.join(__dirname, f);
  if (!fs.existsSync(p2)) continue;
  const src = fs.readFileSync(p2, "utf8");
  const lines = src.split("\n");
  console.log("=".repeat(74));
  console.log(f);
  console.log("=".repeat(74));

  /* 先算每个叶子函数的行范围 */
  const leafRange = [];
  for (const name of LEAF) {
    const re = new RegExp("(async\\s+)?function\\s+" + name + "\\s*\\(");
    for (let i = 0; i < lines.length; i++) {
      if (!re.test(lines[i])) continue;
      /* 粗略找函数体结束：从这一行往下第一个行首是 } 的行 */
      let j = i + 1;
      for (; j < lines.length; j++) if (/^\}/.test(lines[j])) break;
      leafRange.push([i, j, name]);
      break;
    }
  }
  const inLeaf = (ln) => leafRange.some(([a, b]) => ln >= a && ln <= b);

  let hits = 0, bad1 = 0, bad2 = 0;
  for (let i = 0; i < lines.length; i++) {
    const c = lines[i].replace(/\/\/.*$/, "").trim();
    if (!PRIM.test(c)) continue;
    hits++;
    const ctx = lines.slice(Math.max(0, i - 5), i + 1).join("\n")
                       .replace(/\/\*[\s\S]*?\*\//g, " ")
                       .replace(/\/\/.*$/gm, " ");
    const queued = /gattSerial\s*\(/.test(ctx);
    const leaf = inLeaf(i);
    if (leaf) {
      console.log("  [叶子] L%-5d %s", i + 1, c.slice(0, 74));
    } else if (queued) {
      console.log("  [OK  ] L%-5d %s", i + 1, c.slice(0, 74));
    } else {
      console.log("  [🔴未入队] L%-5d %s", i + 1, c.slice(0, 74));
      bad1++;
    }
  }
  if (!hits) console.log("  （无 GATT 原语调用）");
  chk(f + "：非叶子的 GATT 原语都入队了", bad1 === 0,
      hits + " 处调用，其中未入队 " + bad1 + " 处");

  /* ⭐⭐ 最值钱的一条：叶子函数【只能被包了队列的调用方】调用。
   * 直接 `await sendCmd(...)` 就是漏网 —— 用户实测的 bug 正是这个形态。*/
  const direct = [];
  for (let i = 0; i < lines.length; i++) {
    const c = lines[i].replace(/\/\/.*$/, "");
    for (const name of LEAF) {
      const re = new RegExp("await\\s+" + name + "\\s*\\(");
      if (!re.test(c)) continue;
      if (inLeaf(i)) continue;                      /* 叶子内部互调不算 */
      const ctx = lines.slice(Math.max(0, i - 3), i + 1).join("\n")
                       .replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/.*$/gm, " ");
      if (!/gattSerial\s*\(/.test(ctx)) direct.push(i + 1);
    }
  }
  chk(f + "：叶子函数只被【入队的】调用方调用", direct.length === 0,
      direct.length ? ("裸调用的行号 " + direct.join(",")) : "无裸调用");
  console.log();
}

/* 额外：确认"按钮类"入口也入队（用户第一次点无日志 = 抛在 try 外之外又被吞） */
{
  const s = fs.readFileSync(path.join(__dirname, "score_studio.html"), "utf8");
  const btns = ["btnPlay", "btnStop", "btnClear", "btnConn"];
  for (const b of btns) {
    const m = s.match(new RegExp("\\$\\('" + b + "'\\)\\.onclick = ([^;]*);"));
    const body = m ? m[1] : "";
    const ok = /gattSerial/.test(body) || !/sendCmd|connect|disconnect/.test(body);
    chk(b + ".onclick 里若发 GATT 则必须入队", ok,
        body.replace(/\s+/g, " ").slice(0, 50));
  }
}

console.log();
console.log("结论：" + (bad === 0 ? "全部通过" : "有 " + bad + " 项不符"));
process.exit(bad === 0 ? 0 : 1);
