// check_guide.js —— 核对「引导模式」在测试曲上的真实产物（bit6 仅指引 + 节拍器）
//
// 为什么必须用网页自己的实现（而不是另写一份）：
//   真正灌谱时跑的就是 score_studio.html 里那段 JS。
//   另写一份"我认为应该怎么转"的实现 = 探针假绿（经验库 C83）。
//   所以这里把 <script> 块抠出来，配假 DOM 在 node 里跑，直接调页面的真函数。
//   写法与同目录的 verify_piece.js / check_roll.js 一致。
//
// 本脚本对 score_studio.html 只读，绝不修改它（该文件正由他人改动）。
//
// 用法：
//   node check_guide.js [文件.mid] [--hex events.hex]
//   缺省 MIDI = 同目录「StJamesInfirmary-funk-测试曲.mid」
//   缺省 hex  = 同目录 events.hex（只读回读用；文件不存在则该项跳过）
//
// 自证能红（推荐每轮都跑一遍）：
//   node check_guide.js --mutate=<名字>
//   把 score_studio.html 的脚本块在【内存里】故意改坏再跑同一套判据，磁盘文件一个字不动。
//   判据必须因此变红 —— 这才证明判据抓的是页面的真实行为，而不是"喂进去的合成数据"。
//   可选名字：no-guide / all-tracks / shift-track / met-7 / gap-240 / avoid-invert /
//             met-tom-tight / ui-drum-leak / ui-throw /
//             solo-nofilter / all-drop-bg / drum-met-keep / drum-track-keep /
//             drum-both-drop / met-tr-minus1 / payload-count /
//             visible-ignore-sel / visible-ignore-guide / guide-subset-guard /
//             drum-inc-not0 / drum-off-type / melody-isdrum（后三个 = 2026-10-16 新口径）
//
// 判据 ①..⑧：
//   ① 引导轨的字 bit6=1，且数量 == 该轨音符数 × 2（on/off 成对、落点与该轨音符一致）
//   ② 其余轨的字 bit6=0（逐轨统计并打印数量）
//   ③ 节拍器落点与数量正确（beat 音型每小节 kick 1 + tom 2 + snare 1 + hihat 4 = 8 下）
//      · 一半直接单测 buildMetronome(tickMax, {})（不避让）验生成器本身
//      · 一半验产物：避让后的下数守恒 + 落点逐点核对 + 前两小节落点抽查
//   ④ 节拍器 + 谱面鼓：同一件鼓相邻落点间隔 >= 480 tick（方案 B 口径，跨件不限）
//   ⑤ 全曲 bit6=1 的字数 > 0（非空洞）
//   ⑥ 反向证伪：全置位 / 全零 / 错轨 三种反控下，判据①必须变红
//   ⑦ 回读：产物用页面自己的 unpackWord 解回来，guide 位与预期一致
//   ⑧ UI 填充路径不崩 + 引导轨下拉内容正确（直接调页面的 buildTrackPicker）
//
// 判据 ⑨..⑬（2026-10-16 新增：引导范围 guideScope + 鼓声来源 guideDrum + 所见即所灌）：
//   ⑨ guideScope="solo" 时 visibleWords 里【只剩】tempo(-1) + 引导轨 + 节拍器(-2)，
//      背景轨一个字都不剩；且引导轨字数与 ="all" 时【完全一致】（证明裁的是别人不是它）
//   ⑩ guideScope="all" 时背景旋律轨（Bass/Piano/Pad 这类非鼓轨）的字【还在】，逐轨字数与全量一致
//   ⑪ guideDrum 三档：met ⇒ 谱面鼓轨 0 字 / 节拍器 >0；track ⇒ 节拍器 0 字 / 谱面鼓 >0；
//      both ⇒ 两者都 >0（三档都要求 tempo 与引导轨仍在）
//   ⑫ 所见即所灌：visibleWords 的长度 == buildPayload(visibleWords) 反推出的字数
//      （结构 = 4 个复位帧 + 1 个总数帧 + N 个事件帧，总数帧里写的 N 也必须等于它）；
//      且 buildScore(visibleWords).tickMax <= buildScore(全量).tickMax
//   ⑬ 非空洞 + 反向证伪：solo -> all 必须【变长】（相等即红）；guideOn=false 必须【原样返回】
//   ⑭ 选轨 × 引导裁剪：只选 [引导轨, 鼓轨] 时 visibleWords 仍然正确（抓"两个过滤器串联 ⇒ 下标错位"
//      这个实测坑：全选正常，只选 [吉他,鼓] 时引导轨置位数从 72 掉到 45、鼓轴字数变 185）
//
// 判据 ⑮..⑲（2026-10-16 鼓与旋律彻底分离 —— 手册 §二 / §4.1-7 校验器 / §7.3 机械检查）：
//   ⑮ 鼓事件（is_drum=1）的 inc 全 0 · 旋律事件（is_drum=0 且排除 kind=2 tempo）的 inc 全非 0 ·
//      is_drum=0 的事件里轴号落 12..15 的必须 0 条 · 可见字里"is_drum 字数 == 轴=12+dt 的字数"
//   ⑯ 鼓的每个 kind=0 都有配对 kind=1（按 (axis, drum_type)），OFF 也带 is_drum=1 与同一 drum_type
//      （手册点名"漏了会挂音/耗尽鼓池"）+ is_drum=1 时 note_off5 必须为 0
//   ⑰ 鼓件【按 drum_type 认件】（2 位 = timbre[8:7]，4 件）：四件齐全 +
//      轴 == 12 + drum_type（axis-12 == dt）+ 两条 dt 读取路径一致 + 页面表与手册【独立写死的表】一致
//   ⑱ 旋律 note_off5 口径：可弹(MIDI 45..75) => MIDI-45；越界 => 31 哨兵（⛔ 不许钳到 0）
//   ⑲（本轮新增）镲族 8 个音高（46/49/51/52/53/55/57/59）在页面 GM 表里必须【显式列出】-> hihat
//   ⑳（第三轮回退 4 件口径）鼓力度逐件定值：Kick 230 · Snare 235 · HiHat 175 · Tom 220；鼓 OFF 写 0
//      （与 esp32/tools/check_drum_split.py 判据⑧ 同口径；⛔ 上一轮 8 件新增的四件力度已随扩位删掉）
//   ⚠️ ⑮⑯⑰⑱⑲ 全程按 unpackWord 出来的字段判；⛔ 不再拿"轴号落 12..15"当鼓的标志
//      —— 那正是本次要拆掉的老口径（鼓的识别 = bit5 + drum_type）。
//
// 2026-10-16【第三轮 · 回到 4 件】的口径（本脚本独立写死，⛔ 不读页面的表当期望值）：
//   FPGA 线收回了"扩到 8 件"（他们只有 4 件鼓音色，那几个新 inc 是同一纯音引擎的高频音高）。
//   drum_type = timbre[8:7]（2 位，⛔ 不读 bit19）= kick0 snare1 hihat2 tom3（镲族显式归 hihat）
//   鼓的轴 = 12 + drum_type = kick 12 · snare 13 · hihat 14 · tom 15（一件一轴）
//   ⛔ 上一轮的 dt 键（((dt&3)<<1)|(dt>>2) = 0/2/4/6/1/3/5/7）与"8..15"两套旧写法都作废。
//   旋律仍用 0..11（与鼓的 12..15 分开：note_off 按 (axis, src) 两维匹配，src 不同）。
//   鼓力度：Kick 230 · Snare 235 · HiHat 175 · Tom 220；鼓的 OFF 写 0。
//   note_off5：可弹(45..75) => MIDI-45（0..30）；越界 => 31 哨兵（不点灯）；⛔ 不许钳到 0。
//     ⚠️ 哨兵只作用于【旋律】；鼓的 note_off5 恒 0（判据⑯，本轮不回退）。
//
// 独立位提取（rawOf）必须同步认识 bit5（is_drum）与 bits[4:0]（note_off5）：
//   ⛔ 不许改成"直接信页面 unpackWord"（那是拿被验者验自己 = 假绿，经验库 C83）。
//   判据⑦ 拿它与页面的 unpackWord 逐字段比，并用【独立编码器】往返验"一个位域都没漏"。
//
// 2026-10-16 页面接口（判据按这个口径写）：
//   · 主 API = visibleWords(conv)：【一趟】循环里同时做"选轨 + 引导裁剪"（唯一来源 = 所见即所灌）
//   · guideScopedWords(words, conv) 保留，但必须传【全量】conv.words；
//     收到子集时打错误日志并【原样返回】（长度守卫，⛔ 不静默错位）
//   · __setGuide(on, idx, met, style, scope, drum) —— 后两个可选，不传就不改
//   · __setTrackSel(ids)：null = 未选过（=全选），数组 = 只选这些轨
//   · 节拍器字源轨号 = -2（tempo 仍是 -1）
//   · ⭐ 节拍器避让规则：guideOn && guideDrum === "met"（谱面鼓轨马上会被丢掉）⇒ 【不避让】；
//     track / both 档才按"同一件鼓相邻落点 >= 480"避让。判据③按这个开关分别重算。
//
// 判据⑨..⑭ 的期望值同样在脚本里独立重算（见 expectKeep / cmpVis / payload 结构解析），
//   ⛔ 不调用页面的 guideScopedWords 来验页面的 visibleWords。
//   ⛔ 也不按【字值】去归属源轨 —— 节拍器 kick 与谱面 kick 同 tick 时字值完全相同，
//      按值归属一定假红。计数一律走与值无关的口径：unpackWord 后的 guide 位 / 轴 12..15 / kind==2。
//   （页面缺函数时这几条报红并打印缺哪个，⛔ 不用"自己实现一份"去替它——那是探针假绿 C83）
//
// 关键纪律：每条判据都配"反控"——喂一个故意错的输入，要求该判据变红。
//   判据没有反控 = 无法证明它不是恒真的假绿，那种绿一文不值。
//   本文件里凡是能从页面读到的表（音型、轴号、间隔），期望值一律在脚本里
//   独立写死（见 WANT_* 常量），绝不拿页面的表去验页面的表。

"use strict";

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const HERE = __dirname;
const argv = process.argv.slice(2);
let midPath = null, hexPath = null;
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--hex") hexPath = argv[++i];
  else if (argv[i].indexOf("--mutate=") === 0) { /* 见下面"自证能红"一节 */ }
  else midPath = argv[i];
}
if (!midPath) midPath = path.join(HERE, "StJamesInfirmary-funk-测试曲.mid");
if (!hexPath) hexPath = path.join(HERE, "events.hex");
if (!fs.existsSync(midPath)) { console.error("找不到 MIDI：" + midPath); process.exit(2); }

/* ===========================================================================
   独立写死的期望值（不从页面读）
   =========================================================================== */
const WANT_BAR  = 3840;                 // 一小节 = 960 PPQN × 4（4/4）
const WANT_GAP  = 480;                  // 同一件鼓相邻落点下限（方案 B 口径）
/* 2026-10-16 第三轮（FPGA 线收回 8 件）：鼓件的识别口径回到
 * drum_type = timbre[8:7]（2 位，⛔ 不读 bit19），共 4 件。
 * 轴口径：鼓的 axis = 12 + drum_type（一件一轴）= kick 12 · snare 13 · hihat 14 · tom 15。
 * ⛔ 上一轮的 dt 键（((dt&3)<<1)|(dt>>2) = 0/2/4/6/1/3/5/7）与"8..15"两套旧写法都作废。
 * ⛔ 不再按 inc 认件 —— 鼓的 inc 恒为 0（FPGA 按 drum_type 从 drum_gen 的表里自己取）。 */
const WANT_TYPE = { kick: 0, snare: 1, hihat: 2, tom: 3 };
const WANT_TYPE_NAME = { 0: "kick", 1: "snare", 2: "hihat", 3: "tom" };
const WANT_AXIS_KEY = { 0: 12, 1: 13, 2: 14, 3: 15 };   // dt -> axis（独立写死）
const WANT_AXIS = { kick: 12, snare: 13, hihat: 14, tom: 15 };
const WANT_BASE_TYPES = [0, 1, 2, 3];   // 四件（§7.3-3 要求都有）
const WANT_DRUM_AXIS_BASE = 12, WANT_DRUM_AXIS_MAX = 15;   // 鼓轴段（独立写死）
/* 鼓力度逐件定值（判据⑳；与 esp32/tools/check_drum_split.py 判据⑧ 同口径）。
   生效值 = drum_gen.v 默认 + top.v 覆盖：Kick 未被覆盖仍 230 · Snare 235 · HiHat 175 · Tom 220。
   ⛔ 上一轮给"扩到 8 件"新增的四件力度（openhat/crash/ride/splash）已随扩位一起删掉。 */
const WANT_DRUM_VEL = { 0: 230, 1: 235, 2: 175, 3: 220 };
/* 镲族：必须【显式列出】指向 hihat（判据⑲；⛔ 不靠表外兜底 -> tom） */
const WANT_CYMBAL_GMS = [46, 49, 51, 52, 53, 55, 57, 59];
const WANT_MELODY_BAN_AXIS_MIN = 12;    // §7.3-1：旋律不许占 12..15（独立写死，⛔ 不取页面常数）
const AXIS_KEY_TXT = [0, 1, 2, 3].map(t => t + "->" + WANT_AXIS_KEY[t]).join(" ");
const WANT_BEAT = {                     // 需求单给的 beat 音型
  beats: [["kick", 0], ["tom", 960], ["snare", 1920], ["tom", 2880]],
  hats:  [0, 960, 1920, 2880],
};
const BIT_GUIDE = 1n << 6n;             // bit6 = 仅指引
const M_GUIDE   = 1n;

/* ⭐ 2026-10-16 需求单：节拍器字的源轨号从 -1 改成 -2。
   -1 仍表示 tempo 等公共事件；-2 专指节拍器。这里独立写死，⛔ 不从页面读。 */
const WANT_MET_TR   = -2;
const WANT_TEMPO_TR = -1;

/* ⭐ 灌谱字节流的结构（独立写死：与 esp32/tools/score_word.py 的帧格式一致）。
   payload = 4 个复位帧 + 1 个总数帧 + N 个事件帧，每帧 9 字节。
   ⇒ 字数 N 可以从 payload 长度【反推】，也可以从总数帧里【读出来】——两者必须相等。 */
const WANT_FRAME = { bytes: 9, hdrEvent: 0xA5, hdrTotal: 0x00, resetFrames: 4 };

/* ===========================================================================
   把 score_studio.html 的脚本块抠出来，在假 DOM 里跑
   =========================================================================== */
