`timescale 1ns/1ps
`default_nettype none

// ═══════════════════════════════════════════════════════════════════════════
// tb_base_semi -- ⭐ T2 起始音（base note）· 2026-10-01
//
//   ⭐ **被测行为**：⭐ `note_manager` 把 `base_semi_i`（⭐ 八度×12）换算成八度档，
//      并在 **`voice_phase_inc_o` 输出处**做移位（⭐ 0 档 ⇒ **逐位恒等**）✅
//
//   ⭐⭐ **判据（7 条）**
//      T1 ⭐ **oct=0 ⇒ 逐位恒等**（⭐ §54 ② 的"由构造保证" ✅）
//      T2 ⭐ oct=1 ⇒ 精确 **×2**
//      T3 ⭐ oct=2 ⇒ 精确 **×4**
//      T4 ⭐ **非法值被拒**（⭐ 13 / 36 / 127 ⇒ ⭐ oct 回 **0**）
//      T5 ⭐ **只在 commit 拍更新**（⭐ 值变了但不 commit ⇒ ⭐ 不变 ✅）
//      T6 ⭐ **滑音路径也带移位**（⭐ 走真 `pitch_upd` 端口 ⇒ ⭐ 输出仍带移位 ✅）
//      T7 ⭐ **复位 ⇒ oct 回 0**
//
//   ⚠️⚠️ **实测踩到的坑（⭐ 记下来防复发）**：
//      🔴 **iverilog 不支持 `force` 数组元素** —— 我第一版想用
//         `force dut.phase_r[0] = TV;` 直接钉住内部寄存器，
//         ⇒ iverilog 报 `cannot %force/vec4 to the word of a variable array` ⚠️
//      ⇒ ⭐ **改走【真实 note-on 序列】**（⭐ 按 `tb_note_manager.sv:375` 的 `press_a` ✅）
//      📌 副作用是**更好**：⭐ T6 因此能走**真滑音端口**，⭐ 而不是假造 ✅
//
//   ⭐ **非空洞性（⭐ 必做）**：⭐ 把 `note_manager.v` 输出处的
//      `(base_oct_r == 2'd0) ? phase_r[g] : (phase_r[g] << base_oct_r)`
//      改成恒 `phase_r[g]` ⇒ ⭐ **T2/T3/T6 必须 FAIL** ✅
// ═══════════════════════════════════════════════════════════════════════════

