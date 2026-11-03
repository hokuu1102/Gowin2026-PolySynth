`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// debounce.sv · 按键 + EC11 编码器去抖与正交解码（T14，丙线 L9）
//
// 硬件事实（files/10-硬件/ 接口总表 + K-12 / K-62）：
//   · 4 个按键 + EC11 编码器 A/B/SW 全部【直连 FPGA】，⛔ 无并串器件（K-12）。
//   · 按键/编码器均为【上拉输入】⇒ ACTIVE_LOW = 1（按下 = 0）。
//
// ⭐ 与 sync_input 的关系（K-62）：本模块【先去抖】，但输入仍是板外异步信号，
//    因此【必须先接 sync_input 打两拍再去抖】。本模块在端口层面不例化 sync_input，
//    由顶层负责同步（与 K-62「仍待做：把 SPI/按键输入实际接上 sync_input」一致）；
//    但为便于独立单元验证，tb 里会在激励前先经过一个 2 级同步器模型。
//
// 输出语义：
//   key_level[i]   去抖后的稳定电平（1 = 按下，已按 ACTIVE_LOW 归一化）
//   key_down[i]    1 周期脉冲：按下事件（一次按下只产生一次）
//   key_up[i]      1 周期脉冲：释放事件
//   enc_cw/enc_ccw 1 周期脉冲：EC11 每走一个格雷步产生一次（4 步 / 1 定位）
//   enc_err        1 周期脉冲：A/B 同时变化（非法跳变），已滤除、不产生计数
//
// 判据（K-01 同款思路——「只产生一次事件」必须可失败）：
//   注入抖动序列后，key_down/key_up 各恰好一次、enc_cw 按格雷步精确计数。
// ─────────────────────────────────────────────────────────────────────────────
module debounce #(
    parameter integer NKEY       = 4,              // 直连按键数
    parameter integer CLK_HZ     = 50_000_000,     // 系统时钟
    parameter integer DB_MS      = 5,              // 去抖稳定时间（ms）
    parameter integer ACTIVE_LOW = 1               // 1 = 硬件低有效（上拉，按下接地）
) (
    input  wire            clk,
    input  wire            rst_n,

    // ---- 4 个直连按键 --------------------------------------------------------
    input  wire [NKEY-1:0] key_in,
    output reg  [NKEY-1:0] key_level,
    output wire [NKEY-1:0] key_down,
    output wire [NKEY-1:0] key_up,

    // ---- EC11 编码器 ---------------------------------------------------------
    input  wire            enc_a,
    input  wire            enc_b,
    input  wire            enc_sw,
    output reg             enc_a_lvl,
    output reg             enc_b_lvl,
    output reg             enc_sw_lvl,
    output wire            enc_sw_down,
    output wire            enc_sw_up,
    output reg             enc_cw,
    output reg             enc_ccw,
    output wire [1:0]      enc_state,
    output reg             enc_err
);

    // ── 去抖稳定周期数：DB_MS 毫秒换算成系统时钟拍 ─────────────────────────
    localparam integer DB_CYC_RAW = (CLK_HZ / 1000) * DB_MS;
    localparam integer DB_CYC = (DB_CYC_RAW < 1) ? 1 : DB_CYC_RAW;

    // ── 按键：NKEY 路计数去抖 ───────────────────────────────────────────────
    // 每路独立计数器：输入必须连续稳定 DB_CYC 拍才更新输出电平。
    // ⭐ 归一化：先按 ACTIVE_LOW 把物理电平归一成「1 = 按下/有效」，再与输出比较。
    reg [31:0] key_cnt [0:NKEY-1];
    wire [NKEY-1:0] key_norm;
    integer    ki;

    assign key_norm = ACTIVE_LOW ? ~key_in : key_in;

    always @(posedge clk) begin
        if (!rst_n) begin
            for (ki = 0; ki < NKEY; ki = ki + 1) begin
                key_level[ki] <= 1'b0;
                key_cnt[ki]   <= 32'd0;
            end
        end else begin
            for (ki = 0; ki < NKEY; ki = ki + 1) begin
                if (key_norm[ki] == key_level[ki]) begin
                    key_cnt[ki] <= 32'd0;
                end else if (key_cnt[ki] >= DB_CYC - 1) begin
                    key_level[ki] <= key_norm[ki];
                    key_cnt[ki]   <= 32'd0;
                end else begin
                    key_cnt[ki] <= key_cnt[ki] + 32'd1;
                end
            end
        end
    end

    // ── 边沿检测（1 周期脉冲）──────────────────────────────────────────────
    reg [NKEY-1:0] key_level_d;
    always @(posedge clk) begin
        if (!rst_n) key_level_d <= {NKEY{1'b0}};
        else        key_level_d <= key_level;
    end
    assign key_down =  key_level & ~key_level_d;
    assign key_up   = ~key_level &  key_level_d;

    // ── EC11 编码器：A/B/SW 三路各自独立去抖 ────────────────────────────────
    // ⭐ A/B 是正交编码：方向语义绑定【物理接线】，⛔ 不能在去抖时归一化取反
    //    （取反会把正转变成反转）。故 A/B 去抖后【保持物理电平】；
    //    只有 SW 键（和普通按键一样是"开关到地"）才做 ACTIVE_LOW 归一化。
    reg [31:0] enc_cnt [0:2];
    reg [2:0]  enc_lvl;      // [0]=A物理, [1]=B物理, [2]=SW归一化后
    integer    ei;

    wire [2:0] enc_in = {enc_sw, enc_b, enc_a};
    // 归一化：仅 SW（bit2）取反，A/B（bit0/1）保持物理电平。
    wire [2:0] enc_norm = ACTIVE_LOW ? {~enc_in[2], enc_in[1], enc_in[0]}
                                      : enc_in;

    always @(posedge clk) begin
        if (!rst_n) begin
            enc_lvl <= 3'b000;
            for (ei = 0; ei < 3; ei = ei + 1) enc_cnt[ei] <= 32'd0;
        end else begin
            for (ei = 0; ei < 3; ei = ei + 1) begin
                if (enc_norm[ei] == enc_lvl[ei]) begin
                    enc_cnt[ei] <= 32'd0;
                end else if (enc_cnt[ei] >= DB_CYC - 1) begin
                    enc_lvl[ei] <= enc_norm[ei];
                    enc_cnt[ei] <= 32'd0;
                end else begin
                    enc_cnt[ei] <= enc_cnt[ei] + 32'd1;
                end
            end
        end
    end

    // SW 键的去抖后电平与边沿
    always @(posedge clk) begin
        if (!rst_n) begin
            enc_a_lvl  <= 1'b0;
            enc_b_lvl  <= 1'b0;
            enc_sw_lvl <= 1'b0;
        end else begin
            enc_a_lvl  <= enc_lvl[0];
            enc_b_lvl  <= enc_lvl[1];
            enc_sw_lvl <= enc_lvl[2];
        end
    end

    reg enc_sw_lvl_d;
    always @(posedge clk) begin
        if (!rst_n) enc_sw_lvl_d <= 1'b0;
        else        enc_sw_lvl_d <= enc_sw_lvl;
    end
    assign enc_sw_down =  enc_sw_lvl & ~enc_sw_lvl_d;
    assign enc_sw_up   = ~enc_sw_lvl &  enc_sw_lvl_d;

    // ── 正交解码：格雷序列 00 → 01 → 11 → 10 → 00 记为正转（CW）────────────
    // 两位同时变化视为非法跳变，只报 enc_err，不产生计数。
    assign enc_state = {enc_b_lvl, enc_a_lvl};

    reg [1:0] st_d;
    always @(posedge clk) begin
        if (!rst_n) st_d <= 2'b00;
        else        st_d <= enc_state;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            enc_cw  <= 1'b0;
            enc_ccw <= 1'b0;
            enc_err <= 1'b0;
        end else begin
            enc_cw  <= 1'b0;
            enc_ccw <= 1'b0;
            enc_err <= 1'b0;
            case ({st_d, enc_state})
                // 合法 · 正转
                4'b00_01: enc_cw  <= 1'b1;
                4'b01_11: enc_cw  <= 1'b1;
                4'b11_10: enc_cw  <= 1'b1;
                4'b10_00: enc_cw  <= 1'b1;
                // 合法 · 反转
                4'b00_10: enc_ccw <= 1'b1;
                4'b10_11: enc_ccw <= 1'b1;
                4'b11_01: enc_ccw <= 1'b1;
                4'b01_00: enc_ccw <= 1'b1;
                // 非法 · 两位同时变化
                4'b00_11: enc_err <= 1'b1;
                4'b11_00: enc_err <= 1'b1;
                4'b01_10: enc_err <= 1'b1;
                4'b10_01: enc_err <= 1'b1;
                default: ;
            endcase
        end
    end

endmodule