const HTML = path.join(HERE, "..", "..", "tools", "score_studio.html");
if (!fs.existsSync(HTML)) { console.error("找不到 score_studio.html：" + HTML); process.exit(2); }
const htmlSrc = fs.readFileSync(HTML, "utf8");
const htmlStat = fs.statSync(HTML);
const blocks = [...htmlSrc.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
if (!blocks.length) { console.error("RED: score_studio.html 里没找到 <script> 块"); process.exit(2); }
let blk = blocks[0];
/* 该文件正被他人改动 ⇒ 记一个脚本块指纹，报告里写清"判的是哪一版"。
   指纹取【突变之前】的原始脚本块。 */
const FP = crypto.createHash("sha256").update(blk, "utf8").digest("hex").slice(0, 12);

/* ===========================================================================
   自证能红：--mutate=<名字> 把脚本块在【内存里】故意改坏，再跑同一套判据。
   磁盘上的 score_studio.html 一个字都不动。
   判据必须因此变红 —— 这才证明判据抓的是【页面的真实行为】，
   而不是"只对喂进去的合成数据敏感"。
   锚点出现次数必须正好 1 次，否则直接报错退出：锚点被页面改动挪走了，
   这个突变就已经失效，⛔ 不能装作跑过。
   =========================================================================== */
const MUTATIONS = {
  "no-guide":     { find: "e.guide ? 1 : 0", repl: "0",
                    expect: "①⑤⑥⑦", note: "bit6 永远写 0（引导模式完全不生效）。⑥⑦ 是连带红：①红了，⑥的正控和⑦的预期都对不上" },
  "all-tracks":   { find: "const gd = !!(guideOn && guideTrackIdx !== null && sg.tr === guideTrackIdx);",
                    repl: "const gd = !!guideOn;",
                    expect: "①②⑥⑦", note: "置位不看轨身份（每条轨都置位）" },
  "shift-track":  { find: "sg.tr === guideTrackIdx", repl: "sg.tr === (guideTrackIdx + 1)",
                    expect: "①②⑥⑦",
                    note: "置位错一条轨（off-by-one）。注意⑥的错轨反控会【反转成绿】——" +
                          "因为页面的实际置位恰好就是被 +1 的那条轨，所以「按它判」反而对；⑥整体仍因①红而红" },
  "met-7":        { find: "hats: [0, 960, 1920, 2880] },\n  off:",
                    repl: "hats: [0, 960, 1920] },\n  off:",
                    expect: "③", note: "beat 音型少一下踩镲（每小节 7 下）" },
  "gap-240":      { find: "const DRUM_DUR_TICK = 480;", repl: "const DRUM_DUR_TICK = 240;",
                    expect: "③",
                    note: "避让阈值 480 -> 240。注意：这份曲子没有落在 240..479 区间的同件碰撞，" +
                          "该突变在产物上不可观测（metCount/skipped 一模一样）=> 只有③的常数核对能抓；" +
                          "④的灵敏度改由 avoid-invert 突变 + 它自己的合成反控来证" },
  "avoid-invert": { find: "const near = (takenByInc[inc] || []).some(t => Math.abs(t - tick) < DRUM_DUR_TICK);",
                    repl: "const near = !(takenByInc[inc] || []).some(t => Math.abs(t - tick) < DRUM_DUR_TICK);",
                    /* ⭐ 2026-10-16：页面把避让键从 inc 改成了 drum_type（手册 §二口径）
                     *   ⇒ 主锚失效，补一个备用锚（alt 机制：取第一个出现次数正好符合要求的）。 */
                    alt: [{ find: "const near = (takenByType[dt] || []).some(t => Math.abs(t - tick) < DRUM_DUR_TICK);",
                            repl: "const near = !(takenByType[dt] || []).some(t => Math.abs(t - tick) < DRUM_DUR_TICK);" }],
                    expect: "③",
                    note: "避让判据取反（该避让的不避让）。这份曲子的同件碰撞【全是同 tick 重合】，" +
                          "去重后不产生新间隔 => 打不到④，只有③能抓" },
  /* 唯一能真的造出"同件间隔 < 480"的突变：给 beat 音型加一个 tom@1200，
     它与 tom@960 只差 240；而避让只比【谱面】鼓，看不见节拍器自己 => ④必须红。 */
  "met-tom-tight": { find: 'beat: { beats: [["kick", 0], ["tom", 960], ["snare", 1920], ["tom", 2880]],',
                     repl: 'beat: { beats: [["kick", 0], ["tom", 960], ["snare", 1920], ["tom", 2880], ["tom", 1200]],',
                     expect: "③④", note: "beat 音型多一个 tom@1200（与 tom@960 只差 240）" },
  "ui-drum-leak": { find: "      if (t.drum) continue;\n      opts.push('<option value=\"' + t.idx + '\"' +",
                    repl: "      opts.push('<option value=\"' + t.idx + '\"' +",
                    expect: "⑧", note: "引导轨下拉把鼓轨也列进去" },
  "ui-throw":     { find: 'const gsel = $("gd_track");',
                    repl: 'const gsel = $("gd_track"); __no_such_fn__();',
                    expect: "⑧", note: "UI 填充路径抛异常（调用一个不存在的函数）" },

  /* ⭐⭐ 2026-10-17 新增：把"准备阶段整体后移"改回【丢弃】= 复现用户实测的那个 bug
   *    （"加了准备小节之后，原曲最开始的小节被截断了"）。
   *    ⚠️ 这是这条判据的非空洞性证明：不修的时候它必须红。 */
  /* ⭐⭐ 2026-10-18：把"初始 BPM 钉在 0"去掉（= 旧写法，所有事件一律后移）
   *    ⇒ secToTick(0) 会返回 prepEnd ⇒ 游标一出生就站在示范段开头
   *    ⇒ 这是"游标/进度错位"的【根因复现】，㉒ 必须红。 */
  "prep-shift-tempo": { find: "if (e.kind === KIND_TEMPO && e.tick === 0) continue;",
                        repl: "if (false) continue;",
                        expect: "㉒",
                        note: "初始 tempo 也后移（旧写法）⇒ secToTick(0)=prepEnd ⇒ 游标起点被推到示范段；㉒ 必红" },  "prep-drop":    { find: "for (const e of evs) e.tick += prepEnd;",
                    repl: "for (let _i = evs.length - 1; _i >= 0; _i--) { if (evs[_i].tick < prepEnd) evs.splice(_i, 1); }",
                    expect: "㉑",
                    note: "准备阶段改成【丢弃 tick < prepEnd 的事件】= 原 bug（原曲开头被裁掉）；㉑ 必须红" },

  /* ⭐ 2026-10-16 新增：引导范围 / 鼓声来源 / 所见即所灌 / 选轨×裁剪 / 节拍器源轨号。
     ⚠️ 锚点按页面【当时】的写法取；页面换个写法就会"出现 0 次"⇒ 直接报错退出（⛔ 不假装跑过）。 */
  "solo-nofilter": { find: 'return guideScope !== "solo";', repl: "return true;",
                     expect: "⑨⑬",
                     note: "solo 分支失效（选了 solo 也照样保留背景轨）——⑨ 抓逐字/计数，⑬ 抓「solo 与 all 一样长」" },
  "all-drop-bg":   { find: 'return guideScope !== "solo";', repl: "return false;",
                     expect: "⑩⑬",
                     note: "solo 分支变成恒真（all 也把背景轨全丢掉）——⑩ 抓背景轨字没了，⑬ 抓两侧一样长" },
  "drum-met-keep": { find: 'if (t && t.drum) return guideDrum !== "met";',
                     repl: "if (t && t.drum) return true;",
                     expect: "⑪",
                     note: "met 档不再丢谱面鼓轨（本该只留节拍器，结果谱面鼓也留着）" },
  "drum-track-keep": { find: 'if (src === -2) return guideDrum !== "track";',
                       repl: "if (src === -2) return true;",
                       expect: "⑪",
                       note: "track 档不再丢节拍器（本该只要谱面鼓轨，结果节拍器也留着）" },
  "drum-both-drop": { find: 'if (t && t.drum) return guideDrum !== "met";',
                      repl: 'if (t && t.drum) return guideDrum !== "met" && guideDrum !== "both";',
                      expect: "⑪",
                      note: "both 档被当成 met（本该两者都要，结果谱面鼓轨被丢掉）" },
  "met-tr-minus1": { find: "srcTrack: -2, guide: false });", repl: "srcTrack: -1, guide: false });",
                     count: 2,
                     expect: "③⑨⑪",
                     note: "节拍器源轨号退回 -1（需求单已改成 -2）——③ 的 WANT_MET_TR 常数核对必须抓；" +
                           "⑨⑪ 是连带红：本脚本按 -2 重算，页面却把节拍器当 -1 处理" },
  "payload-count": { find: "const parts = [resetSequence(), frameTotal(words.length)];",
                     repl: "const parts = [resetSequence(), frameTotal(words.length + 1)];",
                     expect: "⑫",
                     note: "总数帧里写的 N 比真实字数多 1（灌下去固件的 exp 会对不上）——⑫ 的 payload 结构解析必须抓" },
  "visible-ignore-sel": { find: "if (keepBySelection(src) && keepByGuide(src, conv)) keep.push(conv.words[i]);",
                          repl: "if (keepByGuide(src, conv)) keep.push(conv.words[i]);",
                          expect: "⑭",
                          note: "visibleWords 不再做选轨过滤（只选子集也把整份都灌下去）" },
  "visible-ignore-guide": { find: "if (keepBySelection(src) && keepByGuide(src, conv)) keep.push(conv.words[i]);",
                            repl: "if (keepBySelection(src)) keep.push(conv.words[i]);",
                            expect: "⑨⑩⑪⑬⑭",
                            note: "visibleWords 不再做引导裁剪（引导范围/鼓声来源全部失效）" },
  "guide-subset-guard": { find: "if (words.length !== conv.words.length) {", repl: "if (false) {",
                          expect: "⑭",
                          note: "guideScopedWords 的长度守卫被去掉 ⇒ 喂子集会按下标错位（踩过的坑）——" +
                                "⑭ 的长度守卫核对必须抓" },

  /* ⭐⭐ 2026-10-16 新增（鼓与旋律分离 / 手册 §二 · §4.1-7）：新位域与件名口径的突变自证。
     ⚠️ 锚点取的是页面里【那一句核心口径】；页面换写法就会"出现 0 次"⇒ 直接报错退出（⛔ 不假装跑过）。 */
  "drum-inc-not0": { find: "const inc = isDrum ? 0", repl: "const inc = isDrum ? 5243",
                     expect: "⑮",
                     note: "鼓事件的 inc 写回非 0（撞上「21 位装不下 26/28 位 inc」的老毛病 ⇒ 又变电子音）" },
  "melody-isdrum": { find: "const isDrum = e.isDrum ? 1 : 0;", repl: "const isDrum = 1;",
                     expect: "⑮",
                     note: "所有事件都标 is_drum=1（旋律全被当成鼓 —— 正是手册 §〇 第 1 条要防的「旋律变鼓」）" },
  "drum-off-type": { find: "timbre: DRUM_TYPE_OF[d.name] & 3,",
                     repl: "timbre: n.on ? (DRUM_TYPE_OF[d.name] & 3) : ((DRUM_TYPE_OF[d.name] + 1) & 3),",
                     expect: "⑯",
                     note: "鼓的 OFF 带错 drum_type（ON/OFF 配不上 ⇒ 鼓 voice 永久 held ⇒ 保留池耗尽）" },
};
let mutated = null;
{
  const mArg = argv.find(a => a.indexOf("--mutate=") === 0);
  if (mArg) {
    const nm = mArg.slice("--mutate=".length);
    const m = MUTATIONS[nm];
    if (!m) {
      console.error("未知突变：" + nm + "（可选：" + Object.keys(MUTATIONS).join(" / ") + "）");
      process.exit(2);
    }
    /* 锚点可以给多个候选（find/repl 主锚 + alt 备用锚）：取第一个出现次数正好符合要求的。
       默认要求正好 1 次；给了 count 就按 count 次（用于"同一句话出现两处"的场景）。 */
    const cands = [m].concat(m.alt || []);
    const wantN = (m.count === undefined) ? 1 : m.count;
    let hit = null;
    const counts = [];
    for (const c of cands) {
      const n = blk.split(c.find).length - 1;
      counts.push(n);
      if (n === wantN && !hit) hit = c;
    }
    if (!hit) {
      console.error("突变 " + nm + " 的锚点在当前页面里出现次数为 [" + counts.join(", ") +
                    "]（要求 " + wantN + " 次）——页面已改动，该突变失效，拒绝假装跑过。");
      console.error("  锚点：" + cands.map(c => JSON.stringify(c.find.slice(0, 70))).join(" | "));
      process.exit(2);
    }
    blk = blk.split(hit.find).join(hit.repl);
    mutated = nm;
  }
}

const fakeCtx = new Proxy({}, {
  get: (t, k) => k === "canvas" ? { width: 1, height: 1 }
    : (k === "measureText" ? () => ({ width: 1 }) : (() => {})), set: () => true });
/* 假元素要够结实：页面的 boot() -> fitCanvas() 会读 cv.parentElement.getBoundingClientRect()，
   少一个成员就在加载期抛错。
   另外 querySelector 必须返回一个假元素（⛔ 不是 null）——
   页面的 buildTrackPicker 会写 lab.querySelector("input").onchange = ...，
   返回 null 会在"打开 MIDI"这条路径上直接抛错（判据⑧要覆盖的正是这条路）。 */
const mkEl = (ctx, cw, ch) => new Proxy({
  style: {}, classList: { add() {}, remove() {} }, getContext: () => ctx,
  clientWidth: cw, clientHeight: ch, width: cw, height: ch,
  parentElement: { getBoundingClientRect: () => ({ left: 0, top: 0, width: cw, height: ch }) },
  querySelectorAll: () => [],
  querySelector: () => mkEl(ctx, cw, ch),
  addEventListener() {},
  appendChild() {}, insertAdjacentHTML() {}, removeChild() {}, focus() {}, remove() {},
  getBoundingClientRect: () => ({ left: 0, top: 0, width: cw, height: ch }),
  textContent: "", innerHTML: "", value: "", checked: false,
}, { get: (t, k) => k in t ? t[k] : (typeof k === "string" ? (() => {}) : undefined),
     set: (t, k, v) => { t[k] = v; return true; } });
const fakeEl = () => mkEl(fakeCtx, 800, 600);
/* getElementById 必须【按 id 缓存同一个元素】：页面写 el.innerHTML / el.textContent
   之后判据⑧要把它读回来，每次返回新元素就永远读到空。 */
const elById = new Map();
const doc = {
  getElementById: id => { if (!elById.has(id)) elById.set(id, fakeEl()); return elById.get(id); },
  querySelector: () => fakeEl(), querySelectorAll: () => [], addEventListener() {},
  createElement: () => fakeEl(), body: fakeEl(),
};
const win = { addEventListener() {} };

/* 追加的导出：只做"把页面已有的状态变量 / 已有函数暴露出来"这件事，不重写任何页面逻辑。
   __guideSetLocal 与页面测试钩子 __setGuide 写的是同一组模块级变量
   （guideOn / guideTrackIdx / metOn / metStyle / guideScope / guideDrum）—— 见下面"测试钩子"一节。
   ⚠️ 2026-10-16：scope / drum 两个参数可选，不传就不改（与页面 __setGuide 的口径一致）；
      页面若还没声明这两个变量，用 typeof 挡住 —— 否则严格模式下赋值未声明变量会抛 ReferenceError，
      连带把①..⑧ 全部打成 RED（那是【本脚本】造成的假红，⛔ 不能算页面的账）。 */
const APPEND =
  "\n; function __guideSetLocal(on, idx, met, style, scope, drum) {" +
  "\n    guideOn = !!on;" +
  "\n    guideTrackIdx = (idx === null || idx === undefined) ? null : idx;" +
  "\n    if (met !== undefined && met !== null) metOn = !!met;" +
  "\n    if (style) metStyle = style;" +
  "\n    if (scope && typeof guideScope !== 'undefined') guideScope = scope;" +
  "\n    if (drum && typeof guideDrum !== 'undefined') guideDrum = drum;" +
  "\n  }" +
  "\n; function __guideStateLocal() {" +
  "\n    return { guideOn: guideOn, guideTrackIdx: guideTrackIdx, metOn: metOn, metStyle: metStyle," +
  "\n             guideScope: (typeof guideScope === 'undefined') ? null : guideScope," +
  "\n             guideDrum: (typeof guideDrum === 'undefined') ? null : guideDrum };" +
  "\n  }" +
  /* 判据⑧要跑 UI 填充路径，而 updateGuideSummary() 读的是 lastConv
     ⇒ 得像 check_roll.js 的 __setScore 那样把谱面交给页面。 */
  "\n; function __setLastConv(c) { lastConv = c; }" +
  "\n; return { parseMidi, midiToWords, buildScore, isDrumTrack, timbreOfTrack, TIMBRE_NAMES," +
  " isDrumAxis, DRUM_AXIS_OF, " +
  /* ⚠️ DRUM_AXIS_BASE：2026-10-16 第三轮页面【回退到 4 件】后鼓就占 12..15（一件一轴），
     这个常量在页面里已删除（不再需要"预留段起点"这个概念）。
     typeof 保护：页面没有它就导出 null、判据直接跳过该项（⛔ 不当成页面出错）；
     ⛔ 也【不再】断言"12..15 保留段空出"—— 第三轮鼓就在 12..15，那条断言已作废。
     本判据的 §7.3-1 期望值（旋律不许占 12..15）由 WANT_MELODY_BAN_AXIS_MIN 独立写死，
     ⛔ 不依赖这个页面常量。 */
  " DRUM_AXIS_BASE: (typeof DRUM_AXIS_BASE === 'number') ? DRUM_AXIS_BASE : null, " +
  "MELODY_AXIS_MAX, DRUM_INC, MIDI_PPQN," +
  /* ⭐⭐ 2026-10-18：准备段的【时间轴起点】判据要用到这两个换算函数
     （secToTick 的积分起点是 score.tempos[0].tick —— 那正是本 bug 的根）。
     typeof 保护：页面没有就导出 null，判据跳过并如实报，⛔ 不当成页面出错。 */
  " secToTick: (typeof secToTick === 'function') ? secToTick : null," +
  " tickToSec: (typeof tickToSec === 'function') ? tickToSec : null," +
  /* ⭐ 2026-10-16（手册 §二）：把页面自己的鼓件口径表也带出来 ——
     判据③/⑰ 拿它与手册 §二/§4.3【独立写死的表】对照（⛔ 不是拿页面的表验页面的表）。
     typeof 保护：页面还没写出来时导出 null，判据会明确报缺，⛔ 不抛 ReferenceError。 */
  " DRUM_TYPE_OF: (typeof DRUM_TYPE_OF === 'object') ? DRUM_TYPE_OF : null," +
  /* 2026-10-16 第三轮：GM 音高 -> 鼓件名的表也要带出来 —— 判据⑲ 核对
     "镲族 8 个音高必须【显式列出】-> hihat"（⛔ 不靠表外兜底 -> tom）。 */
  " GM_DRUM_MAP: (typeof GM_DRUM_MAP === 'object') ? GM_DRUM_MAP : null," +
  " KIND_ON, KIND_OFF, KIND_TEMPO, packWord, unpackWord, wordToBytes, frameFromWord," +
  " buildMetronome, MET_PATTERNS, MET_STYLE_NAME, BAR_TICK, DRUM_DUR_TICK," +
  " buildTrackPicker, updateGuideSummary, __setLastConv," +
  " __guideSetLocal, __guideStateLocal," +
  /* ⭐ 2026-10-16 新增接口（typeof 保护：页面还没写出来时导出 null，
     判据⑨..⑬ 据此报"页面还没有这个函数"，⛔ 不是本脚本自己造一份替它跑） */
  " guideScopedWords: (typeof guideScopedWords === 'function') ? guideScopedWords : null," +
  " visibleWords: (typeof visibleWords === 'function') ? visibleWords : null," +
  " wordsForSelected: (typeof wordsForSelected === 'function') ? wordsForSelected : null," +
  " keepBySelection: (typeof keepBySelection === 'function') ? keepBySelection : null," +
  " keepByGuide: (typeof keepByGuide === 'function') ? keepByGuide : null," +
  " __setTrackSel: (typeof __setTrackSel === 'function') ? __setTrackSel : null," +
  " buildPayload: (typeof buildPayload === 'function') ? buildPayload : null," +
  " resetSequence: (typeof resetSequence === 'function') ? resetSequence : null," +
  " frameTotal: (typeof frameTotal === 'function') ? frameTotal : null," +
  " FRAME_BYTES: (typeof FRAME_BYTES === 'number') ? FRAME_BYTES : null," +
  " HDR_EVENT: (typeof HDR_EVENT === 'number') ? HDR_EVENT : null," +
  " HDR_TOTAL: (typeof HDR_TOTAL === 'number') ? HDR_TOTAL : null," +
  " RESET_FRAMES: (typeof RESET_FRAMES === 'number') ? RESET_FRAMES : null," +
  /* 页面自带测试钩子就带出来用（typeof 保护：还没有时不能直接引用，否则 ReferenceError） */
  " __setGuide: (typeof __setGuide === 'function') ? __setGuide : null };";


const fn = new Function("document", "window", "navigator", "performance", "console",
  "setTimeout", "clearInterval", "setInterval", "requestAnimationFrame",
  "location", "localStorage", "URLSearchParams",
  blk + APPEND);

let API = null, loadErr = null;
try {
  API = fn(doc, win, { bluetooth: null }, { now: () => 0 }, { log: () => {} },
    setTimeout, () => {}, () => 0, () => 0,
    { protocol: "http:", host: "x", search: "" },
    { getItem: () => null, setItem() {} },
    class { constructor() {} get() { return null; } });
} catch (e) { loadErr = e; }

const SEP = "=".repeat(86);
console.log(SEP);
console.log("引导模式核对：" + path.basename(midPath));
console.log("  被测页面：" + HTML);
console.log("    脚本块指纹 sha256[0:12] = " + FP + "   脚本块 " + blk.split("\n").length +
            " 行 · 文件 " + htmlStat.size + " 字节 · 改动时间 " + htmlStat.mtime.toISOString());
console.log("    （该文件正由他人改动 ⇒ 指纹用来对齐「这份报告判的是哪一版」）");
if (mutated) {
  console.log("    突变模式 --mutate=" + mutated + "：" + MUTATIONS[mutated].note +
              "（只在内存里改坏，磁盘文件未动）· 预期判据（至少）" + MUTATIONS[mutated].expect + " 变红");
  console.log("    ⚠️ 实测可能【多出】连带红：一处改坏会同时打中依赖同一事实的判据" +
              "（例：bit6 恒 0 ⇒ ⑨⑩⑪⑭ 的引导位计数也对不上）——多红不算弱，少红才算。");
}
console.log(SEP);

if (!API) {
  const t = loadErr && loadErr.constructor ? (loadErr.constructor.name + ": " + loadErr.message)
                                           : String(loadErr);
  console.log();
  console.log("RED: 无法加载 score_studio.html 的脚本块（页面可能在改到一半）。");
  console.log("  报错原文：" + t);
  if (loadErr && loadErr.stack) console.log("  栈：" + String(loadErr.stack).split("\n").slice(0, 6).join("\n      "));
  console.log();
  console.log("  结论：有 1 项 RED");
  process.exit(1);
}

/* ===========================================================================
   测试钩子 __setGuide
   需求单约定页面提供 __setGuide(on, idx, met, style)。若还没加进来，
   就回退到 __guideSetLocal（写同一组模块级状态变量，与钩子等价），
   并把"直接调用页面钩子"的报错原文照抄出来，方便对齐进度。
   =========================================================================== */
const pageHook = (typeof API.__setGuide === "function") ? API.__setGuide
               : (typeof win.__setGuide === "function") ? win.__setGuide
               : null;
let hookErrText = "";
if (!pageHook) {
  try { API.__setGuide(true, 0, true, "beat"); }
  catch (e) { hookErrText = (e && e.constructor ? e.constructor.name : "Error") + ": " + (e && e.message); }
}
const setGuide = pageHook || API.__guideSetLocal;

/* ===========================================================================
   输入：解析 MIDI，选引导轨
   =========================================================================== */
const buf = fs.readFileSync(midPath);
const parsed = API.parseMidi(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length));
const SCALE = API.MIDI_PPQN / parsed.division;

/* 轨表。注意 parsed.tracks[i].notes 里存的是 on/off【事件】（带 on 字段），
   所以"音符数"= on 事件数，"该轨字数" = 2 × 音符数。 */
const tracks = parsed.tracks.map((t, i) => {
  const on  = t.notes.filter(n => n.on);
  const off = t.notes.filter(n => !n.on);
  return {
    idx: i, name: t.name || "(无名)", drum: API.isDrumTrack(t),
    onCount: on.length, offCount: off.length, evCount: t.notes.length,
    onTicks: on.map(n => Math.round(n.tick * SCALE)).sort((a, b) => a - b),
  };
});
const tuned = tracks.filter(t => !t.drum);
if (!tuned.length) { console.error("RED: 这份 MIDI 里没有非鼓轨，引导轨无从选起"); process.exit(2); }
/* 引导轨 = 音符最多的非鼓轨（鼓轨按需求不给选） */
const gTrack = tuned.slice().sort((a, b) => (b.onCount - a.onCount) || (a.idx - b.idx))[0];
const K = gTrack.idx;

/* ---- 跑页面转换：四种状态组合（scope / drum 可选，不传就不改 —— 与页面钩子同口径） ---- */
const runGuide = (on, idx, met, style, scope, drum) => {
  setGuide(on, idx, met, style, scope, drum);
  const st = API.__guideStateLocal();
  const want = { guideOn: !!on, guideTrackIdx: (idx === null || idx === undefined) ? null : idx,
                 metOn: !!met, metStyle: style };
  let ok = st.guideOn === want.guideOn && st.guideTrackIdx === want.guideTrackIdx &&
           st.metOn === want.metOn && st.metStyle === want.metStyle;
  /* scope / drum 只在明确传了的时候核对（页面还没这两个变量时 st 里是 null，也不能算它的账） */
  if (scope !== undefined) ok = ok && (st.guideScope === scope);
  if (drum !== undefined)  ok = ok && (st.guideDrum === drum);
  if (!ok) {
    console.log("RED: 设置引导状态后回读不一致 —— 想要 " + JSON.stringify(want) +
                " scope=" + scope + " drum=" + drum + "，实际 " + JSON.stringify(st));
    process.exit(2);
  }
  return API.midiToWords(parsed);
};

const convBase  = runGuide(false, null, false, "beat", "all", "met");   // 基线：无引导、无节拍器
const convMain  = runGuide(true,  K,    true,  "beat", "all", "met");   // 主产物：引导 + 节拍器（鼓声=节拍器 ⇒ 不避让）
const convZero  = runGuide(false, null, true,  "beat", "all", "met");   // 无引导、有节拍器（反控用）
const convBoth  = runGuide(true,  K,    true,  "beat", "all", "both");  // 鼓声=两者 ⇒ 谱面鼓会响 ⇒ 仍避让
/* ⭐ 2026-10-16 页面新规则：guideOn && guideDrum === "met" ⇒ 谱面鼓会被丢掉 ⇒ 节拍器不避让。
   这里由【本脚本按状态独立判定】避让与否，⛔ 不读页面的 scoreDrumsDropped。 */
const avoidMain = false;   // 主产物是 met 档（引导开）⇒ 不避让
const avoidBoth = true;    // both 档 ⇒ 谱面鼓会响 ⇒ 避让

/* ===========================================================================
   解码与通用工具
   =========================================================================== */
const unpack = w => API.unpackWord(w);
/* 独立位提取（不复用页面的 unpackWord）—— 判据⑦用它来验页面的解码器。
 * ⭐⭐ 2026-10-16（手册 §二）：必须同步认识 bit5（is_drum）与 bits[4:0]（note_off5）——
 *   否则"新位域写错了"这件事在本核对器里【看不见】（旧版只提到 bit6，正好漏掉这两个）。
 * ⛔ 不许改成"直接信页面 unpackWord"：那是拿被验者验自己 = 假绿（经验库 C83）。 */
const rawOf = w => ({
  tick:   Number((w >> 44n) & 0xFFFFFn), inc:    Number((w >> 23n) & 0x1FFFFFn),
  axis:   Number((w >> 19n) & 0xFn),     vel:    Number((w >> 11n) & 0xFFn),
  kind:   Number((w >> 9n)  & 0x3n),     timbre: Number((w >> 7n)  & 0x3n),
  guide:  Number((w >> 6n)  & 0x1n),
  /* 2026-10-16 第三轮：bit19 【不再】是 drum_type 的 MSB —— 它只是 axis 字段的 bit0。
   * ⛔ 这里不再单独提取 bit19（上一轮的"共享位"读法已随"扩到 8 件"一起作废）。 */
  isDrum: Number((w >> 5n)  & 0x1n),     note5:  Number(w & 0x1Fn),
});
const FIELDS = ["tick", "inc", "axis", "vel", "kind", "timbre", "guide", "isDrum", "note5"];
const diffFields = (a, b) => FIELDS.filter(f => a[f] !== b[f]);
/* ⭐ 独立编码器（⛔ 不用页面的 packWord）：判据⑦ 用它往返验"独立提取没漏任何位域"。
 *   覆盖全部 64 位：tick20 + inc21 + axis4 + vel8 + kind2 + timbre2 + guide1 + isDrum1 + note5 5 = 64 */
const mkWord = o =>
  ((BigInt(o.tick || 0) & 0xFFFFFn) << 44n) | ((BigInt(o.inc || 0) & 0x1FFFFFn) << 23n) |
  ((BigInt(o.axis || 0) & 0xFn) << 19n)     | ((BigInt(o.vel || 0) & 0xFFn) << 11n) |
  ((BigInt(o.kind || 0) & 0x3n) << 9n)      | ((BigInt(o.timbre || 0) & 0x3n) << 7n) |
  ((BigInt(o.guide || 0) & 0x1n) << 6n)     | ((BigInt(o.isDrum || 0) & 0x1n) << 5n) |
  (BigInt(o.note5 || 0) & 0x1Fn);

/* 2026-10-16 第三轮（FPGA 线收回 8 件）：鼓件名 = drum_type = {bit19, timbre[8:7]} 改为
 *   【2 位 timbre[8:7]】（kick=0 · snare=1 · hihat=2 · tom=3；镲族全部归 hihat）。
 *   ⛔ 删掉原来的 nameOfInc（按 inc 反查件名）：鼓的 inc 恒为 0，按 inc 反查会全认成"inc0"。 */
const DRUM_TYPE_NAME = { 0: "kick", 1: "snare", 2: "hihat", 3: "tom" };
const nameOfType = t => DRUM_TYPE_NAME[t & 3] || ("type" + (t & 3));
/* drum_type 两位读取的两条【独立】路径（判据⑦/⑰ 拿它们互证）：
 *   dtOf 走页面 unpackWord 给出的 timbre（被验者的解码结果）；
 *   dtOfRaw 走本文件的独立位提取（原始位 bit 8..7）。 */
const dtOf = o => (o.timbre & 3);
const dtOfRaw = o => (o.timbre & 3);
/* 上一轮（8 件）的三位读法 {bit19, timbre[8:7]}：只用来做判据⑰ 的【反控】——
 *   证明"多读一位"在本产物上是能被抓到的（轴 13/15 的事件 bit19=1）。 */
const dtOfLegacy3 = o => (((o.axis & 1) << 2) | (o.timbre & 3));

/* 节拍器字的判定。
   ⭐ 2026-10-16 需求单：节拍器字的源轨号从 -1 改成 -2 ⇒ 这里必须认 -2。
   ⚠️ 同时仍认 -1（旧口径）—— 因为"认得出节拍器"只影响【报告与③④的取材】，
      真正"源轨号必须是 -2"的硬判据放在 pred3 / pred3gen 里用 WANT_MET_TR 卡死。
   ⭐⭐ 2026-10-16【鼓与旋律分离】：鼓的身份改成【is_drum=1】（手册 §二），
      ⛔ 不再用"轴号落 12..15"猜。这同时是一条隐式硬判据：节拍器字若漏了 is_drum=1，
      它就【认不出来】⇒ 判据③ 的落点核对立刻报"该响没响"。 */
const isMetWord = (d, tr) => ((tr === WANT_MET_TR || tr === WANT_TEMPO_TR) && d.isDrum === 1);
const decWords = conv => conv.words.map((w, i) => ({ i, w, d: unpack(w), tr: conv.evTrack[i] }));

/* ===========================================================================
   判据谓词（纯函数，正控与反控都走同一份代码 —— 反控能红才证明它不是恒真）
   =========================================================================== */

/* 判据①的谓词 */
function pred1(words, evTrack, idx, onTicks) {
  const bad = [];
  const guideIdx = [];
  for (let i = 0; i < words.length; i++) if (unpack(words[i]).guide === 1) guideIdx.push(i);
  /* 1) 每条置位字的源轨必须是引导轨 */
  const wrongTr = guideIdx.filter(i => evTrack[i] !== idx);
  if (wrongTr.length) {
    bad.push("有 " + wrongTr.length + " 个置位字的源轨不是引导轨（例：下标 " + wrongTr[0] +
             " 的源轨 = " + evTrack[wrongTr[0]] + "，引导轨 = " + idx + "）");
  }
  /* 2) 数量 == 音符数 × 2 */
  const expect = onTicks.length * 2;
  if (guideIdx.length !== expect) bad.push("置位字数 " + guideIdx.length + " != 音符数×2 = " + expect);
  /* 3) on/off 成对，且 on 的 tick 必须命中该轨音符落点 */
  const onSet = new Set(onTicks);
  const fifo = new Map();
  let nOn = 0, nOff = 0, unclosedOn = 0, orphanOff = 0, tickMiss = 0;
  const axes = new Set();
  for (const i of guideIdx) {
    const d = unpack(words[i]);
    const key = d.axis + "|" + d.inc;
    axes.add(d.axis);
    if (d.kind === API.KIND_ON) {
      nOn++;
      if (!onSet.has(d.tick)) tickMiss++;
      if (!fifo.has(key)) fifo.set(key, []);
      fifo.get(key).push(d.tick);
    } else if (d.kind === API.KIND_OFF) {
      nOff++;
      const q = fifo.get(key);
      if (q && q.length) q.shift(); else orphanOff++;
    }
  }
  for (const [, q] of fifo) unclosedOn += q.length;
  if (nOn !== nOff) bad.push("on " + nOn + " 个 / off " + nOff + " 个，不成对");
  if (unclosedOn || orphanOff) bad.push("配对失败：未闭合 on " + unclosedOn + " · 无主 off " + orphanOff);
  if (tickMiss) bad.push("有 " + tickMiss + " 个置位 on 的 tick 不在该轨音符落点集合里");
  return { ok: bad.length === 0, bad: bad, n: guideIdx.length, expect: expect,
           nOn: nOn, nOff: nOff, axes: [...axes].sort((a, b) => a - b) };
}

/* 判据②的谓词 */
function pred2(words, evTrack, idx) {
  const st = new Map();
  for (let i = 0; i < words.length; i++) {
    const tr = evTrack[i];
    if (!st.has(tr)) st.set(tr, { total: 0, guide: 0 });
    const s = st.get(tr); s.total++;
    if (unpack(words[i]).guide === 1) s.guide++;
  }
  const bad = [];
  for (const [tr, s] of st) {
    if (tr !== idx && s.guide > 0) bad.push("轨 " + tr + " 有 " + s.guide + " 个置位字（应为 0）");
  }
  return { ok: bad.length === 0, bad: bad, st: st };
}

/* 判据③的谓词：按需求单的音型【独立重算】每一个落点，再与产物对齐。
   ⭐ 2026-10-16 页面新规则：避让与否取决于 guideDrum ——
      `guideOn && guideDrum === "met"`（谱面鼓轨马上会被丢掉）时节拍器【不再避让】谱面鼓；
      track / both 档才按"同一件 >= 480"避让。
      ⇒ avoid 由【本脚本按状态独立判定】后传进来，⛔ 不读页面的 scoreDrumsDropped。 */
