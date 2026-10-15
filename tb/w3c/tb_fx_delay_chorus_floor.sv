`timescale 1ns/1ps
// ============================================================================
// tb_fx_delay_chorus_floor.sv -- C14：合唱【读下界】判据（⭐ 直连 `fx_delay`）
//
//  ⭐ 为什么需要这一条：`fx_delay.v` 的 `DLY_MIN_CH`（合唱模式的读下界）
//     ⛔ **在本次修复之前完全没有判据** —— `tb_fx_chain` / `tb_fx_delay_production`
//     / `tb_fx_chain_latency_contract` 三个 tb 都**没在合唱模式下**把
//     `delay_i` 推到下界、也**没检查** LFO 峰附近的湿声值
//     ⇒ 🔴 "下界差 1"（128 而不是 129）**能一路全绿地漏过去**。
//
//  ── 不变量（⭐ 判据的推导，⛔ 不是经验值）─────────────────────────────────
//     · 读基址 ≡ 本样本自己的写地址（`wr_s0` 与 `rd0_s0` **同沿同源**）
//       ⇒ 上一样本的写地址 = 基址 − 1
//     · tap0 读（`T_k`）  需 `D ≥ f + 1`
//     · tap1 读（`T_k+1`）需 `D ≥ f + 2`
//       ⭐ 因为 tap1 落在【基址 − 1】（= 上一样本已写的槽）才可见；
//          落在【基址】就是**本样本正在写的槽** ⇒ 读到**上一圈**（≈ DEPTH 样点前）
//     · `f = floor(mod_Q8/256)`，`mod_Q8 ∈ [−32768, +32666]` ⇒ `f ∈ [−128, +127]`
//       ⇒ ⭐⭐ **合唱下界 = MOD + 1 = 129**
//     🔴 若下界 = 128：`D=128, m=+127` 时 tap1 落在基址 ⇒ 插值权重 254/256
//        ⇒ 湿声几乎全是**上一圈的错值**，且触发窗口 = 每 LFO 周期 **64 个样点**
//        ⇒ ⭐ 周期性爆音（这正是本次要修的现象）。
//
//  ── 本 tb 的构造（⭐ 让"差 1"必然暴露）───────────────────────────────────
//     · `AW=10` ⇒ DEPTH=1024（小线，填 2 圈只要 2048 个样点，仿真快）
//     · `CHORUS_MOD_SAMPLES=128` · `LFO_INC=2048` ⇒ **16 个样点**就到三角峰
//       （`lfo_r=32768 → tri=32767 → mod_Q8=32766 → f=+127`；⭐ LFO 周期 = 65536/2048
//        = **32 个样点** ⇒ 96 个样点的窗口里峰出现 **3 次**：n = 2064 / 2096 / 2128）
//     · `sel=1`（合唱）· `delay_i=0` ⇒ **必被夹到 `DLY_MIN_CH`**
//     · `mix=128`（0.5）· `fb=0` ⇒ `sample_o = x[n] + (wet >>> 1)`（干声恒 1.0）
//     · 用**斜坡** `x[n] = 64·n − 98304` 填满 `2·DEPTH`，再继续灌 `96` 个样点
//       （斜坡步长 64 ⇒ 18 bit 存储**无损**，期望值可以逐点精确算出来）
//     · 断言：`2·(sample_o − x[n]) ≈ x[n − (MOD+1)]`
//       ⭐ 容差 `TOL = 2·MOD·STEP = 16384`（精确界 = `MOD·STEP = 8192`）
//       🔴 下界 = 128 时，LFO 峰那几拍读到上一圈 ⇒ 差 ≈ `DEPTH·STEP = 65536`
//          ≫ 容差 ⇒ **必红**（本 tb 已实测：`|err| = 56770`）
//       ✅ 下界 = 129 时全绿（实测 `worst |err| = 8192` = 精确界）
//
//  ⚠️ 本 tb 判据的**能红实证**（⭐ 见交付报告）：把 `DLY_MIN_CH` 退回
//     `CHORUS_MOD_SAMPLES`（= 128）⇒ 本 tb 立刻 FAIL，且只在
//     `f = MOD−1` 的样点上报错 ⇒ ⭐ 证明判据不是空洞的。
// ============================================================================
`default_nettype none

