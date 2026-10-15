// Frozen BG mixer reference. Only module name and full-line comments differ.
`timescale 1ns/1ps
`default_nettype none

module tdm_render_mixer_bg_reference #(
    parameter integer POLY_TARGET         = 32,
    parameter integer OSC_PER_VOICE       = 2,
    parameter integer OSC_SAMPLE_W        = 16,
    parameter integer ENV_W               = 16,
    parameter integer SAMPLE_W            = 24,
    parameter integer CLK_PER_SAMPLE      = 1024,
    parameter integer RENDER_DEADLINE_CYC = 927,
    parameter integer RESERVED_N          = 0,
    parameter integer NORM_GAIN_STEP      = 1,
    parameter integer OUTPUT_HEADROOM_SH  = 0
) (
    input  wire                                             clk_i,
    input  wire                                             rst_n_i,
    input  wire                                             render_start_i,
    input  wire [POLY_TARGET*OSC_PER_VOICE*OSC_SAMPLE_W-1:0] osc_sample_bus_i,
    input  wire [POLY_TARGET*ENV_W-1:0]                     env_level_i,
    input  wire [POLY_TARGET-1:0]                           voice_active_i,
    output wire                                             dry_valid_o,
    output wire signed [SAMPLE_W-1:0]                       dry_sample_o,
    output wire                                             deadline_fault_o,
    output wire [$clog2(POLY_TARGET):0]                     n_active_o
);

    localparam integer LW  = (POLY_TARGET <= 1) ? 1 : $clog2(POLY_TARGET);
    localparam integer OW  = (OSC_PER_VOICE <= 1) ? 1 : $clog2(OSC_PER_VOICE);
    localparam integer SUM_W = OSC_SAMPLE_W + OW + 1;
    localparam integer PROD_W = SUM_W + ENV_W;
    localparam integer ACC_W = PROD_W + LW + 1;

    localparam [LW:0] CNT_LAST  = POLY_TARGET[LW:0];
    localparam [LW:0] CNT_TOTAL = (POLY_TARGET + 2);

    localparam [LW:0] CNT_MAX_V  = {LW+1{1'b1}};
    localparam [LW:0] DEADLINE_C = (RENDER_DEADLINE_CYC > CNT_MAX_V)
                                   ? CNT_MAX_V
                                   : RENDER_DEADLINE_CYC[LW:0];

    reg [LW:0]  cnt;
    reg         busy;
    reg         valid_r;

    localparam [LW-1:0] LAST_IDX = POLY_TARGET - 1;
    wire [LW-1:0] cnt_sel = (cnt[LW-1:0] > LAST_IDX) ? LAST_IDX : cnt[LW-1:0];

    parameter integer LANE_WS = 4;                                    // ⭐ 权重和 = 2^4 = 16
    parameter integer LANE_W0 = (OSC_PER_VOICE <= 1) ? 16 : 9;        // ⭐ 1.125 = 9/8（单 lane ⇒ 单位增益） // 注意：仅用于自检，⛔ 不参与运算（实现在 :255 的 shift/add 恒等式里）
    parameter integer LANE_W1 = (OSC_PER_VOICE <= 1) ? 0  : 7;        // ⭐ 0.875 = 7/8 // 注意：仅用于自检，⛔ 不参与运算（实现在 :255 的 shift/add 恒等式里）

    localparam integer LSUM_W = SUM_W + LANE_WS;

    reg signed [SUM_W-1:0]  vs_c;
    reg signed [SUM_W-1:0]  vs_sum;    // ⭐ 普通 lane 和（⛔ 不含权重）
    reg signed [SUM_W-1:0]  vs_dif;    // ⭐ lane 差（⭐ 只用前两个 lane）
    reg signed [LSUM_W-1:0] vs_w;      // ⭐ 加权和（⛔ 不要用 `SUM_W`，会溢出）
    integer oi;

    always @(*) begin
        vs_sum = {SUM_W{1'b0}};
        for (oi = 0; oi < OSC_PER_VOICE; oi = oi + 1)
            vs_sum = vs_sum + $signed(osc_sample_bus_i[(cnt_sel*OSC_PER_VOICE + oi)*OSC_SAMPLE_W +: OSC_SAMPLE_W]);

        if (OSC_PER_VOICE <= 1) begin
            vs_c = vs_sum;
        end else if (OSC_PER_VOICE == 2) begin
            vs_dif = $signed(osc_sample_bus_i[cnt_sel*2*OSC_SAMPLE_W +: OSC_SAMPLE_W])
                   - $signed(osc_sample_bus_i[(cnt_sel*2+1)*OSC_SAMPLE_W +: OSC_SAMPLE_W]);
            vs_w   = $signed({vs_sum, 3'b0}) + vs_dif;   // ⭐ 8·(L0+L1) + (L0−L1) = 9L0+7L1
            vs_c   = vs_w >>> LANE_WS;                   // ⭐ ÷16（权重和）
        end else begin
            vs_c = vs_sum >>> 1;
        end
    end

    initial begin
        if ((LANE_W0 != 9) || (LANE_W1 != 7))
            $display("ERROR [tdm_render_mixer] LANE_W0/W1 = (%0d,%0d) but the shift/add identity implements (9,7) => THE PARAMETERS HAVE NO EFFECT, update the code (see the LANE_W0 comment)",
                     LANE_W0, LANE_W1);
    end

    wire [ENV_W-1:0] env_c = env_level_i[cnt_sel*ENV_W +: ENV_W];

    reg signed [SUM_W-1:0] vs_c_r;
    reg        [ENV_W-1:0] env_c_r;
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            vs_c_r  <= {SUM_W{1'b0}};
            env_c_r <= {ENV_W{1'b0}};
        end else if (busy) begin
            vs_c_r  <= vs_c;
            env_c_r <= env_c;
        end
    end

    wire signed [SUM_W-1:0]   vs_s   = vs_c_r;
    wire signed [ENV_W:0]     env_s  = $signed({1'b0, env_c_r});
    wire signed [PROD_W-1:0]  prod_c = vs_s * env_s;

    reg signed [PROD_W-1:0] prod_r;
    reg signed [ACC_W-1:0]  acc_r;

    reg fault_r;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            cnt      <= {(LW+1){1'b0}};
            busy     <= 1'b0;
            valid_r  <= 1'b0;
            prod_r   <= {PROD_W{1'b0}};
            acc_r    <= {ACC_W{1'b0}};
            fault_r  <= 1'b0;
        end else begin
            valid_r <= 1'b0;

            if (render_start_i) begin
                cnt    <= {(LW+1){1'b0}};
                busy   <= 1'b1;
                acc_r  <= {ACC_W{1'b0}};
                prod_r <= {PROD_W{1'b0}};
            end else if (busy) begin
                if (cnt >= 2 && (cnt <= CNT_LAST + 1'b1))
                    acc_r <= acc_r + prod_r;

                prod_r <= prod_c;

                if (cnt == CNT_TOTAL[LW:0]) begin
                    busy    <= 1'b0;
                    valid_r <= 1'b1;
                end else begin
                    cnt <= cnt + 1'b1;
                end

                if (cnt >= DEADLINE_C)
                    fault_r <= 1'b1;
            end
        end
    end

    wire signed [ACC_W-1:0] sh = acc_r >>> ENV_W;

    localparam integer SCALE_UP = SAMPLE_W - 16;      // ⭐ 24-16 = 8
    wire signed [ACC_W-1:0] sh24 = sh <<< SCALE_UP;


    localparam integer NORMAL_N = (RESERVED_N >= POLY_TARGET)
                                  ? 0 : (POLY_TARGET - RESERVED_N);

    wire [LW:0] pc_l1 [0:POLY_TARGET/2-1];
    genvar gi;
    generate
        for (gi = 0; gi < POLY_TARGET/2; gi = gi + 1) begin : g_pc1
            assign pc_l1[gi] = ((gi*2   < NORMAL_N) ? {{LW{1'b0}}, voice_active_i[gi*2]}   : {(LW+1){1'b0}})
                             + ((gi*2+1 < NORMAL_N) ? {{LW{1'b0}}, voice_active_i[gi*2+1]} : {(LW+1){1'b0}});
        end
    endgenerate

    reg [LW:0] pc_sum;
    integer pi;
    always @(*) begin
        pc_sum = {(LW+1){1'b0}};
        for (pi = 0; pi < POLY_TARGET/2; pi = pi + 1)
            pc_sum = pc_sum + pc_l1[pi];
    end

    reg [LW:0] n_active_r;
    always @(posedge clk_i) begin
        if (!rst_n_i)            n_active_r <= {(LW+1){1'b0}};
        else if (render_start_i) n_active_r <= pc_sum;
    end
    assign n_active_o = n_active_r;
    wire [LW:0] n_active = n_active_r;


    function [15:0] gain_sqrt_lut;
        input [LW:0] n;
        begin
            case (n)
                6'd0:  gain_sqrt_lut = 16'd64;    // ⭐ 无 voice（增益无意义，取安全值）
                6'd1:  gain_sqrt_lut = 16'd64;    // 64/√1  = 64.0
                6'd2:  gain_sqrt_lut = 16'd45;    // 64/√2  = 45.3
                6'd3:  gain_sqrt_lut = 16'd37;    // 64/√3  = 37.0
                6'd4:  gain_sqrt_lut = 16'd32;    // 64/√4  = 32.0
                6'd5:  gain_sqrt_lut = 16'd29;    // 64/√5  = 28.6
                6'd6:  gain_sqrt_lut = 16'd26;    // 64/√6  = 26.1
                6'd7:  gain_sqrt_lut = 16'd24;    // 64/√7  = 24.2
                6'd8:  gain_sqrt_lut = 16'd23;    // 64/√8  = 22.6
                6'd9:  gain_sqrt_lut = 16'd21;    // 64/√9  = 21.3
                6'd10: gain_sqrt_lut = 16'd20;    // 64/√10 = 20.2
                6'd11: gain_sqrt_lut = 16'd19;    // 64/√11 = 19.3
                6'd12: gain_sqrt_lut = 16'd18;    // 64/√12 = 18.5
                6'd13: gain_sqrt_lut = 16'd18;    // 64/√13 = 17.8
                6'd14: gain_sqrt_lut = 16'd17;    // 64/√14 = 17.1
                6'd15: gain_sqrt_lut = 16'd17;    // 64/√15 = 16.5
                6'd16: gain_sqrt_lut = 16'd16;    // 64/√16 = 16.0
                6'd17: gain_sqrt_lut = 16'd16;    // 64/√17 = 15.5
                6'd18: gain_sqrt_lut = 16'd15;    // 64/√18 = 15.1
                6'd19: gain_sqrt_lut = 16'd15;    // 64/√19 = 14.7
                6'd20: gain_sqrt_lut = 16'd14;    // 64/√20 = 14.3
                6'd21: gain_sqrt_lut = 16'd14;    // 64/√21 = 14.0
                6'd22: gain_sqrt_lut = 16'd14;    // 64/√22 = 13.6
                6'd23: gain_sqrt_lut = 16'd13;    // 64/√23 = 13.3
                6'd24: gain_sqrt_lut = 16'd13;    // 64/√24 = 13.1
                6'd25: gain_sqrt_lut = 16'd13;    // 64/√25 = 12.8
                6'd26: gain_sqrt_lut = 16'd13;    // 64/√26 = 12.6
                6'd27: gain_sqrt_lut = 16'd12;    // 64/√27 = 12.3
                6'd28: gain_sqrt_lut = 16'd12;    // 64/√28 = 12.1
                6'd29: gain_sqrt_lut = 16'd12;    // 64/√29 = 11.9
                6'd30: gain_sqrt_lut = 16'd12;    // 64/√30 = 11.7
                6'd31: gain_sqrt_lut = 16'd11;    // 64/√31 = 11.5
                default: gain_sqrt_lut = 16'd11;  // 64/√32 = 11.3
            endcase
        end
    endfunction

    reg [15:0] norm_gain_r;
    wire [15:0] norm_gain_target = gain_sqrt_lut(n_active_r);
    localparam [15:0] NORM_GAIN_STEP_W = NORM_GAIN_STEP;
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            norm_gain_r <= 16'd64;
        end else if (NORM_GAIN_STEP == 0) begin
            norm_gain_r <= norm_gain_target;
        end else if (render_start_i) begin
            if (norm_gain_target > norm_gain_r)
                norm_gain_r <= ((norm_gain_target - norm_gain_r) > NORM_GAIN_STEP_W)
                             ? (norm_gain_r + NORM_GAIN_STEP_W) : norm_gain_target;
            else if (norm_gain_target < norm_gain_r)
                norm_gain_r <= ((norm_gain_r - norm_gain_target) > NORM_GAIN_STEP_W)
                             ? (norm_gain_r - NORM_GAIN_STEP_W) : norm_gain_target;
        end
    end
    wire [15:0] norm_gain = norm_gain_r;

    reg signed [ACC_W+15:0] sh_norm_r;
    always @(posedge clk_i) begin
        if (!rst_n_i)
            sh_norm_r <= {(ACC_W+16){1'b0}};
        else
            sh_norm_r <= (sh24 * $signed({1'b0, norm_gain_r}))
                         >>> (7 + OUTPUT_HEADROOM_SH);
    end
    wire signed [ACC_W+15:0] sh_norm_w = sh_norm_r;

    localparam signed [ACC_W+15:0] LIM_TH_W = {{(ACC_W-8){1'b0}}, 24'sh700000};  // T = 7/8 FS
    wire signed [ACC_W+15:0] exc_pos = (sh_norm_w > LIM_TH_W)
                                    ? (sh_norm_w - LIM_TH_W) : {(ACC_W+16){1'b0}};
    wire signed [ACC_W+15:0] exc_neg = (sh_norm_w < -LIM_TH_W)
                                    ? ((-LIM_TH_W) - sh_norm_w) : {(ACC_W+16){1'b0}};
    reg signed [ACC_W+15:0] exc_pos_d;
    reg signed [ACC_W+15:0] exc_neg_d;
    reg signed [ACC_W+15:0] sh_norm_d;
    reg signed [ACC_W+15:0] exc_pos_sq_d;
    reg signed [ACC_W+15:0] exc_neg_sq_d;
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            exc_pos_d    <= {(ACC_W+16){1'b0}};
            exc_neg_d    <= {(ACC_W+16){1'b0}};
            sh_norm_d    <= {(ACC_W+16){1'b0}};
            exc_pos_sq_d <= {(ACC_W+16){1'b0}};
            exc_neg_sq_d <= {(ACC_W+16){1'b0}};
        end else begin
            exc_pos_d    <= exc_pos;
            exc_neg_d    <= exc_neg;
            sh_norm_d    <= sh_norm_w;
            exc_pos_sq_d <= (exc_pos * exc_pos) >>> 21;
            exc_neg_sq_d <= (exc_neg * exc_neg) >>> 21;
        end
    end
    localparam signed [ACC_W+15:0] KNEE_W = {{(ACC_W-8){1'b0}}, 24'sh100000};   // W = 2^20
    wire signed [ACC_W+15:0] ceil_w    = LIM_TH_W + (KNEE_W >>> 1);   // T + W/2 = 0x780000 = 15/16 FS
    wire signed [ACC_W+15:0] knee_pos  = (exc_pos_d >= KNEE_W)
                                       ? ceil_w
                                       : (LIM_TH_W + exc_pos_d - exc_pos_sq_d);
    wire signed [ACC_W+15:0] knee_neg  = (exc_neg_d >= KNEE_W)
                                       ? ceil_w
                                       : (LIM_TH_W + exc_neg_d - exc_neg_sq_d);
    wire signed [ACC_W+15:0] lim_pos = (sh_norm_d >  LIM_TH_W) ?  knee_pos : sh_norm_d;
    wire signed [ACC_W+15:0] lim_neg = (sh_norm_d < -LIM_TH_W) ? -knee_neg : sh_norm_d;
    wire signed [ACC_W+15:0] lim_w   = (sh_norm_d > LIM_TH_W) ? lim_pos : lim_neg;

    wire [ACC_W+15:0] sh_final_w = lim_w;
    wire over_pos = ~sh_final_w[ACC_W+15] && (|sh_final_w[ACC_W+14 : SAMPLE_W-1]);
    wire over_neg =  sh_final_w[ACC_W+15] && ~(&sh_final_w[ACC_W+14 : SAMPLE_W-1]);

    reg signed [SAMPLE_W-1:0] samp_r;
    always @(posedge clk_i) begin
        if (!rst_n_i)
            samp_r <= {SAMPLE_W{1'b0}};
        else if (over_pos)
            samp_r <= {1'b0, {(SAMPLE_W-1){1'b1}}};   // +最大（2^(W-1)-1）
        else if (over_neg)
            samp_r <= {1'b1, {(SAMPLE_W-1){1'b0}}};   // −最小（−2^(W-1)）
        else
            samp_r <= lim_w[SAMPLE_W-1:0];            // ⭐ 限幅后【才】截到 24 位
    end

    reg [3:0] valid_d;
    always @(posedge clk_i) begin
        if (!rst_n_i) valid_d <= 4'b0000;
        else          valid_d <= {valid_d[2:0], valid_r};
    end
    assign dry_valid_o      = valid_d[3];
    assign dry_sample_o     = samp_r;
    assign deadline_fault_o = fault_r;

    initial begin
        if (CNT_TOTAL > RENDER_DEADLINE_CYC)
            $display("ERROR [tdm_render_mixer] POLY_TARGET+2=%0d > RENDER_DEADLINE_CYC=%0d => 每帧都会超时（A6 失效）",
                     CNT_TOTAL, RENDER_DEADLINE_CYC);
        if (CNT_TOTAL > CLK_PER_SAMPLE)
            $display("ERROR [tdm_render_mixer] POLY_TARGET+2=%0d > CLK_PER_SAMPLE=%0d => 帧内跑不完（会周期性错帧）",
                     CNT_TOTAL, CLK_PER_SAMPLE);
        if ((OUTPUT_HEADROOM_SH < 0) || (OUTPUT_HEADROOM_SH > 3))
            $display("ERROR [tdm_render_mixer] OUTPUT_HEADROOM_SH=%0d outside 0..3",
                     OUTPUT_HEADROOM_SH);

        if (gain_sqrt_lut(6'd1) != 16'd64)
            $display("ERROR [tdm_render_mixer] P0-32: gain_sqrt_lut[N=1]=%0d != 64 => 文档口径（基准 64）已失效，必须同步改注释",
                     gain_sqrt_lut(6'd1));
        $display("INFO  [tdm_render_mixer] P0-32 交付口径: 基准=64 · OUTPUT_HEADROOM_SH=%0d => 单音峰 ≈ %0d%% FS",
                 OUTPUT_HEADROOM_SH, (100 * 64) >> (7 + OUTPUT_HEADROOM_SH));
    end

endmodule

`default_nettype wire
