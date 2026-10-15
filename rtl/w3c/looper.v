`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// looper.v · 事件域 Looper（⭐ T37：单层录制 + 播放）
//
//  ⭐ 接口**严格照** `files/20-代码/looper接口定义-20260924.md`（⭐ 已冻结）
//  ⭐ 接法 = 该文档 §3.2 的**方案 A**（⭐ 重放走【源 A】，⛔ 不动 `evt_merge`）
//
//  ⭐⭐ 为什么便宜（⭐ 上游设计 §〇）：
//     ⭐ **"叠加" = 两条事件流 OR 起来** ⇒ ⛔ **不需要任何音频混音**
//     ⭐ 本模块**只碰事件流**，⛔ **不碰音频** ⇒ ⭐ **零音频合规风险** ✅
//
//  ⭐⭐ 2026-09-29 新增（⭐ 用户需求）：⭐ **回放携带【录制时的音色】**
//     🔴 用户原话：*"希望录制回放的时候，是输出录制时的音色，
//        ⭐ 而不是跟随现在手弹的音色播放"* ✅
//     ⭐ 做法：⭐ 事件字 **66 → 68 bit**（⭐ 音色字段**追加在最高位**，⭐ ⛔ 不动既有偏移 ✅）
//        ＋ ⭐ 新增 `live_timbre_i` / `play_timbre_o` / `play_timbre_valid_o` ✅
//     ⭐ 语义：⭐ **每个音各自记住它按下那一刻的音色**（⭐ 录制中途切 `'I'` 也各自正确 ✅）
//     📌 **下游不用改**：⭐ `seq_arb`（score 口）→ `evt_merge` → `note_manager.evt_timbre_i`
//        三层**都已有** timbre 通路 ✅ ⇒ ⭐ `top.v` 只需接**两根线** ✅
//
//  ⭐⭐ T37 的范围（⭐ ⛔ 不是全部 Looper）：
//     ✅ 单层（`LAYERS = 1`）录制 + 按 `tick` 重放 + `clear`
//     ✅ **停录时【补发 `note_off`】**（⭐ 否则 loop 里那个音**永不停止**
//        —— ⭐ 上游 §2 明确写这是 looper **最容易犯的错**）
//     ✅ 可观测：`evt_cnt` / `full` / `drop_cnt` / `overflow`（⭐ `K-106`：⛔ 不许静默失效）
//     ⛔ **不做**（⭐ 留给后续）：多层（`T40`）· 与手弹叠加（`T39`，要扩 `evt_merge`）
//        · `note_manager` 的 voice 预留
//     ✅ **2026-09-30 起：⭐ 对齐小节（`T41`）已实现** —— ⭐ 见下方 §小节对齐 ✅
//        （🔴 修的正是用户上板报告的"**回放过几次之后会逐渐延后**"—— ⭐ 根因就是
//         `loop_len` 不是整数小节 ⇒ ⭐ 每绕一圈相位偏一点 ⇒ **误差逐圈累加**）✅
//
//  ⚠️ **不集成进 `top.v`**（⭐ 本文件先独立 tb 验证 —— ⭐ 本项目既有做法：
//     ⭐ `evt_merge`/`seq_arb`/`drum_gen` 都是"先独立验、再集成"）✅
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module looper #(
    parameter integer AXIS_W  = 4,
    parameter integer PHASE_W = 32,
    parameter integer VEL_W   = 8,
    parameter integer KIND_W  = 2,
    //  ⭐⭐ 2026-09-29 新增（⭐ 用户需求）：⭐ **音色字段**（⭐ 与 `note_manager.TIMBRE_W` 一致 = 2 ✅）
    parameter integer TIMBRE_W = 2,
    parameter integer TICK_W  = 20,
    //  ⭐ T37 = **单层**（⭐ 上游 §四 第 1 步）⇒ ⚠️ **本版只实现 1 层**
    //     ⭐ `T40` 再扩到 3 层（⭐ 那时要动 `note_manager` 的配额）
    parameter integer LAYERS  = 1,
    //  ⭐ 每层事件上限（⭐ 上游 §2.4 已估算：2048/层）
    parameter integer EVT_MAX = 2048,
    parameter integer CNT_W   = 16      // ⭐ 事件计数位宽
) (
    input  wire                  clk_i,
    input  wire                  rst_n_i,

    // ══════════════════════════════════════════════════════════════════════
    // ① 音乐时钟（⭐ 来自 `beat_gen`）
    // ══════════════════════════════════════════════════════════════════════
    input  wire                  tick_i,        // ⭐ PPQN tick 脉冲
    input  wire [TICK_W-1:0]     tick_cnt_i,    // ⭐ 小节内 tick 计数
    input  wire                  bar_start_i,   // ⭐ 小节起点
    input  wire                  transport_i,   // ⭐ run 状态

    // ══════════════════════════════════════════════════════════════════════
    // ② ⭐ 手弹事件【旁路监听】—— ⚠️ **只读**！⛔ 本模块不许驱动这几根线
    // ══════════════════════════════════════════════════════════════════════
    input  wire                  live_valid_i,
    input  wire [AXIS_W-1:0]     live_axis_i,
    input  wire [PHASE_W-1:0]    live_inc_i,
    input  wire [VEL_W-1:0]      live_vel_i,
    input  wire [KIND_W-1:0]     live_kind_i,
    //  ⭐⭐ 2026-09-29 新增（⭐ 用户需求）：⭐ **【录制那一刻】的音色**
    //   🔴 **为什么**：⭐ 用户原话 —— *"希望录制回放的时候，是输出录制时的音色，
    //      ⭐ 而不是跟随现在手弹的音色播放"* ✅
    //   ⭐ 语义：⭐ 由 `top.v` 接**当前手弹音色**（⭐ `timbre_sel_r`，⭐ 即串口 `'I'` 选的 ✅）
    //      ⇒ ⭐ **每个音各自记住它按下时的音色**（⭐ 录制中途切 `I` 也各自正确 ✅）
    input  wire [TIMBRE_W-1:0]   live_timbre_i,
    //  ⭐⭐ 2026-09-29 新增（⭐ 用户需求）：⭐ **手弹【位置式力度】流**（⭐ 只读旁路监听）
    //
    //  🔴 **为什么必须有这个输入**（⭐ 有代码依据，⛔ 不是推测）：
    //     ⭐ 回放要"**从起点插值到终点**" ⇒ ⭐ **必须知道【松手那一刻】的力度** ✅
    //     ⚠️ 而 `live_vel_i`（`note_off` 那条事件自带的力度）**不是当前力度**：
    //        · `top.v:2609`  `w3a_evt_vel = (am_pos_in < VEL_TRIG_TH) ? VEL_DEFAULT
    //                                   : pos_to_vel(am_pos_in)`
    //        · ⭐ 而 `note_off` 是**松手**那一刻产生的 ⇒ `am_pos_in` 已落到释放阈以下
    //        ⇒ 🔴 **恒为 `VEL_DEFAULT = 200`**（⭐ 与"按住时有多重"**毫无关系**）✅
    //     ⭐ 所以端点只能**自己跟**：⭐ 本端口 = `top.v` 的 `vu_valid_r/vu_axis_r/vu_val_r`
    //        （⭐ 与 `note_manager.vel_upd_*` **同一个源** ✅ ⇒ 录到的端点
    //         与"手弹当时真正用的力度"**逐值一致** ✅）
    //
    //  📌 **音高端点为什么不需要额外的流**：⭐ `axis_map.v:511` 已改成
    //     "**按轴号查表**"（⭐ `frac` 恒 0，见 `axis_map.v:506-508`）
    //     ⇒ ⭐ 音高**只由轴号决定** ⇒ ⭐ 松手时查到的 `inc` 与按下时**完全相同** ✅
    //     ⇒ ⭐ 音高端点 = "该轴最后一次已知值"（⭐ 由 `note_on` 维护）**已经够用** ✅
    //     （⚠️ 若将来"滑弦"启用、音高真的会在按键期间变化 ⇒ ⭐ 那时**也要加一路
    //       `live_pitch_*` 流**，⭐ 与这里完全同构 —— 现在加是死代码，⛔ 不加）
    //
    //  ⚠️ **不接（悬空）= `x`** ⇒ ⭐ 本模块一律用 `=== 1'b1` 判定 ⇒
    //     ⭐ **老 tb 不接本端口时，行为与改动前【完全一致】** ✅
    //     （📌 与 `event_extract.enable_i` 的"**悬空 = 使能**"是**同一套
    //       【向后兼容优先】**口径 ✅）
    input  wire                  live_vel_valid_i,
    input  wire [AXIS_W-1:0]     live_vel_axis_i,
    input  wire [VEL_W-1:0]      live_vel_value_i,

    // ══════════════════════════════════════════════════════════════════════
    // ③ ⭐ 重放输出（⭐ → 源 A，⭐ 单周期脉冲）
    // ══════════════════════════════════════════════════════════════════════
    output reg                   play_valid_o,
    output reg  [AXIS_W-1:0]     play_axis_o,
    output reg  [PHASE_W-1:0]    play_inc_o,
    output reg  [VEL_W-1:0]      play_vel_o,
    output reg  [KIND_W-1:0]     play_kind_o,
    //  ⭐⭐ 2026-09-29 新增：⭐ **回放携带的【录制时音色】**（⭐ 与 `play_valid_o` **同拍** ✅）
    //   ⇒ ⭐ 下游 `seq_arb`(score 口) → `evt_merge` → `note_manager.evt_timbre_i` ✅
    //     （⭐ 三层**都已有** timbre 通路，⭐ ⛔ 不需要动它们 ✅）
    output reg  [TIMBRE_W-1:0]   play_timbre_o,
    output reg                   play_timbre_valid_o,

    //  ⭐⭐ 2026-09-29 新增（⭐ 用户需求）：⭐ **回放【插值更新】**（⭐ 单周期脉冲）
    //
    //  🔴 **修的缺陷**（⭐ 用户上板报告）：
    //     · *"loop 的声音比键盘小"* —— ⭐ 因为原来回放**只带 `note_on` 那一个力度**
    //     · *"loop 回放没有 release 尾音"* —— ⭐ `adsr.v` 的 release 是
    //       **每采样拍固定步长** ⇒ ⭐ **尾音长度 ∝ 松手时的包络电平 ∝ 力度** ✅
    //       （⭐ 实测：力度 200 ⇒ 峰 51200 ⇒ sustain 12800 ⇒ PAD 尾音 ≈262 ms；
    //         力度 64 ⇒ 4096 ⇒ ≈84 ms —— ⭐ **3 倍差距** ✅）
    //     ⭐ 而**手弹时力度是【位置式】连续更新的**（`top.v` 的 `vu_*`，每轴 ~328 µs）
    //     ⇒ 🔴 只录一个 `note_on` 力度 ⇒ **又小又短** ✅
    //
    //  ⭐⭐ **本组输出的语义**：⭐ "该轴**此刻的插值音高/力度**是这两个值"
    //     · ⭐ 由 `top.v` **或进** `note_manager` 的
    //       `pitch_upd_valid_i` / `vel_upd_valid_i`（⭐ 与手弹那两路**共用通路** ✅）
    //     · ⚠️ 与 `play_valid_o` **无关**（⭐ 后者是"事件"，本组是"参数"——
    //       ⭐ 冻结表铁律：**参数永不产生音符** ✅）
    //     · ⚠️ **本模块【主动避让】手弹的更新流**（⭐ 见下方 `live_busy`）
    //       ⇒ ⭐ 与手弹**结构上不可能同拍**（⛔ 不靠"谁先谁后"的约定）✅
    output reg                   play_upd_valid_o,
    output reg  [AXIS_W-1:0]     play_upd_axis_o,
    output reg  [PHASE_W-1:0]    play_upd_inc_o,
    output reg  [VEL_W-1:0]      play_upd_vel_o,

    // ══════════════════════════════════════════════════════════════════════
    // ④ 控制（⭐ 每层独立；⭐ T37 只用 `[0]`）
    // ══════════════════════════════════════════════════════════════════════
    input  wire [LAYERS-1:0]     rec_req_i,     // ⭐ 开始录制（单周期）
    input  wire [LAYERS-1:0]     stop_req_i,    // ⭐ 停止录制（⭐ 会补发 `note_off`）
    input  wire [LAYERS-1:0]     play_en_i,     // ⭐ 播放使能（电平）
    input  wire [LAYERS-1:0]     clear_req_i,   // ⭐ 清空该层

    // ══════════════════════════════════════════════════════════════════════
    // ⑤ ⭐⭐ 可观测性（⭐ `K-106`：⛔ 不许静默失效）
    // ══════════════════════════════════════════════════════════════════════
    output wire [LAYERS-1:0]     layer_state_o,   // ⭐ 0 = 空闲 · 1 = 录/放
    //  ⭐⭐ 2026-10-14：⭐ **"已武装、等小节线"**（⭐ 给指示灯用 ✅）
    //     🔴 **为什么需要**：⭐ 按下 `R` 后**不是立刻起录**，而是等 `bar_start_i`
    //        （⭐ 见上面 `ST_RECPEND` 与 `:1156` 的长注释 —— ⭐ 为了 `loop_len` 是整数小节 ✅）
    //        ⇒ ⚠️ **这一整段窗口里弹的音一个都不录**
    //        （⭐ 最长 = 一整小节 ⇒ ⭐ 120 BPM 下 **2 秒**）
    //        ⇒ 🔴 **用户感知为"第一个音被吞掉了"** ✅
    //     📌 ⭐ `layer_state_o` **只有 1 位**（⭐ `:1518`）
    //        ⇒ ⚠️ 分不出"在录"和"武装中" ⇒ 🔴 **灯上看不出来** ⇒ ⭐ 用户不知道要等 ✅
    //     ✅ 所以单开这一根，⭐ 让灯能显示**第 4 种状态**
    //        （⭐ 见 `top.v` 的 `led_looper_st` 与 `led_indicator.v` 的码 3 ✅）
    output wire                  rec_pending_o,
    //  ⚠️ Verilog-2001 **不支持数组端口**（⭐ 接口文档 §2.1 第 2 条）
    //     ⇒ ⭐ 必须**展平成一个向量**（每层 16 bit）
    output wire [LAYERS*16-1:0]  evt_cnt_flat_o,
    output wire [LAYERS-1:0]     full_o,          // ⭐ 该层录满（⭐ 再录会丢）
    output wire [15:0]           drop_cnt_o,      // ⭐ 丢了几个事件（**饱和**，⛔ 不回绕）
    output reg                   overflow_o,      // ⭐ sticky（⭐ 复位才清）
    //  ══════════════════════════════════════════════════════════════════════
    // ⑥ ⭐⭐⭐⭐ 2026-10-11：⭐ **录制回传（导出读口）** ✅
    //  ══════════════════════════════════════════════════════════════════════
    //  ⭐ **用途**：⭐ 把**已录下的事件**读出来（⭐ 交给导出 FSM ⇒ `u_tx_fifo` ⇒
    //     ⭐ ESP32 ⇒ BLE ⇒ PC ✅）—— ⭐ 即用户要的"**录制回传**" ✅
    //  📌 ⭐ **语义**：⭐ `dump_en_i` 拉高时，⭐ `mem` 的**读口归导出**
    //     ⇒ ⭐ `dump_data_o` 在**下一拍**给出 `mem[dump_addr_i]` ✅
    //     ⚠️ 因此**导出期间⛔ 不要放音**（⭐ 由导出 FSM 保证：⭐ 只在层空闲时导 ✅）
    //  🔴 **为什么⛔ 不能"再加一个读口"**：⭐ 见下方 `mem_rd_addr` 那段长注释
    //     （⭐ BSRAM 是 **1 写口 ＋ 1 读口** ⇒ ⚠️ 加第二个读口会**推不出 BSRAM**
    //      ⇒ 🔴 退回 DFF 阵列 ⇒ ⭐ 就是 `135168 > 60780` 的**综合失败** ✅）
    //  ⚠️ **老例化不接这三个端口** ⇒ `dump_en_i` 是 `z` ⇒ ⭐ 由下方 `=== 1'b1`
    //     解码成 **0** ⇒ ⭐ **读口仍归放音** ⇒ ⭐ **行为与加端口之前完全一致** ✅
    input  wire                  dump_en_i,       // ⭐ 1 = 导出占用读口（⭐ 与放音互斥 ✅）
    input  wire [CNT_W-1:0]      dump_addr_i,     // ⭐ 导出地址（⭐ 0 .. cnt_r-1 ✅）
    //  ⭐⭐ 2026-10-11：⭐ **导出数据 = 线上 64 位格式**（⭐ 由本模块重打包 ⇒ 单一来源 ✅）
    //     📌 ⭐ 与 `evt_uart_rx`/`evt_buf` 的帧载荷**逐位一致** ⇒ ⭐ 可直接回灌 ✅
    output wire [63:0]           dump_data_o,
    //  ⭐⭐ 2026-10-11：⭐ **截断标志**（⭐ 本条 `phase_inc` 超出 21 位 ⇒ ⚠️ 导出失真 ✅）
    //     📌 ⭐ 用途：⭐ 让"**不是原样**"这件事**可见**（⭐ `K-106`：⛔ 不许静默失真 ✅）
    //     📌 ⭐ 典型：⭐ 曲谱事件恒 0 ✅ · ⭐ 实时弹的事件可能为 1 ✅
    output wire                  dump_clip_o
);

    // ── 参数自检（⭐ 与 `clk_gen`/`tlc5916`/`top` 的 `PARAM_OK` 同一套路）──────
    //   🔴 **为什么必须有**：⭐ 本版**只实现了 1 层**（⭐ `T37`）
    //      ⇒ ⚠️ 若有人 `LAYERS(3)` 例化它 ⇒ 🔴 **第 2/3 层【完全没有逻辑】**
    //         ⇒ ⭐ 而端口/观测**看起来都在** ⇒ ⭐ **静默失效**（⭐ `C45` 的最坏形式）
    initial begin
        if (LAYERS != 1)
            $display("ERROR [looper] this build implements ONE layer only (T37): LAYERS=%0d. Raise LAYERS only together with the per-layer logic (T40).", LAYERS);
        if (EVT_MAX > (1 << CNT_W))
            $display("ERROR [looper] EVT_MAX=%0d does not fit in CNT_W=%0d", EVT_MAX, CNT_W);
        //  ⚠️ `evt_cnt_flat_o` 的位宽 = `LAYERS*16`，⭐ 而 `cnt_r` 是 `CNT_W` 位
        //     ⇒ ⭐ 两者**必须相等**（⭐ 否则要么零宽复制、要么静默截断）
        if ((LAYERS * 16) != CNT_W)
            $display("ERROR [looper] evt_cnt_flat_o is %0d bits but CNT_W=%0d -- they must match (see the flat-port note)", LAYERS * 16, CNT_W);
        //  ⚠️ 补发扫描是**按 16 个轴**写的（`close_mask_r` 16 位）⇒ ⭐ `AXIS_W` 必须是 4
        if (AXIS_W != 4)
            $display("ERROR [looper] the note_off close-out scan assumes 16 axes: AXIS_W=%0d", AXIS_W);
    end

    // ── 事件打包（⭐ 一个事件 = 一个 `EW` 位字）──────────────────────────────
    //   ⚠️ Verilog-2001 **不允许对数组元素做部分选择**（`mem[i][7:0]` 非法）
    //      ⇒ ⭐ 必须**先把字读进 `wire`** 再 `+:` 取段（⭐ 本项目 `K-91` 同族纪律）
    localparam integer EW = TICK_W + KIND_W + AXIS_W + PHASE_W + VEL_W + TIMBRE_W;
    localparam integer O_VEL  = 0;
    localparam integer O_INC  = O_VEL  + VEL_W;
    localparam integer O_AXIS = O_INC  + PHASE_W;
    localparam integer O_KIND = O_AXIS + AXIS_W;
    localparam integer O_TICK = O_KIND + KIND_W;
    //  ⭐⭐ 2026-09-29 新增：⭐ 音色字段**追加在【最高位】** ⇒ ⛔ 不动上面任何偏移 ✅
    //     📌 最小改动 ⇒ ⚠️ 已有字段的顺序/语义**一个都没变** ✅（⭐ 事件字 66 → 68 bit ✅）
    localparam integer O_TBR  = O_TICK + TICK_W;

    //  ⚠️ **`K-91`：⛔ 不能对 `integer` 参数做位选**（`EVT_MAX[15:0]` 在 Verilog-2001 非法）
    //     ⇒ ⭐ 先落成**有宽度的 `localparam` 向量**再比较 ✅
    localparam [CNT_W-1:0] EVT_MAX_V = EVT_MAX;

    // ── 状态 ────────────────────────────────────────────────────────────────
    //  ⚠️ 2026-09-29：⭐ 状态从 **2 位加宽到 3 位** —— ⭐ 4 个码已用满，⭐ 要加"补发后清空"
    localparam [2:0] ST_IDLE = 3'd0;   // ⭐ 没录过（或刚 clear）
    localparam [2:0] ST_REC  = 3'd1;   // ⭐ 正在录
    localparam [2:0] ST_CLOSE= 3'd2;   // ⭐ 停录后**补发 `note_off`**（⭐ **存进 `mem`** ⇒ 是录音的一部分）
    localparam [2:0] ST_HOLD = 3'd3;   // ⭐ 录完了，等 `play_en_i`
    //  ⭐⭐ 2026-09-29 修 bug①：⭐ **回放中"清空 / 停播"时【直接吐 `note_off`】**（⭐ ⛔ 不存 `mem`）
    //
    //   🔴 **上板实测（用户报告）**：⭐ **回放中按 `C` 清空 ⇒ 当前正在响的那个音【永久挂住】** ✅
    //   🔴 **根因（代码级）**：⭐ 原 `clear` 分支直接 `state <= ST_IDLE` ＋ 清 `cnt_r`/`rd_ptr_r`
    //      ⇒ ⭐ **正在响的 loop 音【永远收不到 `note_off`】**
    //      ⇒ ⭐ `note_manager` 的 `gate_r` **永久为 1** ⇒ ⚠️ **挂音** ✅
    //   ✅ **修法**：⭐ 先**逐轴补发**（⭐ 复用 `ST_CLOSE` 那套扫描）⇒
    //      ⭐ `clr_after_r` 决定"补完是否清空"（⭐ 1 = 清空 · 0 = 只是停播）✅
    //   📌 **同一个缺陷类**：⭐ **"停播"（`play_en` 落）也会挂音** ⇒ ⭐ 一并修 ✅
    localparam [2:0] ST_LCLOSE = 3'd4; // ⭐ 逐轴补发（⭐ 清空 / 停播 / 重录 共用）
    //  ⭐⭐ 2026-09-29【结构性修法】：⭐ **"补发完之后去哪"**（⭐ 由 `leave_to_r` 携带）✅
    //   🔴 **为什么需要**：⭐ `ST_HOLD` 有 **3 条**退出路径（⭐ `clear` / `play_en` 落沿 / `rec_req`）⚠️
    //      ⇒ ⭐ 每条都要"补发完再去对应的地方" ⇒ ⭐ **必须把"去哪"参数化** ✅
    localparam [1:0] LEAVE_HOLD = 2'd0; // ⭐ 只是停播 ⇒ 补完回 `ST_HOLD`（⭐ 保留录音）
    localparam [1:0] LEAVE_IDLE = 2'd1; // ⭐ 清空   ⇒ 补完清干净 ⇒ `ST_IDLE`
    localparam [1:0] LEAVE_REC  = 2'd2; // ⭐ 重录   ⇒ 补完开始录 ⇒ `ST_REC`
    //  ⭐⭐ 2026-09-30（`T41` 小节对齐）：⭐ **"已请求起录、⭐ 正在等小节起点"**
    //   🔴 **为什么需要它**：⭐ 见下方 §小节对齐 的大段说明 ——
    //      ⭐ 若按下 `R` 就立刻起录 ⇒ `loop_len` 不是整数小节 ⇒ **与鼓机越跑越偏** ✅
    //   ⭐ `3'd5` 是本 FSM 的**第 6 个状态**（⭐ 原用 0~4 ⇒ 3 位够用，⛔ 不用加宽）✅
    localparam [2:0] ST_RECPEND = 3'd5; // ⭐ 待起录（⭐ 等 `bar_start_i`）

    reg [2:0]       state;
    //  ⭐⭐ 2026-09-29 修 bug①：⭐ **"loop 现在有哪些轴在响"**
    //     ⭐ 重放 `note_on` ⇒ 置位 · ⭐ 重放 `note_off` ⇒ 清零 ✅
    //     ⇒ ⭐ **清空 / 停播时用它逐轴补发 `note_off`**（⭐ 否则挂音）✅
    reg [15:0]      play_active_r;
    //  ⭐⭐ 2026-09-29【结构性修法】：⭐ **补发完之后去哪**（⭐ 见 `LEAVE_*`）✅
    //   ⚠️ 原来是 1 位 `clr_after_r`（⭐ 只表达"清空 or 停播"）⇒ ⭐ 现在要能表达
    //      "**去 `ST_REC`**"（⭐ 回放中按 `R` 重录 ✅）⇒ ⭐ **加宽到 2 位** ✅
    reg [1:0]       leave_to_r;
    //  ⭐ `play_en_i` 的上一拍（⭐ 用来检出"停播"这个下降沿）
    reg             play_en_d_r;
    reg [EW-1:0]    mem [0:EVT_MAX-1];      // ⭐ 事件存储（⭐ 按 `tick` **自然有序**：录进来的顺序就是时间序）
    reg [CNT_W-1:0] cnt_r;                  // ⭐ 已存事件数
    reg [TICK_W-1:0] rec_tick_r;            // ⭐ 录制中的相对 tick（⭐ 从 `rec_req` 起算）
    reg [TICK_W-1:0] loop_len_r;            // ⭐ 循环长度（⭐ 停录那一刻的 `rec_tick_r`）
    reg [TICK_W-1:0] play_tick_r;           // ⭐ 重放中的相对 tick
    reg [CNT_W-1:0]  rd_ptr_r;              // ⭐ 重放读指针（⭐ **只前进** ⇒ 天然按 tick 有序）
    reg              tick_pend_r;           // ⭐ 本拍有 tick 待推进（⭐ 等本 tick 的事件排空）
    reg [15:0]       drop_r;                // ⭐ 丢弃计数（饱和）
    reg              full_r;                // ⭐ 录满
    reg [15:0]       close_mask_r;          // ⭐ 停录时**还没收到 `note_off`** 的轴（⭐ 补发用）
    reg [3:0]        close_scan_r;          // ⭐ 补发扫描位（⭐ 一次补一个轴）

    // ══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-09-30：⭐ **小节对齐（`T41`）** —— ⭐ 修用户上板报告的"回放越跑越偏"
    //
    //  🔴 **用户原话**：*"回放的节拍会对不上，回放过几次之后会逐渐延后。比如第一次
    //     响在第一拍，后面就会延后到第二拍，第三遍开始第一次响"* ✅
    //
    //  🔴 **根因（⭐ 设计文档【早就写明】，⭐ 只是没实现 —— ⛔ 不是新发现）**：
    //     `files/20-代码/Looper详细设计.md` §4.4（标题就叫"**决定"能不能用"**"）原文：
    //       · *"随便一个时刻按下 `rec_start` ⇒ loop 长度不是整数小节
    //          ⇒ **与鼓机越跑越偏**"* ✅
    //       · *"`rec_start` 不立即生效，而是等下一个 `bar_start`（对齐）；
    //          `rec_stop` 同理**量化到最近的整小节**"* ✅
    //     ⚠️ 而本模块原来：⭐ `rec_req` / `stop_req` / `play_en` **全部立即生效**，
    //        ⭐ `loop_len_r <= rec_tick_r`（⭐ 按下停录那一刻的**原始** tick 计数）
    //        ⇒ ⭐ **每绕一圈相位偏 `loop_len mod TICKS_PER_BAR` 个 tick**
    //        ⇒ 🔴 **误差逐圈累加**（⭐ 正是用户听到的"逐渐延后"）✅
    //     📌 本文件头部原来就写着"⛔ 不做（留给后续）… 对齐小节（`T41`）" ✅
    //
    //  ⭐ **修法（⭐ 三条，⭐ 与 §4.4 逐条对应）**：
    //     ① **起录对齐**：⭐ `rec_req` 只置"待起录"（`ST_RECPEND`）⇒ 等 `bar_start_i` 才真进 `ST_REC`
    //     ② **停录量化**：⭐ `loop_len` 量化到**最近的整小节**（⭐ 用 `tick_cnt_i` 判前后半小节）
    //     ③ **起播对齐**：⭐ `play_en` 先只置"对齐标志"（`play_aligned_r`）⇒ 等 `bar_start_i` 才真走 tick
    //        （⭐ 否则 loop 的 `tick 0` 落在小节中间 ⇒ 即使长度对了，⭐ **内容也整体偏一个固定相位**）✅
    //
    //  ⚠️ **向后兼容（⭐ 与 `live_vel_valid_i` 的"悬空 = 无更新"同一套口径）**：
    //     ⭐ **没见过 `bar_start_i` ⇒ `grid_ok_r = 0` ⇒ 三条全部【旁路】**，
    //        ⭐ 行为与改动前**逐位相同** ✅
    //     📌 依据（⭐ 实测 grep，⛔ 不是推测）：⭐ `tb_looper` / `tb_score_looper_coexist`
    //        这两个**唯一**实例化 `looper` 的 tb **都不驱动 `bar_start_i`**（⭐ 恒 0）✅
    // ══════════════════════════════════════════════════════════════════════
    reg [TICK_W-1:0] bar_len_r;       // ⭐ 一小节的 tick 数（⭐ 由相邻两个 `bar_start` 量出来）
    reg [TICK_W-1:0] bar_cnt_r;       // ⭐ 量尺：⭐ 距上一个 `bar_start` 的 tick 数
    reg              bar_seen_r;      // ⭐ 已见过 ≥1 个 `bar_start`
    reg              grid_ok_r;       // ⭐ 小节网格可用（⭐ 第 2 个 `bar_start` 起才置 1）
    reg [TICK_W-1:0] rec_bar_tick_r;  // ⭐ ② 本遍录制中**最近一个小节起点**处的 tick 数
    reg [CNT_W-1:0]  rec_bar_cnt_r;   // ⭐ ② 同上，但记的是**事件条数**（⭐ 舍去半小节时一起退）
    reg              rec_aligned_r;   // ⭐ 本遍录制**是不是从小节起点起录的**（⭐ 否则不量化）
    reg              play_aligned_r;  // ⭐ ③ 起播已对齐小节（⭐ 0 = 已请求、还在等小节线）

    //  ── ⭐ 小节网格量尺（⭐ 只在 transport 走着时量）─────────────────────────
    //   ⭐ `bar_start_i` 那一拍**就是**本小节第 1 个 tick —— 依据（⭐ 代码，⛔ 不是推测）：
    //      · `beat_gen.v:212-220`：⭐ `tick_q` 与 `bar_start_q` 在**同一个 `if (do_tick)` 里**置位
    //        ⇒ ⭐ 两个脉冲**同拍** ✅
    //      · `beat_gen.v:166`：⭐ `at_bar_start = (tick_cnt_q == 16'd0)` ⇒ 小节起点 = 编号 0 那一拍 ✅
    //   ⇒ ⭐ 数到下一个 `bar_start` 时 `bar_cnt_r` 恰好 = **一小节的 tick 数** ✅
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            bar_len_r  <= {TICK_W{1'b0}};
            bar_cnt_r  <= {TICK_W{1'b0}};
            bar_seen_r <= 1'b0;
            grid_ok_r  <= 1'b0;
        end else if (tick_i && transport_i) begin
            if (bar_start_i) begin
                //  ⚠️ **第 1 个 `bar_start`** 量到的是"从复位/上次停止到这一刻" ⇒ **不可信**
                //     ⇒ ⭐ 只记数、⛔ 不置 `grid_ok`（⭐ 第 2 个起 `bar_len_r` 才是真值 ✅）
                bar_len_r  <= bar_cnt_r;
                bar_cnt_r  <= {{(TICK_W-1){1'b0}}, 1'b1};   // ⭐ 本拍 = 新小节第 1 个 tick
                grid_ok_r  <= bar_seen_r;
                bar_seen_r <= 1'b1;
            end else begin
                bar_cnt_r  <= bar_cnt_r + 1'b1;
            end
        end
    end

    // ⭐ 事件类型编码（⭐ 与 `note_manager.note_kind_i` 一致）
    //   ⚠️ **必须在下面 `rec_inc_w` 之前声明** —— ⭐ 它要按 `KIND_OFF` 判端点 ✅
    localparam [KIND_W-1:0] KIND_ON  = {KIND_W{1'b0}};   // 0 = note_on
    localparam [KIND_W-1:0] KIND_OFF = {{(KIND_W-1){1'b0}}, 1'b1}; // 1 = note_off

    // ══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-09-29 新增：⭐ **端点跟踪 / 插值**（⭐ 用户需求：复现"轻→重"手势）
    // ══════════════════════════════════════════════════════════════════════
    //  ── ① 录制侧：⭐ 每轴"**本音期间的最大力度**"（⭐ 端点 = **峰值**，⛔ 不是末值）──
    //   🔴 **为什么不能直接用 `live_inc_i`/`live_vel_i`**：⭐ 见端口区注释 ——
    //      ⭐ `note_off` 自带的 `vel` **恒为 `VEL_DEFAULT(200)`** ✅
    //   ⚠️ 音高由 `note_on` 维护即可（⭐ `axis_map` 已改成"按轴号查表"✅）
    //
    //  ⭐⭐ **2026-09-30 改动：端点语义 "松手那一刻的末值" ⇒ "本音期间的峰值"** ✅
    //   🔴 **实测到的分歧（⭐ `tb/w3c/tb_looper_tail.sv`，⭐ 4 种行程，⭐ 见报告）**：
    //      同一段行程下，手弹与回放的 **`vel_r@off` 逐值相同**（⭐ 力度通路没问题），
    //      🔴 但 **`note_off` 那一刻的包络电平差 30%~63%**：
    //        · ⭐ 普通按：⭐ 手弹 `env@off=34343` · ⭐ 回放 `24137`（⭐ 70%）
    //        · ⭐ 重按  ：⭐ 手弹 `59939` · ⭐ 回放 `36570`（⭐ 61%）
    //        · ⭐ 重按+慢松：⭐ 手弹 `59838` · ⭐ 回放 `22155`（⭐ 37%）
    //      ⇒ ⭐ **尾音时长 = `env@off` / `release_step`** ⇒ 🔴 **回放尾音按比例变短**
    //         （⭐ 正是用户报的"回放没有 release 尾音"）✅
    //
    //   ⭐ **根因（⭐ 结构性，⛔ 不是时序巧合）**：
    //      · ⭐ 手弹时 `note_manager` 的 `vel_r` 是**跟着位置走的**（⭐ ±8/采样拍）
    //        ⇒ ⭐ 一段"**先按重、再松手**"的行程里，`vel_r` **中途冲到峰值**（如 255）
    //        ⇒ ⭐ `adsr` 的 `peak_level = vel<<8` 冲到 65280、
    //           `sustain_level = peak×230/256` 冲到 58650
    //        ⇒ ⭐ 而 `adsr` 的 **decay 是每采样拍 1**（⭐ `adsr.v:65`）⇒ ⭐ **一个 50 ms 的音根本降不下来**
    //        ⇒ ⭐ **`note_off` 那一刻包络仍挂在 ~60k** ⇒ 🔴 **release 从高处起步 ⇒ 尾音长** ✅
    //      · 🔴 而 looper **只记两个端点**（`note_on` 起点 ＋ 松手末值），⭐ 中间**线性插值**
    //        ⇒ ⭐ 回放的 `vel_r` **永远爬不到那个中途峰值**（⭐ 末值往往只有 159/95）
    //        ⇒ ⭐ 包络峰值低 ⇒ `sustain_level` 低 ⇒ 🔴 **release 从低处起步 ⇒ 尾音短** ✅
    //      📌 **与"极轻按键"无关**（⭐ 已实测否证）：⭐ 轻按（⭐ 峰值 70）时两边**完全相等**
    //         —— ⭐ 因为那种行程**本来就没有中途峰值** ✅
    //
    //   ✅ **修法（⭐ 最小、⭐ 只改"端点取哪个值"）**：⭐ **记【峰值】而不是【末值】** ✅
    //      · ⭐ 起音 ⇒ 峰值 := 起音力度 · ⭐ 其后每次 `vel_upd` ⇒ `peak := max(peak, 新值)`
    //      · ⭐ 松手 ⇒ 用峰值当 `note_off` 的 `vel`（⭐ 也就是插值终点 `ep_vel`）✅
    //      ⇒ ⭐ 回放的 `vel_r` 会**一路爬到峰值** ⇒ ⭐ 包络峰值与手弹**同一个量级**
    //        ⇒ ⭐ `env@off` 与尾音时长**对齐** ✅
    //      📌 **单调手势下两者逐值相同**（⭐ "轻→重"：⭐ 峰值 == 末值）⇒
    //         ⭐ `tb_looper` 的端点判据（⭐ 240 / 160）**一字不改、照样绿** ✅
    //      ⚠️ **只多一个 16×8 位数组的 `max` 比较**（⭐ ⛔ 不扩事件字、⛔ 不加端口）✅
    reg [PHASE_W-1:0] last_inc_r [0:15];
    reg [VEL_W-1:0]   vel_max_r [0:15];
    //  ── ② 每轴"当前未闭合的 `note_on`"的存储地址（⭐ 终点**写回**的目标）──────
    //   ⭐ 语义：⭐ `on_open_r[a]=1` ⇒ "轴 a 的 `note_on` 已落盘、⭐ 还没收到 `note_off`"
    //   ⚠️ **必须有 `on_open_r`**：⭐ `close_mask_r` 在"录满丢事件"时**也会置位**
    //      （⭐ 见下方录制段）⇒ ⚠️ 若不加这道门，补发时会把**陈旧的地址**当成
    //      本音的 `note_on` ⇒ 🔴 **覆盖掉别人的端点**（⭐ 静默错数据）✅
    reg [CNT_W-1:0]   on_addr_r  [0:15];
    reg [15:0]        on_open_r;

    //  ── ③ 回放侧：⭐ 插值状态（⭐ 每轴一份；⭐ 由共享引擎一拍扫一个轴）────────
    //   ⭐ 语义：⭐ `ramp_mask[a]=1` ⇒ "轴 a 正在从 `ramp_*[a]` 爬向 `rtgt_*[a]`" ✅
    reg [PHASE_W-1:0] ramp_inc  [0:15];   // ⭐ 当前插值音高（⭐ 发出去的就是它）
    reg [VEL_W-1:0]   ramp_vel  [0:15];   // ⭐ 当前插值力度
    reg [PHASE_W-1:0] rtgt_inc  [0:15];   // ⭐ 终点音高（⭐ 来自 `ep_mem`）
    reg [VEL_W-1:0]   rtgt_vel  [0:15];   // ⭐ 终点力度（⭐ 来自 `ep_mem`）
    reg [TICK_W-1:0]  rend_tick [0:15];   // ⭐ 终点 tick（⭐ 到了就吸附 + 收工）
    reg [15:0]        ramp_mask;
    reg [3:0]         ramp_sc;            // ⭐ 引擎的轴扫描位（⭐ 一拍一个轴）
    reg               ramp_go;            // ⭐ 本轮要扫一遍（⭐ 每 tick 置一次）

    //  ── ⭐ 落盘时用的 inc/vel（⭐ `note_off` 换成"**本音峰值力度**" = 端点）──────
    //   ⚠️ **必须在【模块级】声明** —— 🔴 Verilog-2001 要求"声明先于语句"，
    //      ⛔ 不能写在 `always` 块中间（⭐ 本项目已踩过：40+ 连锁语法错 ✅）
    //   📌 `vel` 取**峰值**（⛔ 不是末值）—— ⭐ 理由见 `vel_max_r` 那段长注释 ✅
    wire [PHASE_W-1:0] rec_inc_w = (live_kind_i == KIND_OFF) ? last_inc_r[live_axis_i]
                                                             : live_inc_i;
    wire [VEL_W-1:0]   rec_vel_w = (live_kind_i == KIND_OFF) ? vel_max_r[live_axis_i]
                                                             : live_vel_i;
    //  ── ⭐ 停录补发那条 `note_off` 落在**循环的最后一个可播 tick**（`loop_len-1`）──
    //   ⚠️ 与既有 `ST_CLOSE` 的算式**逐字一致**（⭐ 那里原来写的是内联表达式）
    wire [TICK_W-1:0]  close_tick_w = (loop_len_r == {TICK_W{1'b0}}) ? {TICK_W{1'b0}}
                                                                    : (loop_len_r - 1'b1);

    //  ── ⭐ 手弹更新流"本拍有没有"（⭐ 引擎避让用）──────────────────────────────
    //   ⚠️ **悬空（`x`）⇒ 视为【没有】** —— ⭐ 老 tb 不接该端口 ⇒ ⛔ 不许影响任何行为 ✅
    wire live_busy = (live_vel_valid_i === 1'b1);

    //  ── ⭐ 插值步长（⭐ 组合；⭐ **每拍重算**，⭐ 只对 `ramp_sc` 那一个轴求值）────
    //   ⭐ 取 `step = max(1, ceil(|diff| / 2^floor(log2(ticks_left))))`
    //   🔴 **为什么"每 tick 重算"而不是"起音时算一次"**：
    //      ⚠️ 起音时算一次 ⇒ 步长**固定** ⇒ ⚠️ 一旦引擎的实际推进节奏
    //         （⭐ 一拍扫一个轴）与 tick 节奏不同步 ⇒ 🔴 **到不了终点** ⇒ 尾音又变短 ✅
    //      ⭐ 逐拍重算 ⇒ `ticks_left` 变小时步长**自动变大** ⇒ ⭐ **自校正** ✅
    //   🔴 **为什么取 `ceil`（⭐ 宁可早到，⛔ 不可晚到）**：
    //      · ⭐ **晚到** ⇒ 🔴 松手时力度还没到终点 ⇒ **尾音短**（⭐ 本功能要修的正是它）
    //      · ⭐ **早到** ⇒ ⚠️ 只是手势被压缩到前半段（⭐ 且引擎每拍做**上钳位** ⇒
    //         ⛔ 不冲过终点）⇒ ⭐ **代价可接受** ✅
    //      ⇒ ⭐ `ceil(|diff| / 2^f)`（⭐ `2^f <= ticks_left`）⇒ 步长 ∈
    //         `[|diff|/ticks_left, 2|diff|/ticks_left]` ⇒ ⭐ **最迟也在跨度内到达** ✅
    //      📌 极端情形也自洽：⭐ `ticks_left = 1` ⇒ `f = 0` ⇒ ⭐ 步长 = 整段差
    //         ⇒ **最后一拍一步到位**（⭐ 绝不"到不了"）✅
    //  ⭐⭐ 2026-09-30：⭐ **改成"先分段、段内二分"**（⭐ 与原 `for` 循环**逐值等价**）
    //   🔴 **为什么改**：⭐ 原来的 `for` 循环（⭐ `if (v >= (1<<k)) flog2 = k`）
    //      被综合成 **`TICK_W`(20) 级串联的优先链** ⇒ ⭐ 它就是关键路径里
    //      那串 `u_looper/n232_s4x` 节点（⭐ 见 `impl/pnr/Gowin2026.timing_paths`）✅
    //   ⭐ 新结构：⭐ 5 个 4 bit 段 OR **并行**求"最高非零段"，⭐ 再在段内二分最高位
    //      ⇒ ⭐ 深度 ≈ 6 级（⭐ 结果**逐值相同**：⭐ `v=0 ⇒ 0`）✅
    //   ⚠️ 下标按 `TICK_W = 20` 写死（⭐ 本工程 `top.v` 与 `tb_looper` 都用默认 20；
    //      ⭐ 与上方 `PARAM_OK` 自检同一条纪律 —— ⭐ 改 `TICK_W` 必须同步改这里）✅
    function [4:0] flog2;
        input [TICK_W-1:0] v;
        reg s4, s3, s2, s1, s0;
        reg [1:0] e4, e3, e2, e1, e0;
        begin
            s4 = |v[19:16]; s3 = |v[15:12]; s2 = |v[11:8];
            s1 = |v[7:4];   s0 = |v[3:0];
            e4 = v[19] ? 2'd3 : v[18] ? 2'd2 : v[17] ? 2'd1 : 2'd0;
            e3 = v[15] ? 2'd3 : v[14] ? 2'd2 : v[13] ? 2'd1 : 2'd0;
            e2 = v[11] ? 2'd3 : v[10] ? 2'd2 : v[9]  ? 2'd1 : 2'd0;
            e1 = v[7]  ? 2'd3 : v[6]  ? 2'd2 : v[5]  ? 2'd1 : 2'd0;
            e0 = v[3]  ? 2'd3 : v[2]  ? 2'd2 : v[1]  ? 2'd1 : 2'd0;
            flog2 = (s4 ? 5'd16 : s3 ? 5'd12 : s2 ? 5'd8 : s1 ? 5'd4 : 5'd0)
                  + {3'd0, (s4 ? e4 : s3 ? e3 : s2 ? e2 : s1 ? e1 : e0)};
        end
    endfunction

    // ══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-09-30：⭐ **插值步长引擎改为【三级流水】**（⭐ 收敛时序）
    //
    //  🔴 **问题（⭐ PnR 实测原文，⛔ 不是推测）** ——
    //     `impl/pnr/Gowin2026_tr_content.html`（⭐ 同一份也抄进
    //     `sim/evidence/gowin_m0_timing.txt`）报：
    //       · `Numbers of Setup Violated Endpoints | 1702`
    //       · `Actual Fmax = 43.659 MHz`（⭐ 约束 50 MHz）、`Logic Level = 38`
    //       · 最差路径（⭐ `Path Slacks Table` 第 1 行原文）：
    //           `From g_sound.u_looper/ramp_sc_0_s1/Q
    //            To   g_sound.u_looper/play_upd_inc_o_27_s0/D
    //            Path Slack -2.905  Data Delay 22.852`
    //     ⇒ ⭐ **38 级组合逻辑**（⭐ 历史最好 12 级 ⇒ `55.349 MHz`，⭐ 见
    //        `git show 7863b40:sim/evidence/gowin_m0_timing.txt`）✅
    //
    //  ⭐ **根因**：⭐ 整条链挤在**一拍**里 ——
    //     `取操作数 → f = flog2(left) → 2^f → +2^f-1 → >>f → max(1)
    //      → ± step → 与终点比较 → 吸附`
    //     ⭐ 其中 `flog2` 是 20 级串联优先链，⭐ 另有**两个变长移位器** ✅
    //
    //  ⭐ **修法**：⭐ 在三个天然断点插寄存器 ⇒ ⭐ 组合深度各约 1/3：
    //     · ⭐ 阶段 A：⭐ 取操作数 + `left` + `f` + `2^f` + `|diff|` + 方向
    //     · ⭐ 阶段 B：⭐ `+2^f-1` → `>>f` → `max(1)`  ⇒ `sinc` / `svel`
    //     · ⭐ 阶段 C：⭐ `cur ± step` → 与终点比较 → **吸附** → 输出 + 写回
    //
    //  ⭐ **每级 ns 预算（⭐ 50 MHz ⇒ 20 ns/拍）**：
    //     ⭐ `impl/pnr/Gowin2026.timing_paths` 的节点到达时间把原路径切成
    //        `3.571→9.800`（**6.2 ns**：⭐ 取数 + `flog2` + `2^f`）
    //        `9.800→17.416`（**7.6 ns**：⭐ 变长右移 + `max(1)`）
    //        `17.416→22.838`（**5.4 ns**：⭐ 加减 + 与终点比较 + 吸附）
    //     ⇒ ⭐ 每级再加 `Tco+时钟网 ≈ 3.6 ns` 与 `布线+建立 ≈ 3.6 ns`
    //        ⇒ ⭐ `13.4 / 14.8 / 12.6 ns` ⇒ ⭐ **三级都进 20 ns** ✅
    //     📌 不拆时 `6.2+7.6+5.4 = 19.2 ns` 逻辑 + `3.6+3.6` 固定开销
    //        = `26.4 ns` ⇒ ⭐ 正是实测 `22.852 ns` 的量级 ✅
    //
    //  ⭐ **吞吐【不变】**（⭐ 关键）：⭐ 阶段 A **每拍推进一个轴**
    //     （⭐ `ramp_sc` 每拍 +1）⇒ ⭐ 仍 **16 拍扫完 16 轴**，
    //     ⭐ 与原实现**逐拍相同** ⇒ ⭐ 插值更新频率**不变** ✅
    //     （⭐ 所以 `tb_looper` 的 `upd_n` / `distinct` 判据不受影响）
    //  ⭐ **行为【不变】**：
    //     · ⭐ 阶段 A 读的操作数与**原实现同一拍**读的是同一批寄存器值 ✅
    //     · ⭐ 写回晚 2 拍 ⇒ ⚠️ 必须挡掉"这 2 拍里事件装载分支写过同一个轴"
    //       ⇒ ⭐ `pa_hit` / `pb_hit`（⭐ 原实现靠"事件分支在 `always` 里更靠后"
    //          取胜；⭐ 现在跨拍了，⭐ 必须显式挡）✅
    //     · ⭐ `play_upd_*` 晚 2 拍 ⇒ ⭐ 仍在**同一个 tick 内**
    //       （⭐ tick ≥ 12 拍，⭐ 硬件上 ~26000 拍）✅
    // ══════════════════════════════════════════════════════════════════════

    //  ── ⭐ 阶段 A（组合）：⭐ 取操作数 + `f` + `2^f` ────────────────────────────
    wire [PHASE_W-1:0] ramp_inc_c = ramp_inc[ramp_sc];
    wire [VEL_W-1:0]   ramp_vel_c = ramp_vel[ramp_sc];
    wire [PHASE_W-1:0] rtgt_inc_c = rtgt_inc[ramp_sc];
    wire [VEL_W-1:0]   rtgt_vel_c = rtgt_vel[ramp_sc];
    wire [TICK_W-1:0]  rend_tick_c= rend_tick[ramp_sc];
    //  ⭐ 还剩几个 tick 走到终点（⭐ `0` ⇒ 本拍就收工，⭐ 见阶段 C 的吸附分支）
    wire [TICK_W-1:0]  ramp_left  = (rend_tick_c > play_tick_r)
                                  ? (rend_tick_c - play_tick_r)
                                  : {TICK_W{1'b0}};
    wire [4:0]         ramp_f     = flog2(ramp_left);       // ⭐ f = floor(log2(left))
    wire [TICK_W-1:0]  ramp_pw    = {{(TICK_W-5){1'b0}}, 5'd1} << ramp_f;   // ⭐ 2^f
    //  ⭐ 差值（⭐ 用【幅度】而不是有符号数 ⇒ ⭐ 加减方向由"谁大"决定，⛔ 不碰符号位 ✅）
    wire               ramp_up    = (rtgt_inc_c > ramp_inc_c);
    wire               ramp_dn    = (rtgt_inc_c < ramp_inc_c);
    wire [PHASE_W:0]   ramp_dinc  = ramp_up ? ({1'b0, rtgt_inc_c} - {1'b0, ramp_inc_c})
                                            : ({1'b0, ramp_inc_c} - {1'b0, rtgt_inc_c});
    wire               vel_up     = (rtgt_vel_c > ramp_vel_c);
    wire               vel_dn     = (rtgt_vel_c < ramp_vel_c);
    wire [VEL_W:0]     ramp_dvel  = vel_up ? ({1'b0, rtgt_vel_c} - {1'b0, ramp_vel_c})
                                           : ({1'b0, ramp_vel_c} - {1'b0, rtgt_vel_c});
    //  ⭐ 本轴该不该吐（⭐ 用**本拍**的 `ramp_mask`，⭐ 与原实现一致）
    wire               ramp_msk_c = ramp_mask[ramp_sc];
    //  ⭐ 走到终点 tick ⇒ ⭐ 本轮收工（⭐ 用**本拍**的 `play_tick_r` / `rend_tick`）
    wire               ramp_snap_c= (play_tick_r >= rend_tick_c);

    //  ── ⭐ 流水线寄存器（⭐ 后缀 `a` = 阶段 A→B、`b` = 阶段 B→C）──────────────
    reg [3:0]         pa_ax;
    reg [PHASE_W-1:0] pa_inc, pa_tgt;
    reg [VEL_W-1:0]   pa_vel, pa_tv;
    reg [PHASE_W:0]   pa_dinc;
    reg [VEL_W:0]     pa_dvel;
    reg [TICK_W-1:0]  pa_pw;
    reg [4:0]         pa_f;
    reg               pa_up, pa_dn, pa_vup, pa_dvn;
    reg               pa_msk, pa_snap, pa_hit, pa_last, pa_v;
    reg [3:0]         pb_ax;
    reg [PHASE_W-1:0] pb_inc, pb_tgt, pb_sinc;
    reg [VEL_W-1:0]   pb_vel, pb_tv, pb_svel;
    reg               pb_up, pb_dn, pb_vup, pb_dvn;
    reg               pb_msk, pb_snap, pb_hit, pb_last, pb_v;

    //  ── ⭐ 阶段 B（组合）：⭐ `ceil(|diff| / 2^f)`，⭐ `|diff| != 0` 时至少走 1 格 ──
    //     ⚠️ 中间量多一位（`+2^f-1` 可能进位）⇒ ⭐ `PHASE_W+1` / `VEL_W+1` ✅
    wire [PHASE_W:0]   pb_qinc  = (pa_dinc + pa_pw - 1'b1) >> pa_f;
    wire [VEL_W:0]     pb_qvel  = (pa_dvel + pa_pw - 1'b1) >> pa_f;
    wire [PHASE_W-1:0] pb_sinc_w = (pa_dinc[PHASE_W-1:0] == {PHASE_W{1'b0}})
                                 ? {PHASE_W{1'b0}}
                                 : ((pb_qinc[PHASE_W-1:0] == {PHASE_W{1'b0}})
                                       ? {{(PHASE_W-1){1'b0}}, 1'b1} : pb_qinc[PHASE_W-1:0]);
    wire [VEL_W-1:0]   pb_svel_w = (pa_dvel[VEL_W-1:0] == {VEL_W{1'b0}})
                                 ? {VEL_W{1'b0}}
                                 : ((pb_qvel[VEL_W-1:0] == {VEL_W{1'b0}})
                                       ? {{(VEL_W-1){1'b0}}, 1'b1} : pb_qvel[VEL_W-1:0]);

    //  ── ⭐ 阶段 C（组合）：⭐ `cur ± step` ⇒ 到终点【吸附】⛔ 不冲过 ─────────────
    //     ⚠️ `step <= |diff|` ⇒ ⭐ `cur ± step` **不会越过终点、也不会溢出**（⭐ 无符号安全 ✅）
    wire [PHASE_W-1:0] pc_inc_w =
          pb_up ? ((pb_inc + pb_sinc >= pb_tgt) ? pb_tgt : (pb_inc + pb_sinc))
        : pb_dn ? ((pb_inc - pb_sinc <= pb_tgt) ? pb_tgt : (pb_inc - pb_sinc))
        :         pb_inc;
    wire [VEL_W-1:0]   pc_vel_w =
          pb_vup ? ((pb_vel + pb_svel >= pb_tv) ? pb_tv : (pb_vel + pb_svel))
        : pb_dvn ? ((pb_vel - pb_svel <= pb_tv) ? pb_tv : (pb_vel - pb_svel))
        :          pb_vel;

    // ⭐ 事件类型编码（⭐ 与 `note_manager.note_kind_i` 一致）
    //   ⚠️ **已在文件上方（`close_scan_r` 之后）声明** —— ⭐ 那里是 `rec_inc_w` 的需要 ✅

    // ── ⭐⭐ 重放读侧：⭐ **必须【同步读】**（⭐ 否则 BSRAM 推不出来）────────────
    //   🔴 **实测（⭐ 2026-09-29，⭐ 第一次 PnR 就抓到）**：
    //      ⭐ 原来写的是**异步读**（`wire e_word = mem[rd_ptr_r];`）⇒
    //      🔴 Gowin 报 `ERROR (IF0008): The number(135168) of DFF used to infer
    //         "mem" exceeds the resource limit(60780)` ⇒ ⭐ **整个综合失败** ⚠️
    //      ⚠️ 而**仿真 100% 全绿**（⭐ `tb_looper` 9 条判据全过）——
    //      ⭐ 这正是 `K-91` 那一类：⭐ **"仿真过了" ⛔ ≠ "能综合"** ✅
    //   ⭐ 修法：⭐ **把读出的字打一拍**（⭐ Gowin BSRAM 的输出**必须寄存**）✅
    //      ⚠️ 代价：⭐ 每吐一条事件要 **2 拍**（⭐ 1 拍推进指针 ＋ 1 拍等数据回来）
    //         ⇒ ⭐ 对 PPQN tick（⭐ 120 BPM 时 **61440 拍**）**完全无影响** ✅
    //
    //  ⭐⭐⭐⭐ 2026-10-11（⭐ **录制回传**）：⭐ **导出读口复用【同一个】读口** ✅
    //
    //  🔴🔴 **为什么必须复用而⛔ 不能"再加一个读口"**：
    //     ⭐ 上面那条教训说明 `mem` **必须被推成 BSRAM** ✅
    //     ⚠️ 而 BSRAM 的**物理结构**是 **1 写口 ＋ 1 读口** ⇒
    //        🔴 再加一条 `always @(posedge clk) dump <= mem[dump_addr]`
    //        ⇒ ⭐ 综合器**推不出 BSRAM** ⇒ 🔴 **退回 DFF 阵列** ⇒
    //        ⭐ 就是上面那个 `135168 > 60780` 的 **综合失败** ✅
    //     ✅ **所以：⭐ 一个【地址 mux】把读口借给导出** —— ⭐ 结构上**只有一个读口** ✅
    //
    //  📌 ⭐ **优先级**：⭐ `dump_en_i` 高 ⇒ ⭐ **导出期间读口归导出** ✅
    //     ⚠️ 因此**导出时必须停止放音**（⭐ 由导出 FSM 保证：⭐ 只在层空闲时导 ✅）
    //     —— ⭐ 这不是限制，⭐ 而是**语义上就该如此**（⭐ 导出的是"已录下的东西" ✅）
    //  ⚠️ **Z-safe 解码**（⭐ 与 `oscillator_bank.voice_phase_rst_i` / `drum_gen.pos_reset_i`
    //     ⭐ 同一套口径 ✅）：⭐ 老例化**不接** `dump_en_i` ⇒ 该位是 `z`
    //     ⇒ ⚠️ 用普通 `if` 会得到 `x` ⇒ 🔴 判据真假不定 ✅
    wire             dump_en_w    = (dump_en_i === 1'b1);
    //  ⭐⭐⭐⭐ 2026-10-13（⭐ **`P0-25` fix 4**）：⭐ **给"读地址"加回一个比较器** ✅
    //
    //  🔴 **问题**：⭐ `u_looper` 的 BSRAM 读路径是**短路径 hold** ✅
    //     ⭐ 路径：⭐ `rd_ptr_r` → ⭐ `mem_rd_addr`（⭐ **只是一个 mux** ✅）→ ⭐ BSRAM 地址 ✅
    //     ⭐ 基线 slack 只有 **0.137 ns**、⭐ 门限 **0.05 ns** ⇒ ⚠️ **余量 0.087 ns** ✅
    //     ⭐ 实测：⭐ 加了 1 个 FF（⭐ `eu_active_r` ✅）就掉到 **0.032 ns** ⇒ 🔴 **门红** ✅
    //
    //  ⭐ 本项目 `sim/gowin_build.ps1` 的 `P0-25` 注释里写着**修法方向** ✅（⭐ `:417-419` ✅）：
    //     *"⭐ 不要在 `rd_ptr_r` → RAM 读地址之间**删**逻辑（⭐ 例如砍掉比较器 ✅）
    //        —— 同理会把路径变短；⭐ **要动只能【加】**"* ✅
    //  ⇒ ⭐ **本改动就是"加回一个比较器"** ✅
    //
    //  ✅ **为什么是【功能等价】的**（⭐ 关键 ✅）：
    //     ⭐ `e_ready`（⭐ 见下方 ✅）**本来就要求** ⭐ `rd_ptr_r < cnt_r` ✅
    //     ⇒ ⭐ `rd_ptr_r >= cnt_r` 时**根本不会用到读出来的数据** ✅
    //     ⇒ ⭐ 所以 else 分支取 **0** 是**安全的**（⭐ 数据被丢弃 ✅）
    //     📌 ⭐ 即：⭐ 行为**逐位不变** ✅，⭐ 只是**多了一个比较器** ⇒ ⭐ 路径**变长** ✅
    //
    //  ⚠️ ⭐ **为什么⛔ 不加寄存器**：⭐ `looper` 的读是**1 拍**的（⭐ `e_word_r <= mem[...]` ✅）
    //     ⇒ ⭐ 加流水级会**破坏读契约** 🔴 ⇒ ⭐ 这正是文档说"**无 RTL 解**"的那条路 ✅
    //
    //  📌 ⭐ **已实测否定的路线**（⭐ 2026-10-13 ✅）：
    //     ⭐ `set_option -correct_hold_violation 1` ⇒ ⭐ **slack 一点没变**（⭐ 0.051 → 0.051 ✅）
    //     ⭐ `set_option -place_option 2`（⭐ 时序优先 ✅）⇒ ⭐ 反而**更差**（⭐ 0.041 ✅）
    wire [CNT_W-1:0] mem_rd_addr  = dump_en_w ? dump_addr_i
                                  : (rd_ptr_r < cnt_r) ? rd_ptr_r : {CNT_W{1'b0}};
    reg  [EW-1:0]    e_word_r;
    always @(posedge clk_i) e_word_r <= mem[mem_rd_addr];
    //  ⭐ 导出数据 = **同一个读口**的输出（⭐ 见上方"为什么必须复用"✅）
    //
    //  ⭐⭐⭐⭐ 2026-10-11：⭐ **导出给的是【线上 64 位格式】，⛔ 不是内部 68 位** ✅
    //
    //  ⭐ **为什么在这里重打包（⭐ 而不是让导出 FSM 自己拼）**：
    //     ⭐ 字段布局（⭐ `O_VEL`/`O_INC`/`O_AXIS`/`O_KIND`/`O_TICK`/`O_TBR` ✅）
    //        是**本模块的私有知识** ⇒ ⭐ 让导出 FSM 再抄一份 ⇒ 🔴 **两个来源**
    //        ⇒ ⚠️ 将来改布局 ⇒ ⭐ **静默拼错**（⭐ 那正是本项目最怕的一类）✅
    //     ✅ **单一来源**：⭐ 布局在本模块 ⇒ ⭐ **重打包也在本模块** ✅
    //
    //  ⭐ **线上格式（⭐ 与 `evt_uart_rx`/`evt_buf` 的 9 字节帧**逐位一致 ✅）**：
    //     ⭐ `tick[63:44]`（20）· ⭐ `inc[43:23]`（**21**）· ⭐ `axis[22:19]`（4）·
    //     ⭐ `vel[18:11]`（8）· ⭐ `kind[10:9]`（2）· ⭐ `timbre[8:7]`（2）· ⭐ `[6:0]` 保留 ✅
    // 2026-10-13 原说法“音符零扩展/直接截低 21 位”错误：
    // 顶层回灌音符左移 10，因此导出必须反向转换单位。
    // dump_clip_o 表示低 10 位量化损失或越界，不再表示正常音高高位被截。
    // 速度事件 kind=2 不使用音符转换；不能混用两种量纲。
    wire [19:0] dw_tick = e_word_r[O_TICK +: TICK_W];
    wire [1:0]  dw_kind = e_word_r[O_KIND +: KIND_W];
    wire [3:0]  dw_axis = e_word_r[O_AXIS +: AXIS_W];
    wire [31:0] dw_inc  = e_word_r[O_INC  +: PHASE_W];
    wire [7:0]  dw_vel  = e_word_r[O_VEL  +: VEL_W];
    wire [1:0]  dw_tbr  = e_word_r[O_TBR  +: TIMBRE_W];

    // 2026-10-13 correction: note increments are stored per audio sample;
    // the score wire format is per 50MHz clock (top scales notes by 1024).
    // Floor quantization loses at most 1023 phase units (~0.01164Hz).
    // Tempo kind=2 keeps its clock-domain increment. Report any precision loss.
    wire [20:0] dw_wire_inc = (dw_kind == 2'd2) ? dw_inc[20:0]
                              : (dw_inc[31] ? 21'h1fffff : dw_inc[30:10]);
    assign dump_data_o = {dw_tick, dw_wire_inc, dw_axis, dw_vel, dw_kind, dw_tbr, 7'b0};
    assign dump_clip_o = (dw_kind == 2'd2) ? (|dw_inc[31:21])
                                          : (dw_inc[31] | (|dw_inc[9:0]));

    // ══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-09-29 新增：⭐ **端点侧表 `ep_mem`**（⭐ "起点→终点"插值的【必需】信息）
    //
    //  🔴 **为什么需要一张侧表**（⭐ 这是本功能最关键的结构性决定）：
    //     ⭐ 插值必须**同时**知道：⭐ 起点音高/力度 ＋ 终点音高/力度 ＋ tick 跨度 ✅
    //     ⚠️ 而事件字里：⭐ `note_on` 带**起点**、`note_off` 带**终点**（⭐ 设计如此）
    //        ⇒ 🔴 **回放到 `note_on` 那一刻，终点还躺在【后面】的 `note_off` 里** ——
    //           ⭐ 而插值必须**从 `note_on` 之后就开始**（⭐ 尾音取决于整条轨迹 ✅）
    //
    //  ⭐ **修法（⭐ ⛔ 不扩事件字宽、⛔ 不做回看扫描）**：
    //     ⭐ 把终点**另存一份**，按 **`note_on` 的地址**索引 ✅
    //     · ⭐ **录制时**：`note_on` 落盘 ⇒ 该地址写"无效"（⭐ 兜底，防陈旧数据）；
    //        `note_off` 落盘（⭐ 或停录补发）⇒ **把终点写回 `note_on` 的地址** ✅
    //       📌 两个地址分属**两块不同的 RAM** ⇒ ⚠️ **不争写口**（⭐ 这正是它能"同拍写完"的原因；
    //          ⚠️ 若改成"扩宽 `mem` 再回写 `note_on`" ⇒ 🔴 **单写口必然冲突** ⇒
    //          要么丢事件、要么多一个补写状态机 ✅）
    //     · ⭐ **回放时**：`ep_mem[rd_ptr_r]` 与 `mem[rd_ptr_r]` **同地址、同拍寄存**
    //        ⇒ ⭐ `ep_word_r` 与 `e_word_r` **天然对齐** ⇒ ⭐ **零额外延迟** ✅
    //  📌 **信息完全等价**：⭐ 与"`note_off` 事件字里的终点"是**同一份数据**，
    //     ⭐ 只是多了一个"**按 `note_on` 地址取**"的入口 ⇒ ⭐ 回放侧**不需要回看** ✅
    // ══════════════════════════════════════════════════════════════════════
    localparam integer EP_W   = 1 + TICK_W + VEL_W + PHASE_W;
    //  ⚠️ **偏移必须与写侧的拼接顺序 `{valid, tick, vel, inc}` 逐位对齐**
    //     （⭐ Verilog 拼接：**最左 = 最高位**）——
    //     🔴 第一版按"低位在前"写偏移 ⇒ ⭐ 读出来的 `valid` 是 `inc` 的最低位
    //        ⇒ 🔴 **插值永远不启动**（⭐ 而事件流一切正常，⭐ 极难定位 ✅）
    localparam integer O_EPIN = 0;                   // ⭐ 终点音高（⭐ 拼接的最右）
    localparam integer O_EPVE = O_EPIN + PHASE_W;    // ⭐ 终点力度
    localparam integer O_EPT  = O_EPVE + VEL_W;      // ⭐ 终点 tick（⭐ 插值的跨度端点）
    localparam integer O_EPV  = O_EPT  + TICK_W;     // ⭐ 1 = 本 `note_on` 有终点（⭐ 最高位）
    reg [EP_W-1:0] ep_mem [0:EVT_MAX-1];
    reg [EP_W-1:0] ep_word_r;
    always @(posedge clk_i) ep_word_r <= ep_mem[rd_ptr_r];

    // ══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-09-29 新增：⭐ **端点侧表的【独立写口】**（⭐ BSRAM 推断的硬要求）
    //
    //  🔴 **为什么必须单独写一个写口**（⭐ 实测，⛔ 不是推测）：
    //     第一版把 `ep_mem[...] <= ...` **直接写在主 FSM 的三个地方** ⇒
    //     🔴 Gowin 综合**整个失败**：
    //        `ERROR (IF0008) : The number(124928) of DFF used to infer "ep_mem"
    //         exceeds the resource limit(60780)`
    //        （⭐ `124928 = 2048 × 61` ⇒ ⭐ **整张表落成 DFF**，⭐ 一个 BSRAM 都没用上）
    //     ⚠️ 而**同一个 `always` 块里的 `mem`**（⭐ 68 位、⭐ 同样 2048 深）**推得出来**
    //        （⭐ 8 个 BSRAM）⇒ ⭐ 所以根因 ⛔ **不是位宽**、⛔ **不是"异步读"**
    //        （⭐ 两表的读都是同步的、写法逐字相同）⇒ ⭐ **是写地址表达式的【个数】** ✅
    //     📌 **实测对照（⭐ 精简工程逐项 `run syn`，⭐ 每次约 10 s）**：
    //        · 写地址 **3 个不同表达式** ⇒ 🔴 `IF0008`（⭐ 就是原写法）
    //        · 写地址 **2 个不同表达式** ⇒ ✅ 推得出（⭐ 两两组合都试过）
    //        · 写地址 **1 个表达式**       ⇒ ✅ 推得出（⭐ `mem` 正是这一类 ✅）
    //     ⇒ ⭐ 修法：⭐ **把三个写入点的地址【组合预选】成一根 `ep_wa_w`** ⇒
    //        RAM 只看见**一个地址表达式** ⇒ ⭐ 与 `mem` 完全同构 ✅
    //
    //  ⚠️ **为什么用组合（⛔ 不寄存）**：
    //     ⭐ 寄存 ⇒ 落盘**晚一拍** ⇒ ⚠️ `ST_CLOSE` 最后一拍写的那条，
    //     ⭐ 下一拍回放就可能读到同一地址 ⇒ 🔴 **读到旧值（⭐ 插值不启动）**
    //     ⇒ ⭐ **行为会变**（⭐ 本任务要求行为逐位不变）⇒ ⛔ 必须同拍落盘 ✅
    //     （⭐ 且 `ram_c` 对照已证：⭐ 组合预选的地址**照样推得出 BSRAM** ✅）
    //
    //  📌 **等价性**：⭐ 三个写入点的**条件与数据与原实现逐条相同**，
    //     只是把"地址/数据"从 FSM 里搬到组合逻辑 ⇒ ⭐ 时序与语义**完全不变** ✅
    // ══════════════════════════════════════════════════════════════════════
    //  ══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-10-16：⭐ **`clear_req_i` 进 FSM 前先打一拍**（⭐ 修 setup 违例 ✅）
    //
    //  🔴 **违例现场**（⭐ `impl/pnr/Gowin2026.timing_paths` 第 1 条 ✅）：
    //     · ⭐ 起点 `u_ctrl_key_map/loop_clear_req_o_s0/Q`
    //     · 🔴 终点 `g_sound.u_looper/ep_mem_ep_mem_0_4_s/ADA[8]`（⭐ **BSRAM 写地址** ✅）
    //     · 🔴 slack = **-1.009 ns**（⭐ arrival 21.614 / required 20.604 ✅）
    //     · ⭐ 数据路径 **17.018 ns**、⭐ 逻辑级数 **7** ✅
    //     · 🔴 同一条路径**扇出 19 个端点**（⭐ `ep_mem` 的 `ADA` × 12、
    //        ⭐ `mem` 的 `CEA` × 2、⭐ `vel_max_r` 的 `CE` × 1、⭐ 其余同锥 ✅）
    //        ⇒ ⭐ clk_sys 的 TNS **-11.524** 里它一条就占 **-9.7** ✅
    //
    //  ⭐ **判性质 = 真长链、⛔ 不是布局噪声**（⭐ 判据 = **逻辑级数** ✅）：
    //     ⭐ RTL 上从 `clear_req_i[0]` 到 BSRAM 写口就是这一条：
    //        `clear_req_i[0]` → `br_leave_w`（⭐ `:742` ✅）
    //        → `br_clear_w`（⭐ `:744` ✅）→ `br_recst_w`/`br_close_w`（⭐ `:761`/`:763` ✅）
    //        → `ep_w_off_w`/`ep_w_on_w`/`ep_w_cls_w`（⭐ `:793`/`:797`/`:800` ✅）
    //        → `ep_we_w`/`ep_wa_w`（⭐ `:806`/`:807` ✅）→ `ep_mem` 写口 ✅
    //     ⭐ 实测级数 = **7**（⭐ `cnt_r_15_s5 → rec_bar_tick_r_19_s3 → n7347_s3
    //        → n14630_s3 → ep_wd_w_59_s4 → ep_wa_w_5_s3 → ep_wa_w_5_s2` ✅）
    //     ⭐ **> 6 级 ⇒ 真长链**（⭐ 布局噪声典型 ≤ 3~4 级 ✅）
    //     📌 ⭐ 其中**前 2 级（4.253 ns）在 `top.v`**（⭐ 就是
    //        `cmd_loop_clear_req = cc | km` 与 `& ~rd_lock` 那一小段 ✅）
    //        ⇒ ⭐ 光靠重跑布局**救不回来**（⭐ 结构性 ✅）
    //
    //  ✅ **修法（⭐ 二选一里挑【最小改动、最低风险】的那条 ✅）**：
    //     ⭐ 在**本模块入口**把 `clear_req_i` 打一拍 ⇒ ⭐ 长链**从这一拍重新起算** ✅
    //     · ⭐ 砍掉：⭐ `ctrl_key_map` → `top.v` 门控 → 本模块入口那 **4.253 ns**
    //        （⭐ 含跨模块长走线 ✅）
    //     · ⭐ 新路径 = ⭐ 本拍 Q → `br_leave_w` → … → BSRAM（⭐ 约 12.8 ns ✅）
    //        ⇒ ⭐ 预估 slack 由 **-1.009** 回到 **+3 ~ +4 ns** ✅
    //     📌 ⭐ **为什么不改 `top.v`**：⭐ 本轮 `top.v` 被多个 agent 并发改
    //        （⭐ 另有 bit6 引导路由在动 ✅）⇒ ⭐ 改动落在本文件**零冲突** ✅
    //        📌 ⭐ 而且落在**本模块入口**⇒ ⭐ `calib_cmd`（串口 `'C'`）那条**一起修好** ✅
    //     📌 ⭐ **为什么不拆 `ep_mem` 写口那条组合链**（⭐ 备选 (b) ✅）：
    //        ⭐ 那条三选一 mux 是**BSRAM 只认一个地址表达式**的硬要求
    //        （⭐ 见 `:708-735` 的长注释 ✅）⇒ 🔴 一拆 ⇒ ⭐ 综合**推不出 BSRAM**、
    //        ⭐ 退回 DFF 阵列 ⇒ ⭐ `IF0008`（⭐ 124928 > 60780 ✅）⇒ 🔴 **整个 PnR 失败** ✅
    //        ⇒ ⭐ 本文件里"拆链"这条路**是死的** ✅
    //
    //  ⚠️ **语义代价（⭐ 逐条核对过 ✅）**：
    //     · ⭐ `clear_req_i` 是**单拍脉冲**（⭐ `ctrl_key_map:226` 长按阈值那一刻置 1、
    //        ⭐ 下一拍 `:178` 默认清零 ✅；⭐ `calib_cmd:558` 同构 ✅）
    //        ⇒ ⭐ 打一拍**只把"清空"整体推后 20 ns**（⭐ 对 2 s 长按手感**零影响** ✅）
    //     · 🔴 **⛔ 不会"清两次"**：⭐ 本拍是**寄存器**、⛔ 不是电平展宽
    //        ⇒ ⭐ 一个脉冲进 ⇒ **恰好一个脉冲出** ✅
    //        （⭐ 判据 = `tb/w3c/tb_looper.sv` 的 `CLEARPIPE` 段 ✅）
    //     · ⭐ `:1113` 的 `leave_to_r <= clear_req_i[0] ? …` 与 `:742`/`:744`
    //        **必须同源** ⇒ ⭐ 三处**一起换成** `clear_req_w` ✅
    //        （🔴 否则 `br_leave_w` 用新值、`leave_to_r` 用旧值 ⇒ ⭐ 语义漂移 ✅）
    //     · ⭐ 复位用 `rst_n_i` 同步清零（⭐ 与 `:903` 的主 FSM 同口径 ✅）
    //     · ⭐ `z` 安全（⭐ 与 `:611` 的 `dump_en_w` 同套路 ✅）：⭐ 老例化不接
    //        `clear_req_i` ⇒ ⭐ 该位是 `z` ⇒ ⭐ `=== 1'b1` 解码成 **0**（⭐ 而非 `x` ✅）
    //  ══════════════════════════════════════════════════════════════════════
    reg  clear_pipe_r;
    always @(posedge clk_i) begin
        if (!rst_n_i) clear_pipe_r <= 1'b0;
        else          clear_pipe_r <= (clear_req_i[0] === 1'b1);
    end
    wire clear_req_w = clear_pipe_r;      // ⭐ 唯一消费者 = 下面三条（⭐ 同源 ✅）

    //  ── ⭐ FSM 分支译码（⭐ 与下方 `always` 块的优先级链【逐条同式】）──────────
    //   🔴 **为什么抽出来**：⭐ 写口在 FSM **之外** ⇒ ⚠️ 它必须知道"本拍走哪条分支"
    //      ⇒ ⭐ 把这套优先级**定义一次、两处共用** ⇒ ⛔ 不会漂移 ✅
    //   📌 `br_*_w` 与 FSM 里原来的条件**代数等价**：⭐ 链上前面都为假时
    //      `br_recst_w ≡ (state == ST_REC)`、`br_close_w ≡ (state == ST_CLOSE)`
    //      ⇒ ⭐ 逐位行为不变 ✅
    wire br_leave_w = ((clear_req_w) || (rec_req_i[0] && (state != ST_REC)))
                      && (state == ST_HOLD) && (play_active_r != 16'd0);
    wire br_clear_w = ~br_leave_w && clear_req_w;
    //  ⭐⭐ 2026-09-30（`T41` ①）：⭐ **"待起录"等到小节起点 ⇒ 真起录**
    //   ⚠️ 排在 `br_rec_w` **之前** ⇒ ⭐ 同一个 `bar_start` 拍上不会再被 `rec_req` 抢走 ✅
    wire br_recpend_w = ~br_leave_w && ~br_clear_w && (state == ST_RECPEND)
                        && bar_start_i && transport_i;
    //  ⭐⭐ 2026-09-30（`T41` ①）：⭐ **"待起录"期间再按一次 `R` ⇒ 取消** ✅
    //   🔴 **为什么必须处理**（⭐ 有代码依据）：⭐ `top.v:2959` 的
    //      `stop_req_i = cmd_loop_rec_req & loop_rec_on_r`
    //      ⇒ ⚠️ 用户在"待起录"窗口里再按一次 `R` ⇒ 到这里的**是 `stop_req`** ✅
    //      🔴 若不处理 ⇒ `top.v` 的 `loop_rec_on_r` 与 looper 的实际状态**反相**
    //         ⇒ ⭐ 之后每一次 `R` 都发**错的命令**（⭐ 想停发 `rec_req`、想录发 `stop_req`）
    //         ⇒ 🔴 用户看到的是"**按 R 没反应 / 要按两下**"（⭐ 与 `T41` 无关的新毛病）✅
    //   ⭐ 语义：⭐ 取消 ⇒ 有旧录音就回 `ST_HOLD`（⛔ 不清），⭐ 否则回 `ST_IDLE` ✅
    wire br_reccancel_w = ~br_leave_w && ~br_clear_w && ~br_recpend_w
                          && (state == ST_RECPEND) && stop_req_i[0];
    wire br_rec_w   = ~br_leave_w && ~br_clear_w && ~br_recpend_w && ~br_reccancel_w
                      && rec_req_i[0] && (state != ST_REC) && (state != ST_RECPEND);
    wire br_recst_w = ~br_leave_w && ~br_clear_w && ~br_recpend_w && ~br_reccancel_w
                      && ~br_rec_w && (state == ST_REC);
    wire br_close_w = ~br_leave_w && ~br_clear_w && ~br_recpend_w && ~br_reccancel_w
                      && ~br_rec_w && ~br_recst_w && (state == ST_CLOSE);

    //  ── ⭐⭐ 2026-09-30：⭐ **停录量化（`T41` ②）** 的判据 ────────────────────────
    //   ⭐ `tick_cnt_i` = 小节内 tick 编号（⭐ `beat_gen` 契约，⭐ `:166`/`:220`）
    //      ⇒ ⭐ 它 **< 半小节** ⇒ 离"上一小节线"更近 ⇒ **舍去**（⭐ 这就是"量化到最近"）
    //      ⇒ ⭐ 否则            ⇒ 离"下一小节线"更近 ⇒ **补足**到下一小节 ✅
    //   ⚠️ `rec_aligned_r` 这道门**不能省**：⭐ 只有"**从小节起点起录**"的那一遍，
    //      `rec_bar_tick_r` 才真的是"整数个小节的 tick 数"（⭐ 见起录两处的赋值）✅
    //   ⚠️ `transport_i` 这道门也不能省：⭐ transport 停了 ⇒ `tick_cnt_i` **冻住**
    //      ⇒ ⭐ 拿它判前后半小节就是**拿陈旧值做决定** ✅
    wire [TICK_W-1:0] bar_half_w  = {1'b0, bar_len_r[TICK_W-1:1]};   // ⭐ 半小节 = 右移一位
    wire              quant_ok_w  = rec_aligned_r && grid_ok_r && transport_i;
    //  ⭐⭐ 2026-09-30（`T41` ①）：⭐ **起录要不要"等小节"**
    //   ⭐ 网格可用 ＋ transport 走着 ＋ **现在不是小节起点** ⇒ ⭐ 等（⭐ 进 `ST_RECPEND`）
    //   ⚠️ 若 `rec_req` **正好踩在 `bar_start_i` 上** ⇒ ⭐ 立刻起录（⭐ 它本来就是对齐的），
    //      ⛔ 不必白等一整小节（⭐ 那是 2 秒的"按了没反应"）✅
    //   ⚠️ 网格不可用 / transport 停着 ⇒ ⭐ 立刻起录（⭐ 与改动前逐位相同）✅
    wire              rec_align_w = grid_ok_r && transport_i && ~bar_start_i;
    //  ⚠️ `rec_bar_tick_r == 0` ⇒ ⭐ 连一整小节都没录满 ⇒ ⚠️ 舍去会得到**零长度 loop**
    //     ⇒ ⭐ 强制"补足到 1 小节"（⭐ `K-106`：⛔ 不许静默产出非法长度）✅
    wire              quant_up_w  = (tick_cnt_i >= bar_half_w)
                                    || (rec_bar_tick_r == {TICK_W{1'b0}});
    wire [TICK_W-1:0] quant_len_w = quant_ok_w
                                  ? (quant_up_w ? (rec_bar_tick_r + bar_len_r) : rec_bar_tick_r)
                                  : rec_tick_r;                   // ⭐ 网格不可用 ⇒ 与改动前逐位相同
    wire              quant_drop_w= quant_ok_w && ~quant_up_w;    // ⭐ 舍去 ⇒ 事件计数也要退

    //  ── ⭐ 三个写入点（⭐ 条件与原实现逐条相同）────────────────────────────────
    //   ① 录制中收到 `note_off` ⇒ 把**终点**写回【那个 `note_on` 的地址】✅
    wire ep_w_off_w = br_recst_w && ~stop_req_i[0] && live_valid_i
                      && (cnt_r < EVT_MAX_V) && (live_kind_i == KIND_OFF)
                      && on_open_r[live_axis_i];
    //   ② 录制中收到 `note_on` ⇒ 该地址先写"**无效**"（⭐ 兜底，防陈旧数据 ✅）
    wire ep_w_on_w  = br_recst_w && ~stop_req_i[0] && live_valid_i
                      && (cnt_r < EVT_MAX_V) && (live_kind_i != KIND_OFF);
    //   ③ `ST_CLOSE` **补发**的 `note_off` 也是该音的终点 ⇒ ⭐ 同样写回 ✅
    wire ep_w_cls_w = br_close_w && close_mask_r[close_scan_r]
                      && (cnt_r < EVT_MAX_V) && on_open_r[close_scan_r];

    //  ── ⭐ **唯一的**地址 / 数据 / 写使能（⭐ BSRAM 只认这一个地址表达式）──────
    //   📌 三个使能**天然互斥**（⭐ ①② 按 `kind` 分叉、⭐ ③ 在另一条分支上）⇒
    //      ⭐ 下面三元的先后**不影响语义** ✅
    wire             ep_we_w = ep_w_off_w | ep_w_on_w | ep_w_cls_w;
    wire [CNT_W-1:0] ep_wa_w = ep_w_cls_w ? on_addr_r[close_scan_r]
                             : ep_w_off_w ? on_addr_r[live_axis_i]
                             :              cnt_r;
    wire [EP_W-1:0]  ep_wd_w = ep_w_cls_w
                             ? {1'b1, close_tick_w,
                                vel_max_r[close_scan_r], last_inc_r[close_scan_r]}
                             : ep_w_off_w
                             ? {1'b1, rec_tick_r, rec_vel_w, rec_inc_w}
                             : {EP_W{1'b0}};
    //  ⚠️ **写口 ⛔ 不带复位** —— ⭐ 与 `mem` / `e_word_r` 同一条纪律：
    //     🔴 复位会让 BSRAM 退化成 DFF（⭐ 而且与上面的读口**同块多驱动** = 变黑盒 ✅）
    always @(posedge clk_i)
        if (ep_we_w) ep_mem[ep_wa_w] <= ep_wd_w;

    wire               ep_valid = ep_word_r[O_EPV];
    wire [TICK_W-1:0]  ep_tick  = ep_word_r[O_EPT  +: TICK_W];
    wire [VEL_W-1:0]   ep_vel   = ep_word_r[O_EPVE +: VEL_W];
    wire [PHASE_W-1:0] ep_inc   = ep_word_r[O_EPIN +: PHASE_W];


    //  ⭐ 上一拍**刚推进过**指针 ⇒ ⚠️ 本拍的 `e_word_r` 还是**旧地址**的数据
    reg          rd_adv_r;

    wire [TICK_W-1:0]  e_tick = e_word_r[O_TICK +: TICK_W];
    wire [KIND_W-1:0]  e_kind = e_word_r[O_KIND +: KIND_W];
    wire [AXIS_W-1:0]  e_axis = e_word_r[O_AXIS +: AXIS_W];
    wire [PHASE_W-1:0] e_inc  = e_word_r[O_INC  +: PHASE_W];
    wire [VEL_W-1:0]   e_vel  = e_word_r[O_VEL  +: VEL_W];
    //  ⭐⭐ 2026-09-29 新增：⭐ 回放时取回**录制时的音色** ✅
    wire [TIMBRE_W-1:0] e_tbr = e_word_r[O_TBR +: TIMBRE_W];

    //  ⭐ 本拍**可以吐**：⭐ 指针有效 ＋ ⭐ 数据已跟上（⛔ 不是刚推进过）＋ ⭐ 属于本 tick
    wire e_ready = (rd_ptr_r < cnt_r) && ~rd_adv_r && (e_tick == play_tick_r);

    //  ⭐ "本 tick 的事件还没排空" —— ⭐ 只有排空后才允许推进 `play_tick_r`
    //     🔴 **为什么需要**：⭐ 同一 tick 可能有**多条**事件（和弦）
    //        ⇒ ⚠️ 若 tick 一到就推进 ⇒ 🔴 **后面的同拍事件会被跳过**（⭐ 丢音）
    //  ⭐ "本 tick 还有事件要吐吗" ⇒ ⚠️ **必须把"数据还没跟上"那一拍也算作【没排空】**
    //     🔴 否则刚吐完一条就允许推进 tick ⇒ 🔴 **同拍剩下的会被跳过**（⭐ 丢音）
    wire e_more_this_tick = (rd_ptr_r < cnt_r) && (rd_adv_r || (e_tick == play_tick_r));
    wire rd_drained = ~e_more_this_tick;

    //  ⭐ 重放**什么时候真的在跑**
    //
    //  ⭐⭐ 2026-09-30（`T41` ③）：⭐ **`play_aligned_r` 这道门 = "起播对齐小节"** ✅
    //   🔴 **为什么必须对齐**：⭐ `play_tick_r` 从 0 起算 ⇒ ⭐ 若在**小节中间**起播，
    //      loop 的 `tick 0` 就落在小节中间 ⇒ 🔴 **即使 `loop_len` 是整数小节，
    //      整个 loop 的内容也【整体偏一个固定相位】⇒ 与节拍器/鼓机永远错拍** ✅
    //   ⭐ 语义：⭐ `play_aligned_r = 0` ⇒ "**已请求起播、但还没等到小节线**" ⇒ ⛔ 先不走 tick
    //   ⚠️ **⛔ 不能写成"`play_en` 上升沿置 pending、`bar_start` 清 pending"** ——
    //      🔴 **实测踩过（第一版）**：⭐ 那样 `playing` 在"`play_en` 刚拉高"那一拍
    //      还是真（⭐ `pending` 尚未置位）⇒ ⭐ **本拍就把 `tick 0` 的事件吐了出去**
    //      ⇒ 🔴 **相位仍然是"按下的那一刻"**（⭐ 实测：相位 = 91，⭐ 恰好等于按下的
    //      小节内编号 ⇒ 判据红 ✅）⇒ ⭐ **必须用"对齐标志"而不是"pending 标志"**：
    //      · ⭐ **没在播（`~play_want_w`）⇒ 清 0**（⭐ 下次起播重新等小节）
    //      · ⭐ **小节线到 ⇒ 置 1**（⭐ 寄存 ⇒ `playing` **下一拍**才为真 ✅）
    //   ⚠️ **关键细节（⛔ 不许"同拍放行"）**：⭐ `bar_start_i` 那一拍只置标志，
    //      ⇒ ⭐ **本拍的 `tick_i` 不被消费** ⇒ ⭐ `play_tick_r` 停在 0 **整整一个 tick 槽**
    //      ⇒ ⭐ `tick 0` 的事件就落在【本小节第一个 tick 槽】里 ✅
    //      （⚠️ 若同拍放行 ⇒ `tick 0` 的**第二条**（和弦）会被跳过 —— ⭐ 那是另一种丢音）✅
    //   ⚠️ `grid_ok_r = 0`（⭐ 老 tb / 没接 `bar_start`）⇒ ⭐ `~grid_ok_r` 那一项
    //      让 `playing` 退回**改动前的表达式** ⇒ ⭐ 逐位不变 ✅
    wire play_want_w = (state == ST_HOLD) && play_en_i[0] && transport_i
                       && (cnt_r != {CNT_W{1'b0}});
    wire playing = play_want_w && (play_aligned_r || ~grid_ok_r);

    //  ⭐ 循环回绕：走到 `loop_len_r` 就回 0
    wire [TICK_W-1:0] play_tick_nxt = (play_tick_r + 1'b1 >= loop_len_r)
                                    ? {TICK_W{1'b0}} : (play_tick_r + 1'b1);
    wire wrap_now = (play_tick_r + 1'b1 >= loop_len_r);

    // ══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-09-30：⭐ **插值流水线的【写回挡板】与【推进条件】**
    //
    //  🔴 **为什么需要 `evt_*_hit`**：
    //     原实现里"事件装载分支"（⭐ `if (e_ready)` 那一支，⭐ 在 `always` 里
    //     **更靠后**）与插值引擎**同拍**写 `ramp_inc` / `ramp_vel` / `ramp_mask`
    //     ⇒ ⭐ 同一个轴时**事件分支赢**（⭐ 后写覆盖先写）✅
    //     ⚠️ 现在写回晚了 **2 拍** ⇒ 🔴 若不挡，插值引擎会把事件刚装载的
    //     **起点值**覆盖成"按旧终点算出来的值" ⇒ ⭐ **起点丢失**（⭐ 静默错数据）✅
    //     ⇒ ⭐ 用 `pa_hit` / `pb_hit` 把"这 2 拍里被事件装载过的轴"记下来 ✅
    //     📌 写回**那一拍**不需要挡：⭐ 事件分支仍在 `always` 里更靠后 ⇒ 它照样赢 ✅
    //
    //  🔴 **为什么 `eng_en_w` 要带 `~pa_last & ~pb_last`**：
    //     ⭐ 轴 15 进流水线后要**停扫 2 拍**（⭐ 让 15 走完 B/C 两级收尾）
    //     ⇒ ⭐ 每轮**恰好扫 0..15**（⭐ 与原实现"扫到 `4'hF` 就停"一致）✅
    //     ⚠️ 否则会多扫 1~2 个轴（⭐ 轴号已回绕到 0/1）⇒ ⭐ 相位漂移 ✅
    // ══════════════════════════════════════════════════════════════════════
    wire evt_wr_w   = playing && e_ready;      // ⭐ 本拍事件装载分支**会写** ramp_inc/vel/mask
    wire evt_hitA_w = evt_wr_w && (e_axis == ramp_sc);   // ⭐ 命中"阶段 A 这一拍"的轴
    wire evt_hitB_w = evt_wr_w && (e_axis == pa_ax);     // ⭐ 命中"阶段 B 这一拍"的轴
    //  ⭐ 阶段 A 的推进条件（⭐ `playing` 已由外层分支保证，⭐ 这里再写一次便于阅读）
    wire eng_en_w   = playing && ramp_go && ~live_busy && ~pa_last && ~pb_last;

    //  ⭐ 停录时还有哪些轴**没收到 `note_off`**（⭐ 从 `live_*` 维护）
    integer ai;
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            state        <= ST_IDLE;
            cnt_r        <= {CNT_W{1'b0}};
            rec_tick_r   <= {TICK_W{1'b0}};
            loop_len_r   <= {TICK_W{1'b0}};
            play_tick_r  <= {TICK_W{1'b0}};
            rd_ptr_r     <= {CNT_W{1'b0}};
            tick_pend_r  <= 1'b0;
            rd_adv_r     <= 1'b0;       // ⭐ 同步读的"数据未跟上"标志
            // ⭐ 2026-09-29 修 bug①
            play_active_r <= 16'd0;
            leave_to_r    <= LEAVE_HOLD;
            play_en_d_r   <= 1'b0;
            //  ⚠️ ⛔ **`e_word_r` 不在这里复位** —— 🔴 它有自己的 `always` 块
            //     （⭐ 见上方"同步读"那段）⇒ ⚠️ **两个块同时驱动 = 多驱动** ⇒
            //     🔴 Gowin 报 `EX2000: Net 'e_word_r[65]' is constantly driven
            //        from multiple places` ⇒ ⭐ **模块变黑盒** ⚠️
            //  📌 而且**不加复位**才对 BSRAM 推断最友好（⭐ 纯同步读）✅
            //     ⚠️ 未复位也不会传播 X：⭐ `e_ready` 要求 `rd_ptr_r < cnt_r`
            //        ⇒ ⭐ 复位后 `cnt_r = 0` ⇒ **永远不读** ✅
            drop_r       <= 16'd0;
            full_r       <= 1'b0;
            close_mask_r <= 16'd0;
            close_scan_r <= 4'd0;
            //  ⭐⭐ 2026-09-30（`T41`）：⭐ 小节对齐的 4 个状态位一起复位 ✅
            //   ⚠️ `bar_len_r` / `bar_cnt_r` / `bar_seen_r` / `grid_ok_r`
            //      **不在这里** —— ⭐ 它们有自己的 `always` 块（⭐ 同 `e_word_r` 的纪律：
            //      ⛔ 两个块同时驱动 = 多驱动 ⇒ 综合报 `EX2000` ⇒ **模块变黑盒**）✅
            rec_bar_tick_r <= {TICK_W{1'b0}};
            rec_bar_cnt_r  <= {CNT_W{1'b0}};
            rec_aligned_r  <= 1'b0;
            play_aligned_r <= 1'b0;
            play_valid_o <= 1'b0;
            play_axis_o  <= {AXIS_W{1'b0}};
            play_inc_o   <= {PHASE_W{1'b0}};
            play_vel_o   <= {VEL_W{1'b0}};
            play_kind_o  <= KIND_OFF;
            //  ⭐⭐ 2026-09-29 新增：⭐ 音色输出复位 ✅
            play_timbre_o       <= {TIMBRE_W{1'b0}};
            play_timbre_valid_o <= 1'b0;
            //  ⭐⭐ 2026-09-29 新增：⭐ 插值输出 / 端点跟踪 / 插值状态 复位 ✅
            //   ⚠️ `ep_word_r` **不在这里复位**（⭐ 它有自己的 `always` 块 ——
            //      ⭐ 与 `e_word_r` 同一条纪律：⛔ 两个块同时驱动 = 多驱动 ✅）
            //   ⚠️ 未复位的 `ep_word_r` 也不会传播 X：⭐ 它只在 `e_ready` 那一拍被用，
            //      而 `e_ready` 要求 `rd_ptr_r < cnt_r` ⇒ ⭐ 复位后 `cnt_r = 0` ⇒ 永不读 ✅
            play_upd_valid_o <= 1'b0;
            play_upd_axis_o  <= {AXIS_W{1'b0}};
            play_upd_inc_o   <= {PHASE_W{1'b0}};
            play_upd_vel_o   <= {VEL_W{1'b0}};
            ramp_mask    <= 16'd0;
            ramp_sc      <= 4'd0;
            ramp_go      <= 1'b0;
            //  ⭐⭐ 2026-09-30：⭐ 插值流水线的**有效位 / 挡板位**一起复位
            //     ⚠️ 只复位这 6 个就够 —— ⭐ 其余流水寄存器被 `pa_v`/`pb_v` 挡着，
            //        ⭐ 复位后 `pb_v = 0` ⇒ ⛔ 不会把 `x` 传到 `ramp_inc` / 输出 ✅
            pa_v    <= 1'b0;  pb_v    <= 1'b0;
            pa_hit  <= 1'b0;  pb_hit  <= 1'b0;
            pa_last <= 1'b0;  pb_last <= 1'b0;
            on_open_r    <= 16'd0;
            for (ai = 0; ai < 16; ai = ai + 1) begin
                last_inc_r[ai] <= {PHASE_W{1'b0}};
                vel_max_r[ai] <= {VEL_W{1'b0}};
                on_addr_r [ai] <= {CNT_W{1'b0}};
                ramp_inc  [ai] <= {PHASE_W{1'b0}};
                ramp_vel  [ai] <= {VEL_W{1'b0}};
                rtgt_inc  [ai] <= {PHASE_W{1'b0}};
                rtgt_vel  [ai] <= {VEL_W{1'b0}};
                rend_tick [ai] <= {TICK_W{1'b0}};
            end
            overflow_o   <= 1'b0;
        end else begin
            //  ⭐ `play_valid_o` 是**单周期脉冲** ⇒ 默认拉低（⭐ 冻结表 §〇 约定 4）
            play_valid_o <= 1'b0;
            //  ⭐⭐ 2026-09-29 新增：⭐ `play_timbre_valid_o` **必须与 `play_valid_o` 同拍** ✅
            //     ⇒ ⭐ 下游才会把"这条事件"和"它的音色"配成一对 ✅
            play_timbre_valid_o <= 1'b0;

            // ══════════════════════════════════════════════════════════════
            //  ⭐⭐ 2026-09-30（`T41` ③）：⭐ **"起播已对齐小节"标志**
            //   ⭐ 置位：⭐ 小节线到（⭐ 寄存 ⇒ `playing` 下一拍才为真 ⇒
            //      ⭐ 本拍的 `tick_i` 不被消费 ⇒ `play_tick_r` 停在 0 一个整槽 ✅）
            //   ⭐ 清零：⭐ **没在播就清**（⭐ 下次起播重新等小节）——
            //      ⚠️ 这一条顺带覆盖"**transport 停了又开**"（⭐ 那条也会把
            //      `play_tick_r` 归零 ⇒ ⭐ 同样必须重新对齐）✅
            //   ⚠️ `grid_ok_r = 0`（⭐ 老 tb / 没接 `bar_start`）⇒ ⭐ `playing` 里
            //      有 `|| ~grid_ok_r` ⇒ ⭐ 本标志**不起作用** ⇒ 行为逐位不变 ✅
            // ══════════════════════════════════════════════════════════════
            if (~play_want_w)
                play_aligned_r <= 1'b0;              // ⭐ 没在播 ⇒ 下次重新对齐
            else if (bar_start_i)
                play_aligned_r <= 1'b1;              // ⭐ 小节线到 ⇒ 放行（⭐ 下一拍才走 tick）

            // ══════════════════════════════════════════════════════════════
            //  ⭐⭐ 2026-09-29 新增：⭐ **回放插值引擎**（⭐ 每 tick 扫一轮 16 轴，⭐ 一拍一个轴）
            //
            //  🔴 **为什么"一拍一个轴"**：⭐ 16 轴**并行**做"加减 + 比较 + 钳位"会白烧
            //     ~16 倍逻辑（⭐ 而一个 tick 有 **26000 拍**预算，⭐ 完全用不完）
            //     ⇒ ⭐ **共享一套运算**、⭐ 顺序扫 ✅
            //  ⭐ **更新频率 = 每 PPQN tick 一条**（⭐ 本模块**本来就有**这个时基）
            //     · ⭐ `PPQN = 960`（`beat_gen.v:61`）⇒ 120 BPM 时 **0.52 ms/条**
            //     · ⭐ 手弹位置式力度是 **每轴 328 µs**（16 轴 × 20.48 µs）
            //       ⇒ ⭐ 两者**同一量级**（回放略粗 1.6×）✅
            //     · ⭐ 且 `note_manager` 收到后按 **±8/采样拍**平滑（⭐ 0.65 ms 满量程）
            //       ⇒ ⭐ 中间台阶被抹平 ⇒ ⭐ 听感是**连续滑行** ✅
            //  ⚠️ **主动避让手弹**（`live_busy`）：⭐ `top.v` 把两路**或**进同一条
            //     `vel_upd_*`/`pitch_upd_*` ⇒ ⚠️ 同拍会丢一条 ⇒ ⭐ 本引擎**让一拍**
            //     （⭐ 下一拍再补）⇒ ⭐ **结构上不可能撞**（⛔ 不靠"谁优先"的约定）✅
            // ══════════════════════════════════════════════════════════════
            play_upd_valid_o <= 1'b0;
            if (!playing) begin
                //  ⚠️ 没在播 ⇒ ⭐ 清掉插值状态（⭐ 下次起播从头来，⛔ 不留残余 ✅）
                ramp_mask <= 16'd0;
                ramp_go   <= 1'b0;
                ramp_sc   <= 4'd0;
                //  ⭐ 流水线一起清（⭐ 与"不留残余"同一条纪律；⭐ 复位分支同式）✅
                pa_v <= 1'b0;  pb_v <= 1'b0;
                pa_hit <= 1'b0; pb_hit <= 1'b0;
                pa_last <= 1'b0; pb_last <= 1'b0;
            end else begin
                // ── ⭐⭐ 阶段 C：⭐ 收尾（⭐ 写回 + 输出 + 收工判定）───────────────
                //   ⚠️ 写回晚 2 拍 ⇒ ⭐ 用 `pb_*`（⭐ 见文件上方三级的说明）✅
                if (pb_v) begin
                    //  ⚠️ `pb_hit` ⇒ 本轴在这 2 拍里被事件装载分支重新写过
                    //     ⇒ ⭐ 写回让位（⭐ 与原实现"事件分支优先"逐位等价）✅
                    //  ⚠️ `pb_msk` ⇒ 原实现**整段都在 `if (ramp_mask[ramp_sc])` 里**
                    //     ⇒ ⭐ 本轴没在插值时**既不写回、也不清掩码**（⭐ 必须照抄，
                    //        ⛔ 否则"掩码已清的轴"会被引擎继续往旧终点推 ⇒ **静默漂移**）✅
                    if (!pb_hit && pb_msk) begin
                        ramp_inc[pb_ax] <= pc_inc_w;
                        ramp_vel[pb_ax] <= pc_vel_w;
                        //  ⭐ 走到终点 tick ⇒ ⭐ 本轮插值收工
                        //     （⚠️ 另有兜底：⭐ 回放到该轴的 `note_off` 时**无条件清零** ✅）
                        if (pb_snap)
                            ramp_mask[pb_ax] <= 1'b0;
                    end
                    //  ⭐ 吐**本拍的新值**（⭐ 寄存器与输出同拍 ⇒ 下游看到的就是本模块状态 ✅）
                    //     ⚠️ 输出**不受 `pb_hit` 影响** —— ⭐ 原实现里事件分支不碰 `play_upd_*` ✅
                    play_upd_valid_o <= pb_msk;
                    play_upd_axis_o  <= pb_ax;
                    play_upd_inc_o   <= pc_inc_w;
                    play_upd_vel_o   <= pc_vel_w;
                    //  ⭐ 轴 15 收尾 ⇒ ⭐ 本轮扫完：⭐ 指针归零 + 停扫
                    //     （⭐ 与原实现"扫到 `4'hF` 就 `ramp_sc <= 0; ramp_go <= 0`"同义）✅
                    if (pb_last) begin
                        ramp_sc <= 4'd0;
                        ramp_go <= 1'b0;
                    end
                end

                // ── ⭐⭐ 阶段 B：⭐ `+2^f-1` / `>>f` / `max(1)`（⭐ 每拍无条件推进）──
                pb_ax   <= pa_ax;    pb_inc  <= pa_inc;   pb_tgt  <= pa_tgt;
                pb_vel  <= pa_vel;   pb_tv   <= pa_tv;
                pb_up   <= pa_up;    pb_dn   <= pa_dn;
                pb_vup  <= pa_vup;   pb_dvn  <= pa_dvn;
                pb_sinc <= pb_sinc_w; pb_svel <= pb_svel_w;
                pb_msk  <= pa_msk;   pb_snap <= pa_snap;
                //  ⭐ 累积"这 2 拍里事件分支命中过本轴"（⭐ 写回挡板）✅
                pb_hit  <= pa_hit | evt_hitB_w;
                pb_last <= pa_last;  pb_v    <= pa_v;

                // ── ⭐⭐ 阶段 A：⭐ 取操作数 + `f` / `2^f`（⭐ 每拍推进一个轴）────
                if (eng_en_w) begin
                    pa_ax   <= ramp_sc;
                    pa_inc  <= ramp_inc_c;  pa_tgt  <= rtgt_inc_c;
                    pa_vel  <= ramp_vel_c;  pa_tv   <= rtgt_vel_c;
                    pa_dinc <= ramp_dinc;   pa_dvel <= ramp_dvel;
                    pa_pw   <= ramp_pw;     pa_f    <= ramp_f;
                    pa_up   <= ramp_up;     pa_dn   <= ramp_dn;
                    pa_vup  <= vel_up;      pa_dvn  <= vel_dn;
                    pa_msk  <= ramp_msk_c;  pa_snap <= ramp_snap_c;
                    pa_hit  <= evt_hitA_w;
                    pa_last <= (ramp_sc == 4'hF);
                    pa_v    <= 1'b1;
                    //  ⭐ 每拍推进一个轴 ⇒ ⭐ 仍 16 拍扫完 16 轴（⭐ 吞吐不变）✅
                    ramp_sc <= ramp_sc + 4'd1;
                end else begin
                    pa_v    <= 1'b0;
                    pa_hit  <= 1'b0;
                    pa_last <= 1'b0;
                end
            end

            // ── 控制（⭐ 优先级：clear > rec > stop）──────────────────────
            //  ══════════════════════════════════════════════════════════════
            //  ⭐⭐ 2026-09-29【结构性修法】：⭐ **"离开回放"只有【一个】判定点**
            //
            //  🔴 **原缺陷（⭐ 第一版修法的教训 —— 用户指出"禁止修表象"）**：
            //     ⭐ `ST_HOLD` 有 **3 条**退出路径 —— ⭐ ① `clear_req` ② `play_en` 落沿
            //     ⭐ ③ **`rec_req`（回放中按 `R` 重录）** ⚠️
            //     ⚠️ 而**每条都要自己记得补发 `note_off`** ⇒ ⭐ 我第一版**只补了 ①②**
            //     ⇒ 🔴 **③ 那条仍然挂音** ✅
            //
            //  ⭐⭐ **真正的源头是【设计里缺一条不变量】**：
            //     ⭐ **"只要 `ST_HOLD` 里还有音在响（`play_active_r != 0`），
            //        ⛔ 就不许离开 `ST_HOLD`"** ✅
            //
            //  ✅ **修法**：⭐ 把这条不变量**写成代码** —— ⭐ **所有"离开回放"的请求
            //     一律先转成 `ST_LCLOSE`**，⭐ 由 `leave_to_r` 记住"补完之后去哪" ✅
            //     · ⭐ `clear_req` ⇒ `LEAVE_IDLE`（⭐ 补完清空 ✅）
            //     · ⭐ `rec_req`   ⇒ `LEAVE_REC` （⭐ 补完开始录 ✅）
            //     · ⭐ 停播        ⇒ `LEAVE_HOLD`（⭐ 补完回 `ST_HOLD` ✅，⭐ 见下方 `playing` 分支）
            //  📌 ⭐ **以后再加退出路径时，只要走这个判定点就不会漏** ✅
            //  ══════════════════════════════════════════════════════════════
            //   ⚠️ 条件已抽成 `br_leave_w`（⭐ 定义见上方 `ep_mem` 写口那段）——
            //      🔴 因为端点侧表的写口在 FSM 之外，⭐ 两处**必须共用同一套优先级** ✅
            if (br_leave_w) begin
                //  ⭐⭐ **唯一出口**：⭐ 先逐轴补发，⭐ 补完按 `leave_to_r` 去对应状态 ✅
                close_mask_r <= play_active_r;
                close_scan_r <= 4'd0;
                //  ⚠️ 与 `:742`/`:744` **同源**（⭐ 都用打了一拍的 `clear_req_w` ✅）
                leave_to_r   <= clear_req_w ? LEAVE_IDLE : LEAVE_REC;
                state        <= ST_LCLOSE;
            end else if (br_clear_w) begin
                //  ⭐ 没有音在响 ⇒ ⭐ 直接清（⭐ 与旧行为一致）
                state        <= ST_IDLE;
                cnt_r        <= {CNT_W{1'b0}};
                rd_ptr_r     <= {CNT_W{1'b0}};
                play_tick_r  <= {TICK_W{1'b0}};
                loop_len_r   <= {TICK_W{1'b0}};
                rec_tick_r   <= {TICK_W{1'b0}};
                full_r       <= 1'b0;
                tick_pend_r  <= 1'b0;
                rd_adv_r     <= 1'b0;
                close_mask_r <= 16'd0;
                play_active_r<= 16'd0;
                //  ⭐⭐ 2026-09-30（`T41`）：⭐ 清空 ⇒ **"起播对齐"标志也一起清**
                //     🔴 否则：⭐ 清空后 `play_en` 还开着 ⇒ ⚠️ 若不清，⭐ 下一次
                //        **录完**回到 `ST_HOLD` 时会带着一个**陈旧的"已对齐"**直接起播
                //        （⭐ 而那时 `play_tick_r` 刚归零 ⇒ 🔴 又落在小节中间）✅
                //     ⭐ 顺带：⭐ "待起录"（`ST_RECPEND`）也被本分支带走（⭐ `state <= ST_IDLE`）✅
                play_aligned_r <= 1'b0;
            end else if (br_recpend_w) begin
                //  ══════════════════════════════════════════════════════════
                //  ⭐⭐ 2026-09-30（`T41` ①）：⭐ **待起录 ⇒ 小节起点到 ⇒ 真起录**
                //   ⭐ 语义与下面的 `br_rec_w` 立刻起录那条**逐条相同** ——
                //      ⚠️ 只有"**什么时候**"不同（⭐ 这里等到了 `bar_start_i`）✅
                //   ⭐ `rec_aligned_r <= 1`：⭐ 本遍**确实是**从小节起点起录的
                //      ⇒ ⭐ 停录时才允许量化（⭐ 见 `quant_ok_w`）✅
                //  ══════════════════════════════════════════════════════════
                state          <= ST_REC;
                cnt_r          <= {CNT_W{1'b0}};
                rec_tick_r     <= {TICK_W{1'b0}};
                rd_ptr_r       <= {CNT_W{1'b0}};
                play_tick_r    <= {TICK_W{1'b0}};
                full_r         <= 1'b0;
                close_mask_r   <= 16'd0;
                close_scan_r   <= 4'd0;
                on_open_r      <= 16'd0;
                rec_bar_tick_r <= {TICK_W{1'b0}};
                rec_bar_cnt_r  <= {CNT_W{1'b0}};
                rec_aligned_r  <= 1'b1;
                play_aligned_r <= 1'b0;   // ⭐ 起录 ⇒ 旧的"已对齐"作废（⭐ 录完自然会重新等）
                //  ⭐⭐ 2026-10-14：⭐ **这里 `state` 进 `ST_REC` ⇒ `rec_pending_o` 自动落回 0** ✅
                //     📌 ⭐ 所以"武装中"的灯**只在真正等小节线时亮** ✅
            end else if (br_reccancel_w) begin
                //  ⭐⭐ 2026-09-30（`T41` ①）：⭐ **取消"待起录"**（⭐ 理由见 `br_reccancel_w`）
                //   ⚠️ ⛔ **不清 `cnt_r`**：⭐ 上一遍录音还在 ⇒ ⭐ 回 `ST_HOLD` 继续可播 ✅
                state <= (cnt_r != {CNT_W{1'b0}}) ? ST_HOLD : ST_IDLE;
            end else if (br_rec_w) begin
                if (rec_align_w) begin
                    //  ⭐⭐ 2026-09-30（`T41` ①）：⭐ **网格可用 ⇒ 先"待起录"**
                    //   🔴 **为什么**：⭐ 此刻起录 ⇒ `rec_tick_r = 0` 落在小节中间
                    //      ⇒ ⭐ `loop_len` 永远不是整数小节 ⇒ 🔴 **与鼓机越跑越偏** ✅
                    //   ⭐ 只置状态，⛔ **不清 `cnt_r`** —— ⚠️ 上一条录音要留到
                    //      `bar_start` 那一刻才清（⭐ 否则这半个小节里 `cnt_r = 0`
                    //      而 `mem` 还在 ⇒ ⭐ 状态与内容**不一致**）✅
                    state <= ST_RECPEND;
                end else begin
                //  ⭐ 开始录制：⭐ 从**此刻**起算 tick（⭐ 与 `beat_gen` 的 tick 对齐）
                //  ⚠️ 走到这里只有两种情形（⭐ `rec_align_w` 为假）：
                //     · ⭐ **网格未知**（`grid_ok_r = 0`：⭐ 老 tb / 没接 `bar_start`）
                //     · ⭐ **transport 停着**（⭐ 没有 `bar_start` 可等 ⇒ 等了也没意义）
                //     ⇒ ⭐ 两种情况都**退回改动前的行为**（⭐ 立即起录、不量化）✅
                state        <= ST_REC;
                cnt_r        <= {CNT_W{1'b0}};
                rec_tick_r   <= {TICK_W{1'b0}};
                rd_ptr_r     <= {CNT_W{1'b0}};
                play_tick_r  <= {TICK_W{1'b0}};
                full_r       <= 1'b0;
                close_mask_r <= 16'd0;
                close_scan_r <= 4'd0;
                rec_bar_tick_r <= {TICK_W{1'b0}};
                rec_bar_cnt_r  <= {CNT_W{1'b0}};
                //  ⭐ 只有"踩着 `bar_start` 立刻起录"才算对齐（⭐ `rec_align_w` 已排除
                //     网格不可用/transport 停 ⇒ 这里 `bar_start_i` 必为真 ✅）
                rec_aligned_r  <= grid_ok_r && transport_i;
                play_aligned_r <= 1'b0;
                //  ⭐⭐ 2026-09-29 修 bug②：⭐ **`on_open_r` 泄漏**（⭐ 录制中 `clear` 之后）✅
                //   🔴 **缺陷**：⭐ 录制中按 `clear` ⇒ `br_leave_w` 为假（⭐ 它要求
                //      `state == ST_HOLD`）⇒ ⭐ 走 `br_clear_w` 那条 ⇒ 直接回 `ST_IDLE`，
                //      ⚠️ **既不补发 `note_off`、也不清 `on_open_r`** ✅
                //   🔴 **后果（⭐ 静默）**：⭐ 那个还按着的音的 `on_addr_r`（⭐ **上一遍
                //      录音的地址**）留到下一遍录音 ⇒ ⭐ 下一次录制期间再松开那个老键
                //      ⇒ ⭐ 这条**没有前置 `note_on`** 的 `note_off` 却因 `on_open_r[a]=1`
                //      而命中 `ep_w_off_w` ⇒ 🔴 **把终点写到旧地址** ✅
                //      ⚠️ 若该地址在新录音里已经是**别的音**的 `note_on`（⭐ 且它自己的
                //      `note_off` 已经写过终点）⇒ 🔴 **那个音的终点被改写** ⇒ ⭐ 回放时
                //      它的跨度/力度**全错**，⭐ 而且**没有任何报错** ✅
                //   ✅ **为什么清在【起录】而不是【`clear` 那一条】**：⭐ `on_open_r` 的
                //      语义是"**本遍录音里**尚未闭合的 `note_on`" ⇒ ⭐ 它的生命周期
                //      **就是一遍录音** ⇒ ⭐ 在**唯一的入口**清零 ⇒ ⭐ 以后再加"放弃录制"
                //      的路径（⭐ 不止 `clear` 这一条）**都不会漏** ✅
                //      📌 与上方"离开回放只有【一个】判定点"同一条纪律 ✅
                on_open_r    <= 16'd0;
                end     // ⭐ 关闭"网格不可用 ⇒ 立刻起录"那条（⭐ `rec_align_w` 为假）
            end else if (br_recst_w) begin
                // ── 录制中 ────────────────────────────────────────────────
                if (stop_req_i[0]) begin
                    // ══════════════════════════════════════════════════════
                    //  ⭐⭐ 2026-09-30（`T41` ②）：⭐ **停录 ⇒ 量化到最近的整小节**
                    //
                    //  🔴 **改动前**：⭐ `loop_len_r <= rec_tick_r`（⭐ 原始计数）
                    //     ⇒ ⭐ 只要按停的时刻不在小节线上 ⇒ `loop_len mod TICKS_PER_BAR != 0`
                    //     ⇒ 🔴 **每绕一圈相位偏一点、误差逐圈累加**（⭐ 用户听到的"逐渐延后"）✅
                    //
                    //  ⭐ **改动后**：⭐ `loop_len` = **整数个小节**（⭐ `quant_len_w`）✅
                    //
                    //  🔴 **`quant_drop_w`（舍去半小节）时为什么必须退 `cnt_r`**：
                    //     ⭐ 被舍掉的那半小节里的事件 tick 都 **>= `loop_len`**
                    //     ⇒ ⭐ 重放的 `play_tick_r` 只走 `0..loop_len-1` ⇒ **永远匹配不上**
                    //     ⇒ 🔴 读指针**卡在它们上面** ⇒ ⚠️ 而补发的那条 `note_off`
                    //        落在它们**之后**（⭐ 存 `mem` 的顺序）⇒ 🔴 **永远读不到**
                    //     ⇒ ⭐ **跨圈按住的音会挂住**（⭐ 正是本文件反复强调要防的那个缺陷）✅
                    //     ⭐ 退回 `rec_bar_cnt_r`（⭐ 小节起点那一刻的条数）⇒
                    //        ⭐ 舍掉的事件**整条消失** ⇒ `mem` 重新变成**按 tick 有序** ✅
                    //  ⚠️ **补足**（`quant_up_w`）时**不退** —— ⭐ 那时所有事件的 tick
                    //     都 `< loop_len`（⭐ 天然有序、全都可播）⇒ ⛔ 不许丢用户弹的东西 ✅
                    //     📌 代价：⭐ 补足的那一小节里是**静音尾巴**（⭐ 最多半小节），
                    //        且停录时**还按着**的音会拖到补足小节末尾才收到补发的 `note_off`
                    //        （⭐ 因为 `close_tick_w = loop_len-1`，⛔ 不能改小 ——
                    //         ⚠️ 改小就跑到"停录槽里那些事件"之前了 ⇒ 顺序又乱）✅
                    // ══════════════════════════════════════════════════════
                    loop_len_r   <= quant_len_w;
                    if (quant_drop_w)
                        cnt_r    <= rec_bar_cnt_r;
                    state        <= ST_CLOSE;
                    close_scan_r <= 4'd0;
                end else begin
                    if (tick_i)
                        rec_tick_r <= rec_tick_r + 1'b1;

                    //  ⭐⭐ 2026-09-30（`T41` ②）：⭐ **每个小节起点记两个"整小节锚点"**
                    //   · ⭐ `rec_bar_tick_r` = 那一刻的 tick 数 ⇒ ⭐ 停录量化用它当"整数小节"那一档
                    //   · ⭐ `rec_bar_cnt_r`  = 那一刻的事件条数 ⇒ ⭐ 舍去半小节时一起退 ✅
                    //   ⚠️ **`bar_start_i` 与 `tick_i` 同拍**（⭐ `beat_gen.v:212-220`：
                    //      `bar_start_q` 只在 `if (do_tick)` 里置位）⇒ ⭐ 这一刻 `rec_tick_r`
                    //      正要 +1 ⇒ ⭐ **"已录满的整小节 tick 数" = 它 + 1** ✅
                    //   ⚠️ 与 `bar_start` **同拍落盘**的那一条事件**不计入** `rec_bar_cnt_r`
                    //      （⭐ 非阻塞赋值读的是旧值）⇒ ⚠️ 概率 ≈ 1/26000（⭐ 一个 tick 槽
                    //      里只可能有一条）⇒ ⭐ 最坏只是"补一条没有前置 `note_on` 的
                    //      `note_off`"（⭐ 下游无害），⛔ **不挂音** ✅
                    if (bar_start_i) begin
                        rec_bar_tick_r <= rec_tick_r + 1'b1;
                        rec_bar_cnt_r  <= cnt_r;
                    end

                    //  ⭐⭐ 2026-09-29 新增：⭐ **跟住"手弹位置式力度"**（⭐ 端点来源 ✅）
                    //   🔴 **为什么必须跟**：⭐ `note_off` 自带的是**松手那一刻**的力度
                    //      （⭐ 恒为 `VEL_DEFAULT`）⇒ ⭐ 只有**跟住这条流**才知道
                    //      "**按住期间最重到了多少**" ✅
                    //   ⚠️ `=== 1'b1` ⇒ ⭐ **悬空（`x`）视为"没有更新"** ⇒
                    //      ⭐ 老 tb 不接该端口时行为与改动前完全一致 ✅
                    //  ⭐⭐ **2026-09-30：⭐ 取【峰值】而不是【末值】** ✅
                    //   🔴 **为什么**：⭐ `adsr` 的包络电平在 `note_off` 那一刻
                    //      **取决于本音期间的【峰值力度】**（⭐ 见上方 `vel_max_r` 的长注释）——
                    //      ⭐ 手弹时 `vel_r` 中途冲到峰值，⭐ 而 `adsr` 的 decay 只有 1/采样拍
                    //      ⇒ ⭐ 短音**降不下来** ⇒ ⭐ 松手时电平仍高 ⇒ ⭐ 尾音长 ✅
                    //   ⚠️ 取末值 ⇒ 🔴 回放永远爬不到那个峰值 ⇒ 尾音按比例短 ✅
                    //   📌 **单调手势下 `max` == 末值** ⇒ ⭐ 与旧行为**逐值相同** ✅
                    if (live_vel_valid_i === 1'b1)
                        if (live_vel_value_i > vel_max_r[live_vel_axis_i])
                            vel_max_r[live_vel_axis_i] <= live_vel_value_i;

                    if (live_valid_i) begin
                        if (cnt_r < EVT_MAX_V) begin
                            //  ⭐⭐ 端点取值：⭐ `note_off` 换成"**本音期间的峰值力度**"
                            //     （⭐ = 端点）⇒ ⭐ `note_off` 的 `inc`/`vel` 从此**就是终点** ✅
                            //     （⭐ 语义变更依据：本次设计 —— ⭐ `kind` 区分起点/终点 ✅）
                            mem[cnt_r] <= {live_timbre_i, rec_tick_r, live_kind_i, live_axis_i,
                                           rec_inc_w, rec_vel_w};
                            //  ⭐⭐ **端点侧表**（⭐ 见 `ep_mem` 的说明）：
                            //     · ⭐ 起音 ⇒ 该地址先写"无效"（⭐ 兜底，防陈旧数据 ✅）
                            //        ＋ ⭐ 记下它的地址、⭐ 刷新"**本音峰值**" ✅
                            //     · ⭐ 松手 ⇒ **把终点写回【那个 `note_on` 的地址】** ✅
                            //   ⚠️ **这里 ⛔ 不再直接写 `ep_mem`** —— 🔴 三个写地址表达式
                            //      会让 Gowin **推不出 BSRAM**（⭐ 见上方写口那段的实测）
                            //      ⇒ ⭐ 写入改由**独立写口**统一完成（⭐ 条件与此处逐条相同 ✅）
                            if (live_kind_i == KIND_OFF) begin
                                on_open_r[live_axis_i] <= 1'b0;
                            end else begin
                                on_addr_r[live_axis_i]   <= cnt_r;
                                on_open_r[live_axis_i]   <= 1'b1;
                                last_inc_r[live_axis_i]  <= live_inc_i;
                                //  ⭐ 新音 ⇒ 峰值**从它自己的起音力度重新起算**
                                //     （⭐ ⛔ 不许残留上一个音的峰值 —— 否则新音一响就被拉高 ✅）
                                vel_max_r[live_axis_i]   <= live_vel_i;
                            end
                            cnt_r <= cnt_r + 1'b1;
                        end else begin
                            //  🔴 **录满了必须【可见】**（⭐ `K-106`：⛔ 不许静默丢）
                            full_r   <= 1'b1;
                            overflow_o <= 1'b1;
                            if (drop_r != 16'hFFFF)
                                drop_r <= drop_r + 16'd1;
                        end
                        //  ⭐ 维护"哪些轴还按着"（⭐ 供停录时补发）
                        if (live_kind_i == KIND_ON)
                            close_mask_r[live_axis_i] <= 1'b1;
                        else if (live_kind_i == KIND_OFF)
                            close_mask_r[live_axis_i] <= 1'b0;
                    end
                end
            end else if (br_close_w) begin
                // ── 补发 `note_off`（⭐ 一次一个轴，⭐ **16 个轴全扫**）────────
                //   🔴 **这是 looper 最容易犯的错**（⭐ 上游 §2）：⭐ 不补 ⇒ 那个音
                //      **在 loop 里永不停止** ⇒ ⭐ **挂音**
                //   ⚠️ 边界：⭐ 必须扫到 **`4'hF`（轴 15）** 才算完 ⇒ ⚠️ 早一拍退出
                //      ⇒ 🔴 **轴 15 的挂音会被漏掉**（⭐ 本项目 `L88` 同族：⭐ 边界差一）
                if (close_mask_r[close_scan_r]) begin
                    if (cnt_r < EVT_MAX_V) begin
                        //  ⭐ 补发的事件落在**循环的【最后一个可播 tick】**（`loop_len-1`）
                        //     🔴 **原写法存到 `loop_len`** ⇒ ⚠️ 而重放的 `play_tick_r`
                        //        只走 `0 .. loop_len-1` ⇒ 🔴 **那条 `note_off` 永远
                        //        不会被重放** ⇒ ⭐ **防挂音形同虚设**（⭐ 本 tb 判据 ③④ 抓到）
                        //  ⚠️ 音色字段填 0 —— ⭐ 补发的 `note_off` **不用音色**
                        //     （⭐ `note_manager` 只在 `note_on` 提交时锁存音色 ✅）
                        //  ⭐⭐ 2026-09-29：⭐ `inc`/`vel` 改成**该音的终点**（⭐ 最后已知值）
                        //     🔴 **为什么不能继续填 0**：⭐ 跨循环点**一直按住**的音
                        //        ⇒ ⭐ 它的终点就是"补发这一刻的值" ⇒ ⚠️ 填 0 会让回放
                        //        **把力度插值拉到 0** ⇒ 🔴 **尾音反而更短**（⭐ 比不改还差）✅
                        mem[cnt_r] <= {{TIMBRE_W{1'b0}}, close_tick_w,
                                       KIND_OFF, close_scan_r[AXIS_W-1:0],
                                       last_inc_r[close_scan_r],
                                       vel_max_r[close_scan_r]};
                        //  ⭐⭐ **补发的 `note_off` 也是该音的终点** ⇒ ⭐ 端点侧表同样要写 ✅
                        //   ⚠️ **写入由【独立写口】完成**（⭐ 见上方写口那段的实测）——
                        //      🔴 写地址表达式超过 2 个 ⇒ Gowin 推不出 BSRAM ✅
                        cnt_r <= cnt_r + 1'b1;
                    end else begin
                        full_r     <= 1'b1;
                        overflow_o <= 1'b1;
                        if (drop_r != 16'hFFFF)
                            drop_r <= drop_r + 16'd1;
                    end
                    on_open_r[close_scan_r]    <= 1'b0;
                    close_mask_r[close_scan_r] <= 1'b0;
                end
                if (close_scan_r == {AXIS_W{1'b1}})
                    state <= ST_HOLD;                 // ⭐ 最后一个轴也扫到了
                else
                    close_scan_r <= close_scan_r + 4'd1;
            end else if (state == ST_LCLOSE) begin
                //  ⭐⭐ 2026-09-29 修 bug①：⭐ **逐轴补发 `note_off`（⭐ 只【吐】，⛔ 不存 `mem`）**
                //   ⚠️ 与 `ST_CLOSE` 的区别：⭐ `ST_CLOSE` 把 `note_off` **存进 `mem`**
                //      （⭐ 那是**录音的一部分**）；⭐ 这里**直接吐到 `play_valid_o`**
                //      （⭐ 因为这一层马上要被清掉 / 或只是停播）✅
                //   ⚠️ **边界**：⭐ 必须扫到 **`4'hF`（轴 15）** 才算完（⭐ `L88` 同族：⭐ 边界差一）✅
                if (close_mask_r[close_scan_r]) begin
                    play_valid_o <= 1'b1;
                    play_axis_o  <= close_scan_r[AXIS_W-1:0];
                    play_inc_o   <= {PHASE_W{1'b0}};
                    play_vel_o   <= {VEL_W{1'b0}};
                    play_kind_o  <= KIND_OFF;
                    //  ⭐⭐ 2026-09-29 新增：⭐ 直接吐的 `note_off` 也带 `timbre_valid`
                    //     （⭐ 音色填 0 —— ⚠️ `note_off` **不用音色** ✅）
                    play_timbre_o       <= {TIMBRE_W{1'b0}};
                    play_timbre_valid_o <= 1'b1;
                    close_mask_r[close_scan_r] <= 1'b0;
                end
                if (close_scan_r == {AXIS_W{1'b1}}) begin
                    //  ⭐ 扫完（⭐ 最后一个轴也发了）⇒ ⭐ 按 `leave_to_r` 决定收尾（⭐ 三选一 ✅）
                    play_active_r <= 16'd0;
                    close_mask_r  <= 16'd0;
                    if (leave_to_r == LEAVE_IDLE) begin
                        //  ⭐ 清空（⭐ 与"没有音在响时直接清"等价）
                        state        <= ST_IDLE;
                        cnt_r        <= {CNT_W{1'b0}};
                        rd_ptr_r     <= {CNT_W{1'b0}};
                        play_tick_r  <= {TICK_W{1'b0}};
                        loop_len_r   <= {TICK_W{1'b0}};
                        rec_tick_r   <= {TICK_W{1'b0}};
                        full_r       <= 1'b0;
                        tick_pend_r  <= 1'b0;
                        rd_adv_r     <= 1'b0;
                    end else if (leave_to_r == LEAVE_REC) begin
                        //  ⭐⭐ 重录（⭐ 回放中按了 `R`）⇒ ⭐ 补发完再开始录 ✅
                        //     📌 与"直接 `rec_req` 进 `ST_REC`"那段**完全一致** ✅
                        //  ⭐⭐ 2026-09-30（`T41` ①）：⭐ **这条路径也要对齐小节**
                        //   🔴 **为什么**：⭐ 这是 `ST_REC` 的**第二个入口** ——
                        //      ⚠️ 只改 `br_rec_w` 那一处 ⇒ 🔴 "**回放中按 `R` 重录**"
                        //      这条仍然在小节中间起录 ⇒ ⭐ 照样越跑越偏 ✅
                        //      （📌 与 `on_open_r` 那次"两个入口都要改"是**同一个教训**）✅
                        if (rec_align_w) begin
                            //  ⭐ 网格可用 ⇒ 先"待起录"（⭐ ⛔ 不清 `cnt_r`：⭐ 理由同 `br_rec_w`）
                            state <= ST_RECPEND;
                        end else begin
                        state        <= ST_REC;
                        cnt_r        <= {CNT_W{1'b0}};
                        rec_tick_r   <= {TICK_W{1'b0}};
                        rd_ptr_r     <= {CNT_W{1'b0}};
                        play_tick_r  <= {TICK_W{1'b0}};
                        full_r       <= 1'b0;
                        close_scan_r <= 4'd0;
                        rec_bar_tick_r <= {TICK_W{1'b0}};
                        rec_bar_cnt_r  <= {CNT_W{1'b0}};
                        rec_aligned_r  <= grid_ok_r && transport_i;
                        play_aligned_r <= 1'b0;
                        //  ⭐⭐ 2026-09-29 修 bug②：⭐ **起录必须清 `on_open_r`** ✅
                        //   ⚠️ `ST_REC` 有【两个】入口（⭐ 这里是"回放中按 `R`"那条）
                        //      ⇒ ⭐ 两处都要清，⭐ 否则这条路径仍然会漏 ✅
                        //      （⭐ 完整理由见上方 `br_rec_w` 那段）✅
                        on_open_r    <= 16'd0;
                        end
                    end else begin
                        //  ⭐ 只是停播 ⇒ ⭐ 保留录音，⭐ 回到 HOLD（⭐ 下次 `L` 从头播）
                        state        <= ST_HOLD;
                        rd_ptr_r     <= {CNT_W{1'b0}};
                        play_tick_r  <= {TICK_W{1'b0}};
                        tick_pend_r  <= 1'b0;
                        rd_adv_r     <= 1'b0;
                    end
                end else begin
                    close_scan_r <= close_scan_r + 4'd1;
                end
            end else if (state == ST_HOLD) begin
                // ── 播放（⭐ 连续吐事件，⛔ 不用"每 tick 查一遍"）──────────
                if (playing) begin
                    //  ⭐ 2026-09-29：⭐ 记住"上一拍在播" ⇒ ⭐ 下一拍的落沿就是"停播" ✅
                    play_en_d_r <= 1'b1;
                    //  ⭐ `e_ready` ⇒ 本拍的数据**确实**属于本 tick
                    //     （⭐ 同步读 ⇒ 数据比指针晚一拍 ⇒ 用 `rd_adv_r` 挡掉那一拍）
                    if (e_ready) begin
                        play_valid_o <= 1'b1;
                        play_axis_o  <= e_axis;
                        play_inc_o   <= e_inc;
                        play_vel_o   <= e_vel;
                        play_kind_o  <= e_kind;
                        //  ⭐⭐ 2026-09-29 新增：⭐ **吐【录制时】的音色**（⭐ ⛔ 不是现在的 `live_timbre_i` ✅）
                        //   📌 这是本功能的**唯一**行为改动点 ✅
                        play_timbre_o       <= e_tbr;
                        play_timbre_valid_o <= 1'b1;
                        //  ⭐⭐ 2026-09-29 修 bug①：⭐ **维护"哪些轴还响着"**（⭐ 补发用）
                        //     ⭐ `note_on` ⇒ 置位 · ⭐ `note_off` ⇒ 清零 ✅
                        if (e_kind == KIND_ON)
                            play_active_r[e_axis] <= 1'b1;
                        else if (e_kind == KIND_OFF)
                            play_active_r[e_axis] <= 1'b0;

                        //  ══════════════════════════════════════════════════
                        //  ⭐⭐ 2026-09-29 新增：⭐ **插值的装载 / 收工**
                        //   ⭐ 起音 ⇒ 装载"起点 + 终点 + tick 跨度 + 每 tick 步长"，
                        //      ⭐ 并打开 `ramp_mask`（⭐ 起点==终点时不开 ⇒ ⛔ 不白发脉冲 ✅）
                        //   ⭐ 松手 ⇒ **无条件关掉**（⭐ 兜底：⛔ 不许插值越过音符末尾 ✅）
                        //   ⚠️ `ep_word_r` 与 `e_word_r` **同地址同拍** ⇒
                        //      ⭐ 这里读到的 `ep_*` 就是**本 `note_on` 的终点** ✅
                        //   ⚠️ 若没有终点（`ep_valid=0`：⭐ 该 `note_on` 的 `note_off`
                        //      因录满被丢）⇒ ⭐ **不插值**（⭐ 退化成"只带起点"的旧行为，
                        //      ⛔ 不猜、⛔ 不拿陈旧数据 ✅）
                        //  ══════════════════════════════════════════════════
                        if (e_kind == KIND_OFF) begin
                            ramp_mask[e_axis] <= 1'b0;
                        end else begin
                            ramp_inc[e_axis] <= e_inc;
                            ramp_vel[e_axis] <= e_vel;
                            if (ep_valid) begin
                                rtgt_inc[e_axis]  <= ep_inc;
                                rtgt_vel[e_axis]  <= ep_vel;
                                rend_tick[e_axis] <= ep_tick;
                                ramp_mask[e_axis] <= (ep_inc != e_inc)
                                                  || (ep_vel != e_vel);
                            end else begin
                                ramp_mask[e_axis] <= 1'b0;
                            end
                        end
                        rd_ptr_r     <= rd_ptr_r + 1'b1;
                        //  ⭐ 指针动了 ⇒ ⚠️ 下一拍 `e_word_r` 还是旧地址的数据
                        rd_adv_r     <= 1'b1;
                    end else begin
                        rd_adv_r     <= 1'b0;
                    end

                    //  ⭐ tick 脉冲 ⇒ 记下"要推进"，⭐ 但**必须等本 tick 排空**
                    if (tick_i)
                        tick_pend_r <= 1'b1;

                    if (tick_pend_r && rd_drained) begin
                        play_tick_r <= play_tick_nxt;
                        tick_pend_r <= 1'b0;
                        //  ⭐⭐ 2026-09-29 新增：⭐ **每个 tick 让插值引擎扫一轮** ✅
                        //     ⚠️ 本行在引擎那段【之后】⇒ ⭐ 后写覆盖先写 ⇒
                        //        ⭐ 即使引擎同拍刚扫完（`ramp_go <= 0`），本拍仍能重新置 1 ✅
                        ramp_go     <= 1'b1;
                        if (wrap_now) begin
                            rd_ptr_r <= {CNT_W{1'b0}};   // ⭐ 回绕 ⇒ 读指针归零
                            rd_adv_r <= 1'b1;            // ⭐ 指针动了 ⇒ 数据晚一拍
                            //  ⭐ 回绕 ⇒ ⭐ 插值状态清零（⭐ 新一圈从头装载，⛔ 不留残余 ✅）
                            ramp_mask <= 16'd0;
                        end
                    end
                end else begin
                    //  ⚠️ 没在播（`play_en_i=0` 或 `transport_i=0`）⇒ ⭐ 读指针归零
                    //     ⇒ ⭐ 下次从头播（⭐ 保证"每次起播都对齐"）
                    //  ⭐⭐ 2026-09-29 修 bug①：⭐ **"停播"也是同一个缺陷类** ——
                    //     ⚠️ 若停播时还有音在响 ⇒ ⭐ 那些音也收不到 `note_off` ⇒ **挂音** ✅
                    //     ⇒ ⭐ 检出 `play_en` 的**下降沿** ⇒ ⭐ 走同一个 `ST_LCLOSE` 补发
                    //        （⭐ `clr_after_r = 0` ⇒ **只补发，⛔ 不清空**）✅
                    if (play_en_d_r && (play_active_r != 16'd0)) begin
                        close_mask_r <= play_active_r;
                        close_scan_r <= 4'd0;
                        leave_to_r   <= LEAVE_HOLD;   // ⭐ 只是停播 ⇒ ⛔ 不清空
                        state        <= ST_LCLOSE;
                    end
                    play_en_d_r <= 1'b0;
                    rd_ptr_r    <= {CNT_W{1'b0}};
                    play_tick_r <= {TICK_W{1'b0}};
                    tick_pend_r <= 1'b0;
                    rd_adv_r    <= 1'b0;
                end
            end
        end
    end

    // ── 观测输出 ────────────────────────────────────────────────────────────
    //  ⚠️ `evt_cnt_flat_o` 每层 16 bit ⇒ ⭐ 本版 `LAYERS=1`、`CNT_W=16` ⇒ ⭐ 恰好对齐
    //     （⭐ 由上面的 `PARAM_OK` 自检保证；⛔ 不用 `{{0{...}}}` 那种零宽复制 —— 非法）
    //  ⭐⭐ 2026-09-30（`T41`）：⭐ **"待起录"也算"该层活着"** ——
    //     🔴 `K-106` 纪律：⭐ 任何"用户已经按了、但还没生效"的中间态都必须**可观测**
    //     （⭐ 否则"按了 R 没反应"看起来就像**死机**，⭐ 而上板时它是**等小节**）✅
    assign layer_state_o  = {(state == ST_REC) || (state == ST_RECPEND) || playing};
    //  ⭐⭐ 2026-10-14：⭐ **"已武装、还没到小节线"**（⭐ 见端口处长注释 ✅）
    assign rec_pending_o  = (state == ST_RECPEND);
    assign evt_cnt_flat_o = cnt_r;
    assign full_o         = {full_r};
    assign drop_cnt_o     = drop_r;

endmodule

`default_nettype wire
