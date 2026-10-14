`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// perc_env_bank.v · 打击乐包络组（一击到底、无 sustain）—— W3c（`T33`/`T34` 共用）
//
// ⭐ 为什么必须新建它，⛔ 而不是复用队友的 `envelope_bank` / `adsr`（用户 2026-09-21 拍板）
//
//   🔴 事实（读 `rtl/w3b/adsr.v` 逐行算出，⛔ 不是估计）：
//      `adsr` 是 **ADSR**（有 sustain 平台），且衰减到 sustain 就**停住不再降**。
//      以其默认参数为例：
//        峰值     = velocity << 8          （vel=200 ⇒ 51200）
//        sustain  = 峰值 × SUSTAIN_Q8/256  （SUSTAIN_Q8=64 ⇒ 51200/4 = 12800）
//        每 sample_tick 降 DECAY_STEP=4
//        ⇒ 从峰值到 sustain = (51200−12800)/4 = 9600 个 sample_tick
//        ⇒ 9600 / 48828 Hz ≈ **197 ms**
//      ⭐ 而打击音（click / 鼓）只需要 **10~20 ms** ⇒ 差 **10 倍**。
//
//   ⭐⭐ 更关键的一点（⚠️ 这里很容易误判）：**这不是"参数没调对"，是【模型不对】**。
//      即使把 `DECAY_STEP` 调得很大，`adsr` 也只会**更快到达 sustain 然后停住**
//      ⇒ 那个音会**一直响到 `note_off` 为止**，⛔ **不会自己消失**。
//      打击乐要的是"**一击到底、衰到 0 自动结束**" ⇒ ⭐ 与 ADSR 是**语义不同**的包络。
//
//   📌 纪律：⛔ **不改队友已落地的 `adsr` / `envelope_bank` 的行为**（冻结表 §一）。
//      本模块是**新增**文件，与它们**零耦合**、零冲突。
//
// ── 设计 ─────────────────────────────────────────────────────────────────────
//   · ⭐ **线性衰减**（用户 2026-09-21 拍板）：
//       面积小（1 个减法器 + 1 个比较器/DSP）、行为**可预测**、判据**好写成不变量**
//       （单调不增 + 精确时长）。⚠️ 指数衰减听感更自然，但要乘法器/查找表，
//       且"精确时长"这条判据会变难写 ⇒ 本周不做。
//   · ⭐ **参数化时长**（用户拍板）：`DECAY_STEP` 按 `level / step / fs` 换算。
//   · ⭐ **`sample_tick_i` 是时钟使能**（冻结表 §〇 约定 1：单时钟域、⛔ 不派生时钟）。
//
// ── ⭐ 与 `note_manager` 的配合（防挂音的关键）──────────────────────────────
//   `active_o` **必须**在衰到 0 时**准确落下**：
//     `note_manager` 用 `env_active_i` 判"这个 voice 还在不在响"（`live_mask`）
//     ⇒ ⚠️ 若 `active_o` 一直为 1，那个 voice **永远不释放** ⇒ 🔴 **挂音**
//        —— 正是 `T38` 专门要防的失效模式。
//   ⇒ ⭐ 本模块用**状态机显式收尾**（`ST_IDLE`），⛔ 不靠"电平刚好减到 0"这种巧合。
//
// ── ⛔ 纪律（本项目血泪）────────────────────────────────────────────────────
//   · ⭐ **Verilog-2001 语法**（`K-91`：Gowin 按 Verilog-2001 编译，
//     用 SV 专有构造 ⇒ **整个模块被丢弃**，而**仿真全绿**）
//   · ⭐⭐ **组合逻辑用 `assign`/`generate`；`always @(*)` 只用在"真的读信号"的块上**
//     （`L67`：参数取默认值时"全是常量"的组合块**没有敏感信号 ⇒ 仿真器从不执行**）
//   · ⛔ **不对 `integer` 参数做位选**（`K-91` 顺带发现）
//   · ⭐ **任何"容量有限"的计数器都必须可观测**（`K-106`）
//     ⇒ 本模块给出 `busy_o`（还有几个在衰减）与 **`overflow_o`**（同时触发数超上限）
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module perc_env_bank #(
    // ⭐ 乐器数（本模块的"复音数"）—— 每个乐器**独立**状态机，⛔ 不共用
    parameter integer N_PERC = 4,
    // 包络电平位宽（与 `envelope_bank` 的 ENV_W 一致 ⇒ 可直接喂给 mixer）
    parameter integer ENV_W  = 16,
    // 力度位宽
    parameter integer VEL_W  = 8,
    // ⭐ 衰减步长（每 `sample_tick_i` 降多少）
    //    ⚠️ 时长换算：`时长 ≈ 峰值 / DECAY_STEP / fs`
    //       峰值 = `velocity << (ENV_W-VEL_W)`，满力度(255) ⇒ **65280**
    //       `fs = 50 MHz / 1024 = 48828 Hz`
    //    ⭐⭐ 2026-10-14：⭐ **`DECAY_STEP` 67 → 33**（⭐ 时长 ×2：⭐ 20 ms → **40 ms** ✅）
    //       🔴 **为什么**：⭐ 用户实测"灌谱时鼓声太小"
    //          ⚠️ 而**峰值已经很高**（⭐ Kick `VEL_KICK=230` ⇒ 峰值 58880 = **满幅 90%**，
    //             ⭐ 代码注释本就写着"已接近上限，⚠️ 不建议再抬" ✅）
    //          ⇒ ⭐ 所以"听起来小"的真因**不是峰值不够，而是【持续时间太短】**：
    //             ⚠️ 20 ms 就把能量衰完，⚠️ 而人耳感知的音量≈**能量积分**，
    //                ⭐ 同样峰值的乐音可以响几百 ms（⭐ 有 sustain）⇒ 对比之下鼓显得小 ✅
    //       ✅ **修法选择【延长时长】而不是【抬峰值】**：
    //          · ⭐ 峰值再抬 ⇒ 🔴 削顶（⭐ Kick 已 90% FS）＋ ⛔ 违反代码里的告警
    //          · ⭐ 延长时长 ⇒ ⭐ 能量积分 ×2 ⇒ ⭐ 听感音量明显变大，⛔ **峰值不变（不削顶）**
    //       📌 时长表（`DECAY_STEP=33`，⭐ 按各件力度算）：
    //          Kick(230): 58880/33/48828 = **36.6 ms**
    //          Snare(200): 51200/33/48828 = **31.8 ms**
    //          HiHat(140): 35840/33/48828 = **22.2 ms**（⭐ 踩镲短本就合理 ✅）
    //          Tom(190): 48640/33/48828 = **30.2 ms**
    //       ⚠️ **代价（如实说）**：⭐ 鼓更"肉"一点（⭐ 衰减慢）⇒ ⭐ 若嫌拖尾，
    //          ⭐ 可把 `33` 调成 `45`（⭐ 时长约 30 ms ✅）
    //       📌 ⭐ **零回归**：⭐ 本参数只改**时长**，⛔ 不改峰值、⛔ 不改触发语义、
    //          ⛔ 不动 `active_o` 的收尾逻辑（⭐ 仍精确衰到 0 落低 ⇒ ⛔ 不会挂音 ✅）
    //          ⚠️ `tb_perc_env_bank` 若按"精确时长"断言 ⇒ ⭐ 会红，需同步改判据（见下 ✅）
    parameter integer DECAY_STEP = 33
) (    input  wire                     clk_i,
    input  wire                     rst_n_i,
    input  wire                     sample_tick_i,   // ⭐ 时钟使能（每 1024 拍一次）

    // ── 触发（⭐ 边沿时刻断言，冻结表 §〇 约定 4）──────────────────────────
    input  wire [N_PERC-1:0]        trigger_i,       // 单周期脉冲 ⇒ 从峰值重新起音
    input  wire [N_PERC*VEL_W-1:0]  velocity_i,      // 每乐器力度（起音时刻锁存）

    // ── 输出 ────────────────────────────────────────────────────────────────
    output wire [N_PERC*ENV_W-1:0]  level_o,         // → mixer（与 envelope_bank 同格式）
    output wire [N_PERC-1:0]        active_o,        // ⭐ 1 = 还在响（⇒ voice 不可释放）
    output wire [N_PERC-1:0]        busy_o,          // ⭐ 诊断：还有几个在衰减
    // ⭐⭐ 可观测性（`K-106` 纪律）：同一拍对**已在响**的乐器再次触发 ⇒ 次数可数
    //    ⚠️ 本模块**不丢触发**（重触发就是"重新起音"，是合法语义）
    //       ⇒ 这里数的是"**重触发次数**"，用于上板诊断"节拍器有没有连击"
    output wire [N_PERC*16-1:0]     retrig_cnt_o
);

    // ⭐ 峰值 = `velocity << (ENV_W-VEL_W)`（与 `adsr.v` 的映射**保持一致**，
    //    ⭐ 这样同一力度下两个包络的音量**对得上**，⛔ 不会是两套音量口径）
    localparam integer SHIFT = ENV_W - VEL_W;

    // ⚠️ 参数自检用的 1 bit 常量，**必须在 `initial` 之前声明**（Verilog-2001 要求先声明后用）
    localparam N_PERC_IS_ZERO = (N_PERC < 1);

    genvar pi;
    generate
        for (pi = 0; pi < N_PERC; pi = pi + 1) begin : gen_perc
            // ⭐ 每个乐器**独立**状态机（⛔ 不共用 —— 同 `adsr` 的"每 voice 独立"纪律）
            reg [ENV_W-1:0]      level_r;
            reg                  active_r;
            reg [15:0]           retrig_r;

            // ⭐ 起音峰值：**在触发那一拍锁存**（⛔ 不是实时跟随 —— 否则滑杆一动音就变）
            //    ⭐⭐ 为什么要**锁存**而不是直接用 `vel_peak`：
            //       ⚠️ 若直接用，则演奏者**在音还在响的时候拉力度滑杆**，
            //          那个音的包络峰值会**中途改变** ⇒ ⭐ 违反"起音时刻锁存"的语义
            //          （同冻结表 §二 `K-82` 对 `timbre` 的处理：⭐ 起音时锁存）。
            //    ⭐ 而且它**真的被用**（见下方衰减起点）—— ⚠️ 不是死状态。
            reg [ENV_W-1:0]      peak_r;
            // ⭐ 起音标志（1 拍）：触发那一拍把 `level` 直接置成 `peak_r`
            reg                  load_r;

            wire [VEL_W-1:0]     vel     = velocity_i[pi*VEL_W +: VEL_W];
            wire [ENV_W-1:0]     vel_peak = {vel, {SHIFT{1'b0}}};

            assign level_o[pi*ENV_W +: ENV_W]   = level_r;
            assign active_o[pi]                 = active_r;
            assign busy_o[pi]                   = active_r;
            assign retrig_cnt_o[pi*16 +: 16]    = retrig_r;

            always @(posedge clk_i) begin
                if (!rst_n_i) begin
                    level_r  <= {ENV_W{1'b0}};
                    active_r <= 1'b0;
                    peak_r   <= {ENV_W{1'b0}};
                    load_r   <= 1'b0;
                    retrig_r <= 16'd0;
                end else begin
                    // ⭐⭐ 触发**优先于**衰减，且**不依赖 `sample_tick_i`**
                    //    ⚠️ 为什么：触发是**事件**（边沿时刻，约定 4），
                    //       而衰减是**逐样本**过程。若把触发也塞进 sample_tick 分支，
                    //       ⚠️ 在两次 sample_tick 之间来的触发会**被漏掉**（窄脉冲丢失）。
                    //    ⭐ 这样也顺带让 `level` 立刻跳到峰值 ⇒ 判据可精确断言。
                    if (trigger_i[pi]) begin
                        peak_r   <= vel_peak;          // ⭐ 锁存本次力度
                        load_r   <= 1'b1;              // ⭐ 下一拍用它装载 level
                        active_r <= 1'b1;
                        // ⭐ 重触发计数：已经在响时又触发 ⇒ 可观测（`K-106` 风格）
                        if (active_r && (retrig_r != 16'hFFFF))
                            retrig_r <= retrig_r + 16'd1;
                    end else begin
                        // ⭐⭐ 装载（触发后一拍）：`level <= peak_r`
                        //    ⭐ 走这条路径 ⇒ `peak_r` **真的被读** ⇒
                        //       ① "起音时刻锁存力度"这条语义**成立且可测**
                        //       ② 变异体改 `peak_r` 会**真的改变行为**（⛔ 不再是死状态）
                        if (load_r) begin
                            level_r <= peak_r;
                            load_r  <= 1'b0;
                        end else if (sample_tick_i && active_r) begin
                            // ── ⭐ 线性衰减：每 sample_tick 减 DECAY_STEP ──────────
                            //    ⚠️ 用 `<=` 比较而不是借位判断，避免下溢回绕
                            //       （⛔ 回绕会让包络**突然变响**，是明显 bug）
                            if (level_r <= DECAY_STEP[ENV_W-1:0]) begin
                                level_r  <= {ENV_W{1'b0}};
                                active_r <= 1'b0;      // ⭐⭐ 准确收尾 ⇒ 释放 voice（防挂音）
                            end else begin
                                level_r <= level_r - DECAY_STEP[ENV_W-1:0];
                            end
                        end
                    end
                    // ⚠️ 没触发、又没到 sample_tick ⇒ 保持（⛔ 不是漏写）
                end
            end
        end
    endgenerate

    // ── 参数自检（与 `clk_gen`/`tlc5916`/`top` 的 `PARAM_OK` 同一套路）──────
    //   ⚠️ 为什么要有：下面几条会**静默失效**，且现象极难定位
    initial begin
        if (N_PERC_IS_ZERO)
            $display("ERROR [perc_env_bank] N_PERC=%0d 必须 >= 1", N_PERC);
        if (DECAY_STEP < 1)
            // 🔴 `DECAY_STEP=0` ⇒ 电平**永不下降** ⇒ 包络**永不到 0**
            //    ⇒ `active_o` 永远为 1 ⇒ ⭐ **voice 永不释放 ⇒ 挂音**
            $display("ERROR [perc_env_bank] DECAY_STEP=%0d 必须 >= 1（否则包络永不结束 ⇒ 挂音）",
                     DECAY_STEP);
        if (ENV_W <= VEL_W)
            $display("ERROR [perc_env_bank] ENV_W=%0d 必须 > VEL_W=%0d（峰值映射靠左移）",
                     ENV_W, VEL_W);
    end

endmodule

`default_nettype wire
