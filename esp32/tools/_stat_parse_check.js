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
chk("上传后挂标记、由轮询复用那次读来核对（不额外发 GATT）",
    /pendingIntegrityCheck\s*=\s*true/.test(html) &&
    /checkIntegrityFromStat\(st\)/.test(html));
chk("核对函数是【纯判读】、自己不读（否则会挂住 -> 浏览器永久卡住）",
    /function checkIntegrityFromStat\(st\)/.test(html) &&
    !/async function checkIntegrityFromStat/.test(html));
/* ⭐⭐ 2026-10-14 最值钱的一条：轮询必须【不超时】。
 * 看门狗到点会解除 pollInFlight => 下一次轮询又发一个读（前一个还在飞）
 *   => already in progress => 浏览器永久卡住（用户实测 14:41:59）。
 * 不超时 + pollInFlight => 同一时刻最多一个读在飞 => 结构上不可能堆积。*/
chk("轮询用【不超时】的 gattSerial（第二个参数 0）",
    /gattSerial\(\(\) => readStat\(\), 0\)/.test(html));
chk("gattSerial 支持按调用关掉看门狗",
    /function gattSerial\(fn, timeoutMs\)/.test(html) &&
    /if \(!tmo\) return await fn\(\)/.test(html));
chk("上传后【不自动】恢复轮询（起播后才恢复）",
    !/if \(connected\) startPoll\(POLL_RESUME_DELAY_MS\)/.test(html));
/* 2026-10-15：notify 已订阅时，轮询不许主动读。
 * 症状（用户实测）："起播之后要等十几秒才能出声"。
 * 根因：pollOnce 无条件调 readStat()（主动读），而主动读在 ESP32 忙时挂住
 *   => 起播命令排在同一队列的它后面 => 十几秒后才发出。
 * 修法：notify 是自动推的 => 订阅成功就 return，队列里只剩用户命令。 */
{
  const i = html.indexOf("async function pollOnce");
  const j = html.indexOf("if (pollInFlight) return;", i);
  const head = (i >= 0 && j > i) ? html.slice(i, j) : "";
  chk("notify 已订阅时轮询不主动读（否则起播排在读后面）",
      /if \(statNotifyOk\) return;/.test(head));
  chk("非空洞：pollOnce 里确实有 pollInFlight 守卫（证明切片位置对）",
      j > i);
}
/* 2026-10-15：核对前必须【等在途排空】。
 * 症状（用户实测）：上传完立刻核对，报"少 860 帧（4.5%）"，
 *   而 860 x 9 = 7740 字节 ≈ 窗口大小 8 KB ⇒ ⭐ 那不是丢帧，是还在途。
 * 修法：等 fcSent - fcAcked 归零（最多 5 秒）再核对；超时要【报出来】。 */
chk("核对前等在途排空（否则把在途误报成丢帧）",
    /在途已排空/.test(html) && /等待排空超时/.test(html));
/* 2026-10-15：上传中必须禁用「起播」「清池」。
 * 症状（用户实测）：上传中途按起播 => 池里只有 12581 / 16041 帧
 *   => ESP32 报 TOTAL MISMATCH (diff -3406) => 谱面不完整。
 * 根因不在 ESP32 —— 是 UI 允许了中途起播。
 * 教训：按钮的 disabled 要覆盖【所有会被破坏的操作】，
 *   只禁用"发起者"（上传按钮）是不够的。 */
chk("上传中禁用起播/清池（禁与放要成对）",
    /btnPlay"\)\.disabled = true/.test(html) &&
    /btnClear"\)\.disabled = true/.test(html) &&
    /btnPlay"\)\.disabled = false/.test(html) &&
    /btnClear"\)\.disabled = false/.test(html));
chk("起播动作本身也守卫 uploading（防其它路径触发）",
    /if \(uploading\) \{/.test(html) && /请等上传完成再起播/.test(html));
chk("有 GATT 卡死检测与重连指引",
    /gattWedged/.test(html) && /already in progress/.test(html));

/* ⭐⭐ 2026-10-15 最贵的一条教训：`ble=rxN` 是【自开机累计】的。
 * 🔴 症状：用户实测 "已发 75 KB · ESP32 实收 240 KB · 在途 -166 KB"
 *   ⇒ 实收比已发还多、在途算成负数 ⇒ `在途 > 窗口` 永远不成立
 *   ⇒ ⭐ **流控彻底失效** ⇒ 全速冲 ⇒ 丢帧 ⇒ 放不出来。
 * ⭐ 修法：本次上传记基线，只用增量（并夹到 ≥ 0，防清池清零）。
 * ⚠️ 判据必须钉住【减基线】这一步 —— 直接赋值 `fcAcked = st.bleRx` 就是 bug。 */
chk("⭐ 流控用【增量】而不是累计值（fcAcked = bleRx - 基线）",
    /fcAcked\s*=\s*Math\.max\(0,\s*st\.bleRx\s*-\s*fcAckedBase\)/.test(html));
chk("⭐ 上传前记下累计值基线（fcAckedBase = lastBleRx）",
    /fcAckedBase\s*=\s*lastBleRx/.test(html));
chk("非空洞：确实没有直接拿累计值当增量用",
    !/fcAcked\s*=\s*st\.bleRx\s*;/.test(html));

/* ⭐ ev/tf 帧数核对必须存在，且解析不到时【要喊】而不是静默跳过（0.12）。 */
chk("有 ev/tf 帧数核对（判谱面收齐没有）",
    /frameEv/.test(html) && /frameTf/.test(html) && /帧数核对通过/.test(html));
chk("⭐ ev/tf 解析不到时【明确报错】而不是静默跳过",
    /没解析到帧数/.test(html));
chk("核对失败时【明确报错】而不是静默",
    /上传【有丢帧】/.test(html));
/* ⭐ 上传必须有节流（否则必然溢出 —— 0xABF1 无流控）。
 * ⚠️ 2026-10-15：值可能是三元表达式（诊断开关），所以只要求"有定义"，
 *   ⛔ 不要求右边是字面数字。 */
chk("上传有节流 PACING_MS", /const PACING_MS\s*=/.test(html));
/* 进度条三件套必须在循环里（我改节流时把它们整段吃掉了，用户实测"没有进度条"）。
 * 判据：三个赋值都出现在 while 循环体内。 */
{
  const iWhile = html.indexOf("while (sent < total)");
  const iEnd = html.indexOf("上传完成", iWhile);
  const body = (iWhile >= 0 && iEnd > iWhile) ? html.slice(iWhile, iEnd) : "";
  chk("上传循环里有进度条（宽度/文本/速率）",
      /\$\("pb"\)\.style\.width/.test(body) &&
      /pbTxt/.test(body) && /pbRate/.test(body));
}

console.log();
console.log("结论：" + (bad === 0 ? "全部通过" : "有 " + bad + " 项不符"));
process.exit(bad === 0 ? 0 : 1);