function pred3(metOns, metOffs, metCount, metSkipped, bars, scoreTicksByType, avoid) {
  const bad = [];
  /* 期望落点表：偏移 -> 该偏移上应有的鼓名 */
  const offsetNames = new Map();
  const addON = (off, nm) => {
    if (!offsetNames.has(off)) offsetNames.set(off, []);
    offsetNames.get(off).push(nm);
  };
  for (const [nm, off] of WANT_BEAT.beats) addON(off, nm);
  for (const off of WANT_BEAT.hats) addON(off, "hihat");
  const perBarHits = WANT_BEAT.beats.length + WANT_BEAT.hats.length;   // 8
  const expectedTotal = bars * perBarHits;
  if (metCount + metSkipped !== expectedTotal) {
    bad.push("下数守恒不成立：metCount " + metCount + " + metSkipped " + metSkipped +
             " = " + (metCount + metSkipped) + "，期望 " + bars + " 小节 × " + perBarHits + " = " + expectedTotal);
  }
  /* 音型表自检：页面 MET_PATTERNS.beat 必须与需求单一致（防"用页面的表验页面的表"） */
  const pb = API.MET_PATTERNS && API.MET_PATTERNS.beat;
  if (!pb) bad.push("页面没有 MET_PATTERNS.beat");
  else {
    const sameBeats = JSON.stringify(pb.beats) === JSON.stringify(WANT_BEAT.beats);
    const sameHats  = JSON.stringify(pb.hats)  === JSON.stringify(WANT_BEAT.hats);
    if (!sameBeats || !sameHats) bad.push("页面 beat 音型与需求单不一致：beats=" + JSON.stringify(pb.beats) +
                                          " hats=" + JSON.stringify(pb.hats));
  }
  if (API.BAR_TICK !== WANT_BAR) bad.push("页面 BAR_TICK = " + API.BAR_TICK + " != " + WANT_BAR);
  if (API.DRUM_DUR_TICK !== WANT_GAP) bad.push("页面 DRUM_DUR_TICK = " + API.DRUM_DUR_TICK + " != " + WANT_GAP);
  /* 鼓件口径表自检：页面的 DRUM_TYPE_OF / DRUM_AXIS_OF 必须与手册 §二/§4.3 独立表一致 */
  for (const nm of ["kick", "snare", "hihat", "tom"]) {
    if (API.DRUM_TYPE_OF && API.DRUM_TYPE_OF[nm] !== WANT_TYPE[nm]) {
      bad.push("页面 DRUM_TYPE_OF." + nm + " = " + API.DRUM_TYPE_OF[nm] + " != " + WANT_TYPE[nm]);
    }
    if (API.DRUM_AXIS_OF && API.DRUM_AXIS_OF[nm] !== WANT_AXIS[nm]) {
      bad.push("页面 DRUM_AXIS_OF." + nm + " = " + API.DRUM_AXIS_OF[nm] + " != " + WANT_AXIS[nm]);
    }
  }
  /* 逐条核对已响的落点 */
  const present = new Set();
  for (const m of metOns) {
    /* ⭐⭐ 2026-10-16：件名 = drum_type（timbre[8:7] & 3），⛔ 不再按 inc 反查
     *   （新位域下鼓的 inc 恒为 0 ⇒ 旧口径会把四件全认成"inc0"）。 */
    const nm = nameOfType(m.type);
    if (WANT_TYPE[nm] === undefined) { bad.push("节拍器用了越界的 drum_type " + m.type); continue; }
    const b = Math.floor(m.tick / WANT_BAR);
    const off = m.tick - b * WANT_BAR;
    const names = offsetNames.get(off);
    if (!names || names.indexOf(nm) < 0) {
      bad.push("落点不在 beat 音型上：第 " + (b + 1) + " 小节 偏移 " + off + " 的 " + nm +
               "（tick " + m.tick + "）");
    }
    if (m.axis !== WANT_AXIS[nm]) bad.push(nm + " 的轴 = " + m.axis + " != " + WANT_AXIS[nm]);
    if (m.guide !== 0) bad.push("节拍器字 bit6 应为 0，实际 " + m.guide + "（tick " + m.tick + "）");
    if (m.tr !== WANT_MET_TR) bad.push("节拍器字的 srcTrack 应为 " + WANT_MET_TR + "，实际 " + m.tr);
    present.add(m.tick + "|" + nm);
  }
  /* 每个期望落点：要么响了，要么有正当的跳过原因（同件谱面鼓在 480 以内） */
  const skipped = [];
  const barDetail = [];
  for (let b = 0; b < bars; b++) {
    const detail = (b < 2) ? [] : null;
    for (const [off, names] of offsetNames) {
      for (const nm of names) {
        const tick = b * WANT_BAR + off;
        const key = tick + "|" + nm;
        /* ⭐ 避让对照按【drum_type】索引（⛔ 不是 inc）—— 与页面的 takenByType 同口径 */
        const hits = scoreTicksByType[WANT_TYPE[nm]] || [];
        const near = hits.filter(t => Math.abs(t - tick) < WANT_GAP);
        if (present.has(key)) { if (detail) detail.push({ tick: tick, off: off, nm: nm, on: true }); continue; }
        if (avoid && near.length) {
          skipped.push({ tick: tick, nm: nm, bar: b });
          if (detail) detail.push({ tick: tick, off: off, nm: nm, on: false, cause: near[0] });
        } else {
          bad.push("该响没响且无正当理由：第 " + (b + 1) + " 小节 偏移 " + off + " 的 " + nm +
                   "（tick " + tick + "）" +
                   (avoid ? "" : "——本档不避让（引导开 + 鼓声=节拍器，谱面鼓会被丢掉），落点必须全响"));
          if (detail) detail.push({ tick: tick, off: off, nm: nm, on: false, cause: null });
        }
      }
    }
    if (detail) barDetail.push({ bar: b, items: detail.sort((x, y) => (x.tick - y.tick) || x.nm.localeCompare(y.nm)) });
  }
  /* 反向：有碰撞原因却没跳过 = 不该响却响了（只在"该避让"的档里有意义） */
  const wrongEmit = [];
  if (avoid) {
    for (const m of metOns) {
      const nm = nameOfType(m.type); if (WANT_TYPE[nm] === undefined) continue;
      const hits = scoreTicksByType[WANT_TYPE[nm]] || [];
      const near = hits.filter(t => Math.abs(t - m.tick) < WANT_GAP);
      if (near.length) wrongEmit.push("tick " + m.tick + " " + nm + "（谱面同件在 " + near[0] + "）");
    }
    if (wrongEmit.length) {
      bad.push("有 " + wrongEmit.length + " 个落点与谱面同件鼓间隔 < " + WANT_GAP + " 却没跳过：" +
               wrongEmit.slice(0, 3).join(" | "));
    }
  } else if (metSkipped !== 0) {
    bad.push("本档不避让（引导开 + 鼓声=节拍器，谱面鼓会被丢掉），页面却报了 metSkipped = " + metSkipped);
  }
  if (skipped.length !== metSkipped) {
    bad.push("按规则独立重算的跳过数 " + skipped.length + " != 页面报的 metSkipped " + metSkipped);
  }
  if (metOns.length !== metCount) {
    bad.push("实际节拍器 on 字数 " + metOns.length + " != 页面报的 metCount " + metCount);
  }
  /* on/off 成对：off 应在 on + 480，且同件（drum_type）同轴 ——
   * ⭐ 手册点名的死线：OFF 也带 is_drum=1 与同一个 drum_type，否则鼓 voice 永久 held。
   * ⚠️ 配对键本来就是 (tick, drum_type, axis)：新位域下鼓的 inc 恒为 0，
   *    若按 inc 配对会把四件混成一个键（判据变弱）。 */
  const offSet = new Set(metOffs.map(o => o.tick + "|" + o.type + "|" + o.axis));
  let offMiss = 0;
  for (const m of metOns) if (!offSet.has((m.tick + WANT_GAP) + "|" + m.type + "|" + m.axis)) offMiss++;
  if (offMiss) bad.push(offMiss + " 个节拍器 on 没有对应的 off（应 = tick + " + WANT_GAP +
                        "，且 drum_type 与轴都相同）");
  /* 逐件统计 */
  const perDrum = {};
  for (const m of metOns) { const nm = nameOfType(m.type); perDrum[nm] = (perDrum[nm] || 0) + 1; }
  const cap = { kick: bars, snare: bars, tom: bars * 2, hihat: bars * 4 };
  for (const nm of Object.keys(perDrum)) {
    if (perDrum[nm] > cap[nm]) bad.push(nm + " 响了 " + perDrum[nm] + " 下，超过每小节上限（共 " + cap[nm] + "）");
  }
  return { ok: bad.length === 0, bad: bad, expectedTotal: expectedTotal, bars: bars,
           perDrum: perDrum, skipped: skipped, barDetail: barDetail, perBarHits: perBarHits,
           avoid: avoid };
}

/* 判据③的另一半：直接调 buildMetronome（taken 传空 = 不避让）验【生成器本身】。
   为什么必须单测生成器：这份测试曲的鼓轨与节拍器落点重合，产物里 80 下被避让掉 50 下，
   光看产物【验不出】"每小节 kick 1 / tom 2 / snare 1 / hihat 4" —— 那是判据③的原话。 */
function pred3gen(met, bars) {
  const bad = [];
  const ons  = met.evs.filter(e => e.kind === API.KIND_ON);
  const offs = met.evs.filter(e => e.kind === API.KIND_OFF);
  const expect = bars * 8;
  if (met.skipped !== 0) bad.push("taken 传空时不该有跳过，实际 skipped = " + met.skipped);
  if (ons.length !== expect) bad.push("on 数 " + ons.length + " != " + bars + "×8 = " + expect);
  if (offs.length !== expect) bad.push("off 数 " + offs.length + " != " + bars + "×8 = " + expect);
  const per = {};
  const tickSet = new Set();
  for (const e of ons) {
    /* 2026-10-16 第三轮：件名 = drum_type = timbre[8:7]（2 位，4 件），
     * ⛔ 不再按 inc 反查（鼓的 inc 恒为 0 ⇒ 四件会全成"inc0"）。 */
    const nm = nameOfType(dtOf(e));
    per[nm] = (per[nm] || 0) + 1;
    tickSet.add(e.tick + "|" + nm);
    if (e.axis !== WANT_AXIS[nm]) bad.push(nm + " 轴 = " + e.axis + " != " + WANT_AXIS[nm] + "（12+dt）");
    if (e.srcTrack !== WANT_MET_TR) bad.push("节拍器 srcTrack 应 = " + WANT_MET_TR + "，实际 " + e.srcTrack);
    if (e.guide) bad.push("节拍器 guide 应为假，实际 " + e.guide);
    /* 新位域（手册 §二 / §三"鼓"通路）：节拍器是鼓 ⇒ is_drum=1 · inc=0 · note_off5=0 */
    if (e.isDrum !== 1) bad.push("节拍器事件必须带 is_drum=1，实际 " + e.isDrum);
    if (e.inc !== 0) bad.push("节拍器（鼓）的 inc 必须为 0，实际 " + e.inc);
    if (e.note5 !== 0) bad.push("节拍器（鼓）的 note_off5 必须为 0，实际 " + e.note5);
  }
  const cap = { kick: bars, snare: bars, tom: bars * 2, hihat: bars * 4 };
  for (const nm of Object.keys(cap)) {
    if ((per[nm] || 0) !== cap[nm]) {
      bad.push(nm + " 多重性不对：" + (per[nm] || 0) + " != " + cap[nm] +
               "（每小节 " + (cap[nm] / bars) + " 下）");
    }
  }
  /* 落点必须逐点命中独立写死的音型 */
  const want = new Set();
  for (let b = 0; b < bars; b++) {
    for (const [nm, off] of WANT_BEAT.beats) want.add((b * WANT_BAR + off) + "|" + nm);
    for (const off of WANT_BEAT.hats) want.add((b * WANT_BAR + off) + "|hihat");
  }
  let miss = 0, extra = 0;
  for (const k of want) if (!tickSet.has(k)) miss++;
  for (const k of tickSet) if (!want.has(k)) extra++;
  if (miss || extra) bad.push("落点与独立音型不符：缺 " + miss + " 个 / 多 " + extra + " 个");
  /* ⚠️ 2026-10-16：配对键从 (tick, inc) 改成 (tick, drum_type, axis) ——
   *    新位域下鼓的 inc 恒为 0，旧键会把四件混成一个键（判据变弱）。 */
  const offSet = new Set(offs.map(e => e.tick + "|" + dtOf(e) + "|" + e.axis));
  let offMiss = 0;
  for (const e of ons) if (!offSet.has((e.tick + WANT_GAP) + "|" + dtOf(e) + "|" + e.axis)) offMiss++;
  if (offMiss) bad.push(offMiss + " 个 on 没有 tick+" + WANT_GAP + " 的 off（同 drum_type 同轴）");
  return { ok: bad.length === 0, bad: bad, per: per, n: ons.length, expect: expect };
}

/* 判据④的谓词 */
function pred4(ons, gap) {
  /* ⭐⭐ 2026-10-16（手册 §二）："同一件"按【drum_type】分组，
   *   ⛔ 不再按 inc —— 新位域下鼓的 inc 恒为 0，按 inc 分组会把四件当成同一件（假红）。 */
  const byType = new Map();
  for (const o of ons) {
    if (!byType.has(o.type)) byType.set(o.type, new Set());
    byType.get(o.type).add(o.tick);
  }
  const per = {};
  let viol = 0, nGap = 0, minAll = Infinity;
  const ex = [];
  for (const [type, set] of byType) {
    const ts = [...set].sort((a, b) => a - b);
    let mn = Infinity;
    for (let i = 1; i < ts.length; i++) {
      const g = ts[i] - ts[i - 1];
      nGap++;
      if (g < mn) mn = g;
      if (g < minAll) minAll = g;
      if (g < gap) {
        viol++;
        if (ex.length < 4) ex.push(nameOfType(type) + " " + ts[i - 1] + "->" + ts[i] + "（间隔 " + g + "）");
      }
    }
    per[nameOfType(type)] = { n: ts.length, min: (mn === Infinity ? null : mn) };
  }
  const bad = [];
  if (viol) bad.push(viol + " 处同一件相邻落点 < " + gap + " tick");
  /* 非空洞：至少要有 10 个间隔可量 */
  if (nGap < 10) bad.push("可量间隔只有 " + nGap + " 个（< 10，这条判据等于没测）");
  return { ok: bad.length === 0, viol: viol, nGap: nGap, bad: bad,
           minAll: (minAll === Infinity ? null : minAll), per: per, ex: ex };
}

/* 判据⑤的谓词 */
const pred5 = n => n > 0;

/* 判据⑦的谓词：解码路径 + guide 位与预期一致 */
function pred7(words, evTrack, idx, onTicks, hexRes) {
  const bad = [];
  let nFieldDiff = 0, nPackDiff = 0, nByteDiff = 0, nIndepDiff = 0;
  const firstDiff = [];
  for (let i = 0; i < words.length; i++) {
    const w = words[i];
    const page = unpack(w);
    const raw = rawOf(w);
    const df = diffFields(page, raw);
    if (df.length) { nFieldDiff++; if (firstDiff.length < 3) firstDiff.push("字 " + i + " 字段不一致：" + df.join(",")); }
    /* ⭐⭐ 2026-10-16：packWord 现在有 9 个入参 —— 必须把 isDrum(bit5) 与 note5(bits[4:0]) 也传进去。
     *   🔴 旧版只传 7 个：新位域一旦被置位就必然往返不等（实测 664 个字报错）——
     *     那不是页面的账，是核对器自己的口径没跟上新位域。 */
    if (API.packWord(page.tick, page.inc, page.axis, page.vel, page.kind, page.timbre,
                     page.guide, page.isDrum, page.note5) !== w) nPackDiff++;
    /* ⭐ 独立编码器往返：覆盖全部 64 位 —— 独立提取若漏了任何一个位域，这里立刻不等。
     *   ⛔ 这条是"独立比对器确实认识了 bit5 / bits[4:0]"的机械证明。 */
    if (mkWord(raw) !== w) nIndepDiff++;
    const by = API.wordToBytes(w);
    let v = 0n;
    for (let j = 0; j < 8; j++) v = (v << 8n) | BigInt(by[j]);
    if (v !== w) nByteDiff++;
    else {
      const dv = unpack(v);
      /* ⭐ 8 字节往返后，新位域（bit5 / bits[4:0]）也必须原样 */
      if (dv.guide !== raw.guide || dv.isDrum !== raw.isDrum || dv.note5 !== raw.note5) nByteDiff++;
    }
  }
  if (nFieldDiff) bad.push("页面 unpackWord 与独立位提取不一致：" + nFieldDiff + " 个字（" + firstDiff.join(" | ") + "）");
  if (nPackDiff) bad.push("packWord(unpackWord(w)) != w：" + nPackDiff + " 个字");
  if (nIndepDiff) bad.push("独立编码器往返不等（独立位提取漏了位域）：" + nIndepDiff + " 个字");
  if (nByteDiff) bad.push("8 字节序列化往返不一致：" + nByteDiff + " 个字");
  /* guide 位集合 == 引导轨的字集合 */
  const guideIdx = [];
  for (let i = 0; i < words.length; i++) if (unpack(words[i]).guide === 1) guideIdx.push(i);
  const wrongTr = guideIdx.filter(i => evTrack[i] !== idx);
  if (wrongTr.length) bad.push("解回来的置位字有 " + wrongTr.length + " 个不属于引导轨");
  const expect = onTicks.length * 2;
  if (guideIdx.length !== expect) bad.push("解回来的置位字数 " + guideIdx.length + " != 预期 " + expect);
  /* 磁盘产物（若在）：每一行的 guide 位必须与原始 bit6 一致 */
  if (hexRes && hexRes.present) {
    if (hexRes.badHex) bad.push("events.hex 有 " + hexRes.badHex + " 行不是 16 位十六进制");
    if (hexRes.badGuide) bad.push("events.hex 有 " + hexRes.badGuide + " 行的 unpackWord.guide 与原始 bit6 不一致");
  }
  return { ok: bad.length === 0, bad: bad, n: words.length,
           nFieldDiff: nFieldDiff, nPackDiff: nPackDiff, nByteDiff: nByteDiff,
           nIndepDiff: nIndepDiff,
           guideCount: guideIdx.length, expect: expect };
}

/* 判据⑧的谓词：UI 填充路径。
   这条路只有"打开 MIDI"时才走（boot 之后由 openFile 调），前面七条判据一条都不覆盖它
   ⇒ 它抛异常的话，引导轨下拉是空的、状态行是旧的，而产物层面全绿。
   所以这里直接调页面的 buildTrackPicker(conv)，断言"不抛异常 + 下拉内容正确"。 */
function pred8(conv, idx) {
  const bad = [];
  let threw = null;
  setGuide(true, idx, true, "beat");
  API.__setLastConv(conv);              /* updateGuideSummary() 读的是 lastConv */
  try { API.buildTrackPicker(conv); }
  catch (e) { threw = (e && e.constructor ? e.constructor.name : "Error") + ": " + (e && e.message); }
  if (threw) bad.push("buildTrackPicker 抛异常：" + threw);
  const html = String(doc.getElementById("gd_track").innerHTML || "");
  const tags = [...html.matchAll(/<option\b[^>]*>/g)].map(m => m[0]);
  const valOf = tag => { const m = tag.match(/value="([^"]*)"/); return m ? m[1] : null; };
  /* 只数【可选轨】的 option：页面第一项是 '（不选）'（value=""）占位，那不是一条轨 */
  const trackTags = tags.filter(t => { const v = valOf(t); return v !== null && v !== ""; });
  const nonDrum = conv.trackList.filter(t => !t.drum);
  if (trackTags.length !== nonDrum.length) {
    bad.push("下拉里可选轨 option 数 " + trackTags.length + " != 非鼓轨数 " + nonDrum.length);
  }
  const vals = trackTags.map(valOf);
  const wantVals = nonDrum.map(t => String(t.idx));
  for (const w of wantVals) if (vals.indexOf(w) < 0) bad.push("非鼓轨 " + w + " 没有对应的 option");
  for (const v of vals) if (wantVals.indexOf(v) < 0) bad.push("多出一个 option value=" + v + "（鼓轨不该出现）");
  if (new Set(vals).size !== vals.length) bad.push("option 有重复：[" + vals.join(",") + "]");
  /* 引导轨那一项必须带 selected，且只有它带 */
  const selTag = tags.find(t => valOf(t) === String(idx));
  if (!selTag) bad.push("找不到引导轨 " + idx + " 的 option");
  else if (!/\bselected\b/.test(selTag)) bad.push("引导轨 " + idx + " 的 option 没有 selected：" + selTag);
  const otherSel = tags.filter(t => /\bselected\b/.test(t) && valOf(t) !== String(idx));
  if (otherSel.length) bad.push("除引导轨外还有 " + otherSel.length + " 个 option 带 selected");
  /* 状态行必须含"仅指引" */
  const sum = String(doc.getElementById("gd_sum").textContent || "");
  if (sum.indexOf("仅指引") < 0) bad.push("gd_sum 不含「仅指引」：" + JSON.stringify(sum));
  return { ok: bad.length === 0, bad: bad, threw: threw, tags: tags, trackTags: trackTags,
           vals: vals, nonDrum: nonDrum, sum: sum, selTag: selTag };
}

/* ===========================================================================
   反控构造
   =========================================================================== */
const wordsOf = conv => decWords(conv);

/* 主产物的关键切片 */
/* ⭐⭐ 2026-10-16（手册 §二）：节拍器/谱面鼓一律带上【drum_type = timbre[8:7] & 3】——
 *   ⛔ 不再带 inc 当件标识（新位域下鼓的 inc 恒为 0，四件会全挤成一个键）。
 *   ⚠️ inc 仍留着，判据⑮ 要用它查"鼓的 inc 必须为 0"。 */
const mainDec = wordsOf(convMain);
const metOnsMain  = mainDec.filter(o => isMetWord(o.d, o.tr) && o.d.kind === API.KIND_ON)
                           .map(o => ({ tick: o.d.tick, type: dtOf(o.d), inc: o.d.inc,
                                        axis: o.d.axis, guide: o.d.guide, note5: o.d.note5, tr: o.tr }));
const metOffsMain = mainDec.filter(o => isMetWord(o.d, o.tr) && o.d.kind === API.KIND_OFF)
                           .map(o => ({ tick: o.d.tick, type: dtOf(o.d), inc: o.d.inc,
                                        axis: o.d.axis, guide: o.d.guide, note5: o.d.note5, tr: o.tr }));
/* 鼓声=两者（避让档）的节拍器字：判据③的另一半要用它 */
const decBoth = decWords(convBoth);
const metOnsBoth  = decBoth.filter(o => isMetWord(o.d, o.tr) && o.d.kind === API.KIND_ON)
                           .map(o => ({ tick: o.d.tick, type: dtOf(o.d), inc: o.d.inc,
                                        axis: o.d.axis, guide: o.d.guide, note5: o.d.note5, tr: o.tr }));
const metOffsBoth = decBoth.filter(o => isMetWord(o.d, o.tr) && o.d.kind === API.KIND_OFF)
                           .map(o => ({ tick: o.d.tick, type: dtOf(o.d), inc: o.d.inc,
                                        axis: o.d.axis, guide: o.d.guide, note5: o.d.note5, tr: o.tr }));
/* 谱面鼓（非节拍器）的【落点】：节拍器避让规则要用它独立重算。
   注意：只取 kind=ON，不含 off —— 方案 B 的约束是"同一件鼓相邻【落点】>= 480"，
   把 off 也算进去会过度跳过（页面的 taken 同口径，见 buildMetronome 调用处的注释）。
   判据④也是按 ON 去重量间隔的，两条口径必须一致，否则③会出假阳。
   ⭐⭐ 2026-10-16：索引键改成【drum_type】（手册 §二）——
   新位域下鼓的 inc 恒为 0，再按 inc 索引会让四件全挤进同一个键（或压根查不到）
   ⇒ 避让判断静默失效。鼓的识别也从"轴号 12..15"改成【is_drum=1】。 */
const scoreTicksByType = {};
for (const o of mainDec) {
  if (isMetWord(o.d, o.tr)) continue;
  if (o.d.isDrum !== 1) continue;
  if (o.d.kind !== API.KIND_ON) continue;
  const dt = dtOf(o.d);
  (scoreTicksByType[dt] = scoreTicksByType[dt] || []).push(o.d.tick);
}
/* 谱面长度（不含节拍器字）=> 独立算小节数 */
let scoreTickMax = 0;
for (const o of mainDec) if (!isMetWord(o.d, o.tr)) scoreTickMax = Math.max(scoreTickMax, o.d.tick);
const BARS = Math.ceil(scoreTickMax / WANT_BAR);

/* 反控 1：全置位 —— 每轨轮流当引导轨，取并集（"每条轨都置位"） */
const rot = [];
let rotSame = true;
for (const t of tracks) {
  /* ⚠️ scope/drum 必须【显式传】：页面钩子只设"传了的"参数，
     少传就会沿用上一个调用的档 ⇒ 字数都不一样（实测踩过：这里漏传导致 638 vs 736，直接抛错）。 */
  const c = runGuide(true, t.idx, true, "beat", "all", "met");
  const same = c.words.length === convMain.words.length &&
               c.words.every((w, i) => (w & ~BIT_GUIDE) === (convMain.words[i] & ~BIT_GUIDE));
  if (!same) rotSame = false;
  rot.push({ idx: t.idx, words: c.words, same: same,
             g: c.words.filter(w => unpack(w).guide === 1).length });
}
const allSet = convMain.words.map((w, i) => {
  let g = false;
  for (const r of rot) if (unpack(r.words[i]).guide === 1) { g = true; break; }
  return g ? (w | BIT_GUIDE) : (w & ~BIT_GUIDE);
});
/* 反控 3：错轨 —— 找两条音符数相同的非鼓轨，把 A 当引导轨却按 B 的预期判 */
let wrongPair = null;
for (let i = 0; i < tuned.length; i++) {
  for (let j = i + 1; j < tuned.length; j++) {
    if (tuned[i].onCount === tuned[j].onCount) { wrongPair = [tuned[i], tuned[j]]; break; }
  }
  if (wrongPair) break;
}
let ctlWrong = null, ctlWrongRun = null;
if (wrongPair) {
  ctlWrongRun = runGuide(true, wrongPair[0].idx, true, "beat", "all", "met");
  ctlWrong = pred1(ctlWrongRun.words, ctlWrongRun.evTrack, wrongPair[1].idx, wrongPair[1].onTicks);
}
/* 反控 4（判据⑦用）：把一条非引导轨的字的 bit6 硬置 1 */
let corruptedIdx = -1;
for (let i = 0; i < convMain.words.length; i++) {
  if (convMain.evTrack[i] !== K && unpack(convMain.words[i]).guide === 0) { corruptedIdx = i; break; }
}
const corrupt7 = convMain.words.slice();
if (corruptedIdx >= 0) corrupt7[corruptedIdx] = corrupt7[corruptedIdx] | BIT_GUIDE;

