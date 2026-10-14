// _deadlock_check.js —— 离线验证：gattSerial 队列不会自嵌套死锁
const fs = require("fs");
const path = require("path");
const html = fs.readFileSync(path.join(__dirname, "score_studio.html"), "utf8");
const blk = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1])[0];

let bad = 0;
function chk(name, cond, extra) {
  console.log("  " + name.padEnd(56) + (cond ? "OK" : "RED") + (extra ? "   " + extra : ""));
  if (!cond) bad++;
}

console.log("=".repeat(78));
console.log("gattSerial 死锁自检（用户报告：一键上传卡在 BLE 这块）");
console.log("=".repeat(78));

// ---- ① 静态检查：叶子函数不许入队 ----
const fnBody = (name) => {
  const i = blk.indexOf(name);
  if (i < 0) return null;
  // 找到函数体结束（取到下一个 "async function" 或固定长度）
  const j = blk.indexOf("\n}", i);
  return blk.slice(i, j < 0 ? i + 2000 : j);
};
/* ⚠️ 判据必须【剥掉注释】再判 —— 我第一版没剥，
 * 而 readStat 的注释里恰好写了"不要在此处入队" ⇒ 误报红（踩过：C157 同族）。 */
const strip = (t) => t.replace(/\/\*[\s\S]*?\*\//g, "");
for (const fn of ["async function sendCmd", "async function readStat"]) {
  const body = fnBody(fn);
  const code = body === null ? "" : strip(body);
  chk("⭐ " + fn.split(" ")[2] + " 代码里【不】再入队（注释不算）",
      code.indexOf("gattSerial") < 0,
      code.indexOf("gattSerial") >= 0 ? "仍在入队!" : "干净");
}

// ---- ② 用真实的 gattSerial 源码做动态验证 ----
const q = blk.slice(blk.indexOf("let gattQueue = Promise.resolve();"),
                    blk.indexOf("async function sendCmd"));
if (q.length < 20) {
  chk("拿到了 gattSerial 实现", false);
  process.exit(1);
}
// eval 出 gattSerial
const mk = new Function(q + "; return gattSerial;");
const gattSerial = mk();

(async () => {
  // ③ 正常路径：顺序执行 3 个操作
  const order = [];
  await gattSerial(async () => { order.push(1); await new Promise(r => setTimeout(r, 20)); });
  await gattSerial(async () => { order.push(2); await new Promise(r => setTimeout(r, 20)); });
  await gattSerial(async () => { order.push(3); });
  chk("⭐ 三个顺序操作全部执行完", order.join(",") === "1,2,3", order.join(","));

  // ④ 前一个失败，后一个仍要跑（⛔ 不能整条队列报废）
  order.length = 0;
  await gattSerial(async () => { order.push("a"); throw new Error("boom"); }).catch(() => {});
  await gattSerial(async () => { order.push("b"); });
  chk("⭐ 前一个抛错，后一个仍执行", order.join(",") === "a,b", order.join(","));

  // ⑤ ⭐ 关键：模拟"嵌套调用"会不会卡死（旧 bug 的形态）
  //    upload() 里 gattSerial(fn)，而 fn 内部又调 gattSerial —— 现在结构上不可能，
  //    但用"重新入队"验证队列不会自锁。
  const t0 = Date.now();
  let done = false;
  const outer = gattSerial(async () => {
    /* 在【已入队的任务内部】再入队一个新任务 —— 只要队列实现正确
     * （把 chain 更新放在 then 之前），这个内层任务会在外层结束后跑，
     * ⛔ 不会死锁。若实现成"等自己"就会永久挂住。 */
    gattSerial(async () => { done = true; });
    await new Promise(r => setTimeout(r, 30));
  });
  await outer;
  await new Promise(r => setTimeout(r, 50));
  chk("⭐ 队列内再入队 => 不会死锁（内层任务最终执行）",
      done === true && (Date.now() - t0) < 3000, "耗时 " + (Date.now() - t0) + " ms, done=" + done);

  // ⑥ 超时看门狗：一个永不 resolve 的任务要让后面能继续
  const t1 = Date.now();
  let watchdogFired = false;
  const hung = gattSerial(() => new Promise(() => {}));   // 永远不 resolve
  hung.catch(() => {});
  // 下一个任务应该照样跑（队列 chain 不能被 hung 卡住）
  let after = false;
  await gattSerial(async () => { after = true; });
  chk("⭐ 前一个任务永不返回，后一个仍能跑", after === true);
  /* ⚠️ 这一条不判"很快" —— 看门狗就是设计成 15 秒超时的。
   * ⭐ 真正要确认的是【真实调用路径】不会走到这里 */

  console.log();
  console.log("结论：" + (bad === 0 ? "全部通过" : "有 " + bad + " 项不符"));
  process.exit(bad === 0 ? 0 : 1);
})();
