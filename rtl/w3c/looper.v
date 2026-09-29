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
//  ⭐⭐ T37 的范围（⭐ ⛔ 不是全部 Looper）：
//     ✅ 单层（`LAYERS = 1`）录制 + 按 `tick` 重放 + `clear`
//     ✅ **停录时【补发 `note_off`】**（⭐ 否则 loop 里那个音**永不停止**
//        —— ⭐ 上游 §2 明确写这是 looper **最容易犯的错**）
//     ✅ 可观测：`evt_cnt` / `full` / `drop_cnt` / `overflow`（⭐ `K-106`：⛔ 不许静默失效）
//     ⛔ **不做**（⭐ 留给后续）：多层（`T40`）· 与手弹叠加（`T39`，要扩 `evt_merge`）
//        · 对齐小节（`T41`）· `note_manager` 的 voice 预留
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

    // ══════════════════════════════════════════════════════════════════════
    // ③ ⭐ 重放输出（⭐ → 源 A，⭐ 单周期脉冲）
    // ══════════════════════════════════════════════════════════════════════
    output reg                   play_valid_o,
    output reg  [AXIS_W-1:0]     play_axis_o,
    output reg  [PHASE_W-1:0]    play_inc_o,
    output reg  [VEL_W-1:0]      play_vel_o,
    output reg  [KIND_W-1:0]     play_kind_o,

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
    //  ⚠️ Verilog-2001 **不支持数组端口**（⭐ 接口文档 §2.1 第 2 条）
    //     ⇒ ⭐ 必须**展平成一个向量**（每层 16 bit）
    output wire [LAYERS*16-1:0]  evt_cnt_flat_o,
    output wire [LAYERS-1:0]     full_o,          // ⭐ 该层录满（⭐ 再录会丢）
    output wire [15:0]           drop_cnt_o,      // ⭐ 丢了几个事件（**饱和**，⛔ 不回绕）
    output reg                   overflow_o       // ⭐ sticky（⭐ 复位才清）
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
    localparam integer EW = TICK_W + KIND_W + AXIS_W + PHASE_W + VEL_W;
    localparam integer O_VEL  = 0;
    localparam integer O_INC  = O_VEL  + VEL_W;
    localparam integer O_AXIS = O_INC  + PHASE_W;
    localparam integer O_KIND = O_AXIS + AXIS_W;
    localparam integer O_TICK = O_KIND + KIND_W;

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

    // ⭐ 事件类型编码（⭐ 与 `note_manager.note_kind_i` 一致）
    localparam [KIND_W-1:0] KIND_ON  = {KIND_W{1'b0}};   // 0 = note_on
    localparam [KIND_W-1:0] KIND_OFF = {{(KIND_W-1){1'b0}}, 1'b1}; // 1 = note_off

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
    reg [EW-1:0] e_word_r;
    always @(posedge clk_i) e_word_r <= mem[rd_ptr_r];

    //  ⭐ 上一拍**刚推进过**指针 ⇒ ⚠️ 本拍的 `e_word_r` 还是**旧地址**的数据
    reg          rd_adv_r;

    wire [TICK_W-1:0]  e_tick = e_word_r[O_TICK +: TICK_W];
    wire [KIND_W-1:0]  e_kind = e_word_r[O_KIND +: KIND_W];
    wire [AXIS_W-1:0]  e_axis = e_word_r[O_AXIS +: AXIS_W];
    wire [PHASE_W-1:0] e_inc  = e_word_r[O_INC  +: PHASE_W];
    wire [VEL_W-1:0]   e_vel  = e_word_r[O_VEL  +: VEL_W];

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
    wire playing = (state == ST_HOLD) && play_en_i[0] && transport_i && (cnt_r != {CNT_W{1'b0}});

    //  ⭐ 循环回绕：走到 `loop_len_r` 就回 0
    wire [TICK_W-1:0] play_tick_nxt = (play_tick_r + 1'b1 >= loop_len_r)
                                    ? {TICK_W{1'b0}} : (play_tick_r + 1'b1);
    wire wrap_now = (play_tick_r + 1'b1 >= loop_len_r);

    //  ⭐ 停录时还有哪些轴**没收到 `note_off`**（⭐ 从 `live_*` 维护）
    integer ai;
    always @(posedge clk_i or negedge rst_n_i) begin
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
            play_valid_o <= 1'b0;
            play_axis_o  <= {AXIS_W{1'b0}};
            play_inc_o   <= {PHASE_W{1'b0}};
            play_vel_o   <= {VEL_W{1'b0}};
            play_kind_o  <= KIND_OFF;
            overflow_o   <= 1'b0;
        end else begin
            //  ⭐ `play_valid_o` 是**单周期脉冲** ⇒ 默认拉低（⭐ 冻结表 §〇 约定 4）
            play_valid_o <= 1'b0;

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
            if (((clear_req_i[0]) || (rec_req_i[0] && (state != ST_REC)))
                && (state == ST_HOLD) && (play_active_r != 16'd0)) begin
                //  ⭐⭐ **唯一出口**：⭐ 先逐轴补发，⭐ 补完按 `leave_to_r` 去对应状态 ✅
                close_mask_r <= play_active_r;
                close_scan_r <= 4'd0;
                leave_to_r   <= clear_req_i[0] ? LEAVE_IDLE : LEAVE_REC;
                state        <= ST_LCLOSE;
            end else if (clear_req_i[0]) begin
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
            end else if (rec_req_i[0] && (state != ST_REC)) begin
                //  ⭐ 开始录制：⭐ 从**此刻**起算 tick（⭐ 与 `beat_gen` 的 tick 对齐）
                state        <= ST_REC;
                cnt_r        <= {CNT_W{1'b0}};
                rec_tick_r   <= {TICK_W{1'b0}};
                rd_ptr_r     <= {CNT_W{1'b0}};
                play_tick_r  <= {TICK_W{1'b0}};
                full_r       <= 1'b0;
                close_mask_r <= 16'd0;
                close_scan_r <= 4'd0;
            end else if (state == ST_REC) begin
                // ── 录制中 ────────────────────────────────────────────────
                if (stop_req_i[0]) begin
                    //  ⭐ 停录：⭐ 记下循环长度 ⇒ ⭐ 进入 `ST_CLOSE` **补发未闭合的 `note_off`**
                    loop_len_r   <= rec_tick_r;
                    state        <= ST_CLOSE;
                    close_scan_r <= 4'd0;
                end else begin
                    if (tick_i)
                        rec_tick_r <= rec_tick_r + 1'b1;

                    if (live_valid_i) begin
                        if (cnt_r < EVT_MAX_V) begin
                            mem[cnt_r] <= {rec_tick_r, live_kind_i, live_axis_i,
                                           live_inc_i, live_vel_i};
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
            end else if (state == ST_CLOSE) begin
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
                        mem[cnt_r] <= {(loop_len_r == {TICK_W{1'b0}})
                                       ? {TICK_W{1'b0}} : (loop_len_r - 1'b1),
                                       KIND_OFF, close_scan_r[AXIS_W-1:0],
                                       {PHASE_W{1'b0}}, {VEL_W{1'b0}}};
                        cnt_r <= cnt_r + 1'b1;
                    end else begin
                        full_r     <= 1'b1;
                        overflow_o <= 1'b1;
                        if (drop_r != 16'hFFFF)
                            drop_r <= drop_r + 16'd1;
                    end
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
                        state        <= ST_REC;
                        cnt_r        <= {CNT_W{1'b0}};
                        rec_tick_r   <= {TICK_W{1'b0}};
                        rd_ptr_r     <= {CNT_W{1'b0}};
                        play_tick_r  <= {TICK_W{1'b0}};
                        full_r       <= 1'b0;
                        close_scan_r <= 4'd0;
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
                        //  ⭐⭐ 2026-09-29 修 bug①：⭐ **维护"哪些轴还响着"**（⭐ 补发用）
                        //     ⭐ `note_on` ⇒ 置位 · ⭐ `note_off` ⇒ 清零 ✅
                        if (e_kind == KIND_ON)
                            play_active_r[e_axis] <= 1'b1;
                        else if (e_kind == KIND_OFF)
                            play_active_r[e_axis] <= 1'b0;
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
                        if (wrap_now) begin
                            rd_ptr_r <= {CNT_W{1'b0}};   // ⭐ 回绕 ⇒ 读指针归零
                            rd_adv_r <= 1'b1;            // ⭐ 指针动了 ⇒ 数据晚一拍
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
    assign layer_state_o  = {(state == ST_REC) || playing};
    assign evt_cnt_flat_o = cnt_r;
    assign full_o         = {full_r};
    assign drop_cnt_o     = drop_r;

endmodule

`default_nettype wire