/* 磁盘产物回读（只读，不写文件） */
const hexRes = { present: false };
if (fs.existsSync(hexPath)) {
  const lines = fs.readFileSync(hexPath, "utf8").split(/\r?\n/).filter(s => s.trim().length > 0);
  let badHex = 0, badGuide = 0, guideInHex = 0;
  const ws = [];
  for (const ln of lines) {
    const s = ln.trim();
    if (!/^[0-9a-fA-F]{1,16}$/.test(s)) { badHex++; continue; }
    const w = BigInt("0x" + s);
    ws.push(w);
    const d = unpack(w);
    if (d.guide !== Number((w >> 6n) & M_GUIDE)) badGuide++;
    if (d.guide === 1) guideInHex++;
  }
  const eqBase = ws.length === convBase.words.length && ws.every((w, i) => w === convBase.words[i]);
  const eqMain = ws.length === convMain.words.length && ws.every((w, i) => w === convMain.words[i]);
  hexRes.present = true; hexRes.lines = lines.length; hexRes.badHex = badHex;
  hexRes.badGuide = badGuide; hexRes.guideInHex = guideInHex; hexRes.eqBase = eqBase; hexRes.eqMain = eqMain;
}

/* ===========================================================================
   报告：测试钩子 / 轨道表
   =========================================================================== */
console.log();
console.log("【零】测试钩子与输入");
if (pageHook) {
  console.log("  测试钩子：使用页面自带的 __setGuide()");
} else {
  console.log("  测试钩子：页面【还没有】__setGuide() —— 直接调用它的报错原文：");
  console.log("      " + (hookErrText || "(调用未抛错，但 typeof 也不是 function)"));
  console.log("      回退：直接写页面自己的模块级状态 guideOn / guideTrackIdx / metOn / metStyle");
  console.log("      （与钩子等价：判据只依赖 midiToWords 读的那四个变量）");
  console.log("      注意：本脚本不改 score_studio.html，此项只报告、不计入 RED。");
}
console.log("  解析：division = " + parsed.division + " · PPQN = " + API.MIDI_PPQN +
            " · 缩放 SCALE = " + SCALE + " · 轨数 = " + parsed.tracks.length +
            " · tempo 点 = " + parsed.allTempos.length);
console.log("  页面常数：BAR_TICK = " + API.BAR_TICK + " · DRUM_DUR_TICK = " + API.DRUM_DUR_TICK +
            " · DRUM_AXIS_OF = " + JSON.stringify(API.DRUM_AXIS_OF));
console.log("  独立期望：小节 = " + WANT_BAR + " · 同件间隔下限 = " + WANT_GAP +
            " · 轴 = " + JSON.stringify(WANT_AXIS) + " · beat 音型 = " +
            JSON.stringify(WANT_BEAT.beats) + " + 踩镲 " + JSON.stringify(WANT_BEAT.hats));
console.log("  引导轨 = 轨 " + K + "「" + gTrack.name + "」（非鼓、音符最多：" + gTrack.onCount + " 个音）");
console.log("  谱面长度 = " + scoreTickMax + " tick => 小节数 = " + BARS +
            "（页面 metEnd = " + (convBase.tickMax) + "）");
{
  const uiIds = ["gd_on", "gd_track", "gd_met", "gd_style", "gd_sum"];
  const have = uiIds.filter(id => htmlSrc.indexOf('id="' + id + '"') >= 0);
  console.log("  UI id（报告项，非判据）：" + have.join("/") + (have.length === uiIds.length ? " 全在" : "  缺 " + uiIds.filter(x => have.indexOf(x) < 0).join("/")));
}

console.log();
console.log("  轨表（字总数 / bit6=1 均取【主产物：引导 + 节拍器】）");
console.log("  轨  | 轨名        | 音符(on) | 字总数 | bit6=1 | 角色");
console.log("  ----|-------------|----------|--------|--------|----------------");
{
  const st = pred2(convMain.words, convMain.evTrack, K).st;
  const order = [...st.keys()].sort((a, b) => (a < 0 && b < 0) ? (b - a) : (a < 0 ? 1 : b < 0 ? -1 : a - b));
  for (const tr of order) {
    const s = st.get(tr);
    const t = tracks.find(x => x.idx === tr);
    const nm = t ? t.name : (tr === WANT_MET_TR ? "（节拍器）" : "（公共事件）");
    const role = tr === K ? "引导轨" : (tr === WANT_TEMPO_TR ? "公共" : (tr === WANT_MET_TR ? "节拍器" : (t && t.drum ? "鼓" : "背景")));
    console.log("  " + String(tr).padEnd(4) + "| " + String(nm).padEnd(12) + "| " +
      String(t ? t.onCount : "-").padEnd(9) + "| " + String(s.total).padEnd(7) + "| " +
      String(s.guide).padEnd(7) + "| " + role);
  }
}

/* ===========================================================================
   十三条判据（每条都配反控）
   =========================================================================== */
let red = 0, nJudge = 0, mutJudgeOk = null;
const redList = [];
const judge = (no, name, cond, extra) => {
  console.log("  " + (cond ? "[OK] " : "[RED]") + no + " " + name.padEnd(50) + (extra || ""));
  nJudge++;
  if (!cond) { red++; redList.push(no); }
};
const ev = s => console.log("       " + s);
const ctl = s => console.log("       反控 " + s);

console.log();
console.log("【一】判据（反控不红 = 该判据可能是恒真的假绿）");

/* ---------------- ① ---------------- */
const main1 = pred1(convMain.words, convMain.evTrack, K, gTrack.onTicks);
judge("①", "引导轨的字 bit6=1，且数量 = 音符数×2（on/off 成对）", main1.ok,
  "置位 " + main1.n + " 字 / 期望 " + main1.expect);
ev("音符(on) " + gTrack.onCount + " × 2 = " + main1.expect + " · 置位 " + main1.n +
   "（on " + main1.nOn + " / off " + main1.nOff + "）· 用到轴 " + main1.axes.join(","));
ev("该轨 note 事件 " + gTrack.evCount + " 个（on " + gTrack.onCount + " + off " + gTrack.offCount +
   "）= 该轨字总数，二者一致");
if (!main1.ok) main1.bad.forEach(b => ev("未过原因：" + b));

/* ---------------- ② ---------------- */
const main2 = pred2(convMain.words, convMain.evTrack, K);
judge("②", "其余轨（含鼓轨与公共事件）的字 bit6=0", main2.ok,
  (() => { const p = []; for (const [tr, s] of main2.st) if (tr !== K) p.push("轨" + tr + " " + s.guide + "/" + s.total); return p.join(" · "); })());
if (!main2.ok) main2.bad.forEach(b => ev("未过原因：" + b));
{
  /* 反控：把一条别的轨的字 bit6 硬置 1 => 判据②必须红 */
  const c = convMain.words.slice();
  const at = convMain.evTrack.findIndex((tr, i) => tr !== K && unpack(c[i]).guide === 0);
  if (at >= 0) {
    c[at] = c[at] | BIT_GUIDE;
    const r = pred2(c, convMain.evTrack, K);
    ctl("把轨 " + convMain.evTrack[at] + " 的下标 " + at + " 那个字 bit6 置 1 -> 判据② " +
        (r.ok ? "仍然绿（判据失效）" : "变红（符合预期）"));
  } else {
    ctl("找不到可置位的别轨字（无法构造）");
  }
}

/* ---------------- ③ ---------------- */
/* 主产物 = met 档（引导开）⇒ 页面新规则：谱面鼓会被丢 ⇒ 节拍器【不避让】⇒ 落点必须全响 */
const main3 = pred3(metOnsMain, metOffsMain, convMain.metCount, convMain.metSkipped,
                    BARS, scoreTicksByType, avoidMain);
/* 另一档：鼓声=两者 ⇒ 谱面鼓会响 ⇒ 仍然避让（同一件 >= 480），按独立重算逐点核对 */
const main3b = pred3(metOnsBoth, metOffsBoth, convBoth.metCount, convBoth.metSkipped,
                     BARS, scoreTicksByType, avoidBoth);
/* 生成器单测：taken 传空 => 不避让 => 每小节必须正好是音型那 8 下 */
setGuide(true, K, true, "beat", "all", "met");
const gen3 = pred3gen(API.buildMetronome(scoreTickMax, {}), BARS);
judge("③", "节拍器落点与数量正确（beat 每小节 8 下；避让与否随鼓声档）", main3.ok && gen3.ok && main3b.ok,
  "生成器 " + gen3.n + "/" + gen3.expect + " 下 · met 档（不避让）响 " + convMain.metCount +
  " + 跳过 " + convMain.metSkipped + " = " + BARS + "×" + main3.perBarHits +
  " · both 档（避让）响 " + convBoth.metCount + " + 跳过 " + convBoth.metSkipped);
ev("生成器单测（buildMetronome(tickMax, {}) 不避让）：" + JSON.stringify(gen3.per) +
   " · 期望 kick " + BARS + " / tom " + (BARS * 2) + " / snare " + BARS + " / hihat " + (BARS * 4) +
   " = " + gen3.expect + " 下 · 落点逐点命中独立音型");
ev("页面新规则（2026-10-16）：guideOn && guideDrum===\"met\" ⇒ 谱面鼓轨会被丢掉 ⇒ 节拍器【不再避让】" +
   "（否则会在本该响的拍点上留洞）；track / both 档才按同一件 >= " + WANT_GAP + " 避让。");
ev("  met 档：响 " + convMain.metCount + " + 跳过 " + convMain.metSkipped + " = " +
   (convMain.metCount + convMain.metSkipped) + "（不避让 ⇒ 跳过必须为 0，落点必须全响）");
ev("  both 档：响 " + convBoth.metCount + " + 跳过 " + convBoth.metSkipped + " = " +
   (convBoth.metCount + convBoth.metSkipped) + "（避让 ⇒ 跳过数与独立重算一致）");
ev("  （为什么还要单测生成器：避让档里落点被跳掉大半，光看产物验不出每件每小节几下 —— 那是判据③的原话。）");
if (!gen3.ok) gen3.bad.forEach(b => ev("生成器未过原因：" + b));
ev("逐件（met 档）：响 " + JSON.stringify(main3.perDrum) + " · 跳过 " + main3.skipped.length +
   " 下（每件上限 kick " + BARS + "/snare " + BARS + "/tom " + (BARS * 2) + "/hihat " + (BARS * 4) + "）");
for (const bd of main3.barDetail) {
  ev("第 " + (bd.bar + 1) + " 小节落点（" + bd.items.length + " 个期望点）：");
  for (const it of bd.items) {
    console.log("         tick " + String(it.tick).padEnd(6) + " 偏移 " + String(it.off).padEnd(5) +
      it.nm.padEnd(7) + (it.on ? "已响" : (it.cause != null
        ? "跳过（谱面同件鼓 tick " + it.cause + "，距离 " + Math.abs(it.cause - it.tick) + " < " + WANT_GAP + "）"
        : "该响没响且无正当理由")));
  }
}
if (!main3.ok) main3.bad.forEach(b => ev("未过原因（met 档）：" + b));
if (!main3b.ok) main3b.bad.forEach(b => ev("未过原因（both 档）：" + b));
{
  /* 反控 a：抽掉一个已响的落点 => 守恒/落点核对必须红 */
  const a = metOnsMain.slice(0, Math.max(0, metOnsMain.length - 1));
  const ra = pred3(a, metOffsMain, convMain.metCount, convMain.metSkipped, BARS, scoreTicksByType, avoidMain);
  ctl("抽掉 1 个节拍器落点 -> 判据③ " + (ra.ok ? "仍然绿（判据失效）" : "变红（符合预期）"));
  /* 反控 b：把一个落点挪到音型外（+120 tick）=> 必须红 */
  const b = metOnsMain.map((m, i) => i === 0 ? Object.assign({}, m, { tick: m.tick + 120 }) : m);
  const rb = pred3(b, metOffsMain, convMain.metCount, convMain.metSkipped, BARS, scoreTicksByType, avoidMain);
  ctl("把第 1 个落点挪到音型外（+120 tick）-> 判据③ " + (rb.ok ? "仍然绿（判据失效）" : "变红（符合预期）"));
  /* 反控 c：小节数多报 1 => 生成器的数量核对必须红 */
  const rc = pred3gen(API.buildMetronome(scoreTickMax, {}), BARS + 1);
  ctl("把小节数多报 1（" + (BARS + 1) + "）-> 判据③生成器 " +
      (rc.ok ? "仍然绿（判据失效）" : "变红（符合预期）") + "：" + (rc.bad[0] || "（无未过原因）"));
  /* 反控 d：音型换 four，却拿 beat 的期望去判 => 必须红
     （证明落点与多重性判据认得出【音型】，而不是只数个数） */
  setGuide(true, K, true, "four", "all", "met");
  const rd = pred3gen(API.buildMetronome(scoreTickMax, {}), BARS);
  ctl("音型换 four、却按 beat 的期望判 -> 判据③生成器 " +
      (rd.ok ? "仍然绿（判据失效）" : "变红（符合预期）") + "：" + (rd.bad[0] || "（无未过原因）"));
  setGuide(true, K, true, "beat", "all", "met");
  /* 反控 e：把 met 档（不避让）按"该避让"去判 => 必须红（证明 avoid 这个开关是有用的） */
  const re = pred3(metOnsMain, metOffsMain, convMain.metCount, convMain.metSkipped,
                   BARS, scoreTicksByType, true);
  ctl("把 met 档（不避让）按「该避让」去判 -> 判据③ " +
      (re.ok ? "仍然绿（判据失效）" : "变红（符合预期）") + "：" + (re.bad[0] || "（无未过原因）"));
  /* 反控 f：把 both 档（避让）按"不避让"去判 => 必须红 */
  const rf = pred3(metOnsBoth, metOffsBoth, convBoth.metCount, convBoth.metSkipped,
                   BARS, scoreTicksByType, false);
  ctl("把 both 档（避让，跳了 " + convBoth.metSkipped + " 下）按「不避让」去判 -> 判据③ " +
      (rf.ok ? "仍然绿（判据失效）" : "变红（符合预期）") + "：" + (rf.bad[0] || "（无未过原因）"));
}

/* ---------------- ④ ---------------- */
/* ⭐ 2026-10-16：④ 的对象改成【实际灌下去的那一份】（visibleWords）。
   为什么：新规则下 met 档的节拍器不再避让谱面鼓，而谱面鼓【本来就不会被发下去】——
   约束"同一件鼓相邻落点 >= 480"是给 FPGA 的，只对真正会响的字有意义。
   两种档都验：met 档（只剩节拍器）与 both 档（节拍器 + 谱面鼓全在，= 全量）。 */
const drumOnsMain = mainDec.filter(o => o.d.isDrum === 1 && o.d.kind === API.KIND_ON)
                           .map(o => ({ type: dtOf(o.d), tick: o.d.tick, met: isMetWord(o.d, o.tr) }));
const visDrumOns = vis => vis.filter(w => unpack(w).isDrum === 1 && unpack(w).kind === API.KIND_ON)
                             .map(w => ({ type: dtOf(unpack(w)), tick: unpack(w).tick }));
/* ④ 自己要用的可见字：直接调页面的 visibleWords 取（⛔ 不依赖后面 ⑨..⑬ 的快照块） */
const visFor = (scope, drum) => {
  if (typeof API.__setTrackSel === "function") API.__setTrackSel(null);
  setGuide(true, K, true, "beat", scope, drum);
  const c = API.midiToWords(parsed);
  return (typeof API.visibleWords === "function") ? API.visibleWords(c) : null;
};
const onsMetVis  = visDrumOns(visFor("all", "met") || []);
const onsBothVis = visDrumOns(visFor("all", "both") || []);
const main4 = pred4(onsMetVis, WANT_GAP);
const main4b = pred4(onsBothVis, WANT_GAP);
judge("④", "同一件鼓相邻落点间隔 >= " + WANT_GAP + " tick（方案 B，跨件不限）", main4.ok && main4b.ok,
  "met 档可见字：最小 " + main4.minAll + " · " + main4.nGap + " 个间隔 · 违规 " + main4.viol +
  " ｜ both 档：最小 " + main4b.minAll + " · " + main4b.nGap + " 个间隔 · 违规 " + main4b.viol);
ev("对象 = visibleWords（所见即所灌），不是全量字表：全量里 met 档的谱面鼓字【不会发下去】，" +
   "拿它去量 480 只会量出一堆不存在的碰撞。");
ev("met 档逐件：" + Object.entries(main4.per).map(([k, v]) => k + " " + v.n + "下/最小" + v.min).join(" · "));
ev("both 档逐件：" + Object.entries(main4b.per).map(([k, v]) => k + " " + v.n + "下/最小" + v.min).join(" · "));
ev("（报告）全量字表里 met 档的鼓轴落点 " + drumOnsMain.length + " 个（节拍器 " +
   drumOnsMain.filter(o => o.met).length + " + 谱面鼓 " + drumOnsMain.filter(o => !o.met).length +
   "）—— 它们不再要求互不碰撞");
if (!main4.ok) { main4.ex.forEach(b => ev("太近(met)：" + b)); main4.bad.forEach(b => ev("未过原因：" + b)); }
if (!main4b.ok) { main4b.ex.forEach(b => ev("太近(both)：" + b)); main4b.bad.forEach(b => ev("未过原因：" + b)); }
{
  /* 反控：往同件里塞一个 240 tick 的邻居 => 必须红
   * ⭐ 2026-10-16：件标识改成 drum_type（⛔ 不再是 inc）—— 新位域下鼓的 inc 恒为 0。 */
  const kickType = WANT_TYPE.kick;                        /* = 0，独立写死（⛔ 不读页面的表） */
  const kicks = drumOnsMain.filter(o => o.type === kickType).map(o => o.tick).sort((a, b) => a - b);
  const c = drumOnsMain.concat([{ type: kickType, tick: kicks[0] + 240, met: true }]);
  const rc = pred4(c, WANT_GAP);
  ctl("在 kick 的 " + kicks[0] + " 之后 240 tick 插一下 -> 判据④ " +
      (rc.ok ? "仍然绿（判据失效）" : "变红（符合预期，报 " + rc.viol + " 处）"));
  /* ⭐ 追加反控（2026-10-16）：证明 ④ 的"同一件"确实是按【drum_type】分组的（跨件不约束）——
   *   ① 在 snare 的某一下之后 240 tick 插一个 kick ⇒ 不同件 ⇒ 必须【仍然绿】（方案 B 只约束同一件）；
   *   ② 同一位置改成插 snare ⇒ 同件 ⇒ 必须【变红】。
   *   ⛔ 上一版这里写的"把 kick 的 drum_type 改错"证明不了分组键：改完之后 kick 组里只剩新插的那个，
   *      组内没有邻居 ⇒ 本来就该绿（那是判据正确，不是判据失效）。 */
  const snareTicks = drumOnsMain.filter(o => o.type === WANT_TYPE.snare).map(o => o.tick).sort((a, b) => a - b);
  const kickTicks  = drumOnsMain.filter(o => o.type === WANT_TYPE.kick).map(o => o.tick);
  /* ⚠️ 跨件反控要挑一个【离所有 kick 都 >= 480】的位置 ——
   *   随手取 snare+240 会撞上已有的 kick（实测 snare@960 ⇒ 1200 附近本来就有 kick ⇒ 假红）。 */
  let crossTick = -1;
  for (const st of snareTicks) {
    const t = st + 240;
    if (kickTicks.every(k => Math.abs(k - t) >= WANT_GAP)) { crossTick = t; break; }
  }
  if (snareTicks.length && crossTick >= 0) {
    const cross = pred4(drumOnsMain.concat([{ type: WANT_TYPE.kick, tick: crossTick, met: true }]), WANT_GAP);
    ctl("在 snare 附近（tick " + crossTick + "，离所有 kick 都 >= " + WANT_GAP + "）插一个【kick】（跨件）-> 判据④ " +
        (cross.ok ? "仍然绿（符合预期：方案 B 只约束同一件）" : "变红（判据过严：跨件不该被约束）"));
    const st0 = snareTicks[0];
    const same = pred4(drumOnsMain.concat([{ type: WANT_TYPE.snare, tick: st0 + 240, met: true }]), WANT_GAP);
    ctl("在 snare 的 " + st0 + " 之后 240 tick 插一个【snare】（同件）-> 判据④ " +
        (same.ok ? "仍然绿（判据失效：同件 240 没抓住）" : "变红（符合预期，报 " + same.viol + " 处）"));
  } else {
    ctl("这份产物里没有 snare 落点 / 找不到离 kick 足够远的构造点（无法构造跨件对照）");
  }
}

/* ---------------- ⑤ ---------------- */
const guideBits = convMain.words.filter(w => unpack(w).guide === 1).length;
const main5 = pred5(guideBits) && (convMain.guideWords === guideBits);
judge("⑤", "全曲 bit6=1 的字数 > 0（非空洞）", main5,
  "实际置位 " + guideBits + " 字 · 页面 guideWords 账 = " + convMain.guideWords);
if (!main5) ev("未过原因：置位 " + guideBits + " 字，页面账 " + convMain.guideWords + "（两者须相等且 > 0）");
{
  /* 反控：关闭引导 => 必须红 */
  const zeroBits = convZero.words.filter(w => unpack(w).guide === 1).length;
  ctl("关掉引导（guideOn=false）-> 置位 " + zeroBits + " 字，判据⑤ " +
      (pred5(zeroBits) ? "仍然绿（判据失效）" : "变红（符合预期）"));
}

/* ---------------- ⑥ ---------------- */
const ctlAllSet = pred1(allSet, convMain.evTrack, K, gTrack.onTicks);
const ctlZeroR  = pred1(convZero.words, convZero.evTrack, K, gTrack.onTicks);
const ok6 = main1.ok && !ctlAllSet.ok && !ctlZeroR.ok && (ctlWrong ? !ctlWrong.ok : false) && rotSame;
judge("⑥", "反向证伪：全置位/全零/错轨 三种反控下判据①必须红", ok6,
  "全置位 " + (ctlAllSet.ok ? "绿(失效)" : "红") + " · 全零 " + (ctlZeroR.ok ? "绿(失效)" : "红") +
  " · 错轨 " + (ctlWrong ? (ctlWrong.ok ? "绿(失效)" : "红") : "无法构造"));
ev("结构不变量：每轨轮流置位产物的（清掉 bit6 后）字序列与主产物逐字相同 = " + rotSame +
   "（不相同则反控本身无效）");
ev("每轨轮流置位得到的置位数：" + rot.map(r => "轨" + r.idx + "=" + r.g).join(" · "));
ctl("a 全置位（并集）-> 判据① " + (ctlAllSet.ok ? "仍然绿（判据失效）" : "变红（符合预期）") +
    "：置位 " + ctlAllSet.n + " 字 vs 期望 " + ctlAllSet.expect + "（" +
    (ctlAllSet.bad[0] || "无未过原因") + "）");
ctl("b 全零（关引导）-> 判据① " + (ctlZeroR.ok ? "仍然绿（判据失效）" : "变红（符合预期）") +
    "：置位 " + ctlZeroR.n + " 字 vs 期望 " + ctlZeroR.expect);
if (ctlWrong) {
  ctl("c 错轨：把轨 " + wrongPair[0].idx + "「" + wrongPair[0].name + "」当引导轨，" +
      "却按轨 " + wrongPair[1].idx + "「" + wrongPair[1].name + "」的预期判（两轨音符数都是 " +
      wrongPair[1].onCount + "，数量对得上，只能靠轨身份抓）-> 判据① " +
      (ctlWrong.ok ? "仍然绿（判据失效）" : "变红（符合预期）") + "：" +
      (ctlWrong.bad[0] || "无未过原因"));
} else {
  ctl("c 错轨：找不到音符数相同的两条非鼓轨，无法构造");
}

/* ---------------- ⑦ ---------------- */
const main7 = pred7(convMain.words, convMain.evTrack, K, gTrack.onTicks, hexRes);
judge("⑦", "回读：unpackWord 解回的 guide 位与预期一致", main7.ok,
  "解回置位 " + main7.guideCount + " 字 / 预期 " + main7.expect);
ev("字段逐项比对（页面 unpackWord vs 独立位提取）：不一致 " + main7.nFieldDiff + " 字 · " +
   "packWord 往返不符 " + main7.nPackDiff + " 字 · 独立编码器往返不符 " + main7.nIndepDiff +
   " 字 · 8 字节往返不符 " + main7.nByteDiff + " 字");
ev("  （独立位提取与独立编码器都【不调页面的 unpackWord/packWord】——" +
   "覆盖 64 位：tick20+inc21+axis4+vel8+kind2+timbre2+guide1+isDrum1+note5 5，" +
   "⛔ 不是拿被验者验自己）");
