// ═══════════════════════════════════════════════════════════════════════════
//  fx_delay.v —— 总线级数字延迟（回声）效果器（丙线 · W3c · 第四周 D-1）
//
//  ⭐ 归属/挂载点（见 `files/20-代码/效果器延迟预研-丙-20261003.md` §三）：
//    `master_mix`（干声主音量之后）→ `fx_delay` → `i2s_tx`
//    总线级、全局一个：一条延迟线服务整个混音，⛔ 不挂 voice 级。
//
//  ⭐ 四条纪律（预研 §四，逐条遵守）：
//    ① 单时钟域 + 无 PLL + 无门控时钟：环形缓冲读写都用 clk + sample_tick_i 节拍使能。
//    ② 零插入延迟透传干声：valid 流不反压，out_valid = valid_i，干声当拍透传。
//    ③ Verilog-2001 语法（K-91：Gowin 按 2001 编译，SV 专有构造会被静默丢弃）。
//    ④ 可观测性（K-106）：读写指针引出，便于上板诊断。
//
//  ⭐ 环形缓冲延迟线（标准做法）：
//    · 深度 DEPTH = 2^ADDR_W（≥ DELAY_SAMPLES），地址天然回绕。
//    · 写指针 wr：每 tick 自增，写入「当前干声 + 反馈回的旧样点」。
//    · 读指针 rd = wr − D（D = 延迟样本数），读 D 拍前写入的样点 = 湿声。
//    · 反馈：湿声 × feedback 写回 ⇒ 反复回声。
//    · 干湿混合：out = dry×(1−mix) + wet×mix，用移位近似 mix/feedback（省 DSP）。
//
//  ⭐ 关键：rd 必须在「写」之前读（当拍先读旧值，再写入新值），
//    用组合读 + 寄存器延迟样点，保证读到的是「写前」的旧样本。
// ═══════════════════════════════════════════════════════════════════════════
`default_nettype none

module fx_delay #(
    parameter integer SAMPLE_W      = 24,     // 样点位宽
    parameter integer DELAY_SAMPLES = 9766,   // 200 ms @ 48.83 kHz（预研 §2.2）
    parameter integer ADDR_W        = 14      // = clog2(DEPTH)，DEPTH ≥ DELAY_SAMPLES
) (
    input  wire                        clk_i,
    input  wire                        rst_n_i,          // ⭐ 同步复位、低有效

    input  wire                        sample_tick_i,    // ⭐ 节拍使能（复用 master_mix 的）
    input  wire                        valid_i,
    input  wire signed [SAMPLE_W-1:0]  sample_i,         // 干声（来自 master_mix.sample_o）

    input  wire                        fx_en_i,          // ← uart_ui.fx_en_o（1=开）
    input  wire [7:0]                  mix_i,            // 干湿比（Q0.8，[0,1)）
    input  wire [7:0]                  feedback_i,       // 反馈系数（Q0.8，[0,1)）

    output wire                        valid_o,
    output wire signed [SAMPLE_W-1:0]  sample_o,

    // ⭐ K-106 可观测
    output wire [ADDR_W-1:0]           wr_ptr_o,
    output wire [ADDR_W-1:0]           rd_ptr_o
);

    // ── 常量 ────────────────────────────────────────────────────────────────
    localparam integer DEPTH = (1 << ADDR_W);   // 环形缓冲深度（地址回绕）

    // ── 环形缓冲（BSRAM 推断）───────────────────────────────────────────────
    reg signed [SAMPLE_W-1:0] delay_mem [0:DEPTH-1];

    // ── 读写指针 ────────────────────────────────────────────────────────────
    reg [ADDR_W-1:0] wr_r;
    // rd = wr − D（ADDR_W 位减法，自动模 2^ADDR_W 回绕）
    wire [ADDR_W-1:0] rd = wr_r - DELAY_SAMPLES[ADDR_W-1:0];

    // ⭐ 当拍组合读：读到「写前」的旧样本（延迟样点）
    //   ⚠️ 这里不能写成 always 的寄存器读，否则多插一拍延迟。
    //   组合读 delay_mem[rd]，在「写」发生前的同拍，读出旧值。
    wire signed [SAMPLE_W-1:0] delayed = delay_mem[rd];

    // ── 反馈：湿声 × feedback（移位近似，用 feedback_i 高位选档）────────────
    //   feedback_i 是 Q0.8 分数，但为省 DSP 只取高 3 bit 当「移位量档位」：
    //   档 0..7 ⇒ 反馈 ≈ 0, 1/8, 2/8, …, 7/8（档 n ⇒ 乘 n/8）。
    wire [2:0] fb_lvl = feedback_i[7:5];
    // fb_scaled = delayed × (fb_lvl/8)：delayed(24b)×fb_lvl(0..7) → 27 bit，>>3 取回 24 bit
    wire signed [SAMPLE_W+2:0] fb_prod = delayed * $signed({1'b0, fb_lvl});
    wire signed [SAMPLE_W-1:0]  fb_scaled = fb_prod[SAMPLE_W+2:3];

    // ── 写回值：干声 + 反馈（fx_en 关闭时只写干声）─────────────────────────
    wire signed [SAMPLE_W-1:0] write_val = fx_en_i ? (sample_i + fb_scaled) : sample_i;

    // ── 干湿混合（移位近似 mix）─────────────────────────────────────────────
    //   mix_i 高 3 bit = 档位 0..7 ⇒ 湿声占比 = mix_lvl/8
    wire [2:0] mix_lvl = mix_i[7:5];
    // out = dry + (wet − dry) × (mix_lvl/8)，用 >>3 近似
    wire signed [SAMPLE_W:0] diff = {delayed[SAMPLE_W-1], delayed} - {sample_i[SAMPLE_W-1], sample_i};
    wire signed [SAMPLE_W:0] diff_scaled = (diff * $signed({1'b0, mix_lvl})) >>> 3;
    wire signed [SAMPLE_W-1:0] mixed = sample_i + diff_scaled[SAMPLE_W-1:0];

    // ── 主逻辑 ──────────────────────────────────────────────────────────────
    integer mi;
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            wr_r <= {ADDR_W{1'b0}};
            // ⭐ 复位清零延迟线（⛔ 否则反馈读到 x，整条链被 x 污染写不进真实数据）
            //   首发版用循环清零；若综合时序/资源吃紧，可改为「首次 valid 前不反馈」门控。
            for (mi = 0; mi < DEPTH; mi = mi + 1)
                delay_mem[mi] <= {SAMPLE_W{1'b0}};
        end
        else if (sample_tick_i) begin
            // 写：当前干声 + 反馈（写发生在读之后，读的是旧值 ✓）
            delay_mem[wr_r] <= write_val;
            wr_r <= wr_r + 1'b1;
        end
    end

    // ── 输出：零延迟透传 valid，干湿混合输出 ────────────────────────────────
    assign valid_o  = valid_i;
    assign sample_o = fx_en_i ? mixed : sample_i;

    assign wr_ptr_o = wr_r;
    assign rd_ptr_o = rd;

    // ── 参数自检（K-106：⛔ 静默）───────────────────────────────────────────
    initial begin
        if (DELAY_SAMPLES < 2)
            $display("ERROR [fx_delay] DELAY_SAMPLES=%0d must be >= 2", DELAY_SAMPLES);
        if ((1 << ADDR_W) < DELAY_SAMPLES)
            $display("ERROR [fx_delay] 2^ADDR_W=%0d < DELAY_SAMPLES=%0d", (1 << ADDR_W), DELAY_SAMPLES);
        if (DELAY_SAMPLES >= (1 << ADDR_W))
            $display("ERROR [fx_delay] DELAY_SAMPLES=%0d must be < DEPTH=%0d", DELAY_SAMPLES, (1 << ADDR_W));
    end

endmodule
`default_nettype wire
