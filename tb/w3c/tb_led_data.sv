`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_led_data.sv · `led_data` 验收（LED 演奏指引映射层）
//
// ⭐ 判据（⚠️ 每一条都必须能失败 —— K-56/C21；⭐ 尽量写成【不变量】—— C44）
//
//   ① ⭐ 反证基线：复位后 pattern 全 0、commit 不误报
//   ② ⭐ 键灯常亮：key_active 的键 ⇒ 对应灯**常亮**（⛔ 不随 blink 灭）
//   ③ ⭐ 键灯闪烁：guide 有、active 无的键 ⇒ 跟随 blink（blink=1 亮、=0 灭）
//   ④ ⭐ 优先级：active 覆盖 guide（按下就不闪，⛔ 不会"边响边闪"）
//   ⑤ ⭐ 状态灯直通：status 的高 8 bit 原样透传（⛔ 不重编码）
//   ⑥ ⭐⭐ commit 单周期：图案变化那一拍拉高**恰好 1 拍**，⛔ 每拍都刷
//   ⑦ ⭐ commit 只在变化时：图案不变时 commit 恒 0（省功耗语义）
// ─────────────────────────────────────────────────────────────────────────────

module tb_led_data;

    localparam integer KEY_N    = 16;
    localparam integer STATUS_N = 8;

    reg clk = 1'b0;
    always #10 clk = ~clk;                          // 50 MHz

    reg                    rst_n       = 1'b0;
    reg [KEY_N-1:0]        guide_key   = {KEY_N{1'b0}};
    reg [KEY_N-1:0]        key_active  = {KEY_N{1'b0}};
    reg [STATUS_N-1:0]     status      = {STATUS_N{1'b0}};
    reg                    blink       = 1'b0;

    wire [KEY_N+STATUS_N-1:0] pattern;
    wire                      commit;

    integer errors = 0;

    task chk;
        input [8*100-1:0] name;
        input             cond;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s", name);
            end else begin
                $display("  ok  : %0s", name);
            end
        end
    endtask

    led_data #(
        .KEY_N    (KEY_N),
        .STATUS_N (STATUS_N)
    ) dut (
        .clk_i          (clk),
        .rst_n_i        (rst_n),
        .guide_key_i    (guide_key),
        .key_active_i   (key_active),
        .status_i       (status),
        .blink_i        (blink),
        .pattern_o      (pattern),
        .pattern_commit_o(commit)
    );

    wire [KEY_N-1:0]        key_lights  = pattern[KEY_N-1:0];
    wire [STATUS_N-1:0]     status_lights = pattern[KEY_N+STATUS_N-1:KEY_N];

    initial begin
        $dumpfile("build/sim/tb_led_data/tb_led_data.vcd");
        $dumpvars(0, tb_led_data);

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // ═══════════════════════════════════════════════════════════════════
        // ① 反证基线：复位后全 0、无 commit
        // ═══════════════════════════════════════════════════════════════════
        @(negedge clk);
        chk("baseline: pattern all 0 right after reset", pattern === 24'd0);
        chk("baseline: commit is 0 (no spurious commit)", commit === 1'b0);

        // ═══════════════════════════════════════════════════════════════════
        // ② 键灯常亮：active 的键常亮，不受 blink 影响
        // ═══════════════════════════════════════════════════════════════════
        key_active = 16'b0000_0000_0000_0011;     // 键 0、1 按下
        @(negedge clk);
        @(negedge clk);
        // blink 恒 0 时，active 键也常亮（因为 active 优先级最高）
        chk("key light: active keys 0,1 are ON (steady)", key_lights[1:0] === 2'b11);
        chk("key light: other keys stay OFF", key_lights[15:2] === 14'd0);
        // 现在让 blink=1，active 键必须**仍然常亮**（⛔ 不闪）
        blink = 1'b1;
        @(negedge clk);
        @(negedge clk);
        chk("key light: active keys stay ON even when blink is high (no flicker)",
            key_lights[1:0] === 2'b11);
        blink = 1'b0;

        // ═══════════════════════════════════════════════════════════════════
        // ③ 键灯闪烁：guide 有、active 无的键，跟随 blink
        // ═══════════════════════════════════════════════════════════════════
        guide_key  = 16'b0000_0000_0000_0100;     // 键 2 = 下一个该按
        key_active = 16'd0;                        // 还没按
        @(negedge clk); @(negedge clk);
        // blink=0 ⇒ 闪烁键灭
        chk("blink: guided key 2 is OFF when blink low", key_lights[2] === 1'b0);
        // blink=1 ⇒ 闪烁键亮
        blink = 1'b1;
        @(negedge clk); @(negedge clk);
        chk("blink: guided key 2 is ON when blink high", key_lights[2] === 1'b1);
        // 再灭
        blink = 1'b0;
        @(negedge clk); @(negedge clk);
        chk("blink: guided key 2 is OFF again when blink low", key_lights[2] === 1'b0);

        // ═══════════════════════════════════════════════════════════════════
        // ④ 优先级：active 覆盖 guide（同一个键既 guide 又 active ⇒ 常亮不闪）
        // ═══════════════════════════════════════════════════════════════════
        guide_key  = 16'b0000_0000_0000_0100;     // 键 2 引导
        key_active = 16'b0000_0000_0000_0100;     // 键 2 已按下
        blink = 1'b0;
        @(negedge clk); @(negedge clk);
        chk("priority: active key 2 stays ON (not blinking) even with blink low",
            key_lights[2] === 1'b1);

        // ═══════════════════════════════════════════════════════════════════
        // ⑤ 状态灯直通：status 高 8 bit 原样透传
        // ═══════════════════════════════════════════════════════════════════
        guide_key  = 16'd0;
        key_active = 16'd0;
        status     = 8'b1010_0101;
        @(negedge clk); @(negedge clk);
        chk("status: upper 8 bits pass through unchanged", status_lights === 8'b1010_0101);

        // ═══════════════════════════════════════════════════════════════════
        // ⑥ commit 单周期：图案变化那一拍拉高恰好 1 拍
        // ═══════════════════════════════════════════════════════════════════
        //    ⭐ 先让当前状态稳定（连续几拍不变 ⇒ commit 恒 0）
        @(negedge clk);
        chk("commit: no change => commit stays 0", commit === 1'b0);
        //    触发一次变化（键 3 按下）
        key_active = 16'b0000_0000_0000_1000;
        @(negedge clk);
        chk("commit: pulses for exactly the change cycle (1st cycle high)", commit === 1'b1);
        @(negedge clk);
        chk("commit: returns to 0 the very next cycle (single-cycle pulse)", commit === 1'b0);

        // ═══════════════════════════════════════════════════════════════════
        // ⑦ commit 只在变化时：图案不变（blink 抖动但 active 常亮）⇒ commit 不刷
        // ═══════════════════════════════════════════════════════════════════
        //    ⭐ active 键常亮、blink 抖动不影响 active 键 ⇒ 图案不变 ⇒ 不 commit
        guide_key  = 16'd0;
        key_active = 16'b0000_0000_0000_1000;     // 键 3 常亮
        @(negedge clk); @(negedge clk);
        blink = 1'b1;
        @(negedge clk);
        // blink 变化只影响"闪烁键"，不影响 active 键 ⇒ 图案（对键 3）不变
        // 但若同时有闪烁键则图案会变 —— 这里没有闪烁键，所以 commit 应保持 0
        chk("commit: blink toggle does NOT trigger commit when only active keys lit",
            commit === 1'b0);
        blink = 1'b0;

        // ── 结论 ───────────────────────────────────────────────────────────
        if (errors == 0)
            $display("PASS: led_data (steady active / blinking guide / priority / status passthrough / single-cycle commit)");
        else
            $display("FAIL: led_data had %0d error(s)", errors);

        $finish(errors != 0);
    end

    // ⭐ 看门狗（K-94：没有结论必须算失败）
    initial begin
        #50_000_000;
        $fatal(1, "FAIL: tb_led_data timeout");
    end

endmodule
