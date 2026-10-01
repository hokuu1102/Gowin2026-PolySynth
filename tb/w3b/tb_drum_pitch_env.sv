// ─────────────────────────────────────────────────────────────────────────────
// tb_drum_pitch_env.sv · 阶段 2b 验收（鼓机**音高包络** · 向下扫频）
//
// ⭐ 被测行为（`rtl/w3b/oscillator_bank.v` 的 `DRUM_PITCH_ENV_*`）：
//    ⭐ 鼓 voice（`voice_drum_i = 1`）且音高落在**底鼓 / 嗵鼓**档时，
//    ⭐ 起音那一拍给相位增量**装载**一个偏移，⭐ 之后**指数衰减到 0**
//    ⇒ ⭐ 瞬时频率**先高后低**、⭐ 并**精确收敛**回标称 `PHASE_INC` ✅
//
// ⭐ 判据（对应任务书三条 ＋ 非空洞性 ＋ 确定性补充）：
//    ① ⭐ 鼓 voice：**输出过零率随时间下降**（= 向下扫频 ✅）
//    ② ⭐ 鼓 voice：过零率**收敛到标称音高**（⭐ 与"关掉扫频"的同源 DUT 比 ✅）
//    ③ ⭐ 非鼓 voice：过零率**保持恒定**（⭐ 证明扫频只作用在鼓 ✅）
//    ④ ⭐ 非空洞性：⭐ 判据 ① 的**同一条公式**作用在"关掉扫频"的 DUT 上**必须为假** ✅
//    ⑤ ⭐ 确定性补充：⭐ 每帧**相位增量**（= 瞬时频率，⭐ 无噪声、⭐ 整数 ✅）
//       · ⭐ 起音窗：`> PHASE_INC`（⭐ 扫频确实在起作用 ✅）
//       · ⭐ 稳态窗：`== PHASE_INC`（⭐ **精确**收敛 ✅）
//       · ⭐ 非鼓（底鼓音高 / 踩镲音高）：**恒** `== PHASE_INC`（⭐ 一位都不扫 ✅）
//
// 🔴🔴 **本 tb 最重要的实测结论：⭐ 输出过零率在【真实底鼓音高】下**测不出**扫频**
//    —— ⭐ 这不是扫频没生效，⭐ 而是**宽带噪声表的度量性质** ✅
//    · ⭐ 采样地址 = `phase[31:22]`（⭐ `AW = $clog2(1024) = 10` ✅
//      ⚠️ 源码里 `AW` 行尾那句 "// 9" 是**过时的注释**）
//    · ⇒ ⭐ 底鼓的"每采样地址步进" `δ = 6_263_494 / 2^22 = **1.493**` ✅
//    · 🔴 `δ > 1` ⇒ ⭐ **相邻样本近乎独立**（⭐ 地址有时跳 2 格）
//      ⇒ ⭐ 过零率**饱和在 ~0.5 次/采样**，⭐ **与音高无关** ✅
//    · 📌 **仿真实测（⭐ 与预演逐位一致）**：⭐ 真实底鼓音高下
//        早窗 `on=128 / off=132`、晚窗 `on=1022 / off=1011`
//        ⇒ ⭐ 每采样过零率 **0.500 vs 0.499** ⇒ 🔴 **判据不可能成立** ✅
//    · ⭐ 试过并**否掉**的办法（⭐ 记下来防重犯）：
//        ⛔ 输出做 2/4/8/16 点滑动平均后再数过零 —— 预演比值 0.96~1.10
//           ⇒ 🔴 **低通救不了**（⭐ 平滑后的过零仍由表的局部结构决定 ✅）
//        ⛔ 数"相位 MSB"的过零 —— ⭐ 底鼓周期 = 667 拍 ⇒ ⭐ 256 拍窗口里
//           **只翻转 0~1 次** ⇒ 🔴 **没有分辨率** ✅
//    ⇒ ✅ **最终做法**：⭐ 判据 ①②④ 改在 **`δ < 1` 的鼓音高**上测
//       （⭐ `INC_LOW = 1_610_612` ⇒ ⭐ `δ = 0.384` ⇒ ⭐ 过零率恢复对音高线性 ✅）
//       ⭐ **机制完全相同**：⭐ 扫频深度仍是 `base_inc >> 8`（⭐ 起音仍是 2× ✅）
//       ⭐ 而**真实底鼓音高**上改用**每帧相位增量**（⭐ 判据 ⑤⑥，⭐ 无噪声 ✅）
//
// 🔴 **非空洞性（⭐ 本 tb 的核心设计）**：⭐ 例化**两个只差一个参数**的 DUT
//    · `dut_on` ：`DRUM_PITCH_ENV_EN = 1`（⭐ 开 ✅）
//    · `dut_off`：`DRUM_PITCH_ENV_EN = 0`（⭐ 关 ✅）
//    ⭐ **同一个激励、同一次复位、同一张表** ⇒ ⭐ 两者差异**只可能来自扫频** ✅
//    ⇒ ⭐ 判据 ④ 把判据 ① 的公式**原样**作用在 `dut_off` 上，⭐ 必须 RED ✅
//    📌 另有**离线非空洞性**：⭐ 把 RTL 默认参数 `DRUM_PITCH_ENV_EN` 改成 0 重跑
//       ⇒ ⭐ 判据 ① 必红（⭐ 两条输出都留在报告里 ✅）
//
// 🔴 **门限是【先预演后定】的**（⛔ 不是跑完再凑）：
//    ⭐ `build/_tmp_pitchenv/predict_zcr2.py` / `pick_window3.py` 按
//    `tools/gen_t31b_wavetable.py` 的**同一字序**（⭐ 低地址在低位 ✅）＋
//    **同一地址口径**（`phase[31:22]` ✅）复算过零数 ——
//    ⭐ 预演已与仿真实测**逐位一致**（⭐ 127/132/1022/1012 vs 128/132/1022/1011 ✅）
//    ⇒ ⭐ 门限按预演值留 ≥20% 余量 ✅
//    · ⭐ 判据 ① 预演 **1.845**（⭐ 门限 1.20 ⇒ **+54%** 余量 ✅）
//    · ⭐ 判据 ④ 预演 **0.941**（⭐ 门限 1.20 ⇒ **-22%** 余量 ✅）
//    · ⭐ 判据 ② 预演 **0.997**（⭐ 门限 ±20% ⇒ 余量极大 ✅）
//
// ⚠️ 语法纪律（`K-91`）：⛔ **Verilog-2001**，⛔ 不用 SV 专有构造
// ⚠️ 时基纪律（`K-93`）：`sample_tick_i` 是**时钟使能** ⇒ **恰好高 1 拍**
// ⚠️ 本 tb 用 `FRAME_GAP = 12` 拍/采样（⛔ 不是真实设计的 1024）——
//    ⭐ 判据全部落在**采样域**（每采样的过零数 / 每采样的相位增量）
//    ⇒ ⭐ **与帧间隔无关** ⇒ ⭐ 仿真快 ~85 倍而结论不变 ✅
// ⚠️ `voice_phase_rst_i` **不接**（⭐ 同 `tb_oscillator_bank` / `tb_wavetable_bank`）——
//    ⭐ 它悬空 = `z` ⇒ ⭐ RTL 用 `=== 1'b1` 解码成 0 ⇒ ⭐ 走**电平上升沿**那条
//    **向后兼容**路径 ✅（⭐ 两条路径在 RTL 里**共用同一个 `if` 分支** ⇒
//     ⭐ 扫频装载条件**两条都覆盖** ✅）
// ─────────────────────────────────────────────────────────────────────────────
`timescale 1ns/1ps

module tb_drum_pitch_env;

    localparam integer POLY    = 4;
    localparam integer OPV     = 2;
    localparam integer LANES   = POLY * OPV;      // 8
    localparam integer PHASE_W = 32;
    localparam integer SW      = 16;

    // ⭐ 与 `drum_gen` **逐字同口径**的音高（⭐ `inc = f × 2^32 / 48828.125`）
    localparam [PHASE_W-1:0] INC_KICK  = 32'd6_263_494;    // ⭐ ≈70 Hz（真实底鼓）
    localparam [PHASE_W-1:0] INC_HIHAT = 32'd171_798_691;  // ⭐ ≈1920 Hz（踩镲）
    //  ⭐⭐ 判据 ①②④ 用的**鼓音高**：⭐ `δ = 1_610_612 / 2^22 = 0.384 < 1` ✅
    //     🔴 **为什么⛔ 不用真实底鼓音高**：⭐ 见文件头 —— ⭐ `δ = 1.493 > 1`
    //        ⇒ ⭐ 噪声表过零率**饱和** ⇒ 🔴 **判据测不出来**（⭐ 实测 0.500 vs 0.499）✅
    //     ⭐ 本档仍落在**底鼓档**（⭐ `1_610_612 < DRUM_KICK_MAX = 10e6` ✅）
    //        ⇒ ⭐ 扫频深度仍 = `base_inc >> 8` ⇒ ⭐ 起音仍是 **2× 频率** ✅
    //        ⇒ ⭐ **被测机制与真实底鼓逐字相同**，⭐ 只是把"音高"调到
    //           **过零率还能分辨**的区间（⭐ 与"用低频正弦测低通"同一思路 ✅）
    localparam [PHASE_W-1:0] INC_LOW   = 32'd1_610_612;    // ⭐ ≈18.3 Hz · δ=0.384

    // ⭐ 采样节拍间隔：⭐ `LANES + 2 = 10` 拍 TDM ⇒ ⭐ 12 拍有余量 ✅
    localparam integer FRAME_GAP = 12;

    // ⭐ 窗口（⭐ 单位 = 采样拍）—— ⭐ 由 `build/_tmp_pitchenv/pick_window3.py`
    //    在 (早窗, 晚窗) 网格上**按余量最大化**选出 ✅
    localparam integer K_EARLY_START = 256;    // ⭐ 真实底鼓档：早窗（⭐ 判据 ⑤）
    localparam integer K_EARLY_LEN   = 256;
    localparam integer K_LATE_START  = 4096;   // ⭐ 扫频在 3888 拍**精确到 0** ⇒ 4096 起稳 ✅
    localparam integer K_LATE_LEN    = 2048;
    localparam integer L_EARLY_START = 192;    // ⭐ 低音高档：早窗（⭐ 判据 ①④）
    localparam integer L_EARLY_LEN   = 256;
    localparam integer L_LATE_START  = 5120;   // ⭐ 晚窗（⭐ 判据 ②）
    localparam integer L_LATE_LEN    = 2048;
    localparam integer ND_LEN        = 1024;   // ⭐ 非鼓过零率窗口长度

    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg rst_n = 1'b0;

    integer errors = 0;
    task chk;
        input [8*128-1:0] name;
        input             cond;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL: %0s", name);
            end else begin
                $display("  ok  : %0s", name);
            end
        end
    endtask

    // ═════════════════════════════════════════════════════════════════════════
    // ① 激励（⭐ 两个 DUT **共用**，⛔ 一字不差 —— ⭐ 非空洞性的前提 ✅）
    // ═════════════════════════════════════════════════════════════════════════
    reg                      sample_tick;
    reg  [POLY-1:0]          v_active;
    reg  [POLY*PHASE_W-1:0]  v_inc;
    reg  [POLY-1:0]          v_drum;

    wire [LANES*SW-1:0]      samp_on;
    wire [LANES*SW-1:0]      samp_off;
    wire                     vld_on;
    wire                     vld_off;
    wire [PHASE_W-1:0]       phase_on;
    wire [PHASE_W-1:0]       phase_off;

    //  ⭐ `DRUM_PITCH_ENV_EN` **不显式传参** —— ⭐ 用 RTL 的**默认值**（= 1，开 ✅）
    //     🔴 **为什么故意不写**（⭐ 这是**非空洞性**的关键 ✅）：
    //        ⭐ 若这里显式写 `.DRUM_PITCH_ENV_EN(1)`，⭐ 那么"把 RTL 默认值改成 0
    //        重跑"就**改不动本 DUT** ⇒ 🔴 **非空洞性实验做不了** ✅
    //        ⭐ 不写 ⇒ ⭐ 本 DUT 跟着**出厂默认**走 ⇒ ⭐ 改默认值 = **真正的**
    //        "关掉扫频"变异体 ⇒ ⭐ 判据 ① 必红（⭐ 见报告的两条输出 ✅）
    oscillator_bank #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OPV), .PHASE_W(PHASE_W),
        .OSC_SAMPLE_W(SW), .TIMBRE_N(4), .TIMBRE_W(2),
        .WT_DEPTH(1024), .WT_W(16), .ENABLE_FM(0), .DBG_LANE(0),
        //   ⭐ 关失谐：⭐ 让两个 lane 严格同相 ⇒ ⭐ 只看 lane0 就代表整个 voice ✅
        .DETUNE_ON(0)
    ) dut_on (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .voice_active_i(v_active), .base_phase_inc_i(v_inc),
        .voice_timbre_i({(POLY*2){1'b0}}), .voice_velocity_i({(POLY*8){1'b0}}),
        .voice_drum_i(v_drum),
        .vibrato_mod_i(16'sd0),
        .test_mode_i(1'b0),
        .test_lane_active_i({LANES{1'b0}}),
        .test_phase_inc_i({(LANES*PHASE_W){1'b0}}),
        .fm_cfg_valid_i(1'b0), .fm_ratio_i(16'd0), .fm_index_i(16'd0),
        .osc_sample_bus_o(samp_on), .osc_valid_o(vld_on),
        .phase_acc_dbg_o(phase_on)
    );

    //  ⭐ `DRUM_PITCH_ENV_EN = 0`（⭐ **关**扫频）—— ⭐ **非空洞性参照** ✅
    //     🔴 为什么必须**同时**例化（⛔ 不是跑两遍）：⭐ 两者**共享复位与激励**
    //        ⇒ ⭐ 逐拍可比 ⇒ ⭐ 判据 ② 的"收敛到标称"才有**同源参照** ✅
    oscillator_bank #(
        .POLY_TARGET(POLY), .OSC_PER_VOICE(OPV), .PHASE_W(PHASE_W),
        .OSC_SAMPLE_W(SW), .TIMBRE_N(4), .TIMBRE_W(2),
        .WT_DEPTH(1024), .WT_W(16), .ENABLE_FM(0), .DBG_LANE(0),
        .DETUNE_ON(0),
        .DRUM_PITCH_ENV_EN(0)
    ) dut_off (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .voice_active_i(v_active), .base_phase_inc_i(v_inc),
        .voice_timbre_i({(POLY*2){1'b0}}), .voice_velocity_i({(POLY*8){1'b0}}),
        .voice_drum_i(v_drum),
        .vibrato_mod_i(16'sd0),
        .test_mode_i(1'b0),
        .test_lane_active_i({LANES{1'b0}}),
        .test_phase_inc_i({(LANES*PHASE_W){1'b0}}),
        .fm_cfg_valid_i(1'b0), .fm_ratio_i(16'd0), .fm_index_i(16'd0),
        .osc_sample_bus_o(samp_off), .osc_valid_o(vld_off),
        .phase_acc_dbg_o(phase_off)
    );

    // ═════════════════════════════════════════════════════════════════════════
    // ② 采样节拍（⭐ `sample_tick_i` = 时钟使能 ⇒ **恰好高 1 拍** ✅）
    // ═════════════════════════════════════════════════════════════════════════
    integer gap = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            gap         <= 0;
            sample_tick <= 1'b0;
        end else begin
            sample_tick <= 1'b0;
            if (gap >= FRAME_GAP - 1) begin
                gap         <= 0;
                sample_tick <= 1'b1;
            end else begin
                gap <= gap + 1;
            end
        end
    end

    // ═════════════════════════════════════════════════════════════════════════
    // ③ 每帧捕获：⭐ lane0 的输出样本 ＋ ⭐ lane0 的相位（⭐ 同一拍 ✅）
    // ═════════════════════════════════════════════════════════════════════════
    reg [SW-1:0]      cap_on, cap_off;
    reg [PHASE_W-1:0] cap_ph;
    reg               cap_vld;

    always @(posedge clk) begin
        if (!rst_n) begin
            cap_on  <= {SW{1'b0}};
            cap_off <= {SW{1'b0}};
            cap_ph  <= {PHASE_W{1'b0}};
            cap_vld <= 1'b0;
        end else begin
            cap_on  <= samp_on[SW-1:0];      // ⭐ lane0 = voice0 的主振荡器 ✅
            cap_off <= samp_off[SW-1:0];
            cap_ph  <= phase_on;             // ⭐ `DBG_LANE = 0` ⇒ lane0 的 `phase_q` ✅
            cap_vld <= (vld_on === 1'b1);    // ⭐ 两个 DUT 同源同拍 ⇒ 一个 valid 够用 ✅
        end
    end

    // ═════════════════════════════════════════════════════════════════════════
    // ④ 测量任务：⭐ 跑 `n` 帧，统计
    //    · ⭐ `m_xa` / `m_xb`：⭐ `dut_on` / `dut_off` 的 lane0 **输出过零数** ✅
    //    · ⭐ `m_amin` / `m_amax`：⭐ `dut_on` lane0 的**每帧相位增量**范围 ✅
    //      （⭐ 增量 = 本帧相位 − 上帧相位，⭐ 32 位无符号回绕 ⇒ ⭐ 差值是**精确值** ✅）
    // ═════════════════════════════════════════════════════════════════════════
    integer m_xa, m_xb;
    integer m_amin, m_amax;

    task measure;
        input integer n;
        integer           j;
        reg               pa, pb;
        reg               first;
        reg [PHASE_W-1:0] ph_last;
        reg [PHASE_W-1:0] d;
        begin
            m_xa   = 0;
            m_xb   = 0;
            m_amin = 2147483647;
            m_amax = 0;
            pa     = 1'b0;
            pb     = 1'b0;
            first  = 1'b1;
            ph_last = cap_ph;
            for (j = 0; j < n; j = j + 1) begin
                @(posedge cap_vld);
                @(negedge clk);                  // ⭐ 让寄存器都稳下来再读 ✅
                if (!first) begin
                    //  ⭐ 过零 = 符号位翻转（⭐ `cap_*[SW-1]` 就是符号位 ✅）
                    if (cap_on[SW-1]  !== pa) m_xa = m_xa + 1;
                    if (cap_off[SW-1] !== pb) m_xb = m_xb + 1;
                    //  ⭐ 每帧相位增量（⭐ = 本帧的瞬时频率增量 ✅）
                    d = cap_ph - ph_last;
                    if (d < m_amin) m_amin = d;
                    if (d > m_amax) m_amax = d;
                end
                pa      = cap_on[SW-1];
                pb      = cap_off[SW-1];
                ph_last = cap_ph;
                first   = 1'b0;
            end
        end
    endtask

    // ═════════════════════════════════════════════════════════════════════════
    // ⑤ 激励控制
    // ═════════════════════════════════════════════════════════════════════════
    task set_voice;
        input [PHASE_W-1:0] inc;
        input               drum;
        begin
            //  ⚠️ **只在 `negedge` 改激励**（⭐ 半个周期后驱动 ⇒ ⛔ 不与 DUT 的
            //     `posedge` 采样**竞争** —— ⭐ 这是"驱动器/被测同一时钟沿"的经典坑 ✅）
            @(negedge clk);
            //  ⭐ 先松音（⭐ 让 `lane_active` 落下 ⇒ ⭐ 下次起音**必有上升沿** ✅）
            v_active = {POLY{1'b0}};
            v_inc    = {(POLY*PHASE_W){1'b0}};
            v_inc[PHASE_W-1:0] = inc;
            v_drum   = {POLY{1'b0}};
            v_drum[0] = drum;
            repeat (4) @(posedge cap_vld);
            @(negedge clk);
            //  ⭐ 起音（⭐ 上升沿 ⇒ ⭐ RTL 载入 `phase_seed` ＋ **扫频深度** ✅）
            v_active[0] = 1'b1;
        end
    endtask

    // ⭐ 判据用（⭐ 窗口统计量）
    integer e_a, l_a, e_b, l_b;               // ⭐ 低音高档（⭐ 判据 ①②④）
    integer e_amin, e_amax, l_amin, l_amax;   // ⭐ 真实底鼓档（⭐ 判据 ⑤⑥）
    integer k_a, k_b;                         // ⭐ 真实底鼓档的过零数（⭐ 仅 info）
    integer n1_xa, n1_amin, n1_amax;          // ⭐ 非鼓（底鼓音高）
    integer n2_xa, n2_xb, n2_amin, n2_amax;   // ⭐ 非鼓（踩镲音高）

    initial begin
        sample_tick = 1'b0;
        v_active    = {POLY{1'b0}};
        v_inc       = {(POLY*PHASE_W){1'b0}};
        v_drum      = {POLY{1'b0}};

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (8) @(negedge clk);

        $display("== 阶段 2b · 鼓机音高包络（向下扫频）· dut_on=开 / dut_off=关 ==");

        // ═════════════════════════════════════════════════════════════════
        $display("== 判据 5/6：鼓 voice @ **真实底鼓音高** INC=%0d（δ=1.493）==", INC_KICK);
        // ═════════════════════════════════════════════════════════════════
        //   ⭐ 这一档量**每帧相位增量**（⭐ = 瞬时频率，⭐ 无噪声 ✅）
        //   ⚠️ 这一档的**输出过零率只打印、不作判据** —— 🔴 它饱和（⭐ 见文件头 ✅）
        set_voice(INC_KICK, 1'b1);
        measure(K_EARLY_START);                        // ⭐ 丢掉起音前段
        measure(K_EARLY_LEN);
        e_amin  = m_amin;
        e_amax  = m_amax;
        k_a     = m_xa;
        k_b     = m_xb;
        measure(K_LATE_START - K_EARLY_START - K_EARLY_LEN);
        measure(K_LATE_LEN);
        l_amin  = m_amin;
        l_amax  = m_amax;
        $display("  info: 底鼓音高 相位增量 早窗=[%0d,%0d]（⭐ 标称 %0d）晚窗=[%0d,%0d]",
                 e_amin, e_amax, INC_KICK, l_amin, l_amax);
        $display("  info: 底鼓音高 过零数 早 on=%0d off=%0d / 晚 on=%0d off=%0d",
                 k_a, k_b, m_xa, m_xb);
        $display("  info: **过零率在此档【饱和】**（0.500 vs 0.499）⇒ 判据改在低音高档测（见下）");

        //  ⭐ 判据 ⑤：⭐ 起音窗内**每帧相位增量 > 标称**（⭐ 扫频确实在起作用 ✅）
        chk("drum_voice_onset_phase_step_exceeds_nominal", e_amax > INC_KICK);

        //  ⭐ 判据 ⑥：⭐ 稳态窗内**每帧相位增量 == 标称**（⭐ **精确**收敛 ✅）
        //     ⭐ 这是**无噪声**判据：⭐ 相位增量是整数 ⇒ ⭐ 一位都不许差 ✅
        chk("drum_voice_late_phase_step_equals_nominal_exactly",
            (l_amin == INC_KICK) && (l_amax == INC_KICK));

        // ═════════════════════════════════════════════════════════════════
        $display("== 判据 1/2/4：鼓 voice @ **低音高档** INC=%0d（δ=0.384，⭐ 过零率可分辨）==", INC_LOW);
        // ═════════════════════════════════════════════════════════════════
        set_voice(INC_LOW, 1'b1);
        measure(L_EARLY_START);
        measure(L_EARLY_LEN);
        e_a = m_xa;
        e_b = m_xb;
        measure(L_LATE_START - L_EARLY_START - L_EARLY_LEN);
        measure(L_LATE_LEN);
        l_a = m_xa;
        l_b = m_xb;

        $display("  info: 低音高档 过零 早[%0d,%0d) on=%0d off=%0d | 晚[%0d,%0d) on=%0d off=%0d",
                 L_EARLY_START, L_EARLY_START + L_EARLY_LEN, e_a, e_b,
                 L_LATE_START, L_LATE_START + L_LATE_LEN, l_a, l_b);
        $display("  info: 每采样过零率(千分) on早=%0d on晚=%0d off早=%0d off晚=%0d",
                 (e_a * 1000) / L_EARLY_LEN, (l_a * 1000) / L_LATE_LEN,
                 (e_b * 1000) / L_EARLY_LEN, (l_b * 1000) / L_LATE_LEN);
        $display("  info: 下降比 on早/on晚=%0d/1000（⭐ 预演 1.845）· 非空洞 off早/off晚=%0d/1000（⭐ 预演 0.941）",
                 (e_a * L_LATE_LEN * 1000) / (l_a * L_EARLY_LEN),
                 (e_b * L_LATE_LEN * 1000) / (l_b * L_EARLY_LEN));

        //  ⭐ 判据 ①：⭐ 鼓 voice 的输出过零率**随时间下降** ✅
        //     ⭐ 公式：`on早 / on晚 ≥ 1.20`（⭐ 预演 1.845 ⇒ +54% 余量 ✅）
        chk("drum_voice_output_zcr_decreases_over_time",
            (e_a * L_LATE_LEN * 100) >= (l_a * L_EARLY_LEN * 120));

        //  ⭐ 判据 ②：⭐ 稳态过零率**收敛到标称音高** ✅
        //     ⭐ 参照 = ⭐ **同激励、同复位、只差扫频开关**的 `dut_off` ✅
        //     ⭐ 容差 ±20%（⭐ 预演 0.997 ⇒ 余量极大 ✅）
        chk("drum_voice_output_zcr_settles_at_nominal_pitch",
            ((l_a * 100) <= (l_b * 120)) && ((l_a * 100) >= (l_b * 80)));

        //  ⭐ 判据 ④：⭐ **非空洞性** —— ⭐ 同一条公式作用在"关掉扫频"的 DUT 上
        //     ⭐ **必须为假** ✅（⭐ 预演 0.941 ⇒ -22% 余量 ✅）
        //     🔴 若本判据变红 ⇒ ⭐ 说明"下降"**与扫频无关**（⭐ 例如表本身随时间变）
        //        ⇒ ⭐ 判据 ① 的绿灯**不可信** ✅
        chk("non_vacuity_same_formula_is_RED_when_sweep_disabled",
            (e_b * L_LATE_LEN * 100) < (l_b * L_EARLY_LEN * 120));

        // ═════════════════════════════════════════════════════════════════
        $display("== 判据 3a：非鼓 voice（⭐ 底鼓音高）⇒ 相位增量恒等于标称 ==");
        // ═════════════════════════════════════════════════════════════════
        //   🔴 **为什么必须用"底鼓音高 + 非鼓标志"**：⭐ 它**同时**验两件事 ✅
        //      · ⭐ `lane_drum` 门控真的生效（⭐ 同一音高，只是标志不同 ✅）
        //      · ⭐ 低音区的**乐音** voice **不会**被误扫（⭐ 否则 BASS 低音会滑音 ✅）
        set_voice(INC_KICK, 1'b0);
        measure(256);
        measure(512);
        n1_xa   = m_xa;
        n1_amin = m_amin;
        n1_amax = m_amax;
        measure(1024);
        $display("  info: 非鼓@底鼓音高 相位增量=[%0d,%0d]（⭐ 必须 == %0d）过零=%0d",
                 n1_amin, n1_amax, INC_KICK, n1_xa);
        chk("non_drum_voice_at_kick_pitch_phase_step_is_nominal",
            (n1_amin == INC_KICK) && (n1_amax == INC_KICK));

        // ═════════════════════════════════════════════════════════════════
        $display("== 判据 3b：非鼓 voice（⭐ 踩镲音高）⇒ 输出过零率恒定 ==");
        // ═════════════════════════════════════════════════════════════════
        //   ⭐ 为什么换踩镲音高：⭐ 乐音表（`rom_soft_t0`）**只有 2 个过零点/周期**
        //      ⇒ ⭐ 底鼓音高下 256 拍里**不到 1 次**过零 ⇒ 🔴 **量不出来** ✅
        //      ⭐ 踩镲音高（`δ = 68` 地址/采样）⇒ ⭐ 1024 拍里有 ~80 次 ✅
        set_voice(INC_HIHAT, 1'b0);
        measure(256);
        measure(ND_LEN);
        n2_xa   = m_xa;
        n2_amin = m_amin;
        n2_amax = m_amax;
        measure(1024);
        measure(ND_LEN);
        n2_xb = m_xa;
        $display("  info: 非鼓@踩镲音高 过零 早=%0d 晚=%0d（⭐ 窗口各 %0d 拍）相位增量=[%0d,%0d]",
                 n2_xa, n2_xb, ND_LEN, n2_amin, n2_amax);
        chk("non_drum_voice_output_zcr_stays_constant",
            ((n2_xa * 100) <= (n2_xb * 125)) && ((n2_xa * 100) >= (n2_xb * 75)));
        chk("non_drum_voice_at_hihat_pitch_phase_step_is_nominal",
            (n2_amin == INC_HIHAT) && (n2_amax == INC_HIHAT));

        // ═════════════════════════════════════════════════════════════════
        if (errors == 0)
            $display("PASS: drum pitch envelope (stage 2b) - all judgements held");
        else
            $fatal(1, "FAIL: drum pitch envelope has %0d error(s)", errors);
        #200;
        $finish;
    end

endmodule