module tb_fx_delay_chorus_floor;

    localparam integer SAMPLE_W = 24;
    localparam integer AW       = 10;          // ⭐ DEPTH = 1024
    localparam integer MIX_W    = 8;
    localparam integer FB_W     = 8;
    localparam integer MOD      = 128;         // ⭐ CHORUS_MOD_SAMPLES
    localparam integer LFO_INC  = 2048;        // ⭐ 16 个样点就到三角峰
    localparam integer DEPTH    = (1 << AW);
    localparam integer PRIME    = 2 * DEPTH;   // ⭐ 灌 2 圈 ⇒ 线里全是斜坡
    localparam integer WINDOW   = 96;          // ⭐ 峰（f=+127）出现 3 次（周期 32）
    localparam integer STEP     = 64;          // ⭐ 斜坡步长（64 的倍数）
    localparam integer OFF      = -98304;      // ⭐ = −1536×64
    localparam integer D_EXP    = MOD + 1;     // ⭐⭐ 判据：下界 = MOD + 1 = 129
    localparam integer TOL      = 2 * MOD * STEP;   // ⭐ 16384（精确界 8192）

    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg                        rst_n    = 1'b0;
    reg                        valid_i  = 1'b0;
    reg  signed [SAMPLE_W-1:0] sample_i = 24'sd0;

    wire                       valid_o;
    wire signed [SAMPLE_W-1:0] sample_o;
    wire [AW-1:0]              wr_ptr_o;
    wire                       primed_o;
    wire [15:0]                sat_cnt_o;
    wire [15:0]                clamp_cnt_o;

    fx_delay #(
        .SAMPLE_W (SAMPLE_W), .MEM_W (18), .AW (AW),
        .MIX_W    (MIX_W),    .FB_W  (FB_W),
        .LFO_INC  (LFO_INC),  .CHORUS_MOD_SAMPLES (MOD)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .valid_i(valid_i), .sample_i(sample_i),
        .en_i(1'b1),
        .sel_i(2'd1),                  // ⭐ 合唱（调制读地址）
        .delay_i({AW{1'b0}}),          // ⭐ 0 ⇒ 必被夹到 DLY_MIN_CH
        .mix_i(8'd128),                // ⭐ 0.5 ⇒ sample_o = x[n] + (wet >>> 1)
        .fb_i({FB_W{1'b0}}),           // ⭐ 无反馈 ⇒ 线里就是斜坡本身
        .valid_o(valid_o), .sample_o(sample_o),
        .wr_ptr_o(wr_ptr_o), .primed_o(primed_o),
        .sat_cnt_o(sat_cnt_o), .clamp_cnt_o(clamp_cnt_o)
    );

    integer errors = 0;
    task chk;
        input [8*120-1:0] name;
        input             cond;
        begin
            if (cond) $display("  ok  : %0s", name);
            else begin errors = errors + 1; $display("  FAIL: %0s", name); end
        end
    endtask

    integer npush  = 0;
    integer nrecv  = 0;
    integer ncheck = 0;
    integer nfail  = 0;
    integer npeak  = 0;        // ⭐ f == MOD−1 的样点数（非空洞守卫）
    integer worst  = 0;        // ⭐ 最大 |err|
    reg signed [SAMPLE_W-1:0] xram [0:4095];

    //  ⭐ 斜坡：`x[n] = STEP·n + OFF`（⛔ 与 RTL 无关，只是激励）
    function integer xv;
        input integer n;
        begin xv = STEP * n + OFF; end
    endfunction

    //  ⭐ LFO 相位 → 调制整数部分 `f`（⭐ 与 RTL 逐式相同；`>>>` 是 floor）
    function integer lfo_f;
        input integer n;
        integer lr, tri16, mraw, mmul, mq8;   // ⚠️ ⛔ 不能叫 `tri`（Verilog 保留字 = 三态线网）
        begin
            lr    = (LFO_INC * n) % 65536;
            tri16 = (lr >= 32768) ? (65535 - lr) : lr;    // ⭐ = ~lfo_r
            mraw  = tri16 - 16384;
            mmul = mraw * MOD;
            if (mmul >= 0) mq8 =  mmul / 64;              // ⭐ = >>> 6（floor）
            else           mq8 = -(((-mmul) + 63) / 64);
            if (mq8 >= 0)  lfo_f =  mq8 / 256;
            else           lfo_f = -(((-mq8) + 255) / 256);
        end
    endfunction

    task push;
        input signed [SAMPLE_W-1:0] x;
        begin
            @(negedge clk);
            valid_i = 1'b1; sample_i = x;
            xram[npush] = x; npush = npush + 1;
            @(negedge clk);
            valid_i = 1'b0; sample_i = 24'sh55aa55;
            repeat (6) @(negedge clk);
        end
    endtask

    //  ⭐ 记分板：每个 `valid_o` 对应第 `nrecv` 个被推入的样点（一进一出、顺序不变）
    integer n, obs, exp, err, f;
    always @(posedge clk) begin
        if (rst_n && valid_o) begin
            n = nrecv;
            if (n >= PRIME) begin
                f   = lfo_f(n);
                obs = 2 * (sample_o - xram[n]);   // ⭐ 湿声估计（mix=0.5 ⇒ 干声恒 1.0）
                exp = xram[n - D_EXP];            // ⭐ 期望 = 斜坡在 n−D 处的值
                err = obs - exp; if (err < 0) err = -err;
                if (f == (MOD - 1)) npeak = npeak + 1;
                if (err > worst) worst = err;
                if (err > TOL) begin
                    nfail = nfail + 1;
                    if (nfail <= 8)
                        $display("  FAIL C14: n=%0d f=%0d wet_obs=%0d ramp(n-%0d)=%0d |err|=%0d > TOL=%0d",
                                 n, f, obs, D_EXP, exp, err, TOL);
                end
                ncheck = ncheck + 1;
            end
            nrecv = nrecv + 1;
        end
    end

    integer k;
    initial begin
        $display("C14 chorus read floor: AW=%0d DEPTH=%0d MOD=%0d LFO_INC=%0d sel=1 delay_i=0(clamped) mix=128 fb=0",
                 AW, DEPTH, MOD, LFO_INC);
        rst_n = 1'b0; valid_i = 1'b0; sample_i = 24'sd0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // ⭐ 灌 2 圈斜坡 ⇒ 每个槽都是"该在的值"
        for (k = 0; k < PRIME; k = k + 1) push(xv(k));
        // ⭐ 再灌 WINDOW 个 ⇒ 覆盖 LFO 峰（n ≡ 16 mod 32 ⇒ f = +127）
        for (k = PRIME; k < PRIME + WINDOW; k = k + 1) push(xv(k));

        repeat (10) @(negedge clk);

        chk("C14a wet == ramp(n - (MOD+1)) within TOL for every checked sample", nfail == 0);
        chk("C14b non-vacuous: the LFO peak (f = MOD-1 = +127) was visited >= 2 times", npeak >= 2);
        chk("C14c enough samples were checked (>= 64)", ncheck >= 64);
        chk("C14d delay_i = 0 was clamped to the chorus floor (clamp_cnt_o != 0)", clamp_cnt_o !== 16'd0);
        chk("C14e the delay line is primed (2 laps pushed)", primed_o === 1'b1);
        chk("C14f no saturation on this ramp (sat_cnt_o == 0)", sat_cnt_o === 16'd0);
        chk("C14g no X on sample_o", (^sample_o) !== 1'bx);
        chk("C14h write pointer advanced once per sample", wr_ptr_o === ((PRIME + WINDOW) % DEPTH));

        $display("NOTE C14: checked=%0d peak_samples=%0d failures=%0d worst_abs_err=%0d TOL=%0d D_expected=%0d",
                 ncheck, npeak, nfail, worst, TOL, D_EXP);

        if (errors == 0)
            $display("PASS: fx_delay chorus read floor -- MOD+1 = %0d samples of guard, no lap-around at the LFO peak", D_EXP);
        else
            $fatal(1, "FAIL: tb_fx_delay_chorus_floor has %0d error(s)", errors);
        $finish;
    end

    initial begin #5000000; $fatal(1, "FAIL: tb_fx_delay_chorus_floor timeout"); end

endmodule
`default_nettype wire