module tb_base_semi;

    // ⚠️⚠️ **必须与生产配置一致**：⭐ `POLY_TARGET = 32` · ⭐ `IDX_W = 5`
    //   🔴 **我第一版用 `POLY = 4`** ⇒ ⭐ 分配状态机**一个 voice 都选不中**
    //      （⭐ 实测状态轨迹 `0→1→2→3→4→0` 走完、⭐ 但 `best_valid` 恒 0 ⚠️）
    //   📌 **依据**：⭐ `tb_note_manager.sv:30-37` 用的是 `POLY=32` / `IDX_W=5`；
    //      ⭐ `tb_velocity_headroom` 的注释也写明 ⭐ **"production configuration is 32"** ✅
    localparam integer POLY = 32, AXIS_W = 4, PHASE_W = 32;
    localparam integer VEL_W = 8, TIMBRE_W = 2, ENV_W = 16, AGE_W = 16;
    localparam integer IDX_W = 5, EVT_LOST_W = 4;

    reg clk = 1'b0;
    always #10 clk = ~clk;          // ⭐ 50 MHz
    reg rst_n = 1'b0;
    reg sample_tick = 1'b0;

    // ── ⭐ 事件激励 ──────────────────────────────────────────────────────
    reg              note_valid = 1'b0;
    reg [AXIS_W-1:0] note_axis  = 4'd0;
    reg [PHASE_W-1:0] note_phase_inc = 32'd0;
    reg [VEL_W-1:0]  note_velocity = 8'd200;
    reg [1:0]        note_kind = 2'd0;
    reg [2:0]        note_src  = 3'd0;
    reg              vel_upd_valid = 1'b0;
    reg [AXIS_W-1:0] vel_upd_axis  = 4'd0;
    reg [VEL_W-1:0]  vel_upd_value = 8'd0;
    reg [2:0]        vel_upd_src   = 3'd0;
    reg              pitch_upd_valid = 1'b0;
    reg [AXIS_W-1:0] pitch_upd_axis  = 4'd0;
    reg [PHASE_W-1:0] pitch_upd_value = 32'd0;
    reg [2:0]        pitch_upd_src   = 3'd0;
    reg [TIMBRE_W-1:0] default_timbre = 2'd0;
    reg              evt_timbre_valid = 1'b0;
    reg [TIMBRE_W-1:0] evt_timbre = 2'd0;
    // ⭐⭐ 包络回读必须是**真包络**的输出来驱动
    //   🔴 **我第一版把它们恒 0** ⇒ ⭐ `note_manager` 据此判"包络没在响"
    //      ⇒ 🔴 **刚分配就把 voice 放掉** ⇒ ⭐ `voice_gate` 一直是 0 ⚠️
    //      （⭐ 实测：⭐ `fifo_push=1` 触发了、⭐ 但 `fifo_cnt` 又回 0 且 `gate=0` ✅）
    //   ⇒ ⭐ 挂真 `envelope_bank`（⭐ 与 `tb_note_manager.sv:161` 同参数 ✅）
    wire [POLY-1:0]   env_active;
    wire [POLY*ENV_W-1:0] env_level;
    // ── ⭐⭐ T2 的被测激励 ────────────────────────────────────────────────
    reg [6:0]        base_semi   = 7'd0;
    reg              base_commit = 1'b0;

    wire [POLY-1:0]      voice_gate, voice_active, voice_releasing, voice_retrig_reset;
    wire [POLY*AXIS_W-1:0]  voice_axis;
    wire [POLY*PHASE_W-1:0] voice_phase_inc;
    wire [POLY*VEL_W-1:0]   voice_velocity;
    wire [POLY*TIMBRE_W-1:0] voice_timbre;
    wire [POLY*AGE_W-1:0]   voice_age;
    wire                 alloc_valid;
    wire [IDX_W-1:0]     alloc_voice;
    wire                 event_lost;
    wire [EVT_LOST_W-1:0] event_lost_cnt;
    reg                  event_lost_clr = 1'b0;

    note_manager #(
        .POLY_TARGET(POLY), .AXIS_W(AXIS_W), .PHASE_W(PHASE_W),
        .VEL_W(VEL_W), .TIMBRE_W(TIMBRE_W), .ENV_W(ENV_W), .AGE_W(AGE_W),
        .RESERVED_N(0), .DEFAULT_VEL(200), .IDX_W(IDX_W),
        .FIFO_DEPTH(8), .EVT_LOST_CNT_W(EVT_LOST_W)
    ) dut (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .note_valid_i(note_valid), .note_axis_i(note_axis),
        .note_phase_inc_i(note_phase_inc), .note_velocity_i(note_velocity),
        .note_kind_i(note_kind), .note_src_i(note_src),
        .vel_upd_valid_i(vel_upd_valid), .vel_upd_axis_i(vel_upd_axis),
        .vel_upd_value_i(vel_upd_value), .vel_upd_src_i(vel_upd_src),
        .pitch_upd_valid_i(pitch_upd_valid), .pitch_upd_axis_i(pitch_upd_axis),
        .pitch_upd_value_i(pitch_upd_value), .pitch_upd_src_i(pitch_upd_src),
        .default_timbre_i(default_timbre), .evt_timbre_valid_i(evt_timbre_valid),
        .evt_timbre_i(evt_timbre),
        .env_active_i(env_active), .env_level_i(env_level),
        .voice_gate_o(voice_gate), .voice_active_o(voice_active),
        .voice_releasing_o(voice_releasing), .voice_axis_o(voice_axis),
        .voice_phase_inc_o(voice_phase_inc), .voice_velocity_o(voice_velocity),
        .voice_timbre_o(voice_timbre), .voice_age_o(voice_age),
        .voice_retrig_reset_o(voice_retrig_reset),
        .alloc_valid_o(alloc_valid), .alloc_voice_o(alloc_voice),
        .event_lost_o(event_lost), .event_lost_cnt_o(event_lost_cnt),
        .event_lost_clr_i(event_lost_clr),
        // ⭐⭐ T2
        .base_semi_i(base_semi), .base_commit_i(base_commit)
    );

    // ⭐ 观察点：⭐ **正在发声的那个 voice 的 `phase_inc`**
    //   ⚠️ 第一版我盯死 `voice 0` ⇒ 🔴 **全读到 0**（⭐ 分配不一定落在 0 ⚠️）
    //   ⇒ ⭐ 改成"按 `voice_gate` 选" ⇒ ⭐ 不依赖分配策略 ✅
    reg [PHASE_W-1:0] active_inc;
    integer gi;
    always @* begin
        active_inc = {PHASE_W{1'b0}};
        for (gi = 0; gi < POLY; gi = gi + 1)
            if (voice_gate[gi]) active_inc = voice_phase_inc[gi*PHASE_W +: PHASE_W];
    end
    wire [PHASE_W-1:0] v0_inc = active_inc;   // ⭐ 名字沿用，语义 = "发声中的那个"

    // ⭐ 真包络（⭐ 判据要的是"voice 真的被占住"，⭐ 用桩证明不了 ✅）
    envelope_bank #(
        .POLY_TARGET(POLY), .VEL_W(VEL_W), .ENV_W(ENV_W),
        .ATTACK_STEP(669), .DECAY_STEP(3200), .SUSTAIN_Q8(64), .RELEASE_STEP(3200)
    ) u_env (
        .clk_i(clk), .rst_n_i(rst_n), .sample_tick_i(sample_tick),
        .gate_i(voice_gate), .velocity_i(voice_velocity),
        .retrig_reset_i(voice_retrig_reset),
        .env_level_o(env_level), .env_active_o(env_active)
    );

    // ⭐ 诊断监视：⭐ 状态机走到哪一步？
    reg [2:0] st_prev = 3'd0;
    always @(posedge clk) begin
        if (dut.state !== st_prev) begin
            $display("  DBG: state %0d -> %0d (kind=%0d axis=%0d scan=%0d best_v=%0d)",
                     st_prev, dut.state, dut.cur_kind, dut.cur_axis,
                     dut.scan_cnt, dut.best_valid);
            st_prev <= dut.state;
        end
    end

    // ⭐ 诊断监视：⭐ `note_valid` 在 posedge 被看见了吗？⭐ `fifo_push` 触发了吗？
    always @(posedge clk) begin
        if (note_valid === 1'b1)
            $display("  DBG: posedge note_valid=1 rst_n=%b fifo_push=%b full=%b cnt=%0d",
                     rst_n, dut.fifo_push, dut.fifo_full, dut.fifo_cnt);
    end

    integer errors = 0;
    integer checks = 0;
    integer i, n;

    task chk;
        input [8*64-1:0] name;
        input            cond;
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s  (v0_inc=0x%08X)", name, v0_inc);
            end
        end
    endtask

    // ⭐ `sample_tick`：⭐ 每 4 拍来一次（⭐ `note_manager` 的分配推进靠它 ✅）
    initial begin
        forever begin
            repeat (4) @(posedge clk);
            sample_tick = 1'b1;
            @(posedge clk);
            sample_tick = 1'b0;
        end
    end

    // ⭐ 等分配落地（⭐ 带超时 —— ⭐ 见 `C84`：⛔ 不靠"没输出"判卡死）
    task settle;
        begin
            n = 0;
            while ((voice_gate === {POLY{1'b0}}) && (n < 400)) begin
                @(posedge clk); n = n + 1;
            end
            @(negedge clk); #1;
        end
    endtask

    // ⭐ 按一个音（⭐ 抄 `tb_note_manager.sv:375` 的 `press_a` ✅）
    task press_a;
        input [AXIS_W-1:0]  ax;
        input [PHASE_W-1:0] inc;
        begin
            @(negedge clk);
            note_valid = 1'b1; note_axis = ax; note_phase_inc = inc;
            note_velocity = 8'd200; note_kind = 2'd0;
            @(negedge clk);
            note_valid = 1'b0;
            settle;
        end
    endtask

    // ⭐ 发一个 commit 脉冲（⭐ 单周期）
    task do_commit;
        input [6:0] v;
        begin
            @(negedge clk);
            base_semi   = v;
            base_commit = 1'b1;
            @(negedge clk);
            base_commit = 1'b0;
            #1;
        end
    endtask

    // ═════════════════════════════════════════════════════════════════════════
    // ⭐⭐ 2026-10-03（P4 · ROT32 正式落地）：⭐ **换档必须先"静音"**
    //
    //   🔴 **为什么**：⭐ 本方案把"输出端每 lane 变量移位"搬进**存储**
    //      ⇒ ⭐ 换档时要**重算整张相位表**，⭐ 而重算是**每拍只重算 1 个 lane**
    //      （⭐ 32 拍一圈）⇒ ⚠️ 若此刻有音在响，⭐ 那 32 拍就是一次**可闻的音高毛刺**
    //      ⇒ ⭐ RTL 的对策（⭐ 用户批准的决定 ②）：⭐ **`gate_r` 全 0 时才真正换档**
    //      ⇒ ⭐ 本 tb 的换档激励也必须**先松手**（⭐ 与 `tb_transpose` 同一口径）✅
    //
    //   📌 **这是【激励口径】的调整，⛔ 不是判据放宽**：
    //      ⭐ 判据仍然是"⭐ `base_semi = 12` ⇒ **精确 ×2**"（⭐ 一条没删、没改容差）✅
    //      ⭐ 只是把"换档"与"起音"的**先后**调成真实使用顺序
    //         （⭐ 用户换档时手上没有按键 ⇒ ⭐ `gate_r` 全 0 ✅）
    //      📌 而且本 tb **多了一条更强的证据**：⭐ 换档后**再按同一个 `TV`**
    //         ⇒ ⭐ 输出必须**精确**是 `TV << oct`（⭐ 覆盖"写入时移位"这条新路径 ✅）
    // ═════════════════════════════════════════════════════════════════════════
    task release_a;
        begin
            @(negedge clk);
            note_valid = 1'b1; note_axis = 4'd0; note_phase_inc = {PHASE_W{1'b0}};
            note_velocity = 8'd200; note_kind = 2'd1; note_src = 3'd0;
            @(negedge clk);
            note_valid = 1'b0; note_kind = 2'd0;
        end
    endtask

    task wait_gate0;
        begin
            n = 0;
            while ((voice_gate !== {POLY{1'b0}}) && (n < 4000)) begin
                @(posedge clk); n = n + 1;
            end
            @(negedge clk); #1;
        end
    endtask

    task set_oct;
        input [6:0] v;
        begin
            release_a;
            wait_gate0;                      // ⭐ RTL 的换档门槛
            do_commit(v);
            repeat (80) @(posedge clk);      // ⭐ 等轮转重算走完（⭐ 最多 2 档 × 32 拍）
        end
    endtask

    localparam [PHASE_W-1:0] TV = 32'h0000_1234;   // ⭐ 任意测试值（⭐ 低位留 0 便于看移位）

    initial begin
        $display("=== tb_base_semi: T2 base note (octave shift) ===");

        // ── ⭐ 复位 ─────────────────────────────────────────────────────
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ⭐ 按一个音（⭐ 轴 0 ⇒ 落在 voice 0 ✅）
        press_a(4'd0, TV);
        $display("  INFO: after press -> gate=0b%04b alloc=%0d inc=0x%08X | fifo_cnt=%0d empty=%0d state=%0d",
                 voice_gate, alloc_valid, v0_inc,
                 dut.fifo_cnt, dut.fifo_empty, dut.state);
        chk("T0: a note was allocated and the sounding voice carries the note's inc",
            v0_inc === TV);

        // ══ T1 ⭐ oct=0 ⇒ 逐位恒等 ═════════════════════════════════════
        set_oct(7'd0);
        press_a(4'd0, TV);
        chk("T1: base_semi=0  => bit-identical (oct 0)", v0_inc === TV);

        // ══ T2 ⭐ oct=1 ⇒ ×2 ═══════════════════════════════════════════
        //   ⭐ P4-ROT32：⭐ 换档在**静音**下做（⭐ 先松手），⭐ 换完**再按** ✅
        set_oct(7'd12);
        press_a(4'd0, TV);
        chk("T2: base_semi=12 => exactly x2 (oct 1)", v0_inc === (TV << 1));

        // ══ T3 ⭐ oct=2 ⇒ ×4 ═══════════════════════════════════════════
        set_oct(7'd24);
        press_a(4'd0, TV);
        chk("T3: base_semi=24 => exactly x4 (oct 2)", v0_inc === (TV << 2));

        // ══ T4 ⭐ 非法值被拒 ════════════════════════════════════════════
        set_oct(7'd13);
        press_a(4'd0, TV);
        chk("T4a: base_semi=13  => rejected, oct back to 0", v0_inc === TV);
        set_oct(7'd36);
        press_a(4'd0, TV);
        chk("T4b: base_semi=36  => rejected, oct back to 0", v0_inc === TV);
        set_oct(7'd127);
        press_a(4'd0, TV);
        chk("T4c: base_semi=127 => rejected, oct back to 0", v0_inc === TV);

        // ══ T5 ⭐ 只在 commit 拍更新 ════════════════════════════════════
        @(negedge clk);
        base_semi = 7'd24;                      // ⭐ 改了值
        repeat (10) @(posedge clk);             // ⛔ 但【不发】commit
        chk("T5: value changed without commit => oct unchanged", v0_inc === TV);

        // ══ T6 ⭐ 滑音路径也带移位（⭐ 走真 `pitch_upd` 端口）════════════
        set_oct(7'd12);                         // ⭐ oct=1（⭐ 静音换档）
        press_a(4'd0, TV);                      // ⭐ 先有一个在响的 voice
        @(negedge clk);
        pitch_upd_valid = 1'b1;
        pitch_upd_axis  = 4'd0;
        pitch_upd_value = 32'h0000_2000;
        pitch_upd_src   = 3'd0;
        @(negedge clk);
        pitch_upd_valid = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk); #1;
        chk("T6: the glide path is shifted too (oct 1 => x2)",
            v0_inc === (32'h0000_2000 << 1));

        // ══ T7 ⭐ 复位 ⇒ oct 回 0 ══════════════════════════════════════
        //   ⚠️ **⛔ 不能查 `v0_inc`** —— ⭐ 复位会**清 `phase_r`** ⇒ ⭐ 输出本来就是 0 ⚠️
        //      ⇒ ⭐ 直接查**锁存器本身** ✅
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);
        chk("T7: reset => base_oct_r back to 0", dut.base_oct_r === 2'd0);

        // ── ⭐ 汇总 ─────────────────────────────────────────────────────
        if (errors == 0)
            $display("PASS: base_semi -- octave shift is exact, bypassed at 0, and rejects illegal values");
        else
            $display("FAIL: base_semi -- %0d of %0d checks failed", errors, checks);
        $display("INFO: checks=%0d errors=%0d", checks, errors);
        $finish;
    end

    // ⭐ 超时兜底
    initial begin
        #2_000_000;
        $display("FAIL: base_semi -- TIMEOUT");
        $finish;
    end

endmodule