if (hexRes.present) {
  ev("磁盘产物 " + path.basename(hexPath) + "：" + hexRes.lines + " 行 · 非法行 " + hexRes.badHex +
     " · guide 位与原始 bit6 不符 " + hexRes.badGuide + " 行 · 该文件里 bit6=1 的字 " + hexRes.guideInHex +
     " 个 · 与「无引导无节拍器」产物逐字相同 = " + hexRes.eqBase + " · 与主产物相同 = " + hexRes.eqMain);
  ev("  （该 hex 是引导模式之前生成的产物，bit6 全 0 属正常；这里验的是它的解码一致性）");
} else {
  ev("磁盘产物 " + hexPath + " 不存在 => 只验内存字（该项跳过，不计入 RED）");
}
if (!main7.ok) main7.bad.forEach(b => ev("未过原因：" + b));
{
  /* 反控 a：比对器不能是恒真的 —— 故意改一个字段，必须报不一致 */
  const s = rawOf(convMain.words[0]);
  const wrong = Object.assign({}, s, { axis: (s.axis + 1) & 15 });
  ctl("比对器自检：把 axis 改错 1 -> 报不一致字段 " + JSON.stringify(diffFields(wrong, s)) +
      (diffFields(wrong, s).length ? "（符合预期）" : "（比对器恒真，失效）"));
  /* 反控 b：把一条非引导轨的字 bit6 置 1 => guide 位与预期不一致，必须红 */
  if (corruptedIdx >= 0) {
    const r = pred7(corrupt7, convMain.evTrack, K, gTrack.onTicks, hexRes);
    ctl("把下标 " + corruptedIdx + "（源轨 " + convMain.evTrack[corruptedIdx] +
        "）那个字的 bit6 置 1 -> 判据⑦ " + (r.ok ? "仍然绿（判据失效）" : "变红（符合预期）") +
        "：解回置位 " + r.guideCount + " vs 预期 " + r.expect);
  }
}

