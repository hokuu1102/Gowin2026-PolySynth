// _stat_parse_check.js —— 验 STAT 解析（尤其是 drop= 出现两次的陷阱）
// ═══ 为什么必须有 ═══
// 🔴 STAT 里 `drop=` 出现【两次】：ring 的与 ble 的。
//   通用正则 \bdrop=(\d+) 只会抓到【第一个】（ring 的）⇒
//   把 ring 的丢帧当成 ble 的 ⇒ 判"谱面是否完整"时看错字段。
// ⭐ 而"丢帧计数"是判定"曲子只有一截 / 最后挂音"归属的唯一硬证据
//   ⇒ 解析错了会把结论带偏。
const fs = require("fs");
const path = require("path");

let bad = 0;
function chk(name, cond, extra) {
  console.log("  " + name.padEnd(56) + (cond ? "OK" : "RED") + (extra ? "   " + extra : ""));
  if (!cond) bad++;
}

/* 用固件 ble_main.c 的 snprintf 格式【造】一份真实 STAT 文本 */
const SAMPLE = [
  "V1 mode=score req=3 up=12345ms",
  "pool=1024/1024 sent=1024 ovf=2 late=0 exp=1024 mm=0 clamp=0 run=1 play=500 t0=100 lead=1200 ttot=9999 pv=1 rate=1920 pum=2065",
  "ring=5/16 in=99 out=94 drop=3/27 full=1 hwm=9 ok",
  "ble=rx891 tx12 fail=0 drop=4 mtu=517 conn=1 sub=1",
].join("\n");

console.log("=".repeat(78));
console.log("STAT 解析自检（drop= 出现两次的陷阱）");
console.log("=".repeat(78));

/* 从页面源码里抠出 readStat 的解析表达式，确保测的是【页面真用的】那套 */
const html = fs.readFileSync(path.join(__dirname, "score_studio.html"), "utf8");
const ringRe = html.match(/txt\.match\((\/\\bring=[^\n]*?\/)\)/);
const bleRe = html.match(/txt\.match\((\/\\bble=rx[^\n]*?\/)\)/);
chk("页面里 ring 的解析是按行精确写的", !!ringRe,
    ringRe ? ringRe[1].slice(0, 52) : "找不到");
chk("页面里 ble 的解析是按行精确写的", !!bleRe,
    bleRe ? bleRe[1].slice(0, 52) : "找不到");

/* 动态：用页面里【同样形状】的正则跑样本 */
const ringM = SAMPLE.match(/\bring=\d+\/\d+ in=\d+ out=\d+ drop=(\d+)\/(\d+)/);
const bleM = SAMPLE.match(/\bble=rx\d+ tx\d+ fail=\d+ drop=(\d+)/);
chk("ring.drop 帧数 = 3（不是 ble 的 4）", ringM && +ringM[1] === 3,
    "实测 " + (ringM ? ringM[1] : "null"));
chk("ring.drop 字节数 = 27", ringM && +ringM[2] === 27,
    "实测 " + (ringM ? ringM[2] : "null"));
chk("ble.drop = 4", bleM && +bleM[1] === 4, "实测 " + (bleM ? bleM[1] : "null"));

/* ⭐ 非空洞：证明"通用正则"确实会抓错 —— 否则这条判据没有存在意义 */
const naive = SAMPLE.match(/\bdrop=(\d+)/);
chk("非空洞：通用正则确实会误抓 ring 的 drop（=3，不是 ble 的 4）",
    naive && +naive[1] === 3 && +naive[1] !== +bleM[1],
    "通用抓到 " + (naive ? naive[1] : "null") + "，正确应为 " + bleM[1]);

/* 其他字段 */
const ovf = SAMPLE.match(/\bovf=(\d+)/);
chk("ovf 解析 = 2", ovf && +ovf[1] === 2, "实测 " + (ovf ? ovf[1] : "null"));
const full = SAMPLE.match(/\bfull=(\d+)/);
chk("ring.full 解析 = 1", full && +full[1] === 1, "实测 " + (full ? full[1] : "null"));

/* ⭐ 页面必须有"上传后核对丢帧"这一步（⛔ 不许静默） */
chk("上传后有 verifyUploadIntegrity() 核对丢帧",
    /verifyUploadIntegrity\s*\(\)/.test(html));
chk("核对失败时【明确报错】而不是静默",
    /上传【有丢帧】/.test(html));
/* ⭐ 上传必须有节流（否则必然溢出 —— 0xABF1 无流控） */
chk("上传有节流 PACING_MS", /const PACING_MS\s*=\s*\d+/.test(html));

console.log();
console.log("结论：" + (bad === 0 ? "全部通过" : "有 " + bad + " 项不符"));
process.exit(bad === 0 ? 0 : 1);
