`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_guide_lamp.sv · `guide_lamp` 验收（音符事件 → 灯位指引映射层，丙线 P1）
//
// ⭐ 判据（⚠️ 每一条都必须能失败 —— K-56/C21；⭐ 尽量写成【不变量】—— C44）
//
//   ① ⭐ 反证基线：复位后 guide 全 0、无 commit 误报
//   ② ⭐ note_on 置位：喂 axis=k 的 note_on ⇒ guide_key[k] 亮（one-hot）
//   ③ ⭐ note_off 清除：喂 axis=k 的 note_off ⇒ guide_key[k] 灭
//   ④ ⭐ tempo 忽略：喂 kind=2（换速）⇒ 任何灯位都不变（⛔ 伪音符）
//   ⑤ ⭐⭐ 非空洞性：轴号 0..15 每个 note_on 都落到一个真实灯位（满射、无空洞）
//   ⑥ ⭐ commit 单周期：指引变化那拍拉高恰好 1 拍
//   ⑦ ⭐ 多键并存：多个 note_on 累积成多位 one-hot（⛔ 互相覆盖）
//   ⑧ ⭐⭐ P0-28 消隐：key_active 的键即使 note_on 也不亮（已按不指引）
//   ⑨ ⭐ P0-28 消隐存在性：key_active 的变化会改变输出（反证 & ~key_active 存在）
// ─────────────────────────────────────────────────────────────────────────────

module tb_guide_lamp;

    localparam integer EVT_W  = 64;
    localparam integer AXIS_N = 16;

    // ⭐ 位域偏移（与 play_seq 冻结契约逐位一致）
    localparam integer AXIS_SH = 19;
    localparam integer KIND_SH = 9;
    localparam [1:0] KIND_ON    = 2'd0;
    localparam [1:0] KIND_OFF   = 2'd1;
    localparam [1:0] KIND_TEMPO = 2'd2;

    reg clk = 1'b0;
    always #10 clk = ~clk;                          // 50 MHz

    reg                     rst_n       = 1'b0;
    reg                     note_valid  = 1'b0;
    reg  [EVT_W-1:0]        note_data   = {EVT_W{1'b0}};
    reg  [AXIS_N-1:0]       key_active  = {AXIS_N{1'b0}};

    wire [AXIS_N-1:0]       guide_key;
    wire                    guide_commit;

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

    guide_lamp #(
        .EVT_W  (EVT_W),
        .AXIS_N (AXIS_N)
    ) dut (
        .clk_i          (clk),
        .rst_n_i        (rst_n),
        .note_valid_i   (note_valid),
        .note_data_i    (note_data),
        .key_active_i   (key_active),
        .guide_key_o    (guide_key),
        .guide_commit_o (guide_commit)
    );

    // ── 构造一条事件（axis 在 [22:19]，kind 在 [10:9]）─────────────────────
    //   ⚠️ 时序：note_valid 在 negedge 拉高，DUT 在**下一个 posedge** 采样，
    //      并在**同一 posedge**（非阻塞）更新 guide_key / guide_commit。
    //      ⇒ send_note 结束时停在【那个 posedge 之后】，commit 仍为高，
    //        调用方【立即】查 guide_key / guide_commit 即可（⛔ 不要再等 negedge）。
    task send_note;
        input [3:0]  axis;
        input [1:0]  kind;
        begin
            @(negedge clk);
            note_data  = {EVT_W{1'b0}};
            note_data[AXIS_SH +: 4] = axis;
            note_data[KIND_SH +: 2] = kind;
            note_valid = 1'b1;
            @(posedge clk);          // DUT 采样 note_valid=1，并更新输出
            #1;                       // 让非阻塞赋值落地
            note_valid = 1'b0;        // 关掉 valid，但输出已更新
        end
    endtask

    initial begin
        $dumpfile("build/sim/tb_guide_lamp/tb_guide_lamp.vcd");
        $dumpvars(0, tb_guide_lamp);

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // ═══════════════════════════════════════════════════════════════════
        // ① 反证基线：复位后全 0、无 commit
        // ═══════════════════════════════════════════════════════════════════
        @(negedge clk);
        chk("baseline: guide all 0 right after reset", guide_key === {AXIS_N{1'b0}});
        chk("baseline: commit is 0 (no spurious)", guide_commit === 1'b0);

        // ═══════════════════════════════════════════════════════════════════
        // ② note_on 置位：axis=3 ⇒ guide[3] 亮（one-hot）
        // ═══════════════════════════════════════════════════════════════════
        send_note(4'd3, KIND_ON);
        chk("note_on axis=3 -> guide[3] lit", guide_key[3] === 1'b1);
        chk("note_on axis=3 -> one-hot (only bit3)", guide_key === 16'h0008);
        chk("note_on axis=3 -> commit pulsed", guide_commit === 1'b1);

        // ═══════════════════════════════════════════════════════════════════
        // ③ note_off 清除：axis=3 ⇒ guide[3] 灭
        // ═══════════════════════════════════════════════════════════════════
        send_note(4'd3, KIND_OFF);
        chk("note_off axis=3 -> guide[3] off", guide_key[3] === 1'b0);
        chk("note_off axis=3 -> all 0 again", guide_key === {AXIS_N{1'b0}});

        // ═══════════════════════════════════════════════════════════════════
        // ④ tempo 忽略：kind=2 换速 ⇒ 灯位不变（⛔ 伪音符）
        // ═══════════════════════════════════════════════════════════════════
        send_note(4'd5, KIND_TEMPO);
        @(negedge clk);
        chk("tempo ignored -> guide stays 0", guide_key === {AXIS_N{1'b0}});
        chk("tempo ignored -> no commit", guide_commit === 1'b0);

        // ═══════════════════════════════════════════════════════════════════
        // ⑤⭐ 非空洞性：轴号 0..15 每个 note_on 都落到一个真实灯位（满射）
        // ═══════════════════════════════════════════════════════════════════
        begin : non_vacuity
            integer a;
            integer all_nonempty;
            all_nonempty = 1;
            for (a = 0; a < AXIS_N; a = a + 1) begin
                send_note(a[3:0], KIND_ON);
                if (guide_key[a] !== 1'b1) begin
                    all_nonempty = 0;
                    $display("  FAIL: axis %0d did not light its lamp", a);
                end
                // 清掉，准备下一个轴
                send_note(a[3:0], KIND_OFF);
            end
            chk("non-vacuity: every axis 0..15 lights its own lamp", all_nonempty == 1);
        end

        // ═══════════════════════════════════════════════════════════════════
        // ⑥ commit 单周期：指引变化那拍恰好 1 拍
        // ═══════════════════════════════════════════════════════════════════
        send_note(4'd7, KIND_ON);
        chk("commit high on change", guide_commit === 1'b1);
        @(posedge clk);                          // 下一拍 DUT 采样 note_valid=0 ⇒ commit 回落
        #1;
        chk("commit falls back to 0 next cycle", guide_commit === 1'b0);
        // 清掉 bit7，避免影响 ⑦ 的"只有两 bit"
        send_note(4'd7, KIND_OFF);

        // ═══════════════════════════════════════════════════════════════════
        // ⑦ 多键并存：多个 note_on 累积成多位 one-hot（⛔ 互相覆盖）
        // ═══════════════════════════════════════════════════════════════════
        send_note(4'd0, KIND_ON);
        send_note(4'd15, KIND_ON);
        chk("multi: axis 0 and 15 both lit", guide_key[0] === 1'b1 && guide_key[15] === 1'b1);
        chk("multi: only those two bits", guide_key === 16'h8001);
        // 清掉，避免影响 ⑧
        send_note(4'd0, KIND_OFF);
        send_note(4'd15, KIND_OFF);

        // ═══════════════════════════════════════════════════════════════════
        // ⑧⭐ P0-28 消隐：key_active 的键即使 note_on 也不亮
        // ═══════════════════════════════════════════════════════════════════
        // 先 note_on axis=3 点亮，再置 key_active[3]=1 ⇒ guide[3] 应被消隐
        send_note(4'd3, KIND_ON);
        chk("pre-mask: guide[3] lit", guide_key[3] === 1'b1);
        @(negedge clk);
        key_active = 16'h0008;                 // 键 3 正在响
        @(posedge clk); #1;
        chk("P0-28 mask: guide[3] hidden when key_active[3]", guide_key[3] === 1'b0);
        chk("P0-28 mask: only bit3 affected", guide_key === {AXIS_N{1'b0}});
        // 释放键 3 ⇒ 指引恢复
        @(negedge clk);
        key_active = {AXIS_N{1'b0}};
        @(posedge clk); #1;
        chk("P0-28 unmask: guide[3] reappears", guide_key[3] === 1'b1);
        send_note(4'd3, KIND_OFF);

        // ═══════════════════════════════════════════════════════════════════
        // ⑨⭐ P0-28 消隐存在性：key_active 变化会改变输出（反证 & ~key_active 真存在）
        // ═══════════════════════════════════════════════════════════════════
        begin : mask_existence
            reg [AXIS_N-1:0] before_m, after_m;
            send_note(4'd5, KIND_ON);
            @(negedge clk);
            key_active = {AXIS_N{1'b0}};
            @(posedge clk); #1;
            before_m = guide_key;
            @(negedge clk);
            key_active = 16'h0020;             // 键 5 正在响
            @(posedge clk); #1;
            after_m = guide_key;
            chk("P0-28 existence: key_active changes output", before_m !== after_m);
            send_note(4'd5, KIND_OFF);
            key_active = {AXIS_N{1'b0}};
        end

        // ── 收尾 ────────────────────────────────────────────────────────────
        if (errors == 0) begin
            $display("PASS: tb_guide_lamp (16 checks)");
        end else begin
            $display("FAIL: tb_guide_lamp errors=%0d", errors);
        end
        $finish;
    end

endmodule