/* ---------------- ⑧ ---------------- */
const main8 = pred8(convMain, K);
/* 反控：把引导轨换成另一条非鼓轨再填充一次 => selected 必须跟着换（证明它不是写死的） */
const otherTuned = tuned.find(t => t.idx !== K);
const ctl8 = pred8(convMain, otherTuned.idx);
const tagOfVal = (tags, v) =>
  tags.find(t => { const m = t.match(/value="([^"]*)"/); return m && m[1] === String(v); });
const moved8 = /\bselected\b/.test(tagOfVal(ctl8.tags, otherTuned.idx) || "") &&
               !/\bselected\b/.test(tagOfVal(ctl8.tags, K) || "");
pred8(convMain, K);                     /* 复原成引导轨 K */
judge("⑧", "UI 填充路径不崩 + 下拉内容正确（buildTrackPicker）", main8.ok && moved8,
  (main8.threw ? ("抛异常：" + main8.threw) : "不抛异常") +
  " · 可选轨 option " + main8.trackTags.length + "/" + main8.nonDrum.length +
  " · selected 跟着状态走=" + moved8);
ev("gd_track 的 option 共 " + main8.tags.length + " 个 = 1 个「（不选）」占位（value=\"\"）+ " +
   main8.trackTags.length + " 条非鼓轨；鼓轨不出现");
ev("  可选轨 value = [" + main8.vals.join(",") + "] · 期望 [" +
   main8.nonDrum.map(t => t.idx).join(",") + "]（" +
   main8.nonDrum.map(t => t.name + "·" + t.notes + "事件").join(" / ") + "）");
ev("  引导轨 " + K + " 那一项：" + main8.selTag);
ev("gd_sum.textContent = " + JSON.stringify(main8.sum));
if (!main8.ok) main8.bad.forEach(b => ev("未过原因：" + b));
ctl("把引导轨换成轨 " + otherTuned.idx + "「" + otherTuned.name + "」再填充 -> 轨 " +
    otherTuned.idx + " 带 selected、原引导轨 " + K + " 撤掉 selected = " + moved8 +
    (moved8 ? "（符合预期：selected 跟着状态走）" : "（判据失效：selected 是写死的）"));

/* ===========================================================================
   判据⑨..⑬：引导范围（guideScope）/ 鼓声来源（guideDrum）/ 所见即所灌
   ---------------------------------------------------------------------------
   纪律：期望值由本脚本按需求单口径【独立重算】（见 expectKeep），
        ⛔ 不调用页面的 guideScopedWords 去验页面的 visibleWords。
        页面还没写出新函数时，这几条报红并打印"缺哪个函数"——
        ⛔ 不用"本脚本自己实现一份"去替它跑（那是探针假绿，经验库 C83）。
   =========================================================================== */
const NEW_FNS = ["guideScopedWords", "visibleWords", "wordsForSelected", "buildPayload"];
const MISSING_FNS = NEW_FNS.filter(n => typeof API[n] !== "function");
const fnErr = MISSING_FNS.length ? ("页面还没有 " + MISSING_FNS.join(" / ") + "()") : "";
if (MISSING_FNS.length) {
  console.log();
  console.log("  注意：页面尚未提供 " + MISSING_FNS.join(" / ") + "()");
  console.log("        ⇒ 判据⑨..⑬ 会报红（这是【页面还没改完】的账，⛔ 不是本脚本自己造一份替它跑）");
}

/* 独立重算：按需求单口径，visibleWords 该保留哪些下标。
   ⚠️ 这里是【另一份】实现，⛔ 不是把页面的过滤器串起来 —— 这正是判据的意义。
   ⭐ 2026-10-16 页面接口变更（用户实测踩过的坑）：
      · 主 API 是 visibleWords(conv) —— 【一趟】循环里同时做"选轨 + 引导裁剪"；
      · ⛔ 不许把 wordsForSelected() 的输出再喂给 guideScopedWords() ——
        后者按下标读 conv.evTrack，过滤后的子集会让下标错位
        （实测：全选正常，只选 [吉他,鼓] 时引导轨置位数从 72 掉到 45、鼓轴字数变 185）。
      ⇒ 所以本函数也必须在【同一趟】里按【原始下标】判两层，见 expectKeep。 */
function expectKeep(conv, idx, scope, drum, selSet, on) {
  const keep = [];
  for (let i = 0; i < conv.words.length; i++) {
    const src = conv.evTrack[i];
    /* 第一层：选轨（src < 0 的公共事件永远保留；引导轨强制保留） */
    let sel;
    if (src < 0) sel = true;
    else if (!selSet) sel = true;                    /* 没选过 = 全选 */
    else if (on && src === idx) sel = true;
    else sel = selSet.has(src);
    if (!sel) continue;
    /* 第二层：引导范围 / 鼓声来源 */
    let g;
    if (!on) g = true;                               /* 关掉引导 ⇒ 原样 */
    else if (src === WANT_TEMPO_TR) g = true;         /* tempo */
    else if (src === WANT_MET_TR) g = (drum !== "track");   /* 节拍器 */
    else if (src === idx) g = true;                   /* 引导轨 */
    else {
      const t = (conv.trackList || []).find(x => x.idx === src);
      if (t && t.drum) g = (drum !== "met");          /* 谱面鼓轨 */
      else g = (scope !== "solo");                    /* 背景旋律轨 */
    }
    if (g) keep.push(i);
  }
  return keep;
}

/* 逐字比对：页面的 visibleWords 结果必须【逐字】等于 conv.words 的 keep 子序列（含顺序） */
function cmpVis(conv, vis, keep) {
  const bad = [];
  if (vis.length !== keep.length) bad.push("字数 " + vis.length + " != 独立重算 " + keep.length);
  const n = Math.min(vis.length, keep.length);
  let diff = 0, firstAt = -1;
  for (let j = 0; j < n; j++) {
    if (vis[j] !== conv.words[keep[j]]) { diff++; if (firstAt < 0) firstAt = j; }
  }
  if (diff) bad.push("逐字比对有 " + diff + " 处不同（首个在可见下标 " + firstAt + "）");
  return { ok: bad.length === 0, bad: bad, n: vis.length, expectN: keep.length, diff: diff };
}

/* ⭐⭐ 与字值无关的口径（用户 2026-10-16 明确要求）：
   只按 unpackWord 出来的字段数 —— guide 位（= 引导轨字数）、轴 12..15（= 鼓轴字数）、
   kind == KIND_TEMPO（= tempo 字数）。
   🔴 为什么不按字值去归属源轨：节拍器的 kick 与谱面 kick 在同 tick 时【字值完全相同】，
      按值归属一定假红。 */
function visCounts(vis) {
  /* 2026-10-16（手册 §二）扩位后的口径：
   *   鼓的身份 = is_drum(bit5)；轴段计数 nDrumAxis 现在只作 §7.3-1 的守卫
   *   （本轮鼓占 12..15 ⇒ 轴的取值区间与鼓的轴段正好重合，靠"轴号"分不开，
   *      所以 12..15 的守卫只说明"这一段只有鼓能占"）。
   *   替它做交叉核对的是 nDrumKeyOk = 【is_drum=1 且轴 == 12+dt】的字数：
   *   判据⑮ 要求 nDrum == nDrumKeyOk（每个鼓字的轴都必须是它自己 dt 的键）。 */
  let nGuide = 0, nDrum = 0, nDrumAxis = 0, nTempo = 0, nDrumIncNot0 = 0, nMelOnDrumAxis = 0, nDrumKeyOk = 0;
  for (const w of vis) {
    const d = unpack(w);
    if (d.guide === 1) nGuide++;
    if (d.isDrum === 1) {
      nDrum++;
      if (d.inc !== 0) nDrumIncNot0++;
      if (d.axis === WANT_AXIS_KEY[dtOf(d)]) nDrumKeyOk++;
    } else if (d.axis >= WANT_MELODY_BAN_AXIS_MIN && d.kind !== API.KIND_TEMPO) {
      nMelOnDrumAxis++;
    }
    if (d.axis >= WANT_MELODY_BAN_AXIS_MIN) nDrumAxis++;
    if (d.kind === API.KIND_TEMPO) nTempo++;
  }
  return { n: vis.length, nGuide: nGuide, nDrum: nDrum, nDrumAxis: nDrumAxis, nTempo: nTempo,
           nDrumIncNot0: nDrumIncNot0, nMelOnDrumAxis: nMelOnDrumAxis, nDrumKeyOk: nDrumKeyOk };
}
function keepCounts(conv, keep) {
  const sub = keep.map(i => conv.words[i]);
  const c = visCounts(sub);
  return { n: c.n, nGuide: c.nGuide, nDrum: c.nDrum, nDrumAxis: c.nDrumAxis, nTempo: c.nTempo,
           nDrumIncNot0: c.nDrumIncNot0, nMelOnDrumAxis: c.nMelOnDrumAxis, nDrumKeyOk: c.nDrumKeyOk };
}
/* 类别闭包：可见字必须【全部】落进"引导位 / 鼓轴 / tempo"三类之一，一个不漏、一个不多。
   （三类互斥：引导轨是非鼓轨 ⇒ guide 位与鼓轴不相交；tempo 字 guide=0 且轴 0） */
const clsSum = c => c.nGuide + c.nDrum + c.nTempo;
const fullCount = (conv, tr) => {
  let n = 0; for (let i = 0; i < conv.words.length; i++) if (conv.evTrack[i] === tr) n++;
  return n;
};
function histByKeep(conv, keep) {
  const h = new Map();
  for (const i of keep) { const tr = conv.evTrack[i]; h.set(tr, (h.get(tr) || 0) + 1); }
  return h;
}
const bgMelodyIdxs = (conv, idx) => (conv.trackList || []).filter(t => !t.drum && t.idx !== idx).map(t => t.idx);
const drumTrackIdxs = conv => (conv.trackList || []).filter(t => t.drum).map(t => t.idx);
const sumOf = (h, idxs) => idxs.reduce((s, t) => s + (h.get(t) || 0), 0);

/* 一次"快照"：设选轨 + 设引导状态 -> 回读校验 -> 取产物 / 选轨结果 / 可见字 / 与值无关的计数
   selIds：undefined = 不动选轨；null = 未选过（=全选）；数组 = 只选这些轨序号 */
function snap(on, idx, met, style, scope, drum, selIds) {
  const bad = [];
  if (MISSING_FNS.length) bad.push(fnErr);
  if (selIds !== undefined) {
    if (typeof API.__setTrackSel === "function") API.__setTrackSel(selIds);
    else bad.push("页面还没有 __setTrackSel()（选轨场景无法构造）");
  }
  setGuide(on, idx, met, style, scope, drum);
  const st = API.__guideStateLocal();
  const want = { guideOn: !!on, guideTrackIdx: (idx === null || idx === undefined) ? null : idx,
                 metOn: !!met, metStyle: style, guideScope: scope, guideDrum: drum };
  for (const k of Object.keys(want)) {
    if (want[k] === undefined) continue;
    if (st[k] !== want[k]) {
      bad.push("状态 " + k + " 回读 " + JSON.stringify(st[k]) + " != 想要 " + JSON.stringify(want[k]));
    }
  }
  const conv = API.midiToWords(parsed);
  let sel = null, vis = null;
  if (!MISSING_FNS.length) {
    sel = API.wordsForSelected(conv.words, conv);
    vis = API.visibleWords(conv);
  }
  return { on: !!on, idx: (idx === null || idx === undefined) ? null : idx, met: !!met,
           style: style, scope: scope, drum: drum, conv: conv, sel: sel, vis: vis,
           vc: vis ? visCounts(vis) : null,
           selSet: (selIds === undefined || selIds === null) ? null : new Set(selIds),
           state: st, bad: bad };
}

/* 选轨场景：只选 [引导轨, 鼓轨] —— 用户实测踩坑的那一组 */
const DRUM_IDX = tracks.filter(t => t.drum).map(t => t.idx);

const sSoloMet  = snap(true,  K, true, "beat", "solo", "met", null);
const sAllMet   = snap(true,  K, true, "beat", "all",  "met", null);
const sAllTrack = snap(true,  K, true, "beat", "all",  "track", null);
const sAllBoth  = snap(true,  K, true, "beat", "all",  "both", null);
const sOff      = snap(false, null, true, "beat", "solo", "met", null);   /* guideOn=false：必须原样返回 */
const sOff2     = snap(false, null, false, "beat", "solo", "met", null);  /* 引导关 + 节拍器关（用户说的那一档） */
const sSubMet   = snap(true,  K, true, "beat", "all",  "met",   [K].concat(DRUM_IDX));
const sSubTrack = snap(true,  K, true, "beat", "all",  "track", [K].concat(DRUM_IDX));
/* 用户自测用的那一组：引导轨 = 吉他 idx1，只选 [1, 鼓轨]，scope=all / drum=met */
const K1 = tuned.some(t => t.idx === 1) ? 1 : null;
const sK1Sub = (K1 === null) ? null : snap(true, K1, true, "beat", "all", "met", [K1].concat(DRUM_IDX));

/* 前提：选轨过滤不能把字筛掉（否则"背景轨的字还在吗"这类断言会被选轨混淆） */
const selKeepsAll = !!sAllMet.sel && sAllMet.sel.length === sAllMet.conv.words.length;
const selPre = selKeepsAll ? "" : ("选轨过滤把字筛掉了（wordsForSelected " +
  (sAllMet.sel ? sAllMet.sel.length : "?") + " != 全量 " + sAllMet.conv.words.length +
  "）——⑨⑩⑪⑫ 的前提不成立");

/* ---------------- ⑨ ---------------- */
function pred9(sSolo, sAll, idx) {
  const bad = [];
  if (!sSolo.vis) return { ok: false, bad: [fnErr || "没有 visibleWords 结果"], nSolo: 0, nKeep: 0 };
  bad.push.apply(bad, sSolo.bad);
  if (selPre) bad.push(selPre);
  const conv = sSolo.conv;
  const keep = expectKeep(conv, idx, "solo", "met", null, true);
  const cmp = cmpVis(conv, sSolo.vis, keep);
  if (!cmp.ok) bad.push.apply(bad, cmp.bad);
  const h = histByKeep(conv, keep);
  const kc = keepCounts(conv, keep);        /* 独立重算的、与字值无关的三类计数 */
  const vc = sSolo.vc;                      /* 页面产物上同样口径的计数 */
  if (vc.nGuide !== kc.nGuide) bad.push("bit6=1 字数 " + vc.nGuide + " != 独立重算 " + kc.nGuide);
  if (vc.nDrum !== kc.nDrum) bad.push("鼓轴(12..15)字数 " + vc.nDrum + " != 独立重算 " + kc.nDrum);
  if (vc.nTempo !== kc.nTempo) bad.push("tempo(kind=2)字数 " + vc.nTempo + " != 独立重算 " + kc.nTempo);
  /* 类别闭包：可见字必须【全部】落进"引导位 / 鼓轴 / tempo"三类 —— 背景轨的字塞不进来 */
  if (clsSum(vc) !== vc.n) {
    bad.push("类别闭包不成立：引导位 " + vc.nGuide + " + 鼓轴 " + vc.nDrum + " + tempo " + vc.nTempo +
             " = " + clsSum(vc) + " != 可见 " + vc.n);
  }
  /* 三类各自必须正好等于"该有的那一份"（独立写死，⛔ 不拿页面的账去比页面的账） */
  const wantGuide = gTrack.onCount * 2;
  const metWords = fullCount(conv, WANT_MET_TR);
  const tempoWords = fullCount(conv, WANT_TEMPO_TR);
  if (vc.nGuide !== wantGuide) bad.push("bit6=1 字数 " + vc.nGuide + " != 引导轨音符×2 = " + wantGuide);
  if (vc.nDrum !== metWords) bad.push("solo+met 下鼓轴字数 " + vc.nDrum + " != 节拍器字数 " + metWords);
  if (vc.nTempo !== tempoWords) bad.push("tempo 字数 " + vc.nTempo + " != " + tempoWords);
  /* 源轨口径按【原始下标】判（与字值无关）：只许出现 -1 / 引导轨 / -2 */
  const allowed = new Set([WANT_TEMPO_TR, idx, WANT_MET_TR]);
  const leaked = [];
  for (const [tr, n] of h) if (!allowed.has(tr)) leaked.push("轨" + tr + " " + n + " 字");
  if (leaked.length) bad.push("solo 下还有不该出现的源轨：" + leaked.join(" · "));
  const bgs = bgMelodyIdxs(conv, idx);
  const bgLeft = bgs.filter(t => (h.get(t) || 0) > 0);
  if (bgLeft.length) bad.push("背景旋律轨仍有字：" + bgLeft.map(t => "轨" + t).join(","));
  /* 引导轨字数必须与 all 一致（证明裁的是别人不是它） */
  const kcAll = keepCounts(sAll.conv, expectKeep(sAll.conv, idx, "all", "met", null, true));
  if (vc.nGuide !== kcAll.nGuide) {
    bad.push("引导轨字数 solo " + vc.nGuide + " != all " + kcAll.nGuide + "（裁到引导轨自己了）");
  }
  if (!(vc.n > 0)) bad.push("solo 下 visibleWords 为空（空洞）");
  if (!(vc.nGuide > 0)) bad.push("solo 下引导轨 0 字");
  if (!(vc.nDrum > 0)) bad.push("solo 下节拍器 0 字（guideDrum=met 本该保留）");
  if (!(vc.nTempo > 0)) bad.push("solo 下 tempo 0 字（必须保留）");
  return { ok: bad.length === 0, bad: bad, nSolo: vc.n, nKeep: keep.length, vc: vc, kc: kc,
           gSolo: vc.nGuide, gAll: kcAll.nGuide, metWords: metWords, h: h, bgs: bgs, cmp: cmp };
}

/* ---------------- ⑩ ---------------- */
function pred10(sAll, idx) {
  const bad = [];
  if (!sAll.vis) return { ok: false, bad: [fnErr || "没有 visibleWords 结果"], n: 0 };
  bad.push.apply(bad, sAll.bad);
  if (selPre) bad.push(selPre);
  const conv = sAll.conv;
  const keep = expectKeep(conv, idx, "all", "met", null, true);
  const cmp = cmpVis(conv, sAll.vis, keep);
  if (!cmp.ok) bad.push.apply(bad, cmp.bad);
  const h = histByKeep(conv, keep);
  const vc = sAll.vc, kc = keepCounts(conv, keep);
  if (vc.nGuide !== kc.nGuide || vc.nDrum !== kc.nDrum || vc.nTempo !== kc.nTempo) {
    bad.push("与字值无关的计数与独立重算不一致：引导位 " + vc.nGuide + "/" + kc.nGuide +
             " · 鼓轴 " + vc.nDrum + "/" + kc.nDrum + " · tempo " + vc.nTempo + "/" + kc.nTempo);
  }
  const bgs = bgMelodyIdxs(conv, idx);
  const withWords = bgs.filter(t => fullCount(conv, t) > 0);
  const gone = withWords.filter(t => (h.get(t) || 0) === 0);
  if (gone.length) bad.push("all 下背景旋律轨的字不见了：" + gone.map(t => "轨" + t).join(","));
  const diffs = withWords.filter(t => (h.get(t) || 0) !== fullCount(conv, t))
                         .map(t => "轨" + t + " 可见 " + (h.get(t) || 0) + " != 全量 " + fullCount(conv, t));
  if (diffs.length) bad.push("背景轨字数被改了：" + diffs.join(" · "));
  if (!withWords.length) bad.push("这份 MIDI 里没有带字的背景旋律轨（判据⑩无从谈起）");
  const nBg = sumOf(h, withWords);
  if (!(nBg > 0)) bad.push("all 下背景旋律轨合计 0 字");
  /* 四类闭包：可见 = 引导位 + 鼓轴 + tempo + 背景旋律轨（四类互斥） */
  if (vc.n !== vc.nGuide + vc.nDrum + vc.nTempo + nBg) {
    bad.push("四类闭包不成立：引导位 " + vc.nGuide + " + 鼓轴 " + vc.nDrum + " + tempo " + vc.nTempo +
             " + 背景 " + nBg + " = " + (vc.nGuide + vc.nDrum + vc.nTempo + nBg) + " != 可见 " + vc.n);
  }
  return { ok: bad.length === 0, bad: bad, n: vc.n, vc: vc, kc: kc, nBg: nBg,
           h: h, bgs: bgs, withWords: withWords };
}

/* ---------------- ⑪ ---------------- */
function pred11(sMet, sTrack, sBoth, idx) {
  const bad = [];
  const out = {};
  for (const [nm, s, mode] of [["met", sMet, "met"], ["track", sTrack, "track"], ["both", sBoth, "both"]]) {
    if (!s.vis) { bad.push(fnErr || ("没有 " + nm + " 档的 visibleWords 结果")); continue; }
    bad.push.apply(bad, s.bad);
    if (selPre) bad.push(selPre);
    const conv = s.conv;
    const keep = expectKeep(conv, idx, "all", mode, null, true);
    const cmp = cmpVis(conv, s.vis, keep);
    if (!cmp.ok) bad.push.apply(bad, cmp.bad.map(x => nm + " 档：" + x));
    const vc = s.vc, kc = keepCounts(conv, keep), h = histByKeep(conv, keep);
    /* 与字值无关的计数：鼓轴字数、节拍器字数、谱面鼓轨字数、tempo、引导位 */
    const metWords = fullCount(conv, WANT_MET_TR);
    const drumWords = drumTrackIdxs(conv).reduce((a, t) => a + fullCount(conv, t), 0);
    const tempoWords = fullCount(conv, WANT_TEMPO_TR);
    const wantGuide = gTrack.onCount * 2;
    out[nm] = { nMet: metWords, nDrumTrack: drumWords, nTempo: tempoWords, nGuide: wantGuide,
                n: vc.n, nDrumAxis: vc.nDrum, nGuideBit: vc.nGuide, nTempoBit: vc.nTempo,
                metCount: conv.metCount, metSkipped: conv.metSkipped, h: h, kc: kc };
    if (vc.nGuide !== wantGuide) bad.push(nm + " 档下 bit6=1 字数 " + vc.nGuide + " != 引导轨音符×2 = " + wantGuide);
    if (vc.nTempo !== tempoWords) bad.push(nm + " 档下 tempo 字数 " + vc.nTempo + " != " + tempoWords);
    if (nm === "met") {
      /* met：谱面鼓轨丢掉 ⇒ 可见的鼓轴字只能来自节拍器 */
      if (vc.nDrum !== metWords) bad.push("met 档下鼓轴字数 " + vc.nDrum + " != 节拍器字数 " + metWords + "（谱面鼓应一个不剩）");
      if (!(metWords > 0)) bad.push("met 档下节拍器 0 字（应 > 0）");
    } else if (nm === "track") {
      /* track：节拍器丢掉 ⇒ 可见的鼓轴字只能来自谱面鼓轨 */
      if (vc.nDrum !== drumWords) bad.push("track 档下鼓轴字数 " + vc.nDrum + " != 谱面鼓轨字数 " + drumWords + "（节拍器应一个不剩）");
      if (!(drumWords > 0)) bad.push("track 档下谱面鼓轨 0 字（应 > 0）");
      if (!(metWords > 0)) bad.push("track 档下全量里节拍器 0 字（这条判据无从谈起）");
    } else {
      if (vc.nDrum !== metWords + drumWords) bad.push("both 档下鼓轴字数 " + vc.nDrum + " != 节拍器 " + metWords + " + 谱面鼓 " + drumWords + " = " + (metWords + drumWords));
      if (!(metWords > 0)) bad.push("both 档下节拍器 0 字（应 > 0）");
      if (!(drumWords > 0)) bad.push("both 档下谱面鼓轨 0 字（应 > 0）");
    }
    /* 四类闭包（背景旋律轨在 all 档都保留，所以还要加进来） */
    const nBg = sumOf(h, bgMelodyIdxs(conv, idx));
    if (vc.n !== vc.nGuide + vc.nDrum + vc.nTempo + nBg) {
      bad.push(nm + " 档四类闭包不成立：" + vc.nGuide + "+" + vc.nDrum + "+" + vc.nTempo + "+" + nBg +
               " = " + (vc.nGuide + vc.nDrum + vc.nTempo + nBg) + " != 可见 " + vc.n);
    }
    if (!(vc.n > 0)) bad.push(nm + " 档 visibleWords 为空（空洞）");
  }
  return { ok: bad.length === 0, bad: bad, per: out };
}

/* ---------------- ⑫ ---------------- */
/* 独立解析灌谱字节流：4 个复位帧 + 1 个总数帧 + N 个事件帧，每帧 9 字节。
   两个独立的"字数"来源必须一致：① 按长度反推 ② 总数帧里写的值。 */
function parsePayload(p, N, words) {
  const bad = [];
  const F = WANT_FRAME.bytes;
  if (!p || typeof p.length !== "number") return { ok: false, bad: ["buildPayload 没有返回带 length 的东西"] };
  const head = F * (WANT_FRAME.resetFrames + 1);
  const bodyLen = p.length - head;
  const nLen = bodyLen / F;
  if (bodyLen < 0 || !Number.isInteger(nLen)) {
    bad.push("payload 长度 " + p.length + " 不是「" + WANT_FRAME.resetFrames + "复位帧 + 1总数帧 + N事件帧」的结构");
  }
  const expectLen = head + F * N;
  if (p.length !== expectLen) {
    bad.push("payload 长度 " + p.length + " != " + WANT_FRAME.resetFrames + "×" + F + " + " + F +
             " + " + N + "×" + F + " = " + expectLen);
  }
  if (Number.isInteger(nLen) && nLen !== N) {
    bad.push("按 payload 长度反推出的字数 " + nLen + " != visibleWords 长度 " + N);
  }
  let resetBad = 0;
  for (let k = 0; k < WANT_FRAME.resetFrames; k++) {
    for (let b = 0; b < F; b++) if (p[k * F + b] !== WANT_FRAME.hdrEvent) resetBad++;
  }
  if (resetBad) bad.push("复位序列有 " + resetBad + " 个字节不是 0x" + WANT_FRAME.hdrEvent.toString(16));
  const tOff = F * WANT_FRAME.resetFrames;
  let nFrame = null;
  if (p.length >= head) {
    if (p[tOff] !== WANT_FRAME.hdrTotal) {
      bad.push("总数帧头 0x" + p[tOff].toString(16) + " != 0x" + WANT_FRAME.hdrTotal.toString(16));
    }
    let v = 0n;
    for (let b = 1; b < F; b++) v = (v << 8n) | BigInt(p[tOff + b]);
    nFrame = Number(v);
    if (nFrame !== N) bad.push("总数帧里写的 N = " + nFrame + " != visibleWords 长度 " + N);
  }
  let hdrBad = 0, wordBad = 0;
  const cnt = Math.max(0, Math.min(N, Math.floor((p.length - head) / F)));
  for (let j = 0; j < cnt; j++) {
    const off = head + j * F;
    if (p[off] !== WANT_FRAME.hdrEvent) hdrBad++;
    const by = API.wordToBytes(words[j]);
    let same = true;
    for (let b = 0; b < 8; b++) if (p[off + 1 + b] !== by[b]) same = false;
    if (!same) wordBad++;
  }
  if (hdrBad) bad.push("有 " + hdrBad + " 个事件帧的头不是 0x" + WANT_FRAME.hdrEvent.toString(16));
  if (wordBad) bad.push("有 " + wordBad + " 个事件帧的内容与 visibleWords[j] 不符");
  return { ok: bad.length === 0, bad: bad, len: p.length, nLen: nLen, nFrame: nFrame, expectLen: expectLen };
}

function pred12(sAll, idx) {
  const bad = [];
  if (!sAll.vis) return { ok: false, bad: [fnErr || "没有 visibleWords 结果"], n: 0 };
  bad.push.apply(bad, sAll.bad);
  const conv = sAll.conv, vis = sAll.vis, N = vis.length;
  if (!(N > 0)) bad.push("visibleWords 为空（payload 结构核对无意义）");
  /* 页面常数必须与独立写死的帧格式一致 */
  for (const [nm, want] of [["FRAME_BYTES", WANT_FRAME.bytes], ["HDR_EVENT", WANT_FRAME.hdrEvent],
                            ["HDR_TOTAL", WANT_FRAME.hdrTotal], ["RESET_FRAMES", WANT_FRAME.resetFrames]]) {
    if (API[nm] !== null && API[nm] !== undefined && API[nm] !== want) {
      bad.push("页面 " + nm + " = " + API[nm] + " != " + want);
    }
  }
  const p = API.buildPayload(vis);
  const pp = parsePayload(p, N, vis);
  if (!pp.ok) bad.push.apply(bad, pp.bad);
  /* buildScore(可见字) 的 tickMax 不能超过全量谱面 */
  const scVis = API.buildScore(vis, "vis");
  const scAll = API.buildScore(conv.words, "all");
  if (!(scVis.tickMax <= scAll.tickMax)) {
    bad.push("buildScore(visibleWords).tickMax " + scVis.tickMax + " > 全量 " + scAll.tickMax);
  }
  return { ok: bad.length === 0, bad: bad, n: N, payloadLen: p ? p.length : null, pp: pp,
           tickMaxVis: scVis.tickMax, tickMaxAll: scAll.tickMax, fullLen: conv.words.length };
}

/* ---------------- ⑬ ---------------- */
function pred13(sSolo, sAll, sOff, sOff2, idx) {
  const bad = [];
  if (!sSolo.vis || !sAll.vis) return { ok: false, bad: [fnErr || "没有 visibleWords 结果"], nSolo: 0, nAll: 0 };
  const nSolo = sSolo.vis.length, nAll = sAll.vis.length;
  const kSolo = expectKeep(sSolo.conv, idx, "solo", "met", null, true);
  const kAll  = expectKeep(sAll.conv, idx, "all", "met", null, true);
  if (!(nAll > nSolo)) {
    bad.push("all 的字数 " + nAll + " 没有比 solo 的 " + nSolo + " 长（裁剪没在起作用 ⇒ 判据⑬ 红）");
  }
  if ((nAll - nSolo) !== (kAll.length - kSolo.length)) {
    bad.push("变长量 " + (nAll - nSolo) + " != 独立重算的应裁量 " + (kAll.length - kSolo.length));
  }
  /* guideOn=false：必须【原样返回】（两档都验：节拍器开 / 关） */
  const offChk = (s, tag) => {
    if (!s || !s.vis) { bad.push(fnErr || ("没有 " + tag + " 的 visibleWords 结果")); return null; }
    if (s.vis.length !== s.conv.words.length) {
      bad.push(tag + "：字数 " + s.vis.length + " != 原样 " + s.conv.words.length + "（必须原样返回）");
    } else {
      let d = 0;
      for (let j = 0; j < s.vis.length; j++) if (s.vis[j] !== s.conv.words[j]) d++;
      if (d) bad.push(tag + "：逐字有 " + d + " 处不同（必须原样返回）");
    }
    return { n: s.vis.length, raw: s.conv.words.length };
  };
  const o1 = offChk(sOff, "guideOn=false（节拍器开）");
  const o2 = offChk(sOff2, "guideOn=false 且 metOn=false");
  return { ok: bad.length === 0, bad: bad, nSolo: nSolo, nAll: nAll, delta: nAll - nSolo,
           wantDelta: kAll.length - kSolo.length,
           nOff: o1 ? o1.n : null, nRaw: o1 ? o1.raw : null,
           nOff2: o2 ? o2.n : null, nRaw2: o2 ? o2.raw : null };
}

/* ---------------- ⑭ ---------------- */
/* 选轨 × 引导裁剪：只选 [引导轨, 鼓轨] 时 visibleWords 必须仍然正确。
   🔴 这一条抓的是用户实测踩过的坑：把 wordsForSelected() 的输出再喂给 guideScopedWords()
      —— 后者按下标读 conv.evTrack，过滤后的子集会让下标错位。
      现象：全选正常；只选 [吉他,鼓] 时"引导轨置位数"从 72 掉到 45、鼓轴字数变 185（垃圾数）。
   ⭐ 正确口径：visibleWords() 一趟扫【原始】字表，两个谓词各判各的。 */
function pred14(sSubMet, sSubTrack, sK1Sub, idx) {
  const bad = [];
  const chk = (s, mode, tag) => {
    if (!s) { bad.push(tag + "：无法构造（缺 __setTrackSel 或轨不存在）"); return null; }
    if (!s.vis) { bad.push(tag + "：" + (fnErr || "没有 visibleWords 结果")); return null; }
    bad.push.apply(bad, s.bad);
    const conv = s.conv;
    const keep = expectKeep(conv, idx, "all", mode, s.selSet, true);
    const cmp = cmpVis(conv, s.vis, keep);
    if (!cmp.ok) bad.push.apply(bad, cmp.bad.map(x => tag + "：" + x));
    const vc = s.vc, kc = keepCounts(conv, keep);
    if (vc.nGuide !== kc.nGuide || vc.nDrum !== kc.nDrum || vc.nTempo !== kc.nTempo) {
      bad.push(tag + "：与值无关的计数与独立重算不一致（引导位 " + vc.nGuide + "/" + kc.nGuide +
               " · 鼓轴 " + vc.nDrum + "/" + kc.nDrum + " · tempo " + vc.nTempo + "/" + kc.nTempo + "）");
    }
    /* 选轨不许把引导轨裁掉：bit6 字数必须 = 该轨音符数 × 2 */
    const gt = tracks.find(t => t.idx === idx) || { onCount: 0 };
    const wantGuide = gt.onCount * 2;
    if (vc.nGuide !== wantGuide) {
      bad.push(tag + "：bit6=1 字数 " + vc.nGuide + " != 引导轨音符×2 = " + wantGuide + "（选轨把引导轨裁了？）");
    }
    return { vc: vc, kc: kc, n: vc.n, cmp: cmp, wantGuide: wantGuide };
  };
  const a = chk(sSubMet, "met", "只选[引导轨,鼓轨]+met");
  const b = chk(sSubTrack, "track", "只选[引导轨,鼓轨]+track");
  /* met 档不避让 ⇒ 鼓轴字必须正好是"整份音型"：每小节 8 下 × BARS × 2 字 */
  const wantMetWords = BARS * (WANT_BEAT.beats.length + WANT_BEAT.hats.length) * 2;
  if (a && a.vc.nDrum !== wantMetWords) {
    bad.push("只选子集 + met 档下鼓轴字数 " + a.vc.nDrum + " != 整份音型 " + BARS + "×8×2 = " + wantMetWords);
  }
  /* 旧口径（两个过滤器串联）必须与页面结果【不同】—— 否则这个坑就抓不到 */
  let oldCmp = null, guard = null;
  if (sSubMet && sSubMet.sel && typeof API.guideScopedWords === "function") {
    const old = API.guideScopedWords(sSubMet.sel, sSubMet.conv);     /* 子集喂进去（旧口径） */
    const same = old.length === sSubMet.vis.length && old.every((w, j) => w === sSubMet.vis[j]);
    oldCmp = { oldLen: old.length, visLen: sSubMet.vis.length, same: same };
    if (same) {
      bad.push("旧口径（wordsForSelected 的输出再喂 guideScopedWords）与 visibleWords 结果相同" +
               " —— 说明这一组输入下两种口径恰好一致（全选时就是这样；只有选了子集才会分叉）");
    }
    /* guideScopedWords 的长度守卫：喂子集必须【原样返回】，⛔ 不静默错位 */
    const r = API.guideScopedWords(sSubMet.sel, sSubMet.conv);
    const unchanged = r.length === sSubMet.sel.length && r.every((w, j) => w === sSubMet.sel[j]);
    guard = { inLen: sSubMet.sel.length, outLen: r.length, unchanged: unchanged,
              fullLen: sSubMet.conv.words.length };
    if (!unchanged) {
      bad.push("guideScopedWords 收到子集（" + sSubMet.sel.length + " / " + sSubMet.conv.words.length +
               "）却没有原样返回 —— 下标会错位（这正是踩过的坑）");
    }
  }
  /* 用户自测的那一组：引导轨 = 吉他 idx1，只选 [1, 鼓轨]，scope=all / drum=met
     期望 234 = tempo 2 + 引导轨 72（36 个音 × 2）+ 节拍器 160（10 小节 × 8 下 × 2，不避让） */
  let k1 = null;
  if (sK1Sub) {
    if (!sK1Sub.vis) bad.push("吉他 idx1 子集场景：" + (fnErr || "没有 visibleWords 结果"));
    else {
      bad.push.apply(bad, sK1Sub.bad);
      const keep = expectKeep(sK1Sub.conv, 1, "all", "met", sK1Sub.selSet, true);
      const cmp = cmpVis(sK1Sub.conv, sK1Sub.vis, keep);
      if (!cmp.ok) bad.push.apply(bad, cmp.bad.map(x => "吉他 idx1 子集场景：" + x));
      const vc = sK1Sub.vc;
      const g1 = (tracks.find(t => t.idx === 1) || { onCount: 0 }).onCount * 2;
      const t1 = fullCount(sK1Sub.conv, WANT_TEMPO_TR);
      k1 = { n: vc.n, nGuide: vc.nGuide, nDrum: vc.nDrum, nTempo: vc.nTempo,
             wantGuide: g1, wantDrum: wantMetWords, wantTempo: t1,
             wantTotal: g1 + wantMetWords + t1 };
      if (vc.nGuide !== k1.wantGuide) bad.push("吉他 idx1：bit6 字数 " + vc.nGuide + " != " + k1.wantGuide);
      if (vc.nDrum !== k1.wantDrum) bad.push("吉他 idx1：鼓轴字数 " + vc.nDrum + " != " + k1.wantDrum);
      if (vc.nTempo !== k1.wantTempo) bad.push("吉他 idx1：tempo 字数 " + vc.nTempo + " != " + k1.wantTempo);
      if (vc.n !== k1.wantTotal) bad.push("吉他 idx1：可见字数 " + vc.n + " != " + k1.wantTotal +
                                          "（= tempo " + t1 + " + 引导轨 " + g1 + " + 节拍器 " + wantMetWords + "）");
    }
  }
  return { ok: bad.length === 0, bad: bad, sub: a, subTrack: b, k1: k1,
           oldCmp: oldCmp, guard: guard, wantMetWords: wantMetWords };
}

/* ---- 报告：新接口的存在性与取值（非判据，但缺了就全红） ---- */
console.log();
console.log("【一之补】新增接口（引导范围 / 鼓声来源 / 所见即所灌）");
console.log("  页面函数：" + NEW_FNS.map(n => n + (typeof API[n] === "function" ? " ✓" : " ✗")).join(" · "));
console.log("  页面状态：guideScope = " + JSON.stringify(sAllMet.state.guideScope) +
            " · guideDrum = " + JSON.stringify(sAllMet.state.guideDrum) +
            "（默认应为 \"all\" / \"met\"）");
console.log("  节拍器源轨号：独立期望 " + WANT_MET_TR + " · 产物里节拍器字的源轨集合 = " +
            JSON.stringify([...new Set(mainDec.filter(o => isMetWord(o.d, o.tr) &&
              o.d.kind === API.KIND_ON).map(o => o.tr))].sort((a, b) => a - b)));
{
  const uiIds = ["gd_scope", "gd_drum"];
  const have = uiIds.filter(id => htmlSrc.indexOf('id="' + id + '"') >= 0);
  console.log("  UI id（报告项，非判据）：" + have.join("/") +
              (have.length === uiIds.length ? " 全在" : "  缺 " + uiIds.filter(x => have.indexOf(x) < 0).join("/")));
}

/* ---------------- ⑨ ---------------- */
const main9 = pred9(sSoloMet, sAllMet, K);
judge("⑨", "solo：只剩 tempo + 引导轨 + 节拍器（背景轨一个不剩）", main9.ok,
  "可见 " + main9.nSolo + " 字 / 独立重算 " + main9.nKeep + " 字 · 引导轨 " + main9.gSolo +
  " 字（all 时 " + main9.gAll + "）");
ev("逐字比对（页面的 visibleWords vs 独立重算的 keep 子序列）：" +
   (main9.cmp && main9.cmp.ok ? "完全一致" : ("不一致 —— " + ((main9.cmp && main9.cmp.bad) || []).join("；"))));
ev("可见字的源轨分布：" + [...main9.h].sort((a, b) => a[0] - b[0])
     .map(([tr, n]) => "轨" + tr + "=" + n + (tr === K ? "(引导轨)" : tr === WANT_MET_TR ? "(节拍器)"
       : tr === WANT_TEMPO_TR ? "(tempo/公共)" : "(⚠不该在)")).join(" · "));
ev("背景旋律轨（非鼓、非引导）：" + main9.bgs.map(t => "轨" + t).join(",") + " ⇒ 各 0 字（" +
   main9.bgs.map(t => "轨" + t + "=" + (main9.h.get(t) || 0)).join(" · ") + "）");
if (!main9.ok) main9.bad.forEach(b => ev("未过原因：" + b));
{
  /* 反控：拿 all 的结果去判 solo 的判据 => 必须红（证明判据认得出"背景轨还在"） */
  const c = pred9(sAllMet, sAllMet, K);
  ctl("把 all 档的结果当作 solo 的产物来判 -> 判据⑨ " +
      (c.ok ? "仍然绿（判据失效）" : "变红（符合预期）") + "：" + (c.bad[0] || "无未过原因"));
}

/* ---------------- ⑩ ---------------- */
const main10 = pred10(sAllMet, K);
judge("⑩", "all：背景旋律轨的字还在（逐轨字数与全量一致）", main10.ok,
  "可见 " + main10.n + " 字 · 背景轨 " + main10.withWords.map(t => "轨" + t + "=" + (main10.h.get(t) || 0)).join(" · "));
ev("背景旋律轨逐轨：全量字数 vs 可见字数 —— " +
   main10.bgs.map(t => "轨" + t + " " + fullCount(sAllMet.conv, t) + "/" + (main10.h.get(t) || 0)).join(" · "));
if (!main10.ok) main10.bad.forEach(b => ev("未过原因：" + b));
{
  const c = pred10(sSoloMet, K);
  ctl("把 solo 档的结果当作 all 的产物来判 -> 判据⑩ " +
      (c.ok ? "仍然绿（判据失效）" : "变红（符合预期）") + "：" + (c.bad[0] || "无未过原因"));
}

/* ---------------- ⑪ ---------------- */
const main11 = pred11(sAllMet, sAllTrack, sAllBoth, K);
const p11 = main11.per || {};
const f11 = (nm, k) => ((p11[nm] || {})[k]);
judge("⑪", "guideDrum 三档：met / track / both 的鼓声来源各自正确", main11.ok,
  "met 鼓轴字 " + f11("met", "nDrumAxis") + "（节拍器 " + f11("met", "nMet") + " · 谱面鼓 " +
  f11("met", "nDrumTrack") + "）· track 鼓轴字 " + f11("track", "nDrumAxis") + "（节拍器 " +
  f11("track", "nMet") + " · 谱面鼓 " + f11("track", "nDrumTrack") + "）· both 鼓轴字 " +
  f11("both", "nDrumAxis") + "（节拍器 " + f11("both", "nMet") + " + 谱面鼓 " + f11("both", "nDrumTrack") + "）");
ev("谱面鼓轨下标 = [" + drumTrackIdxs(sAllMet.conv).join(",") + "] · 期望：met ⇒ 可见鼓轴字 == 节拍器字数（谱面鼓一个不剩）；" +
   "track ⇒ 可见鼓轴字 == 谱面鼓轨字数（节拍器一个不剩）；both ⇒ 两者之和");
ev("三档的可见字数：met " + f11("met", "n") + " · track " + f11("track", "n") + " · both " + f11("both", "n") +
   " · bit6=1 字数 " + f11("met", "nGuideBit") + "/" + f11("track", "nGuideBit") + "/" + f11("both", "nGuideBit") +
   "（都须 = 引导轨音符×2 = " + f11("met", "nGuide") + "）· tempo 字数 " +
   f11("met", "nTempoBit") + "/" + f11("track", "nTempoBit") + "/" + f11("both", "nTempoBit") +
   "（都须 = " + f11("met", "nTempo") + "）");
ev("节拍器账（页面 conv.metCount / metSkipped）：met 档 " + f11("met", "metCount") + "/" + f11("met", "metSkipped") +
   "（不避让 ⇒ 跳过必须 0）· track 档 " + f11("track", "metCount") + "/" + f11("track", "metSkipped") +
   "（避让，但节拍器字不发下去）· both 档 " + f11("both", "metCount") + "/" + f11("both", "metSkipped") + "（避让）");
if (!main11.ok) main11.bad.forEach(b => ev("未过原因：" + b));
{
  /* 反控：拿 met 档的产物去按 track 档的期望判 => 必须红（证明三档不是同一件事） */
  const c = pred11(sAllMet, sAllMet, sAllBoth, K);
  ctl("把 met 档的产物当作 track 档来判 -> 判据⑪ " +
      (c.ok ? "仍然绿（判据失效）" : "变红（符合预期）") + "：" + (c.bad[0] || "无未过原因"));
}

/* ---------------- ⑫ ---------------- */
const main12 = pred12(sAllMet, K);
judge("⑫", "所见即所灌：payload 结构反推的字数 == visibleWords 长度", main12.ok,
  "可见 " + main12.n + " 字 / 全量 " + main12.fullLen + " 字 · payload " + main12.payloadLen +
  " 字节（反推 " + ((main12.pp || {}).nLen) + " · 总数帧 " + ((main12.pp || {}).nFrame) + "）");
ev("payload 结构 = " + WANT_FRAME.resetFrames + " 复位帧 + 1 总数帧 + N 事件帧（每帧 " +
   WANT_FRAME.bytes + " 字节）⇒ " + WANT_FRAME.bytes * (WANT_FRAME.resetFrames + 1) + " + " +
   WANT_FRAME.bytes + "×" + main12.n + " = " + ((main12.pp || {}).expectLen) + " 字节（实测 " +
   main12.payloadLen + "）");
ev("tickMax：buildScore(可见字) = " + main12.tickMaxVis + " <= buildScore(全量) = " + main12.tickMaxAll +
   " ⇒ " + (main12.tickMaxVis <= main12.tickMaxAll));
if (!main12.ok) main12.bad.forEach(b => ev("未过原因：" + b));
{
  /* 反控 a：把总数帧改大 1 => 必须红（这条是"反推字数"之外的第二条独立来源） */
  const p = API.buildPayload(sAllMet.vis);
  const F = WANT_FRAME.bytes, tOff = F * WANT_FRAME.resetFrames;
  const q = Uint8Array.from(p);
  let v = BigInt(main12.n + 1);
  for (let b = F - 1; b >= 1; b--) { q[tOff + b] = Number(v & 0xFFn); v >>= 8n; }
  const rq = parsePayload(q, main12.n, sAllMet.vis);
  ctl("把总数帧里写的 N 改成 " + (main12.n + 1) + " -> 判据⑫ " +
      (rq.ok ? "仍然绿（判据失效）" : "变红（符合预期）") + "：" + (rq.bad[0] || "无未过原因"));
  /* 反控 b：字数与 payload 对不上（多塞一个字） => 必须红 */
  const rw = parsePayload(API.buildPayload(sAllMet.vis.concat(sAllMet.vis.slice(0, 1))), main12.n, sAllMet.vis);
  ctl("payload 比 visibleWords 多 1 个事件帧 -> 判据⑫ " +
      (rw.ok ? "仍然绿（判据失效）" : "变红（符合预期）") + "：" + (rw.bad[0] || "无未过原因"));
}

/* ---------------- ⑬ ---------------- */
const main13 = pred13(sSoloMet, sAllMet, sOff, sOff2, K);
judge("⑬", "非空洞 + 反向证伪：solo→all 必须变长；guideOn=false 必须原样返回", main13.ok,
  "solo " + main13.nSolo + " -> all " + main13.nAll + "（变长 " + main13.delta +
  "，应裁 " + main13.wantDelta + "）· guideOn=false 原样 " + main13.nOff + "/" + main13.nRaw +
  " · 引导关+节拍器关 原样 " + main13.nOff2 + "/" + main13.nRaw2);
ev("变长量必须 > 0（相等 ⇒ 红）· 且必须等于独立重算的应裁量 " + main13.wantDelta + "（背景旋律轨 + 谱面鼓轨的字数）");
ev("guideOn=false 时 visibleWords 必须与 conv.words 逐字相同（关掉引导模式与以前逐字节相同）——" +
   "两档都验：节拍器开（" + main13.nOff + " 字）与节拍器关（" + main13.nOff2 + " 字）");
if (!main13.ok) main13.bad.forEach(b => ev("未过原因：" + b));
{
  /* 反控：把 all 当成 solo 来判 => 两侧一样长 ⇒ 必须红 */
  const c = pred13(sAllMet, sAllMet, sOff, sOff2, K);
  ctl("把 all 的结果同时当作 solo 与 all -> 判据⑬ " +
      (c.ok ? "仍然绿（判据失效）" : "变红（符合预期）") + "：" + (c.bad[0] || "无未过原因"));
}

/* ---------------- ⑭ ---------------- */
const main14 = pred14(sSubMet, sSubTrack, sK1Sub, K);
judge("⑭", "选轨 × 引导裁剪：只选 [引导轨, 鼓轨] 时 visibleWords 仍然正确", main14.ok,
  "子集+met 可见 " + ((main14.sub || {}).n) + " 字（bit6 " + ((main14.sub || {}).vc || {}).nGuide +
  " / 鼓轴 " + ((main14.sub || {}).vc || {}).nDrum + "）· 子集+track 可见 " +
  ((main14.subTrack || {}).n) + " 字（鼓轴 " + ((main14.subTrack || {}).vc || {}).nDrum + "）" +
  (main14.k1 ? (" · 吉他 idx1 子集 " + main14.k1.n + " 字") : ""));
ev("🔴 抓的坑：把 wordsForSelected() 的输出再喂给 guideScopedWords()（后者按下标读 conv.evTrack）" +
   "⇒ 下标错位 ⇒ 实测「引导轨置位数从 72 掉到 45、鼓轴字数变 185」。");
ev("  只选 [引导轨 " + K + ", 鼓轨 " + DRUM_IDX.join(",") + "] + met：可见 " + ((main14.sub || {}).n) +
   " 字 · bit6 " + ((main14.sub || {}).vc || {}).nGuide + "（期望 " + ((main14.sub || {}).wantGuide) +
   " = 引导轨音符×2）· 鼓轴 " + ((main14.sub || {}).vc || {}).nDrum + "（期望 " + main14.wantMetWords +
   " = " + BARS + " 小节 × 8 下 × 2，met 档不避让）");
ev("  只选子集 + track：可见 " + ((main14.subTrack || {}).n) + " 字 · 鼓轴 " +
   ((main14.subTrack || {}).vc || {}).nDrum + "（期望 = 谱面鼓轨字数）");
if (main14.oldCmp) {
  ev("旧口径（wordsForSelected 的输出再喂 guideScopedWords）得到的字数 " + main14.oldCmp.oldLen +
     " vs 页面 visibleWords 的 " + main14.oldCmp.visLen + " ⇒ 与页面结果不同 = " + (!main14.oldCmp.same) +
     "（不同才对：这正是那个坑）");
}
if (main14.guard) {
  ev("guideScopedWords 的长度守卫：喂子集（" + main14.guard.inLen + " / " + main14.guard.fullLen +
     "）⇒ 原样返回 = " + main14.guard.unchanged + "（⛔ 不静默错位）");
}
if (main14.k1) {
  ev("用户自测那一组（引导轨 = 吉他 idx1，只选 [1, 鼓轨]，scope=all / drum=met）：可见 " + main14.k1.n +
     " = tempo " + main14.k1.nTempo + " + 引导轨 " + main14.k1.nGuide + " + 节拍器 " + main14.k1.nDrum +
     "（期望 " + main14.k1.wantTotal + " = " + main14.k1.wantTempo + " + " + main14.k1.wantGuide +
     " + " + main14.k1.wantDrum + "）");
}
if (!main14.ok) main14.bad.forEach(b => ev("未过原因：" + b));
{
  /* 反控：拿【全选】的产物去按"只选子集"的期望判 => 必须红（证明这条判据真的在管选轨） */
  const c = pred14(sAllMet, sAllTrack, null, K);
  ctl("把全选（scope=all/met）的产物当作「只选[引导轨,鼓轨]」来判 -> 判据⑭ " +
      (c.ok ? "仍然绿（判据失效）" : "变红（符合预期）") + "：" + (c.bad[0] || "无未过原因"));
}

/* ===========================================================================
   判据⑮⑯⑰：鼓与旋律彻底分离（2026-10-16 手册 §二 / §4.1-7 校验器 / §7.3 机械检查）
   ---------------------------------------------------------------------------
   口径：鼓 = is_drum(bit5)=1，件名 = drum_type = timbre[8:7] & 3（kick0 · snare1 · hihat2 · tom3）；
        旋律 = is_drum=0 且【排除 kind=2】（tempo 用 inc 装速度值，按 inc 判会把它当旋律）。
   ⛔ 全程不用"轴号落 12..15"当鼓的标志 —— 那正是本次要拆掉的老口径。
   ⚠️ 判据收成【纯函数】：真产物与"手造坏字"喂进同一个谓词，
      "判据能红"才是机械证明的（⛔ 不靠人眼说"这应该能红"）。
   =========================================================================== */

/* 判据⑮的谓词：§4.1-7 硬检查①② + §7.3 第 1 条 */
function pred15(words, tag) {
  const bad = [];
  let nDrum = 0, nMel = 0, nTempo = 0, drumIncNot0 = 0, melInc0 = 0, melOnDrumAxis = 0;
  const ex = { inc: "", mel: "", ax: "" };
  for (let i = 0; i < words.length; i++) {
    const d = unpack(words[i]);
    if (d.kind === API.KIND_TEMPO) {
      nTempo++;
      if (d.isDrum === 1) bad.push("tempo 事件（kind=2）的 is_drum 必须为 0（字 " + i + "）");
      continue;
    }
    if (d.isDrum === 1) {
      nDrum++;
      if (d.inc !== 0) { drumIncNot0++; if (!ex.inc) ex.inc = "字 " + i + " inc=" + d.inc; }
    } else {
      nMel++;
      if (d.inc === 0) { melInc0++; if (!ex.mel) ex.mel = "字 " + i; }
      /* §7.3-1：保留段 12..15（期望值独立写死，⛔ 不取页面的 isDrumAxis/DRUM_AXIS_BASE） */
      if (d.axis >= WANT_MELODY_BAN_AXIS_MIN) { melOnDrumAxis++; if (!ex.ax) ex.ax = "字 " + i + " axis=" + d.axis; }
    }
  }
  if (drumIncNot0) bad.push("鼓事件 inc 非 0：" + drumIncNot0 + " 条（硬检查②）（" + ex.inc + "）");
  if (melInc0) bad.push("旋律事件 inc=0：" + melInc0 + " 条（" + ex.mel + "）");
  if (melOnDrumAxis) bad.push("is_drum=0 的事件轴号落 12..15：" + melOnDrumAxis + " 条（§7.3-1）（" + ex.ax + "）");
  if (!(nDrum > 0)) bad.push(tag + "：一条鼓事件都没有 ⇒ 判据空洞（测不到东西）");
  if (!(nMel > 0)) bad.push(tag + "：一条旋律事件都没有 ⇒ 判据空洞");
  return { ok: bad.length === 0, bad: bad, tag: tag, nDrum: nDrum, nMel: nMel, nTempo: nTempo,
           drumIncNot0: drumIncNot0, melInc0: melInc0, melOnDrumAxis: melOnDrumAxis };
}

/* 判据⑯的谓词：鼓的 ON/OFF 配对（(axis, drum_type)，手册点名的"漏了就挂音"）+ note_off5=0 */
function pred16(words) {
  const bad = [];
  const keyOf = d => (d.axis & 15) + ":" + dtOf(d);
  const open = new Map();
  let on = 0, off = 0, unclosed = 0, orphan = 0, offNoFlag = 0, note5Bad = 0;
  const ex = [];
  for (let i = 0; i < words.length; i++) {
    const d = unpack(words[i]);
    if (d.kind === API.KIND_TEMPO) continue;
    if (d.isDrum === 1) {
      if (d.note5 !== 0) note5Bad++;
      const k = keyOf(d);
      if (d.kind === API.KIND_ON) {
        on++;
        if (!open.has(k)) open.set(k, []);
        open.get(k).push(i);
      } else {
        off++;
        const q = open.get(k);
        if (q && q.length) q.shift(); else orphan++;
      }
    } else if (d.kind === API.KIND_OFF && d.axis >= WANT_MELODY_BAN_AXIS_MIN) {
      /* 鼓轴段（12..15）上的 OFF 却不是鼓 ⇒ 典型的"鼓 OFF 漏标 is_drum"（会把鼓 voice 永久 held）。
       * 2026-10-16 第三轮：鼓回到 12..15 ⇒ 这条重新成为主指纹（同时 melInc0 也会涨）。 */
      offNoFlag++;
      if (ex.length < 3) ex.push("字 " + i + " axis=" + d.axis + " 的 OFF 没带 is_drum");
    }
  }
  for (const q of open.values()) unclosed += q.length;      /* ⚠️ open 的值是【队列数组】 */
  if (unclosed) bad.push("鼓 ON 没配到同 (axis, drum_type) 的 OFF：" + unclosed + " 条（挂音、耗尽鼓池）");
  if (orphan) bad.push("鼓 OFF 找不到对应的 ON：" + orphan + " 条");
  if (offNoFlag) bad.push("鼓轴段（轴 12..15）上的 OFF 没带 is_drum=1：" + offNoFlag + " 条（" + ex.join(" | ") + "）");
  if (note5Bad) bad.push("is_drum=1 的事件 note_off5 非 0：" + note5Bad + " 条（鼓没有音高）");
  const cnt = {}; for (let t = 0; t < 4; t++) cnt[t] = { on: 0, off: 0 };
  for (const w of words) {
    const d = unpack(w);
    if (d.isDrum !== 1 || d.kind === API.KIND_TEMPO) continue;
    const t = dtOf(d);
    if (d.kind === API.KIND_ON) cnt[t].on++; else cnt[t].off++;
  }
  for (let t = 0; t < 4; t++) {
    if (cnt[t].on !== cnt[t].off) bad.push(nameOfType(t) + " 的 ON/OFF 数不等：" + cnt[t].on + "/" + cnt[t].off);
  }
  return { ok: bad.length === 0, bad: bad, on: on, off: off, unclosed: unclosed, orphan: orphan,
           offNoFlag: offNoFlag, note5Bad: note5Bad, cnt: cnt };
}

/* 判据⑰的谓词：鼓件【按 drum_type 认件】= timbre[8:7]（2 位，4 件），
 *   并核对"轴 == 12 + drum_type"（一件一轴：四件鼓的 src 全是 SRC_KDRUM，
 *   note_off 按 (axis, src) 配对 ⇒ 轴与件一旦错配，一件的 OFF 会清掉另一件的 voice）。 */
function pred17(words) {
  const bad = [];
  const per = {}; for (let t = 0; t < 4; t++) per[t] = 0;
  const axisOf = {};
  let badAxis = 0, rawBad = 0;
  const ex = [];
  for (let i = 0; i < words.length; i++) {
    const w = words[i];
    const d = unpack(w);
    if (d.isDrum !== 1) continue;
    const t = dtOf(d);
    per[t]++;
    if (axisOf[t] === undefined) axisOf[t] = d.axis;
    if (axisOf[t] !== d.axis) {
      badAxis++;
      if (ex.length < 3) ex.push("drum_type " + t + " 出现在轴 " + d.axis + "（另有 " + axisOf[t] + "）");
    }
    if (d.axis !== WANT_AXIS_KEY[t]) {
      badAxis++;
      if (ex.length < 3) ex.push("字 " + i + " drum_type=" + t + " 轴=" + d.axis + " != 12+dt = " + WANT_AXIS_KEY[t]);
    }
    /* 两条【独立】读取路径（页面 unpackWord 的 drumType / 本文件的位提取）必须给出同一个件号 */
    if (dtOfRaw(rawOf(w)) !== t) {
      rawBad++;
      if (ex.length < 3) ex.push("字 " + i + " 两条件号读取路径不一致（位提取给出 " + dtOfRaw(rawOf(w)) + "）");
    }
  }
  for (const t of WANT_BASE_TYPES) if (!(per[t] > 0)) bad.push(nameOfType(t) + "（drum_type=" + t + "）一件都没有");
  if (badAxis) bad.push("drum_type 与轴不是按 12+dt 一一对应：" + badAxis + " 处（" + ex.join(" | ") + "）");
  if (rawBad) bad.push("两条件号读取路径不一致：" + rawBad + " 处（" + ex.join(" | ") + "）");
  /* 页面表 vs 手册独立表（⛔ 不是拿页面的表验页面的表）—— 本轮应当正好 4 件。 */
  if (!API.DRUM_TYPE_OF) bad.push("页面没有 DRUM_TYPE_OF（鼓件口径表缺失）");
  else {
    for (const nm of ["kick", "snare", "hihat", "tom"]) {
      if (API.DRUM_TYPE_OF[nm] !== WANT_TYPE[nm]) {
        bad.push("页面 DRUM_TYPE_OF." + nm + " = " + API.DRUM_TYPE_OF[nm] + " != " + WANT_TYPE[nm]);
      }
      if (API.DRUM_AXIS_OF && API.DRUM_AXIS_OF[nm] !== WANT_AXIS[nm]) {
        bad.push("页面 DRUM_AXIS_OF." + nm + " = " + API.DRUM_AXIS_OF[nm] + " != " + WANT_AXIS[nm]);
      }
    }
    const vals = Object.values(API.DRUM_TYPE_OF).slice().sort((a, b) => a - b);
    if (vals.length !== 4 || vals.some((v, i) => v !== i)) {
      bad.push("页面 DRUM_TYPE_OF 的值域不是 0..3（4 件）：[" + vals.join(",") + "]");
    }
  }
  return { ok: bad.length === 0, bad: bad, per: per, axisOf: axisOf, extMiss: [] };
}

/* 判据⑳的谓词（2026-10-16 第三轮回退 4 件时补上；与 check_drum_split.py 判据⑧ 同口径）：
 *   鼓力度逐件定值 —— Kick 230 · Snare 235 · HiHat 175 · Tom 220，鼓的 OFF 写 0。
 *   为什么必须有这条：上一轮"扩到 8 件"时按 inc 认件、力度表被撑到 8 项；
 *   本轮回到 4 件，力度表同步收成 4 项，且必须【逐条】核对产物，不能只对表。
 *   ⚠️ 只判鼓（is_drum=1）；旋律力度来自 MIDI 原始力度，不由产物单独判定（只作报告）。 */
function pred20(words) {
  const bad = [];
  const seen = {}; for (let t = 0; t < 4; t++) seen[t] = { on: new Set(), nOn: 0, nOff: 0, offBad: 0 };
  let nDrum = 0, nOnBad = 0, nOffBad = 0;
  const ex = [];
  for (let i = 0; i < words.length; i++) {
    const d = unpack(words[i]);
    if (d.isDrum !== 1) continue;
    nDrum++;
    const t = dtOf(d);
    if (t < 0 || t > 3) { if (ex.length < 3) ex.push("字 " + i + " drum_type=" + t + " 越界（4 件只有 0..3）"); continue; }
    if (d.kind === API.KIND_ON) {
      seen[t].nOn++; seen[t].on.add(d.vel);
      if (d.vel !== WANT_DRUM_VEL[t]) {
        nOnBad++;
        if (ex.length < 3) ex.push("字 " + i + " " + nameOfType(t) + " ON 力度 " + d.vel +
                                   " != 定值 " + WANT_DRUM_VEL[t]);
      }
    } else if (d.kind === API.KIND_OFF) {
      seen[t].nOff++;
      if (d.vel !== 0) { seen[t].offBad++; nOffBad++; }
    }
  }
  if (!(nDrum > 0)) bad.push("一条鼓事件都没有 ⇒ 力度判据空洞（测不到东西）");
  if (nOnBad) bad.push("鼓 ON 力度不等于该件定值：" + nOnBad + " 条（" + ex.join(" | ") + "）");
  if (nOffBad) bad.push("鼓 OFF 力度非 0：" + nOffBad + " 条（口径：OFF 写 0）");
  /* 非空洞：四件的定值都必须被取到（否则"改一个力度"可能一件都没样本） */
  for (let t = 0; t < 4; t++) if (!(seen[t].nOn > 0)) bad.push(nameOfType(t) + " 一条 ON 都没有，力度判据空洞");
  return { ok: bad.length === 0, bad: bad, nDrum: nDrum, nOnBad: nOnBad, nOffBad: nOffBad,
           seen: seen, ex: ex };
}

/* 判据⑲的谓词（2026-10-16 第三轮新增）：镲族必须归 hihat。
 *   46/49/51/52/53/55/57/59 在页面 GM_DRUM_MAP 里必须【显式列出】且指向 hihat ——
 *   ⛔ 不靠表外兜底（兜底 -> tom，等于"镲变嗵鼓"，正是本轮要禁的）。
 *   ⚠️ 这份测试曲一个镲族音高都没有 ⇒ 产物上验不到，只能核对这张表。 */
function pred19() {
  const bad = [];
  const note = [];
  const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
  if (!API.GM_DRUM_MAP) bad.push("页面没有 GM_DRUM_MAP（GM 音高 -> 鼓件名的表缺失）");
  else {
    const notListed = WANT_CYMBAL_GMS.filter(g => !has(API.GM_DRUM_MAP, g));
    if (notListed.length) {
      bad.push("镲族 " + notListed.join("/") + " 没有【显式列出】（会走表外兜底 -> tom）");
    }
    const notHat = WANT_CYMBAL_GMS.filter(g => has(API.GM_DRUM_MAP, g) &&
                                               API.GM_DRUM_MAP[g] !== "hihat");
    if (notHat.length) {
      bad.push("镲族没有指向 hihat：" + notHat.map(g => "GM" + g + "->" + API.GM_DRUM_MAP[g]).join(" "));
    }
    note.push("页面表共 " + Object.keys(API.GM_DRUM_MAP).length + " 条");
  }
  /* 反控（静态）：把镲族从表里拿掉、或把它指到 tom，检查器必须认出来 ——
   *   证明这条判据不是恒真的假绿。 */
  const fakeDrop = {};
  for (const k of Object.keys(API.GM_DRUM_MAP || {})) if (WANT_CYMBAL_GMS.indexOf(Number(k)) < 0) fakeDrop[k] = API.GM_DRUM_MAP[k];
  const ctlDrop = WANT_CYMBAL_GMS.filter(g => !has(fakeDrop, g)).length;
  const fakeTom = Object.assign({}, API.GM_DRUM_MAP || {});
  fakeTom[51] = "tom";
  const ctlTom = WANT_CYMBAL_GMS.filter(g => has(fakeTom, g) && fakeTom[g] !== "hihat");
  if (ctlDrop !== WANT_CYMBAL_GMS.length) {
    bad.push("反控失效：把镲族从表里拿掉后只认出 " + ctlDrop + "/" + WANT_CYMBAL_GMS.length + " 个");
  }
  if (!(ctlTom.length === 1 && ctlTom[0] === 51)) {
    bad.push("反控失效：把 GM51 改成 tom 后认出的集合 = [" + ctlTom.join(",") + "]（应只认 51）");
  }
  note.push("反控：拿掉镲族 -> 认出 " + ctlDrop + " 个；GM51->tom -> 认出 [" + ctlTom.join(",") + "]");
  return { ok: bad.length === 0, bad: bad, note: note.join(" · ") };
}

/* 判据⑱的谓词（2026-10-16 新增）：旋律 note_off5 的新口径 ——
 *   可弹（MIDI 45..75）=> MIDI-45；越界（<45 或 >75）=> 31 哨兵（不可弹、不点灯）；
 *   ⛔ 不许钳到 0（0 = A2 = 真实的键 5，会点亮错误的灯）。
 *   ⚠️ 音高从【事件里带的 inc】反推（⛔ 不读页面的 midi 中间量）；inc 只有 21 位 ⇒ 允许 ±1 半音；
 *      边界（45±0.5 / 75±0.5）留死区不判。
 *   ⚠️ 口径边界：哨兵只作用于旋律；鼓的 note_off5 恒 0（判据⑯，本轮不回退）。 */
function note5Scan(list) {
  const SENT = 31, LO = 45, HI = 75;
  const res = { play: 0, unplay: 0, edge: 0, skip: 0, badVal: 0, badSent: 0, badUse: 0, badClamp: 0, ex: [] };
  for (const it of list) {
    const d = it.d || it;
    if (d.isDrum === 1 || d.kind === API.KIND_TEMPO) continue;
    const m = (d.inc === 0) ? null : midiOfInc(d.inc);
    if (m == null) { res.skip++; continue; }
    if (m < LO - 0.5 || m > HI + 0.5) {
      res.unplay++;
      if (d.note5 !== SENT) {
        res.badSent++;
        if (d.note5 === 0) res.badClamp++;
        if (res.ex.length < 3) res.ex.push("tick " + d.tick + " 音高 " + m.toFixed(1) + " 却写 note5=" + d.note5);
      }
    } else if (m < LO || m > HI) {
      res.edge++;
    } else {
      res.play++;
      const want = Math.round(m) - LO;
      if (d.note5 === SENT) {
        res.badUse++;
        if (res.ex.length < 3) res.ex.push("tick " + d.tick + " 音高 " + m.toFixed(1) + " 可弹却写哨兵 31");
      } else if (Math.abs(d.note5 - want) > 1) {
        res.badVal++;
        if (res.ex.length < 3) res.ex.push("tick " + d.tick + " note5=" + d.note5 + " 期望 " + want);
      }
    }
  }
  return res;
}
const midiOfInc = inc => { const hz = inc * 50000000 / 4294967296; return hz > 0 ? 69 + 12 * Math.log2(hz / 440) : null; };
const incOfMidi = m => Math.round(440 * Math.pow(2, (m - 69) / 12) * 4294967296 / 50000000);

const main15  = pred15(convMain.words, "主产物（全量）");
const main15v = pred15(sAllMet.vis, "可见字（所见即所灌）");
const main16  = pred16(convMain.words);
const main17  = pred17(convMain.words);
const vcAll   = sAllMet.vc;
judge("⑮", "鼓/旋律分离：鼓 inc 全 0 · 旋律 inc 全非 0 · 鼓轴全 == 12+dt · is_drum=0 无轴 12..15",
  main15.ok && main15v.ok && vcAll.nDrum === vcAll.nDrumKeyOk &&
  vcAll.nDrumIncNot0 === 0 && vcAll.nMelOnDrumAxis === 0,
  "全量：鼓 " + main15.nDrum + " / 旋律 " + main15.nMel + " · 可见：is_drum 字 " + vcAll.nDrum +
  " == 轴=12+dt 的字 " + vcAll.nDrumKeyOk + " · 鼓 inc≠0 " + (main15.drumIncNot0 + vcAll.nDrumIncNot0) +
  " · 旋律 inc=0 " + (main15.melInc0 + main15v.melInc0) +
  " · 旋律落保留段(12..15) " + (main15.melOnDrumAxis + main15v.melOnDrumAxis));
ev("全量产物（" + main15.nTempo + " 个 tempo）逐条扫：" + main15.nDrum + " 条鼓 / " + main15.nMel + " 条旋律");
ev("可见字（visibleWords，" + vcAll.n + " 字）逐条扫：is_drum=1 的字 " + vcAll.nDrum +
   " 条，其中 inc≠0 的 " + vcAll.nDrumIncNot0 + " 条、轴 == 12+dt 的 " + vcAll.nDrumKeyOk +
   " 条（本轮：这两个数必须相等；鼓占 12..15，旋律一条都不许占这一段）");
if (!main15.ok)  main15.bad.forEach(b => ev("未过原因（全量）：" + b));
if (!main15v.ok) main15v.bad.forEach(b => ev("未过原因（可见字）：" + b));
judge("⑯", "鼓 ON/OFF 按 (axis,drum_type) 全配对（OFF 也带 is_drum=1 与同一 drum_type）+ 鼓 note_off5=0",
  main16.ok,
  "ON " + main16.on + " / OFF " + main16.off + " · 未闭合 " + main16.unclosed + " · 无主 OFF " + main16.orphan +
  " · 保留段上漏标 is_drum 的 OFF " + main16.offNoFlag + " · note_off5≠0 的鼓 " + main16.note5Bad);
ev("逐件 ON/OFF 数（按 drum_type）：" +
   [0, 1, 2, 3].map(t => nameOfType(t) + " " + main16.cnt[t].on + "/" + main16.cnt[t].off).join(" · ") +
   "（手册点名的死线：OFF 漏带 is_drum/drum_type ⇒ 鼓 voice 永久 held ⇒ 保留池耗尽）");
if (!main16.ok) main16.bad.forEach(b => ev("未过原因：" + b));
judge("⑰", "鼓件按 drum_type 认件（4 件）：四件齐全 + 轴 == 12+dt + 两条件号读取路径一致 + 页面表一致",
  main17.ok,
  "四件计数 " + [0, 1, 2, 3].map(t => nameOfType(t) + "=" + main17.per[t]).join(" · ") +
  " · 轴 " + [0, 1, 2, 3].map(t => main17.axisOf[t]).join("/"));
ev("12+dt（鼓的轴 = 12 + drum_type，独立写死）：" + AXIS_KEY_TXT);
ev("对照表（本轮定稿，独立写死）：" +
   [0, 1, 2, 3].map(t => nameOfType(t) + "=drum_type" + t + "/轴" + WANT_AXIS_KEY[t]).join(" · "));
if (!main17.ok) main17.bad.forEach(b => ev("未过原因：" + b));
/* ⑲（2026-10-16 第三轮新增）镲族必须【显式】归 hihat（⛔ 不靠表外兜底 -> tom）。 */
const main19 = pred19();
judge("⑲", "镲族 8 个音高在页面 GM 表里【显式列出】-> hihat（⛔ 不靠兜底 -> tom）",
  main19.ok,
  main19.ok ? ("46/49/51/52/53/55/57/59 全部显式 ->hihat · " + main19.note)
            : main19.bad.join(" | "));
/* ⑳（第三轮回退 4 件口径新增）鼓力度逐件定值 + OFF 写 0。 */
const main20 = pred20(convMain.words);
judge("⑳", "鼓力度逐件定值：Kick230 Snare235 HiHat175 Tom220 · 鼓 OFF 写 0", main20.ok,
  "鼓事件 " + main20.nDrum + " 条 · 力度错 " + main20.nOnBad + " · OFF 力度非 0 " + main20.nOffBad +
  " ｜ 逐件 ON 力度 " + [0, 1, 2, 3].map(t =>
    nameOfType(t) + "=" + ([...main20.seen[t].on].sort((a, b) => a - b).join("/") || "无") +
    "(定值" + WANT_DRUM_VEL[t] + ")").join(" · "));
ev("生效值 = drum_gen.v 默认 + top.v 覆盖（Kick 未被覆盖 ⇒ 230）· OFF 写 0（" +
   [0, 1, 2, 3].map(t => nameOfType(t) + " off " + main20.seen[t].nOff).join(" · ") + "）");
if (!main20.ok) main20.bad.forEach(b => ev("未过原因：" + b));
/* ⑱（2026-10-16 新增）旋律 note_off5 新口径：可弹(45..75) => MIDI-45 · 越界 => 31 哨兵。 */
const n5Main = note5Scan(decWords(convMain));
const n5Vis  = note5Scan(sAllMet.vis ? sAllMet.vis.map(w => unpack(w)) : []);
judge("⑱", "旋律 note_off5：可弹(45..75) => MIDI-45 · 越界 => 31 哨兵（⛔ 不许钳到 0）",
  n5Main.badVal === 0 && n5Main.badSent === 0 && n5Main.badUse === 0 &&
  n5Vis.badVal === 0 && n5Vis.badSent === 0 && n5Vis.badUse === 0 && main16.note5Bad === 0,
  "全量：可弹 " + n5Main.play + " · 越界 " + n5Main.unplay + "（应写 31）· 值不对 " + n5Main.badVal +
  " · 越界没写哨兵 " + n5Main.badSent + "（其中钳到 0 的 " + n5Main.badClamp + "）· 可弹误写哨兵 " + n5Main.badUse +
  " ｜ 可见字：可弹 " + n5Vis.play + " · 越界 " + n5Vis.unplay + " · 违规 " +
  (n5Vis.badVal + n5Vis.badSent + n5Vis.badUse));
ev("音高只从事件里的 inc 反推（⛔ 不读页面的 midi 中间量）；inc 21 位 ⇒ 允许 ±1 半音，边界 45±0.5 / 75±0.5 留死区");
ev("  全量：可弹 " + n5Main.play + " · 越界 " + n5Main.unplay + " · 死区 " + n5Main.edge +
   " · 无法反推 " + n5Main.skip + (n5Main.ex.length ? ("（例 " + n5Main.ex.join(" | ") + "）") : ""));
ev("  可见字：可弹 " + n5Vis.play + " · 越界 " + n5Vis.unplay + " · 死区 " + n5Vis.edge +
   " · 无法反推 " + n5Vis.skip + (n5Vis.ex.length ? ("（例 " + n5Vis.ex.join(" | ") + "）") : ""));
if (n5Main.badSent || n5Main.badVal || n5Main.badUse) {
  n5Main.ex.forEach(x => ev("未过原因（全量）：" + x));
}
{
  /* ---- 反控：手造坏字，喂进【同一个】谓词，要求对应判据变红 ---- */
  const w0 = convMain.words[0], r0 = rawOf(w0);
  const mk = o => mkWord(Object.assign({}, r0, o));
  /* a 鼓事件 inc≠0（§4.1-7 硬检查②） */
  const ra = pred15(convMain.words.concat([mk({ isDrum: 1, inc: 37796, axis: 12, timbre: 0,
                                                kind: API.KIND_ON, note5: 0 })]), "反控 a");
  ctl("手造一条 is_drum=1 且 inc≠0 的字 -> 判据⑮ " +
      (ra.ok ? "仍然绿（判据失效）" : "变红（符合预期）：" + ra.bad[0]));
  /* b 旋律事件 inc=0 */
  const rb = pred15(convMain.words.concat([mk({ isDrum: 0, inc: 0, axis: 2, timbre: 1,
                                                kind: API.KIND_ON, note5: 3 })]), "反控 b");
  ctl("手造一条 is_drum=0 且 inc=0 的旋律字 -> 判据⑮ " +
      (rb.ok ? "仍然绿（判据失效）" : "变红（符合预期）：" + rb.bad[0]));
  /* c is_drum=0 却占鼓轴（§7.3-1） */
  const rc = pred15(convMain.words.concat([mk({ isDrum: 0, inc: 37796, axis: 13, timbre: 1,
                                                kind: API.KIND_ON, note5: 3 })]), "反控 c");
  ctl("手造一条 is_drum=0 且轴=13 的字 -> 判据⑮ " +
      (rc.ok ? "仍然绿（判据失效）" : "变红（符合预期）：" + rc.bad[0]));
  /* d tempo 事件被标成鼓 */
  const rd = pred15(convMain.words.concat([mk({ isDrum: 1, inc: 12345, axis: 0, timbre: 0,
                                                kind: API.KIND_TEMPO, note5: 0 })]), "反控 d");
  ctl("手造一条 kind=2（tempo）却 is_drum=1 的字 -> 判据⑮ " +
      (rd.ok ? "仍然绿（判据失效）" : "变红（符合预期）：" + rd.bad[0]));
  /* e 把一条鼓 OFF 的 is_drum 位【替换】清 0（ON/OFF 不同步 —— 手册点名的漏点） */
  let at = -1;
  for (let i = 0; i < convMain.words.length; i++) {
    const d = unpack(convMain.words[i]);
    if (d.isDrum === 1 && d.kind === API.KIND_OFF) { at = i; break; }
  }
  if (at >= 0) {
    const w1 = convMain.words.slice();
    w1[at] = w1[at] & ~(1n << 5n);
    const re2 = pred16(w1);
    ctl("把一条鼓 OFF 的 is_drum 位清 0（ON/OFF 不同步）-> 判据⑯ " +
        (re2.ok ? "仍然绿（判据失效）" : "变红（符合预期）：" + re2.bad[0]));
    /* f 把同一条鼓 OFF 的 drum_type 改错（0 -> 1） */
    const w2 = convMain.words.slice();
    w2[at] = (w2[at] & ~(0x3n << 7n)) | (1n << 7n);
    const rf = pred16(w2);
    ctl("把一条鼓 OFF 的 drum_type 改成 snare(1)（与 ON 不一致）-> 判据⑯ " +
        (rf.ok ? "仍然绿（判据失效）" : "变红（符合预期）：" + rf.bad[0]));
    /* g 拔掉那条鼓 OFF ⇒ 未闭合 ON 必须 > 0 */
    const w3 = convMain.words.slice(0, at).concat(convMain.words.slice(at + 1));
    const rg = pred16(w3);
    ctl("拔掉一条鼓 OFF -> 判据⑯ " +
        (rg.ok ? "仍然绿（判据失效）" : "变红（符合预期）：" + rg.bad[0]));
    /* h 给一条鼓事件塞 note_off5≠0（鼓没有音高） */
    const w4 = convMain.words.slice();
    w4[at] = (w4[at] & ~0x1Fn) | 7n;
    const rh = pred16(w4);
    ctl("把一条鼓事件的 note_off5 置 7 -> 判据⑯ " +
        (rh.ok ? "仍然绿（判据失效）" : "变红（符合预期）：" + rh.bad[0]));
    /* i 鼓件 drum_type 改错 ⇒ 轴与件不对应（判据⑰） */
    const w5 = convMain.words.slice();
    w5[at] = (w5[at] & ~(0x3n << 7n)) | (2n << 7n);      /* 件号改了、轴没跟着改 ⇒ 轴 != 12+dt */
    const ri = pred17(w5);
    ctl("把一条鼓事件的 drum_type 改成 hihat(2)（轴没跟着变）-> 判据⑰ " +
        (ri.ok ? "仍然绿（判据失效）" : "变红（符合预期）：" + ri.bad[0]));
    /* j ⑰反控：手造鼓字落在【旧口径】的轴上（上一轮 dt 键 0 / 更早的 8）⇒ 轴 != 12+dt，必须红 */
    const rj = pred17(convMain.words.concat([mkWord(Object.assign({}, r0, {
      isDrum: 1, inc: 0, timbre: 0, axis: 0, kind: API.KIND_ON, note5: 0 }))]));
    const rj8 = pred17(convMain.words.concat([mkWord(Object.assign({}, r0, {
      isDrum: 1, inc: 0, timbre: 0, axis: 8, kind: API.KIND_ON, note5: 0 }))]));
    ctl("手造一条鼓字落在 axis=0（上一轮的 dt 键）-> 判据⑰ " +
        (rj.ok ? "仍然绿（判据失效）" : "变红（符合预期）"));
    ctl("手造一条鼓字落在 axis=8（更早的 8..15 口径）-> 判据⑰ " +
        (rj8.ok ? "仍然绿（判据失效）" : "变红（符合预期）"));
    /* j3 ⑰反控（第三轮重点，任务书点名）：手造一条 Snare(dt=1) 落在【kick 的轴 12】上
     *   —— 轴号本身合法（12..15 之内、且这一件上有其它鼓在用），只有"件与轴错配"；
     *   判据⑰ 的硬判据 axis-12 == drum_type 必须把它抓出来（"轴落 12..15"这种软判据抓不到）。 */
    {
      const w12 = convMain.words.concat([mkWord(Object.assign({}, r0, {
        isDrum: 1, inc: 0, timbre: WANT_TYPE.snare, axis: WANT_AXIS.kick,
        kind: API.KIND_ON, note5: 0, vel: WANT_DRUM_VEL[WANT_TYPE.snare] }))]);
      const rj3 = pred17(w12);
      ctl("手造一条 Snare(dt=1) 落在 kick 的轴 12 上 -> 判据⑰ " +
          (rj3.ok ? "仍然绿（判据失效）" : "变红（符合预期）：" + rj3.bad[0]));
    }
    /* j2 ⑰反控（非空洞）：证明"只读 timbre[8:7]（2 位）"在本产物上有鉴别力 ——
     *   若还按上一轮的 3 位 {bit19, timbre[8:7]} 读，件号会在多少条上不同。
     *   本产物有落在轴 13/15（bit19=1）的鼓 ⇒ 这个数必然 > 0。 */
    let legacyDiff = 0;
    for (const w of convMain.words) {
      const d = unpack(w);
      if (d.isDrum !== 1) continue;
      if (dtOfLegacy3(rawOf(w)) !== dtOfRaw(rawOf(w))) legacyDiff++;
    }
    ctl("上一轮的 3 位读法 {bit19,timbre} 与 2 位读法在本产物上会差 " + legacyDiff +
        " 条鼓事件的件号 -> " + (legacyDiff > 0 ? "2 位读法的鉴别力非空洞（符合预期）"
                                                : "两种读法结果相同，检查空洞"));
  } else {
    ctl("找不到可改的鼓 OFF（无法构造 ⑯⑰ 的反控）");
  }
  /* l ⑲反控：镲族缺一条 / 指错件 —— 用 pred19 里的静态反控读数（拿掉镲族、GM51->tom） */
  ctl("把镲族从页面表里拿掉 / 把 GM51 改成 tom -> 判据⑲ 的静态反控读数：" + main19.note);
  /* l2 ⑲反控（真跑谓词，⛔ 不只靠 pred19 内部的算术自证）：
   *   把 GM51 改成 tom 的表【喂回 pred19 的逻辑】重判 —— 用同一个 WANT_CYMBAL_GMS 重扫一遍。 */
  {
    const badGm = {};
    for (const k of Object.keys(API.GM_DRUM_MAP || {})) badGm[k] = (Number(k) === 51) ? "tom" : API.GM_DRUM_MAP[k];
    const notHat = WANT_CYMBAL_GMS.filter(g => Object.prototype.hasOwnProperty.call(badGm, g) &&
                                               badGm[g] !== "hihat");
    ctl("把页面表里 GM51 改成 tom 后重扫镲族 -> 认出的错误集合 [" + notHat.join(",") +
        "] -> 判据⑲ " + ((notHat.length === 1 && notHat[0] === 51) ? "变红（符合预期）"
                                                                    : "仍然绿（判据失效）"));
  }
  /* m ⑳反控：鼓力度两种坏法，喂进【同一个】pred20()。
   *   ⚠️ ON 那条必须挑【定值不是 230】的那一件来改 —— 随手把第一条鼓 ON 改成 230 时，
   *      若第一条正好是 Kick（定值 230）就等于没改 ⇒ 假绿（实测踩过）。 */
  {
    const idx = convMain.words.findIndex(w => {
      const d = unpack(w);
      return d.isDrum === 1 && d.kind === API.KIND_ON && WANT_DRUM_VEL[dtOf(d)] !== 230; });
    if (idx >= 0) {
      const t = dtOf(unpack(convMain.words[idx]));
      const wv = convMain.words.slice();
      wv[idx] = (wv[idx] & ~(0xFFn << 11n)) | (230n << 11n);   /* 力度换成 Kick 的 230（该件定值不是它） */
      const rv = pred20(wv);
      ctl("把一条 " + nameOfType(t) + " ON 的力度换成 Kick 的 230（该件定值是 " + WANT_DRUM_VEL[t] +
          "）-> 判据⑳ " + (rv.ok ? "仍然绿（判据失效）" : "变红（符合预期）：" + rv.bad[0]));
      const wo = convMain.words.slice();
      const atOff = convMain.words.findIndex(w => {
        const d = unpack(w); return d.isDrum === 1 && d.kind === API.KIND_OFF; });
      if (atOff >= 0) {
        wo[atOff] = (wo[atOff] & ~(0xFFn << 11n)) | (BigInt(WANT_DRUM_VEL[dtOf(unpack(wo[atOff]))]) << 11n);
        const ro = pred20(wo);
        ctl("把一条鼓 OFF 的力度写成该件的定值 -> 判据⑳ " +
            (ro.ok ? "仍然绿（判据失效）" : "变红（符合预期）：" + ro.bad[0]));
      }
    }
  }
  /* k ⑱反控：note_off5 的三种坏法，喂进【同一个】note5Scan() */
  {
    const mkD = (midi, n5) => ({ d: { isDrum: 0, kind: API.KIND_ON, tick: 0,
                                      inc: incOfMidi(midi), note5: n5 } });
    const base = decWords(convMain);
    const ka = note5Scan(base.concat([mkD(40, 0)]));
    ctl("手造一条音高 40（越界）却写 note5=0 的字 -> 判据⑱ " +
        (ka.badSent > 0 && ka.badClamp > 0 ? "变红（符合预期）" : "仍然绿（判据失效）") +
        "：越界未写哨兵 " + ka.badSent + " · 钳到 0 的 " + ka.badClamp);
    const kb = note5Scan(base.concat([mkD(60, 31)]));
    ctl("手造一条音高 60（可弹）却写哨兵 31 的字 -> 判据⑱ " +
        (kb.badUse > 0 ? "变红（符合预期）" : "仍然绿（判据失效）") + "：可弹误写哨兵 " + kb.badUse);
    const kc = note5Scan(base.concat([mkD(60, 3)]));
    ctl("手造一条音高 60 却写 note5=3（应为 15）的字 -> 判据⑱ " +
        (kc.badVal > 0 ? "变红（符合预期）" : "仍然绿（判据失效）") + "：值不对 " + kc.badVal);
  }
}


console.log();
/* ===========================================================================
   附：其它音型（报告项，非判据）
   =========================================================================== */
console.log("【二】其它音型自检（报告项，不计入判据）");
for (const style of ["beat", "off", "four"]) {
  const c = runGuide(true, K, true, style, "all", "met");
  const d = c.words.map((w, i) => ({ d: unpack(w), tr: c.evTrack[i] }));
  const ons = d.filter(o => isMetWord(o.d, o.tr) && o.d.kind === API.KIND_ON);
  const byNm = {};
  /* ⭐ 2026-10-16：件名 = drum_type = timbre[8:7] & 3（⛔ 不再按 inc 反查） */
  for (const o of ons) { const nm = nameOfType(o.d.timbre & 3); byNm[nm] = (byNm[nm] || 0) + 1; }
  console.log("  音型 " + style.padEnd(5) + "（" + (API.MET_STYLE_NAME[style] || "?") + "）：响 " +
    c.metCount + " + 跳过 " + c.metSkipped + " = " + (c.metCount + c.metSkipped) +
    "（期望 " + BARS + "×8 = " + (BARS * 8) + "）· 逐件 " + JSON.stringify(byNm));
}
/* ---------------- ㉑ 准备阶段（count-in）：原曲必须【后移】，⛔ 不是被裁掉 ------------ */
/* 🔴 2026-10-17 用户实测："加了准备小节之后，原曲最开始的小节被截断了，
 *    直接从准备小节后的小节开始"。
 *    根因：当时在 visibleWords 里用 `tick < prepEnd` 把事件【直接丢弃】。
 *    ✅ 修法：在 midiToWords 里把【全部事件整体后移 prepEnd】
 *       （语义 = 在原曲前面插入 N 小节节拍器，原曲一个小节都不少）。
 *    ⭐ 本判据钉三件事：① 旋律音数量不变 ② 每个音正好 +prepEnd ③ 准备窗内只有节拍器/tempo。
 *    ⚠️ 补它的原因：本脚本原先【一条】准备阶段的判据都没有 ⇒ 那个 bug 直接溜过去了。 */
{
  const PREP = 1, barT = API.MIDI_PPQN * 4;
  const runPrep = (n) => {
    if (typeof API.__setTrackSel === "function") API.__setTrackSel(null);
    setGuide(true, K, true, "beat", "all", "met", n);   /* 第 7 个参数 = 准备小节数 */
    const c = API.midiToWords(parsed);
    const v = (typeof API.visibleWords === "function") ? API.visibleWords(c) : c.words;
    return { c: c, vis: v };
  };
  const a = runPrep(0), b = runPrep(PREP);
  const mel = (vs) => vs.filter(w => {
    const d = unpack(w); return d.isDrum === 0 && d.kind !== API.KIND_TEMPO;
  });
  const ka = mel(a.vis), kb = mel(b.vis);
  const sig = (arr) => arr.map(w => { const d = unpack(w); return d.tick + "@" + d.inc; }).sort();
  const shifted = sig(ka).map(s => {
    const [t, i] = s.split("@");
    return (Number(t) + PREP * barT) + "@" + i;
  }).sort();
  const sameCount = (ka.length === kb.length && ka.length > 0);
  const sameShift = JSON.stringify(shifted) === JSON.stringify(sig(kb));
  const winOnlyMet = b.vis.every(w => {
    const d = unpack(w);
    return d.tick >= PREP * barT || d.isDrum === 1 || d.kind === API.KIND_TEMPO;
  });
  judge("㉑", "准备小节：原曲整体后移（⛔ 不是被裁掉）",
        sameCount && sameShift && winOnlyMet,
        "旋律 " + ka.length + " -> " + kb.length + " · 后移 " + PREP + " 小节 = " +
        (PREP * barT) + " tick · 准备窗纯净 " + winOnlyMet);
  ev("准备 0：" + ka.length + " 个旋律音 · 准备 " + PREP + "：" + kb.length + " 个（应相同）");
  ev("逐条核对：准备 " + PREP + " 的每个 (tick@inc) == 准备 0 的 +" + (PREP * barT));
  ctl("把 prepEnd 改回\"丢弃 tick < prepEnd 的事件\" -> 判据㉑ 必红（旋律数会变少）");
  /* ⑮ 顺带：prepShift 记账必须对上（越界保护那条路径见页面的 prepShiftWarn） */
  const sh = (b.c && b.c.prepShift) || 0;
  judge("㉑b", "准备阶段的后移量记账 = prepBars × 每小节 tick", sh === PREP * barT,
        "prepShift=" + sh + " 期望 " + (PREP * barT));
}

/* ---------------- ㉒ 准备段的时间轴【起点必须是 0】（游标/进度错位的根因）----------- */
/* 🔴 2026-10-18 用户实测："游标还是从蓝色部分（示范段）开始，不是从准备小节第一个音开始；
 *    播放进度也跟着偏，才放了两小节示范段、重复段根本还没到，进度就显示放完了"。
 *
 * 根因（已修，本判据钉住它）：
 *   准备段的实现是"把所有事件整体后移 prepEnd"，**tick 0 的初始 tempo 也被后移了** ✗
 *   而 `secToTick(sec)` / `tickToSec(tick)` 的积分起点是 `score.tempos[0].tick`
 *   ⇒ `secToTick(0)` 直接返回 **prepEnd**（不是 0）
 *   ⇒ 起播瞬间 `playClockTick()` = 0 + prepEnd ⇒ 游标一出生就站在示范段开头 ✗
 *   ⇒ 进度 = prepEnd/tickMax（本曲正好 33%）⇒ 看着"快放完了" ✗
 *
 * ⭐ 本判据钉四件事（缺一条都能让 bug 复活）：
 *   ① score.tempos[0].tick === 0          （初始 BPM 必须钉在 0）
 *   ② secToTick(0) === 0                  （时间轴积分起点）
 *   ③ 起播瞬间游标 tick === 0 且 进度 === 0
 *   ④ secToTick / tickToSec 互逆           （换算严格对齐，⛔ 各算一套）
 * ⚠️ 为什么㉑ 抓不到它：㉑ 只验"旋律后移了 + 逐条 +prepEnd"，⛔ 没验时间轴积分起点
 *    ⇒ 音符全对、游标全错。这正是"判据数量要等于路径数量"的又一次教训。
 */
{
  if (typeof API.secToTick !== "function" || typeof API.buildScore !== "function") {
    judge("㉒", "准备段的时间轴起点 = 0（游标/进度错位的根因）", false,
          "页面没导出 secToTick/buildScore ⇒ 判据无法执行（⛔ 不当成通过）");
  } else {
    const PREP2 = 2, barT2 = API.MIDI_PPQN * 4, PREP_T = PREP2 * barT2;
    if (typeof API.__setTrackSel === "function") API.__setTrackSel(null);
    setGuide(true, K, true, "beat", "all", "met", PREP2);
    const c2 = API.midiToWords(parsed);
    const v2 = (typeof API.visibleWords === "function") ? API.visibleWords(c2) : c2.words;
    const sc2 = API.buildScore(v2, c2);
    const t0 = (sc2.tempos && sc2.tempos.length) ? sc2.tempos[0].tick : null;
    const s0 = API.secToTick(0, sc2.tempos);
    const tickAtStart = 0 + s0;                       /* playClock.tick0(=0) + secToTick(0) */
    const fracStart = tickAtStart / Math.max(1, sc2.tickMax);
    /* 互逆：随便取一个秒数，正反换算必须回到原值 */
    const probeSec = Math.min(1.0, (sc2.duration || 1) * 0.25);
    const rt = API.tickToSec(API.secToTick(probeSec, sc2.tempos), sc2.tempos);
    const ok1 = (t0 === 0);
    const ok2 = Math.abs(s0) < 1e-6;
    const ok3 = Math.abs(tickAtStart) < 1e-6 && Math.abs(fracStart) < 1e-9;
    const ok4 = Math.abs(rt - probeSec) < 1e-3;
    judge("㉒", "准备段的时间轴起点 = 0（游标/进度错位的根因）",
          ok1 && ok2 && ok3 && ok4,
          "tempos[0].tick=" + t0 + " · secToTick(0)=" + s0.toFixed(1) +
          " · 起播tick=" + tickAtStart.toFixed(1) +
          " · 起播进度=" + (fracStart * 100).toFixed(2) + "%" +
          " · 互逆=" + rt.toFixed(4) + "s/" + probeSec.toFixed(4) + "s");
    ev("准备段长度 = " + PREP_T + " tick（" + PREP2 + " 小节）· 全曲 tickMax = " + sc2.tickMax +
       " ⇒ 准备段应占 " + (PREP_T / Math.max(1, sc2.tickMax) * 100).toFixed(0) + "% 宽度");
    ev("① tempos[0].tick=" + t0 + (ok1 ? " ✓ 初始 BPM 钉在 0" : " ✗ 被后移了"));
    ev("② secToTick(0)=" + s0.toFixed(1) + (ok2 ? " ✓" : " ✗ 应为 0"));
    ev("③ 起播 tick=" + tickAtStart.toFixed(1) + " 进度=" + (fracStart * 100).toFixed(2) + "%" +
       (ok3 ? " ✓ 游标从最左端起" : " ✗ 起点被推到了示范段"));
    ev("④ 换算互逆：" + probeSec.toFixed(4) + "s -> tick " +
       API.secToTick(probeSec, sc2.tempos).toFixed(1) + " -> " + rt.toFixed(4) + "s" +
       (ok4 ? " ✓ 严格对齐" : " ✗ 两套算法不一致"));
    /* 非空洞自证：把初始 tempo 也后移（旧写法）⇒ 上面 ①②③ 必须全红 */
    const s0old = PREP_T;                              /* 旧写法下 secToTick(0) === prepEnd */
    ctl("把初始 tempo 也后移（旧写法）-> secToTick(0)=" + s0old +
        "，起播进度会偏 " + (s0old / Math.max(1, sc2.tickMax) * 100).toFixed(0) +
        "% -> 判据㉒ 必红");
  }
}

/* 收尾把状态复原成"干净"的，避免给后来者留一个半开的状态 */
setGuide(false, null, false, "beat", "all", "met");
if (typeof API.__setTrackSel === "function") API.__setTrackSel(null);

if (mutated) {
  console.log();
  console.log("  突变自证 --mutate=" + mutated + "（" + MUTATIONS[mutated].note + "）：");
  console.log("    预期判据（至少）" + MUTATIONS[mutated].expect + " 变红 · 实际 RED 项 = " +
              (redList.length ? redList.join("") : "（无）"));
  console.log("    ⚠️ 实测多出的红是【连带】的（同一处改坏会打中依赖同一事实的多条判据）；" +
              "判定标准：预期的那几条必须【全部】出现在实测里，且实测不能为空。");
  console.log("    磁盘上的 score_studio.html 未被改动（只在内存里改了脚本块）。");
  /* 机械判定：预期项必须全部命中，且实测非空。不符合 ⇒ 退出码 3（与"判据红"的 1 区分开） */
  const mutWant = MUTATIONS[mutated].expect;
  const mutMiss = [...mutWant].filter(ch => redList.indexOf(ch) < 0);
  mutJudgeOk = (redList.length > 0 && mutMiss.length === 0);
  console.log("    突变判定：" + (mutJudgeOk ? "符合预期（预期项全部命中）"
                                             : ("不符合预期 —— 预期项没命中：" + mutMiss.join(""))));
}

console.log();
console.log("  结论：" + (red === 0 ? "全部通过（" + nJudge + " 项）" : ("有 " + red + " 项 RED")));
process.exit(red === 0 ? 0 : (mutJudgeOk === false ? 3 : 1));
