`timescale 1ns/1ps
// T15 semantic controller.  It deliberately owns the distinction between
// selection events and playing events so downstream voice allocation receives
// one unambiguous note_on/note_off/pluck stream.
`default_nettype none

module play_mode_ctrl #(
    parameter integer AXIS_W  = 4,
    parameter integer DEPTH_W = 12
) (
    input  wire                   clk_i,
    input  wire                   rst_n_i,
    input  wire                   fretboard_mode_i, // 0=keyboard, 1=fretboard

    input  wire                   axis_valid_i,
    input  wire [AXIS_W-1:0]      axis_i,
    input  wire [1:0]             axis_kind_i,      // 0=on, 1=off
    input  wire [DEPTH_W-1:0]     axis_depth_i,
    input  wire                   pluck_valid_i,
    input  wire                   pluck_up_i,       // direction retained at capture seam
    //  ══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-10-15：⭐ **`held_mask` 的清零脉冲**（⭐ 修"脏位 ⇒ 一次拨弦出两个音"）✅
    //
    //  🔴 **缺陷（⭐ 逐行证据，⛔ 不是推断）**：
    //     · ⭐ `event_extract.v:396-403`：⭐ `enable_i === 1'b0` 时
    //       **静默清 `key_on[]`/`refr[]`，⛔ 不发任何事件** ✅
    //     · ⭐ `top.v:4468` 把 `enable_i` 接的是 `at_en_ready`
    //       （⭐ `top.v:2985-2991` = `at_done` 打 16 拍的移位链）
    //     · ⭐ 串口 `'T'`（重 tare）⇒ `calib_autotare.v:310-321` 回 `ST_SWEEP`
    //       ⇒ `done_o` 落 0 ⇒ ⭐ `at_en_ready` 落 0 ✅
    //     ⇒ 🔴 **`'T'` 期间【按住的】任何轴**：⭐ 它的 `KIND_OFF` **永远不会来**
    //        （⭐ `key_on[]` 已被清 ⇒ `:437-438` 的松手分支根本不进）
    //     ⇒ ⭐ 而本模块的 `held_mask` **只由 `KIND_OFF` 清**（⭐ `:188-189`）
    //     ⇒ 🔴 **`held_mask` 里留下一个【永久脏位】**（⭐ 直到复位）✅
    //
    //  🔴 **后果**：⭐ 一次拨弦 ⇒ 发 `popcount(held_mask)` 条 `PLUCK`
    //     ⇒ ⭐ **"一次拨弦出两个音"**（⭐ 用户上板实测症状）✅
    //     📌 ⭐ `HEAD` 版**不会**放大（⭐ 旧版一次只发一个轴 ⇒ 只是"响的是别的音"）
    //        ⇒ ⭐ **这个放大正是"一次拨弦 ⇒ 逐轴发 N 条"引入的** ✅
    //
    //  ✅ **修法（方向 A，⭐ 代价最小、自愈、不踩 `T38`）**：
    //     ⭐ 把 `enable_i` 的**掉沿**引到这里 ⇒ ⭐ **同拍清 `held_mask`** ✅
    //
    //  ⭐⭐ **为什么自愈、⛔ 不丢键**（⭐ 关键，⛔ 别改成"补发 OFF"）：
    //     ⭐ `event_extract.v:419-435` 的 ON 分支条件是
    //        `key_on==0 && pos>=TRIG_TH`，⭐ 而 `key_on` 已被 `:399-402` 清零
    //     ⇒ ⭐ **仍然按着的键会在 1 帧（500 µs）内重新发一次 ON**
    //     ⇒ ⭐ `held_mask` **自动重建** ✓（⭐ 于是"按住不放 ⇒ 下一次拨弦照常出声"）
    //     ⛔ **不改 `event_extract.v`（方向 B）**：⭐ 在那里补发 OFF 会让它的
    //        `FIFO_D=4` 溢出（⭐ 一次掉沿最多 16 个轴 ⇒ 远超深度 4）⇒ 代价高 ✗
    //
    //  🔴🔴 **2026-10-15（⭐ 鹰眼核实）**：⭐ 上面"自愈 ON 让 `held_mask` 自动重建"
    //     只保证**下一次拨弦**照常出声；🔴 而 `keyboard_held[]`（⭐ **"正在响"**的位图）
    //     **不会**被自愈 ON 清掉 ⇒ ⭐ 掉沿前已响、掉沿期间被松开的轴
    //     ⇒ 🔴 **永久挂音**（⭐ 全部 OFF 出口都要求**先收到 OFF 事件**）
    //     ⇒ ⭐ 修法：⭐ 由本模块**自己的** `off_drain` 小 FSM **逐拍补发 OFF**
    //        （⭐ 走 `evt_*` 单事件口 ⇒ ⛔ 不经 `event_extract` 的 `FIFO_D=4` ⇒ 挤不爆）✅
    //        📌 **⛔ 不许改成"直接清 `keyboard_held`"** —— ⭐ 那会让 OFF 出口失效 ⇒ 同样挂音 ✅
    //
    //  ⚠️ **副作用（⭐ 如实记录 · ⭐ 2026-10-15 限定模式）**：⭐ **仅键盘模式**下，
    //     那个已经响着的 voice 会走 `same_hit`（⭐ `note_manager.v:720-722`）**重触发**一次
    //     ⇒ ⭐ 一次极短的再起音（⭐ 听感近不可闻）✅
    //     🔴 **指板模式下【不成立】**：⭐ 重发的 `ON` 在本模块被**吞掉**
    //        （⭐ 指板分支的 ON 只写 `selected_*`，⛔ **不抬 `evt_valid_o`**）
    //        ⇒ ⭐ `note_manager` **根本收不到**这条 ON ⇒ ⛔ 没有 `same_hit` 重触发 ✅
    //     📌 键盘模式的 ON 是**直通**的（⭐ 抬 `evt_valid_o`）⇒ ⭐ 才成立 ✅
    //
    //  ✅ **不踩 `T38`**：⭐ 清 `held_mask` 只影响"下一次拨弦发几条"，
    //     ⛔ **不影响 `note_off`** —— ⭐ OFF 的出口是 `keyboard_held[]` 那条通路
    //     （⭐ `:312-325`），⭐ 与 `held_mask` 是**两套位图** ✓
    //
    //  📌 ⭐ **Z-safe**（⭐ 与 `event_extract.enable_i` 同口径）：⭐ 只认**明确的 1**
    //     ⇒ ⭐ 老 tb（⛔ 不接该端口 ⇒ 悬空 `z`）行为**逐位不变** ✅
    //  ══════════════════════════════════════════════════════════════════════
    input  wire                   axis_clr_i,
    input  wire                   slide_active_i,
    input  wire [AXIS_W-1:0]       slide_axis_i,

    output reg                    evt_valid_o,
    output reg  [AXIS_W-1:0]      evt_axis_o,
    output reg  [1:0]             evt_kind_o,       // 0=on, 1=off, 2=pluck
    output reg  [DEPTH_W-1:0]     evt_depth_o
);
    localparam [1:0] KIND_ON    = 2'd0;
    localparam [1:0] KIND_OFF   = 2'd1;
    localparam [1:0] KIND_PLUCK = 2'd2;

    reg                  selected_valid;
    reg [AXIS_W-1:0]     selected_axis;
    reg [DEPTH_W-1:0]    selected_depth;
    reg                  gate_valid;
    reg [AXIS_W-1:0]     gate_axis;
    localparam integer AXIS_COUNT = (1 << AXIS_W);
    reg [AXIS_COUNT-1:0] keyboard_held;
    reg [AXIS_COUNT-1:0] held_mask;
    reg [DEPTH_W-1:0] axis_depth [0:AXIS_COUNT-1];
    //  ══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-10-15：⭐ **一次拨弦 ⇒ 触发【所有】按住的轴（和弦）** ✅
    //
    //  🔴🔴 **这是【经用户授权】的契约变更**（⭐ 用户 2026-10-15 上板实测后拍板）：
    //     · ⭐ **旧语义（`P0-22` ①）**：⭐ 一次拨弦**只触发一个**轴
    //       （⭐ 用 `rot_q` 在 `held_mask` 上**轮转扫、命中即停**）
    //       ⇒ ⭐ 松**任意**轴 ⇒ 放掉"**正在响的那一个**"（⭐ 因为只有一个 `gate_axis`）
    //       ⇒ 🔴 代价：⭐ **"一次拨弦出和弦"做不到**（⭐ 原取舍注释在
    //          `tb/w3a/tb_play_mode_ctrl.sv` 的 `:165-178`，⭐ 它明文写着
    //          "若将来要一次拨弦出和弦 ⇒ 必须先重谈 `P0-22` ① 的契约，⛔ 不能偷偷改"）
    //     · ⭐ **新语义（⭐ 本次用户授权后生效）**：⭐ 一次拨弦把 `held_mask` 里
    //       **所有**轴**逐拍**各发一条 `PLUCK`（⭐ `evt_*` 是**单事件口**
    //       ⇒ ⭐ N 个轴必须 N 拍，⛔ 不能一拍塞两条）；
    //       ⭐ 松某轴 ⇒ **只放掉该轴自己的音**（⭐ `keyboard_held[]` 逐轴配对），
    //       ⭐ 其余轴的音**继续响** ⇒ ⭐ **和弦** ＋ ⭐ **滑音**（两个轴同时按住）都能测 ✅
    //     📌 ⭐ **用户原话**：*"现在指板模式还是只有一个音，所以滑音也测不出来"*
    //        ⇒ ⭐ **滑音需要两个轴同时按住** ⇒ ⛔ 单轴永远测不出滑音 ✅
    //
    //  📌 **为什么这个改动现在才做得了**（⭐ 上个 agent 已逐行核过，⛔ 不推翻）：
    //     ⭐ `keyboard_held[]` 位图（⭐ `:82` 声明 / `:284` 拨弦置位 /
    //        `:310-331` 逐轴释放 —— ⭐ **行号为当前工作区版**）
    //     **本来就在做逐轴释放** ⇒ ⭐ 当初逼出"一次拨弦一个轴"的那个 `P0-22` ①
    //     冲突**在结构上已经消解** ⇒ ⭐ 剩下的只是让拨弦分支**吐 N 条事件** ✅
    //
    //  ⛔ **一个字都没动 `note_manager`**（⭐ 理由）：
    //     ⭐ `note_manager.v:869-875` 把"每个 `(axis,src)` 同时最多 1 个 voice"
    //     写成**显式设计不变量**（`same_hit`）⇒ ⚠️ 动它风险极高（`K-56` 同族）；
    //     ⭐ 而**指板是"一键一轴"**（⭐ 16 键 16 轴，`axis_map.v:541` 是扁平 16 项查表）
    //     ⇒ ⭐ 各轴互不相同 ⇒ ⛔ **本来就不需要动** ✅
    //  ──────────────────────────────────────────────────────────────────────
    //  ⭐ 实现：多拍状态机（⭐ `evt_*` 每拍只能发一条 ⇒ 逐拍发）
    //     · `pluck_todo` = 本次拨弦**还没发**的轴位图
    //       （⭐ 在拨弦那一拍**快照** `held_mask` ⇒ ⭐ 之后新按下的轴**不**算进这一拨）
    //     · `pluck_run`  = FSM 进行中
    //     · 每拍发 `pluck_todo` 里**最低**的那一位，⭐ 然后清掉那一位；⭐ 清空即收尾
    //     · ⭐ `axis_valid_i` 有效时**避让**（⭐ 与 `pending_pluck` **同级**：
    //         ⚠️ **推迟**到空拍再发）✅
    //       🔴 **2026-10-15 降调（⭐ 鹰眼核实）**：⭐ 原写"⛔ **不丢事件**"是**过强表述** ——
    //          ⚠️ `pending_pluck` **只有 1 位** ⇒ ⭐ FSM 期间来 **≥2 次**拨弦会被**合并成 1 轮**
    //          ⇒ ⭐ **确实会丢**（⭐ 不是"只推迟"）✅
    //          📌 **生产上到不了**：⭐ `async_pluck_capture` 有 **30 ms** 不应期
    //             ⇒ ⭐ 而和弦 FSM 最长 **16 拍**（⭐ 微秒级）⇒ ⭐ 物理不可达 ✅
    //          ⚠️ **但⛔ 不许把它当契约** —— ⭐ 本模块的保证只有
    //             "**1 次**拨弦不丢"，⛔ **不是**"任意多次都不丢" ✅
    reg                    pending_pluck;
    reg                    pluck_run;
    reg [AXIS_COUNT-1:0]   pluck_todo;
    reg [AXIS_W-1:0]       pluck_pick;
    reg                    pluck_pick_valid;
    integer pi, ri;

    //  ══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-10-15（⭐ 鹰眼核实 · **缺陷 3**）：⭐ **`axis_clr` 掉沿 ⇒ 逐拍补发 OFF** ✅
    //
    //  🔴 **缺陷（⭐ 逐行证据）**：⭐ 本模块**只修了 `held_mask`**（⭐ `:held_mask` 那段），
    //     🔴 **没修 `keyboard_held`** ⇒ ⭐ **永久挂音** ✅
    //     序列：⭐ 按住轴 5 ⇒ 拨响（⭐ `keyboard_held[5]=1`）
    //        ⇒ 按 `'T'`（⭐ `at_en_ready` 落 ⇒ `axis_clr_i` 起）
    //        ⇒ `event_extract.v` 清 `key_on[5]` 且**不发 OFF**
    //        ⇒ ⭐ **在使能为 0 期间松开轴 5** ⇒ ⭐ 使能回来后 `pos<TRIG_TH`
    //        ⇒ 🔴 **自愈 ON 也不发** ⇒ ⭐ `keyboard_held[5]` **永久为 1**
    //        ⇒ 🔴 而**全部** OFF 出口（⭐ `:deferred_off` / `:keyboard` /
    //           `:keyboard_held[axis_i]` / `:gate_valid` 四条）都要求
    //           **先收到一条 OFF 事件** ⇒ 🔴 **那条 voice 永久挂音** ✅
    //
    //  ✅ **修法**：⭐ 掉沿那一拍把 `keyboard_held` **快照**进 `off_drain_todo`
    //     ⇒ ⭐ 之后**逐拍**（⭐ 每拍 1 条）走 `evt_*` **单事件口**补发 `KIND_OFF`
    //     ⇒ ⭐ 最多 16 拍 ⇒ ⭐ 补完即止 ✅
    //
    //  ⛔ **为什么不直接清 `keyboard_held`**：⭐ 清掉会让**四条 OFF 出口全部失效**
    //     （⭐ 它们都要"`keyboard_held[axis]` 仍置位"或"收到 OFF"才动作）
    //     ⇒ 🔴 **同样挂音** ⇒ ⛔ 不是修法 ✅
    //  ⛔ **为什么不在 `event_extract` 里同拍补 16 条 OFF**：⭐ 会挤爆 `FIFO_D=4` ✅
    //  ⭐ **逐拍补挤不爆**：⭐ `evt_*` 是**本模块自己的口**，⛔ **不经那个 FIFO** ✅
    //
    //  📌 **优先级**：⭐ 本 FSM 只要求 `!axis_valid_i && !pluck_valid_i`
    //     （⭐ ⛔ **不吞脉冲**：⭐ `pluck_valid_i` 是**单拍**脉冲，⭐ 被吞就是丢拨弦）
    //     ⇒ ⭐ 轴事件/拨弦**永远优先**，⭐ 补 OFF 只在空拍走 ✅
    //     ⚠️ **它会推迟拨弦最多 16 拍**（⭐ 只发生在 `axis_clr` 掉沿那一瞬，
    //        ⭐ 16 拍 ≪ 1 µs ⇒ ⭐ 听感不可达）✅
    //  📌 **Z-safe**：⭐ `off_drain_todo` **只在 `axis_clr_i === 1'b1` 时装载**
    //     ⇒ ⭐ 老 tb（⛔ 不接该端口 ⇒ 悬空 `z`）**永远不装载** ⇒ 行为逐位不变 ✅
    //  ══════════════════════════════════════════════════════════════════════
    reg  [AXIS_COUNT-1:0]  off_drain_todo;
    reg  [AXIS_W-1:0]      off_drain_pick;
    reg                    off_drain_pick_valid;
    integer di;
    // ⭐ `off_drain_pick` 的独热（⭐ 用来把这一位从 `off_drain_todo` 里清掉）
    wire [AXIS_COUNT-1:0] off_drain_onehot = {{(AXIS_COUNT-1){1'b0}}, 1'b1} << off_drain_pick;
    wire [AXIS_COUNT-1:0] off_drain_rest   = off_drain_todo & ~off_drain_onehot;

    // ⭐ 本拍要服务的位图：⭐ FSM 进行中用 `pluck_todo`，否则用（⭐ 快照源）`held_mask`
    wire [AXIS_COUNT-1:0] pluck_work = pluck_run ? pluck_todo : held_mask;
    // ⭐ `pluck_pick` 的独热（⭐ 用来把这一位从 `pluck_todo` 里清掉）
    wire [AXIS_COUNT-1:0] pluck_onehot = {{(AXIS_COUNT-1){1'b0}}, 1'b1} << pluck_pick;
    wire [AXIS_COUNT-1:0] pluck_rest   = pluck_work & ~pluck_onehot;
    // ⭐ 本拍**启动**一次新拨弦：⭐ 无轴事件 ＋ 无 FSM 在跑 ＋ 有轴按住
    //  🔴 **2026-10-15（⭐ 缺陷 2）**：⭐ 加 `axis_clr_i !== 1'b1` 屏蔽 ——
    //     ⚠️ 否则掉沿那一拍 `held_mask` 还是**清零前的旧值**（⭐ 非阻塞赋值**本拍读旧值**）
    //     ⇒ 🔴 会**按脏快照起跑一轮** ✅
    //  📌 用 `!==`（⛔ 不是 `===`）⇒ ⭐ 悬空 `z` 时**不屏蔽** ⇒ ⭐ 老 tb 行为不变 ✅
    wire pluck_begin = !pluck_run && !axis_valid_i && (axis_clr_i !== 1'b1)
                       && (pluck_valid_i || pending_pluck)
                       && (held_mask != {AXIS_COUNT{1'b0}});
    // ⭐ 本拍**真的**发一条 `PLUCK`：⭐ FSM 在跑、或本拍启动；⭐ 且**必须避让** `axis_valid_i`
    //  🔴 **2026-10-15（⭐ 缺陷 2）**：⭐ 同样加 `axis_clr_i` 屏蔽 ——
    //     ⚠️ `pluck_run` 的清零是**非阻塞**的 ⇒ ⭐ 掉沿那一拍它**仍是 1**
    //     ⇒ 🔴 不屏蔽就会**从旧 `pluck_todo` 里再发一条** ✅
    wire pluck_emit_now = !axis_valid_i && (axis_clr_i !== 1'b1)
                          && (pluck_run || pluck_begin) && pluck_pick_valid;

    always @(*) begin
        pluck_pick = {AXIS_W{1'b0}};
        pluck_pick_valid = 1'b0;
        for (pi=0; pi<AXIS_COUNT; pi=pi+1) begin
            if (!pluck_pick_valid && pluck_work[pi]) begin
                pluck_pick = pi[AXIS_W-1:0];
                pluck_pick_valid = 1'b1;
            end
        end
    end

    // ⭐ 补 OFF 的仲裁（⭐ 与 `pluck_pick` **同一写法**：⭐ 取**最低**置位轴 ⇒ ⭐ 顺序确定）
    always @(*) begin
        off_drain_pick = {AXIS_W{1'b0}};
        off_drain_pick_valid = 1'b0;
        for (di=0; di<AXIS_COUNT; di=di+1) begin
            if (!off_drain_pick_valid && off_drain_todo[di]) begin
                off_drain_pick = di[AXIS_W-1:0];
                off_drain_pick_valid = 1'b1;
            end
        end
    end
    reg deferred_off;
    reg [AXIS_W-1:0] deferred_axis;
    wire slide_holds_gate = (slide_active_i === 1'b1) && (slide_axis_i == gate_axis);
    wire slide_holds_axis = (slide_active_i === 1'b1) && (slide_axis_i == axis_i);

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            selected_valid <= 1'b0;
            selected_axis  <= {AXIS_W{1'b0}};
            selected_depth <= {DEPTH_W{1'b0}};
            gate_valid     <= 1'b0;
            gate_axis      <= {AXIS_W{1'b0}};
            keyboard_held  <= {AXIS_COUNT{1'b0}};
            held_mask <= 0;
            pending_pluck <= 0;
            pluck_run <= 1'b0;                       // ⭐ 多拍拨弦 FSM（⭐ 见上）
            pluck_todo <= {AXIS_COUNT{1'b0}};
            off_drain_todo <= {AXIS_COUNT{1'b0}};    // ⭐ 补 OFF FSM（⭐ 见上）
            for (ri=0; ri<AXIS_COUNT; ri=ri+1) axis_depth[ri] <= 0;
            deferred_off <= 1'b0;
            deferred_axis <= {AXIS_W{1'b0}};
            evt_valid_o    <= 1'b0;
            evt_axis_o     <= {AXIS_W{1'b0}};
            evt_kind_o     <= KIND_ON;
            evt_depth_o    <= {DEPTH_W{1'b0}};
        end else begin
            evt_valid_o <= 1'b0;
            //  ⭐⭐ 2026-10-15：⭐ **`enable_i` 掉沿 ⇒ 清 `held_mask`（⭐ 见端口注释）** ✅
            //     ⚠️ **必须放在本分支【最前面】**：⭐ 这样**同一拍**来的轴事件
            //        （⭐ 尤其是"仍按着的键重发的 `ON`"）**优先级更高**
            //        ⇒ ⭐ 它能把刚被清掉的那一位**立刻**置回来（⭐ 快一拍自愈）✅
            //        📌 Verilog 非阻塞赋值的语义：⭐ 同一拍对**同一位**的后一次赋值**胜出**
            //           ⇒ ⭐ `held_mask <= 0` 与 `held_mask[axis_i] <= 1` 天然共存 ✓
            //     ⭐ 只认**明确的 1**（⭐ 与 `event_extract.enable_i` 同口径）：
            //        老 tb 不接该端口 ⇒ 悬空 `z` ⇒ ⛔ **不触发** ⇒ 行为逐位不变 ✓
            //     ──────────────────────────────────────────────────────────────
            //  🔴🔴 **2026-10-15（⭐ 鹰眼核实 · 缺陷 2）**：⭐ 原来**只清 `held_mask`** ✅
            //     🔴 **漏 ①**：⭐ 不清 `pluck_run`/`pluck_todo` ⇒ ⚠️ 掉沿那一拍
            //        **FSM 正在跑**时，`pluck_todo` 里全是**脏轴**
            //        ⇒ 🔴 之后仍按**脏快照**逐拍发 `PLUCK` ✅
            //     🔴 **漏 ②**：⭐ `pluck_begin` **不屏蔽 `axis_clr_i`** ⇒ ⚠️ 掉沿那拍
            //        若**同拍**来一条拨弦 ⇒ 🔴 用**清零前的 `held_mask`** 起跑一轮 ✅
            //        （⭐ 已在上方 `pluck_begin`/`pluck_emit_now` 用 `axis_clr_i !== 1'b1` 屏蔽）
            //     ⭐ **本段的三条**：清 `held_mask` ＋ **中止 FSM** ＋ **装载补 OFF 位图** ✅
            if (axis_clr_i === 1'b1) begin
                held_mask      <= {AXIS_COUNT{1'b0}};
                // ⭐ **中止**没发完的拨弦（⭐ 它的快照已脏 ⇒ 一拍都不许再发）
                pluck_run      <= 1'b0;
                pluck_todo     <= {AXIS_COUNT{1'b0}};
                // ⭐ **缺陷 3**：⭐ 把"仍认为在响"的轴**快照**下来 ⇒ ⭐ 之后**逐拍补 OFF**
                //    ⛔ **不是**直接清 `keyboard_held`（⭐ 那会让四条 OFF 出口全部失效）✅
                off_drain_todo <= keyboard_held;
            end
            // Physical keys and sounding voices are independent.
            if (axis_valid_i && axis_kind_i == KIND_ON) begin
                held_mask[axis_i] <= 1'b1;
                axis_depth[axis_i] <= axis_depth_i;
            end else if (axis_valid_i && axis_kind_i == KIND_OFF) begin
                held_mask[axis_i] <= 1'b0;
                //  🔴🔴 **2026-10-15（⭐ 鹰眼核实 · 缺陷 1）**：⭐ **同拍把这一位从快照里摘掉** ✅
                //     🔴 **缺陷**：⭐ `pluck_todo` 是拨弦那一拍的**快照**
                //        （⭐ 见 `:pluck_work` 那段）⇒ ⚠️ 若某轴在 FSM 窗口内被松开，
                //        `held_mask` 清了、🔴 **`pluck_todo` 没清** ⇒ ⭐ FSM 轮到它时
                //        仍会发一条 `PLUCK` ⇒ 🔴 而它的 `KIND_OFF` **已经用掉了**
                //        ⇒ ⭐ `keyboard_held[axis]` 被置 1 却**永远等不到配对 OFF**
                //        ⇒ 🔴 **挂音** ✅
                //     ✅ **修法（⭐ 选"摘快照位"而不是"改 `pluck_pick_valid` 只认
                //        `pluck_todo & held_mask`"）** —— ⭐ 理由：
                //        ⓐ ⭐ 只改仲裁条件的话，被摘掉的那一位**仍留在 `pluck_todo` 里**
                //           ⇒ ⭐ `pluck_rest` 永不为 0 ⇒ 🔴 **FSM 收不了尾**；
                //           ⚠️ 若改成"跳过它继续"，⭐ 又必须**额外**写"跳过时怎么推进"，
                //           ⭐ 逻辑比这里多得多 ✅
                //        ⓑ ⭐ 本行**同时**保证"已松的轴⛔ 不被算进本次拨弦"与
                //           "⭐ FSM 一定能收尾"（⭐ `pluck_rest` 自然递减）✅
                //        ⓒ ⭐ 与 ON 分支**天然不冲突**：⭐ 同拍 `ON` 走上面的分支 ✅
                pluck_todo[axis_i] <= 1'b0;
            end
            // Save a one-cycle pluck when an axis event occupies the output.
            //  ⭐⭐ 2026-10-15：⭐ **条件从 `axis_valid_i` 放宽到 `axis_valid_i || pluck_run`**
            //     🔴 **为什么**：⭐ 多拍 FSM 在跑时，⭐ 第二拨可能已经来了
            //        （⭐ 生产上 `async_pluck_capture` 有 30 ms 不应期 ⇒ ⚠️ 实际到不了；
            //          ⭐ 但 ⛔ **不许靠"实际到不了"来保证不丢**）✅
            //     ⚠️ **降调（⭐ 见上方 `pending_pluck` 那段）**：⭐ 保证的是
            //        "**1 次**拨弦不丢"（⭐ 锁 1 位、收尾后再起一轮）；
            //        🔴 FSM 期间来 ≥2 次会被合并 ⇒ ⭐ **不是**"任意多次都不丢" ✅
            //     ⇒ ⭐ 锁进 `pending_pluck`，⭐ 等 FSM 收尾后**再起一轮** ✅
            if (!fretboard_mode_i) begin
                pending_pluck <= 1'b0;
                // ⭐ 切回键盘模式 ⇒ ⭐ 放弃没发完的拨弦（⭐ 键盘模式没有拨弦语义）
                pluck_run     <= 1'b0;
                pluck_todo    <= {AXIS_COUNT{1'b0}};
            end else if (pluck_valid_i && (axis_valid_i || pluck_run))
                pending_pluck <= 1'b1;

            // A re-pressed owner withdraws its deferred release. A quiet cycle
            // drains an ended session without dropping simultaneous axis/pluck
            // input. Production scans have a bounded idle gap each snapshot.
            if (axis_valid_i && axis_kind_i == KIND_ON && axis_i == deferred_axis)
                deferred_off <= 1'b0;

            if (deferred_off && !((slide_active_i === 1'b1) && slide_axis_i == deferred_axis)
                             && !axis_valid_i && !pluck_valid_i) begin
                evt_valid_o <= 1'b1;
                evt_axis_o <= deferred_axis; evt_kind_o <= KIND_OFF;
                evt_depth_o <= {DEPTH_W{1'b0}};
                keyboard_held[deferred_axis] <= 1'b0;
                deferred_off <= 1'b0;
                if (gate_axis == deferred_axis) gate_valid <= 1'b0;
            end else if (!axis_valid_i && !pluck_valid_i && off_drain_pick_valid) begin
                //  ⭐⭐ 2026-10-15（⭐ 鹰眼核实 · **缺陷 3**）：⭐ **逐拍补发 OFF** ✅
                //     完整依据见上方 `off_drain_todo` 那段（⭐ 端口/寄存器声明处）✅
                //     ⚠️ **`!axis_valid_i && !pluck_valid_i` 是【硬要求】**：
                //        ⭐ 本分支**排在**键盘分支与拨弦分支**之前**
                //        （⭐ 因为 `else if (!fretboard_mode_i)` 会**吃掉**它后面的一切）
                //        ⇒ 🔴 若不排除这两个脉冲，⭐ **单拍脉冲的 `pluck_valid_i`
                //           会被吞掉 ⇒ 丢拨弦** ✅
                evt_valid_o <= 1'b1;
                evt_axis_o  <= off_drain_pick;
                evt_kind_o  <= KIND_OFF;
                evt_depth_o <= {DEPTH_W{1'b0}};
                keyboard_held[off_drain_pick] <= 1'b0;
                if (gate_axis == off_drain_pick) gate_valid <= 1'b0;
                if (deferred_axis == off_drain_pick) deferred_off <= 1'b0;
                off_drain_todo <= off_drain_rest;
            end else if (!fretboard_mode_i) begin
                // Keyboard: threshold crossing and release are directly musical.
                if (axis_valid_i) begin
                    evt_valid_o <= 1'b1;
                    evt_axis_o  <= axis_i;
                    evt_kind_o  <= axis_kind_i;
                    evt_depth_o <= axis_depth_i;
                    //  ⭐⭐ 2026-10-09（`P0-22`）：⭐ **键盘模式也必须维护"正在响的轴"** ✅
                    //   🔴 **原缺陷**：⭐ 键盘分支**从不写 `gate_valid`/`gate_axis`**
                    //      （⭐ 只有拨弦分支 `:273-274` 写 —— ⭐ 行号为当前工作区版）
                    //      ⇒ ⭐ 键盘模式下 `gate_valid` **恒 0** ✅
                    //      ⇒ 🔴 而指板模式下 OFF 事件的**唯一出口**是 `gate_valid && (axis_i == gate_axis)`
                    //      ⇒ ⭐ `gate_valid=0` 时**一个 OFF 都发不出去** ✅
                    //   🔴 **复现（⭐ 用户实测过的"挂音几分钟不停"）**：
                    //      · ⭐ 键盘模式按住一个键（⭐ `KIND_ON` ⇒ voice 起音）
                    //      · ⭐ 切到【指板】模式（⭐ `fretboard_mode_i=1`，⭐ 它是**运行期信号**：
                    //        `top.v` 的 `play_fretboard_mode = ~ui_mode_piano`
                    //        ⇒ 串口 `'A'` / 屏触摸控件 0 都能随时翻转 ⇒ ⛔ 不是编译期常量）
                    //        ⚠️ **2026-10-13 更正**：本行原写 *"切到 PIANO（`fretboard_mode_i=1`）"*
                    //           —— 🔴 **两处都错**：
                    //           ① ⭐ 极性反了：`fretboard_mode_i=1` 是**指板**，⛔ 不是 PIANO
                    //              （⭐ 端口注释就是 `0=keyboard, 1=fretboard` ✅）
                    //           ② ⭐ `BASS→GUITAR→PIANO→PAD` 是**音色循环**（`'I'`），
                    //              与**演奏模式**是两回事 —— ⚠️ 原文把两者混了 ✅
                    //        📌 挂音的机理不受影响：⭐ 关键是"键盘模式起音、切到指板后松键"
                    //           ⇒ ⭐ 指板分支要 `selected_axis`，⭐ 而键盘模式从没写过它 ✅
                    //      · ⭐ 松键 ⇒ ⭐ 指板分支走 `else if (axis_valid_i)`（⭐ `pluck_valid_i` 为 0）
                    //        ⇒ `axis_i == selected_axis` **不成立**（⭐ 键盘模式从没写过 `selected_axis`）
                    //        ⇒ `gate_valid(0) && …` 为假 ⇒ 🔴 `evt_valid_o` **一拍都不抬**
                    //        ⇒ ⭐ **下游永远收不到 `note_off` ⇒ 挂音** ✅
                    //   ✅ **修法**：⭐ 键盘模式按 `KIND_ON`/`KIND_OFF` 维护 `gate_valid`/`gate_axis`
                    //      ⇒ ⭐ 切到指板模式后，那个音**仍能被放掉** ✅
                    //   📌 **零回归**：⭐ 键盘分支在 `if/else if` 链**最前面**，⭐ 仍优先转发
                    //      ⇒ ⭐ 键盘模式的行为**完全不变**（⭐ 只是多了两个寄存器的影子状态）✅
                    if (axis_kind_i == KIND_ON) begin
                        keyboard_held[axis_i] <= 1'b1;
                        gate_valid <= 1'b1;
                        gate_axis  <= axis_i;
                    end else if (axis_kind_i == KIND_OFF) begin
                        keyboard_held[axis_i] <= 1'b0;
                        if (deferred_axis == axis_i) deferred_off <= 1'b0;
                        //  ⭐ 只在"放掉的正是正在响的那个"时清 ✅
                        if (axis_i == gate_axis) gate_valid <= 1'b0;
                    end
                end
            end else if (pluck_emit_now) begin
                // Fretboard: a pluck is the musical trigger. Direction has
                // already been resolved by async_pluck_capture (UP priority).
                //  ⭐⭐ 2026-10-15：⭐ **一次拨弦 ⇒ 逐拍发【所有】按住的轴** ✅
                //     （⭐ 契约变更的完整说明见文件上方那段 —— ⭐ **经用户授权** ✅）
                //     ⭐ 本拍发 `pluck_pick`（⭐ `pluck_todo` 里**最低**的那一位），
                //        ⭐ 余下的留到后面几拍继续发（⭐ `evt_*` 是**单事件口**）
                evt_valid_o <= 1'b1;
                evt_axis_o  <= pluck_pick;
                evt_kind_o  <= KIND_PLUCK;
                evt_depth_o <= axis_depth[pluck_pick];
                gate_valid  <= 1'b1;
                gate_axis   <= pluck_pick;
                //  ⭐ 推进 FSM：⭐ 清掉刚发的这一位；⭐ 清空 ⇒ 收尾
                pluck_todo  <= pluck_rest;
                pluck_run   <= (pluck_rest != {AXIS_COUNT{1'b0}});
                //  ⭐ 只有**启动那一拍**才消费 `pending_pluck`
                //     （⭐ FSM 中途**不许**清它 ⇒ ⚠️ 否则 FSM 期间来的第二拨会丢）
                if (pluck_begin) pending_pluck <= 1'b0;
                // Track every live hand-play axis, including successive plucks.
                //  ⭐⭐ **逐轴**置位 ⇒ ⭐ 松某轴时**只放掉它自己**
                //     ⇒ ⭐ `note_on` / `note_off` **一一配对**（⭐ 项目 `T38` 防挂音纪律）✅
                keyboard_held[pluck_pick] <= 1'b1;
            end else if (axis_valid_i) begin
                if (axis_kind_i == KIND_ON) begin
                    selected_valid <= 1'b1;
                    selected_axis  <= axis_i;
                    selected_depth <= axis_depth_i;
                end else if (axis_kind_i == KIND_OFF) begin
                    if (axis_i == selected_axis)
                        selected_valid <= 1'b0;
                    //  ⭐⭐ 2026-10-09（`P0-22`）：⭐ **换品后松键也要能放掉正在响的音** ✅
                    //   🔴 **原缺陷**：⭐ 原判据只看 `axis_i == gate_axis` ✅
                    //      ⚠️ 而 `gate_axis` **只在拨弦那一拍锁存**（⭐ 此后只有再次拨弦才更新）
                    //      ⇒ ⭐ 而 `selected_axis` 会随**每一次 `KIND_ON`** 更新 ✅
                    //   🔴 **复现（⭐ 吉他上极常见：滑品不重拨）**：
                    //      · ⭐ `axis_evt(6, ON)` ⇒ `selected_axis=6`
                    //      · ⭐ `pluck_evt` ⇒ evt `PLUCK axis=6`，⭐ `gate_axis=6`（⭐ voice 起音）
                    //      · ⭐ `axis_evt(9, ON)` ⇒ ⭐ `selected_axis=9`（⭐ 而 `gate_axis` 仍是 6）
                    //      · ⭐ `axis_evt(9, OFF)` ⇒ ⭐ `axis_i(9) == selected_axis(9)` ⇒ 清 `selected_valid`
                    //        ⚠️ 但 `gate_valid(1) && (9 == 6)` = 假 ⇒ 🔴 **不发 OFF**
                    //        ⇒ ⭐ **步骤②起的音永远不释放 ⇒ 挂音** ✅
                    //   ✅ **修法（⭐ 两条）**：
                    //      ① ⭐ 判据加 `|| (axis_i == selected_axis)` —— ⭐ 松开的正是"当前选中的轴"也算 ✅
                    //      ② ⭐ `evt_axis_o` 改成发 **`gate_axis`**（⭐ 即**正在响的那个轴**）
                    //         ⚠️ 原来发的是 `axis_i`（⭐ 被松开的轴）⇒ ⭐ 两者不等时会放错音 ✅
                    //   📌 **零回归证明**：⭐ 既有场景里 `axis_i == gate_axis`（⭐ 都是 6）
                    //      ⇒ ⭐ `evt_axis_o` 由 `axis_i` 改成 `gate_axis` **得到同一个值** ⇒ 判据不变 ✅
                    // Every keyboard-origin axis survives a mode change until
                    // its own OFF is forwarded, not only the last gate_axis.
                    if (keyboard_held[axis_i] && slide_holds_axis) begin
                        deferred_off <= 1'b1; deferred_axis <= axis_i;
                    end else if (keyboard_held[axis_i]) begin
                        evt_valid_o <= 1'b1;
                        evt_axis_o <= axis_i;
                        evt_kind_o <= KIND_OFF;
                        evt_depth_o <= {DEPTH_W{1'b0}};
                        keyboard_held[axis_i] <= 1'b0;
                        if (deferred_axis == axis_i) deferred_off <= 1'b0;
                        if (axis_i == gate_axis) gate_valid <= 1'b0;
                    end else if (gate_valid && !slide_holds_gate &&
                                 ((axis_i == gate_axis) || (axis_i == selected_axis))) begin
                        evt_valid_o <= 1'b1;
                        evt_axis_o  <= gate_axis;    // ⭐ 释放【正在响】的那个轴
                        evt_kind_o  <= KIND_OFF;
                        evt_depth_o <= {DEPTH_W{1'b0}};
                        gate_valid  <= 1'b0;
                        keyboard_held[gate_axis] <= 1'b0;
                        if (deferred_axis == gate_axis) deferred_off <= 1'b0;
                    end
                end
            end else if (!axis_valid_i && pluck_run && !pluck_pick_valid) begin
                //  ⭐ 防御（⭐ 正常路径到不了这里）：⭐ `pluck_todo` 空却还在跑 ⇒ 收尾
                pluck_run  <= 1'b0;
                pluck_todo <= {AXIS_COUNT{1'b0}};
            end else if (!axis_valid_i && pending_pluck && (held_mask == {AXIS_COUNT{1'b0}})) begin
                //  ⭐ 拨弦时**一个轴都没按住** ⇒ ⭐ 没有音可触发 ⇒ 丢掉这次请求
                //     （⭐ 与旧版一致：⭐ 旧版靠 `pluck_found == 0` 在这里清）
                pending_pluck <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
