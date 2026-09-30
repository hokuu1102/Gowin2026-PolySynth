`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tb_calib_cmd.sv · `calib_cmd` 自检（⭐ 'T'/'S'/'X'/'M' 命令解析）
//
// ⭐ 判据（⚠️ 每条都必须能失败 —— `K-56`/`C21`）
//   ① ⭐ **帧外的 `'T'`/`'S'`/`'X'`/`'M'` ⇒ 对应脉冲单拍拉高**
//   ② ⭐⭐⭐ **帧【内】的命令字母 ⇒ ⛔ 一律不当命令**（🔴 本模块的核心安全）
//      ⚠️ 这是"曲谱灌入时不会被误触发标定"的唯一保证
//   ③ ⭐ **帧内被忽略的次数要记账**（`in_frame_cnt_o`）⇒ ⭐ 证明边界跟踪真在工作
//   ④ ⭐ **非命令的帧外字节 ⇒ 不产生任何脉冲**（⭐ 但计入 `unknown_cnt_o`）
//   ⑤ ⭐⭐⭐ **空闲归位**：⭐ 半帧后长时间无字节 ⇒ 回到帧外
//      （⭐ 自愈，⚠️ 否则 PC 崩在半帧中间会永久卡死）
//   ⑥ ⭐ **归位之后命令重新可用**（⭐ 自愈真的恢复功能）
//   ⑦ ⭐ **命令脉冲是【单周期】**（⛔ 不是多拍）
//   ⑧ ⭐ **`0xA5` 帧头本身 ⛔ 不被当成命令**
//
// ── 🔴 tb 纪律（本项目血泪）──────────────────────────────────────────────────
//   · ⛔ **不要用 `wait(信号)`** —— ⚠️ 它不推进仿真时间 ⇒ 永久阻塞
//   · ⭐ **顶层 `initial` 里 ⛔ 不能声明变量**（Verilog-2001 限制）
//   · ⭐ `calib_cmd` 是 **Verilog-2001**（`K-91`）
// ─────────────────────────────────────────────────────────────────────────────

module tb_calib_cmd;

    localparam integer GAP_BYTES = 4;         // ⭐ 调小 ⇒ 仿真快（⭐ 真值 16）
    localparam integer CLK_HZ    = 50000000;
    localparam integer BAUD      = 1000000;
    //   ⭐ 字节时间 = 50 拍；⭐ 归位阈值 = 4 × 50 = 200 拍
    localparam integer BYTE_CLK  = (CLK_HZ + BAUD/2) / BAUD;

    localparam [7:0] HDR = 8'hA5;
    localparam [7:0] T   = 8'h54;             // 'T'
    localparam [7:0] S   = 8'h53;             // 'S'
    localparam [7:0] X   = 8'h58;             // 'X'
    localparam [7:0] M   = 8'h4D;             // 'M' Test Mode
    // ⭐ 2026-09-29 新增：⭐ looper 三条（⭐ 必须与 `calib_cmd.v` 的新参数一致）
    localparam [7:0] R   = 8'h52;             // 'R' looper 录/停切换
    localparam [7:0] L   = 8'h4C;             // 'L' looper 播放切换
    localparam [7:0] C   = 8'h43;             // 'C' looper 清空
    // ⭐ 2026-09-29 新增：⭐ 切音色（⭐ 必须与 `calib_cmd.v` 的新参数一致）
    localparam [7:0] I   = 8'h49;             // 'I' 切音色（⭐ 0→1→2→3→0）
    // ⭐ 2026-09-29 新增：⭐ 鼓机节奏型（⭐ 必须与 `calib_cmd.v` 的新参数一致）
    localparam [7:0] D   = 8'h44;             // 'D' 鼓机节奏型（⭐ 0→1→2→3→0）

    integer errors = 0;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    task chk;
        input [1023:0] name;
        input          cond;
        begin
            if (cond) $display("  ok  : %0s", name);
            else begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    // ── DUT ───────────────────────────────────────────────────────────
    reg        rx_done;
    reg  [7:0] rx_data;
    wire       tare_req, span_req, abort_req, test_mode_req;
    wire       loop_rec_req, loop_play_req, loop_clear_req;   // ⭐ 2026-09-29
    wire       timbre_req;                                    // ⭐ 2026-09-29：'I' 切音色
    wire       drum_pattern_req;                              // ⭐ 2026-09-29：'D' 鼓机节奏型
    wire [15:0] cmd_cnt, in_frame_cnt, resync_cnt, unknown_cnt;
    wire [3:0]  idx_o;

    calib_cmd #(
        .CLK_HZ   (CLK_HZ),
        .BAUD     (BAUD),
        .GAP_BYTES(GAP_BYTES),
        .HEADER   (HDR),
        .CMD_TARE (T),
        .CMD_SPAN (S),
        .CMD_ABORT(X),
        .CMD_TEST_MODE(M)
    ) dut (
        .clk_i          (clk),
        .rst_n_i        (rst_n),
        .rx_done_i      (rx_done),
        .rx_data_i      (rx_data),
        .tare_req_o     (tare_req),
        .span_req_o     (span_req),
        .abort_req_o    (abort_req),
        .test_mode_req_o(test_mode_req),
        // ⭐ 2026-09-29：looper 三条
        .loop_rec_req_o (loop_rec_req),
        .loop_play_req_o(loop_play_req),
        .loop_clear_req_o(loop_clear_req),
        // ⭐ 2026-09-29：⭐ 切音色
        .timbre_req_o   (timbre_req),
        // ⭐ 2026-09-29：⭐ 鼓机节奏型（⭐ 'D'）
        .drum_pattern_req_o(drum_pattern_req),
        .cmd_cnt_o      (cmd_cnt),
        .in_frame_cnt_o (in_frame_cnt),
        .resync_cnt_o   (resync_cnt),
        .idx_o          (idx_o),
        .unknown_cnt_o  (unknown_cnt)
    );

    // ═══════════════════════════════════════════════════════════════════
    // ⭐ 监视器：记录每个脉冲【出现时的拍数】与【持续拍数】
    // ═══════════════════════════════════════════════════════════════════
    integer tare_seen, span_seen, abort_seen, test_mode_seen;
    integer loop_rec_seen, loop_play_seen, loop_clear_seen;   // ⭐ 2026-09-29
    integer timbre_seen;                                      // ⭐ 2026-09-29：'I' 切音色
    integer drum_pat_seen;                                    // ⭐ 2026-09-29：'D' 鼓机节奏型
    integer loop_rec_cycles, loop_play_cycles, loop_clear_cycles;   // ⭐ 单周期证明
    integer timbre_cycles;                                          // ⭐ 单周期证明
    integer drum_pat_cycles;                                        // ⭐ 单周期证明
    integer tare_cycles, span_cycles, abort_cycles, test_mode_cycles; // ⭐ 累计高电平拍数
    integer last_tare_cycle, last_span_cycle, last_abort_cycle;
    integer cycle_cnt;

    initial begin
        tare_seen = 0; span_seen = 0; abort_seen = 0; test_mode_seen = 0;
        loop_rec_seen = 0; loop_play_seen = 0; loop_clear_seen = 0;   // ⭐ 2026-09-29
        timbre_seen = 0;                                              // ⭐ 2026-09-29
        drum_pat_seen = 0;                                            // ⭐ 2026-09-29
        loop_rec_cycles = 0; loop_play_cycles = 0; loop_clear_cycles = 0;
        timbre_cycles = 0;
        drum_pat_cycles = 0;
        tare_cycles = 0; span_cycles = 0; abort_cycles = 0; test_mode_cycles = 0;
        last_tare_cycle = -1; last_span_cycle = -1; last_abort_cycle = -1;
        cycle_cnt = 0;
    end

    always @(posedge clk) begin
        cycle_cnt = cycle_cnt + 1;
        if (rst_n) begin
            if (tare_req)  begin tare_seen  = tare_seen  + 1; tare_cycles  = tare_cycles  + 1; last_tare_cycle  = cycle_cnt; end
            if (span_req)  begin span_seen  = span_seen  + 1; span_cycles  = span_cycles  + 1; last_span_cycle  = cycle_cnt; end
            if (abort_req) begin abort_seen = abort_seen + 1; abort_cycles = abort_cycles + 1; last_abort_cycle = cycle_cnt; end
            if (test_mode_req) begin test_mode_seen = test_mode_seen + 1; test_mode_cycles = test_mode_cycles + 1; end
            // ⭐ 2026-09-29：looper 三条
            if (loop_rec_req)   begin loop_rec_seen   = loop_rec_seen   + 1; loop_rec_cycles   = loop_rec_cycles   + 1; end
            if (loop_play_req)  begin loop_play_seen  = loop_play_seen  + 1; loop_play_cycles  = loop_play_cycles  + 1; end
            if (loop_clear_req) begin loop_clear_seen = loop_clear_seen + 1; loop_clear_cycles = loop_clear_cycles + 1; end
            // ⭐ 2026-09-29：⭐ 切音色
            if (timbre_req)     begin timbre_seen     = timbre_seen     + 1; timbre_cycles     = timbre_cycles     + 1; end
            // ⭐ 2026-09-29：⭐ 鼓机节奏型
            if (drum_pattern_req) begin drum_pat_seen = drum_pat_seen + 1; drum_pat_cycles = drum_pat_cycles + 1; end
        end
    end

    // ═══════════════════════════════════════════════════════════════════
    // ⭐ 驱动任务
    // ═══════════════════════════════════════════════════════════════════

    // ⭐ 送一个字节（⭐ 严格单周期 `rx_done`）
    task send_byte;
        input [7:0] b;
        begin
            @(negedge clk);
            rx_data  = b;
            rx_done  = 1'b1;
            @(posedge clk);
            @(negedge clk);
            rx_done  = 1'b0;
            @(posedge clk);
        end
    endtask

    // ⭐ 送一整帧：`0xA5` + 8 字节载荷
    task send_frame;
        input [7:0] p0, p1, p2, p3, p4, p5, p6, p7;
        begin
            send_byte(HDR);
            send_byte(p0); send_byte(p1); send_byte(p2); send_byte(p3);
            send_byte(p4); send_byte(p5); send_byte(p6); send_byte(p7);
        end
    endtask

    // ⭐ 等"空闲归位"发生（⭐ 靠消耗 clk 拍，⛔ 不靠 wait）
    task wait_idle_resync;
        integer n;
        begin
            //   ⭐ 归位阈值 = `GAP_BYTES × BYTE_CLK` 拍 ⇒ ⭐ 多给 2 倍余量
            for (n = 0; n < (GAP_BYTES * BYTE_CLK * 2 + 20); n = n + 1)
                @(posedge clk);
        end
    endtask

    task do_reset;
        begin
            rst_n    = 1'b0;
            rx_done  = 1'b0;
            rx_data  = 8'h00;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
            //   ⭐⭐ **清零监视器**（⭐ 关键）：
            //      🔴 `tare_seen`/`span_seen`/... 是 tb 的**累计计数器**，
            //         ⚠️ 它们**不受 `rst_n` 影响**（⭐ 不是 DUT 信号）
            //      ⇒ ⭐ 若不清，后面所有 `== 0`/`== 1` 的判据都会**带着旧值**失败
            //      📌 这正是我第一版 tb 的错（⭐ 5 条假失败全部源于此）
            tare_seen  = 0; span_seen  = 0; abort_seen  = 0; test_mode_seen = 0;
            tare_cycles = 0; span_cycles = 0; abort_cycles = 0; test_mode_cycles = 0;
            // ⭐ 2026-09-29：looper 三条也要清（⭐ 同一个坑）
            loop_rec_seen = 0; loop_play_seen = 0; loop_clear_seen = 0;
            loop_rec_cycles = 0; loop_play_cycles = 0; loop_clear_cycles = 0;
            timbre_seen = 0; timbre_cycles = 0;   // ⭐ 2026-09-29：'I' 切音色（⭐ 同一个坑）
            drum_pat_seen = 0; drum_pat_cycles = 0; // ⭐ 2026-09-29：'D' 鼓机节奏型（⭐ 同一个坑）
        end
    endtask

    // ═══════════════════════════════════════════════════════════════════
    // ⭐⭐ 主流程
    // ═══════════════════════════════════════════════════════════════════
    integer i, k;
    integer t0, s0, a0;             // ⭐ 基线快照
    integer ifc0;                   // ⭐ 帧内忽略计数基线

    initial begin
        $display("=== tb_calib_cmd ===");

        // ───────────────────────────────────────────────────────────────
        // ⭐ 判据①：帧外三个命令字母 ⇒ 各自脉冲
        // ───────────────────────────────────────────────────────────────
        do_reset();
        send_byte(T);
        chk("'T' outside a frame raises tare_req", tare_seen == 1);
        chk("'T' does NOT raise span_req or abort_req",
            span_seen == 0 && abort_seen == 0);
        send_byte(S);
        chk("'S' outside a frame raises span_req", span_seen == 1);
        send_byte(X);
        chk("'X' outside a frame raises abort_req", abort_seen == 1);
        send_byte(M);
        chk("'M' outside a frame raises test_mode_req", test_mode_seen == 1);
        chk("cmd_cnt_o counted all four commands", cmd_cnt == 16'd4);

        // ⭐⭐ 2026-09-29 新增：⭐ looper 三条命令（⭐ 'R' / 'L' / 'C'）
        //   ⭐ 它们走**同一条**"帧外才认"的路径 ⇒ ⭐ 必须与 `T`/`S`/`X`/`M` 一样：
        //      ⭐ 帧外认 · ⭐ 帧内不认 · ⭐ 单周期 · ⭐ 互不串扰
        send_byte(R);
        chk("'R' outside a frame raises loop_rec_req", loop_rec_seen == 1);
        send_byte(L);
        chk("'L' outside a frame raises loop_play_req", loop_play_seen == 1);
        send_byte(C);
        chk("'C' outside a frame raises loop_clear_req", loop_clear_seen == 1);
        chk("looper letters do NOT cross-fire the older commands",
            (tare_seen == 1) && (span_seen == 1) && (abort_seen == 1) && (test_mode_seen == 1));
        chk("each looper command pulse is exactly ONE cycle wide",
            loop_rec_cycles == 1 && loop_play_cycles == 1 && loop_clear_cycles == 1);
        chk("cmd_cnt_o counted all SEVEN commands", cmd_cnt == 16'd7);

        // ⭐⭐ 2026-09-29 新增：⭐ 切音色命令（⭐ 'I'）
        //   ⭐ 它同样走"帧外才认"那条路 ⇒ ⭐ 判据口径与上面完全一致 ✅
        send_byte(I);
        chk("'I' outside a frame raises timbre_req", timbre_seen == 1);
        chk("'I' does NOT cross-fire the older commands",
            (tare_seen == 1) && (span_seen == 1) && (abort_seen == 1)
            && (test_mode_seen == 1) && (loop_rec_seen == 1)
            && (loop_play_seen == 1) && (loop_clear_seen == 1));
        chk("'I' pulse is exactly ONE cycle wide", timbre_cycles == 1);
        chk("cmd_cnt_o counted all EIGHT commands", cmd_cnt == 16'd8);

        // ⭐⭐ 2026-09-29 新增：⭐ 鼓机节奏型命令（⭐ 'D'）
        //   ⭐ 判据口径与上面 `'I'` **完全一致**（⭐ 同一条"帧外才认"的路径）：
        //      ⭐ ① 帧外认 ✅ · ⭐ ② ⛔ 不串扰别的命令 ✅ · ⭐ ③ 脉冲**恰好一拍宽** ✅
        //      ⭐ ④ 帧内（载荷里）⛔ 绝不认（⭐ 见下方 payload 段）✅
        //   📌 **判据名纯 ASCII、<= 128 字节**（⭐ 本机 `vvp` 会把非 ASCII 打乱）✅
        send_byte(D);
        chk("'D' outside a frame raises drum_pattern_req", drum_pat_seen == 1);
        chk("'D' does NOT cross-fire the older commands",
            (tare_seen == 1) && (span_seen == 1) && (abort_seen == 1)
            && (test_mode_seen == 1) && (loop_rec_seen == 1)
            && (loop_play_seen == 1) && (loop_clear_seen == 1)
            && (timbre_seen == 1));
        chk("'D' pulse is exactly ONE cycle wide", drum_pat_cycles == 1);
        chk("cmd_cnt_o counted all NINE commands", cmd_cnt == 16'd9);

        // ───────────────────────────────────────────────────────────────
        // ⭐ 判据⑦：脉冲必须是【单周期】
        //   ⭐ 每个命令各出现 1 次 ⇒ ⭐ 高电平拍数也必须正好是 1
        // ───────────────────────────────────────────────────────────────
        chk("each command pulse is exactly ONE cycle wide",
            tare_cycles == 1 && span_cycles == 1 && abort_cycles == 1 && test_mode_cycles == 1);

        // ───────────────────────────────────────────────────────────────
        // ⭐⭐⭐ 判据②③：帧【内】的命令字母 ⛔ 绝不当命令
        //   🔴 **本 tb 最重要的一条** ——
        //      ⭐ 构造一个**载荷里塞满 T/S/X 的合法事件帧**
        //      ⇒ ⭐ 它必须被**当成普通数据**（⚠️ 虽然 `calib_cmd` 不解析载荷，
        //         但只要它**不产生任何命令脉冲**就是对的）
        // ───────────────────────────────────────────────────────────────
        do_reset();
        t0 = tare_seen; s0 = span_seen; a0 = abort_seen;
        ifc0 = in_frame_cnt;
        //   ⭐ 载荷 = T S X M R L C T（⭐ 8 个**全是命令字母**！最坏情况）
        //      ⭐ 2026-09-29：⭐ 把**新的 looper 字母也塞进去** ⇒ ⭐ 一起验帧边界
        send_frame(T, S, X, M, R, L, C, I);

        chk("payload full of T/S/X raises NO tare_req",  tare_seen  == t0);
        chk("payload full of T/S/X raises NO span_req",  span_seen  == s0);
        chk("payload full of T/S/X raises NO abort_req", abort_seen == a0);
        chk("payload full of commands raises NO test_mode_req", test_mode_seen == 0);
        // ⭐ 2026-09-29：⭐ 新字母在**帧内**同样⛔ 绝不许产生脉冲
        chk("payload full of commands raises NO loop_rec_req",  loop_rec_seen  == 0);
        chk("payload full of commands raises NO loop_play_req", loop_play_seen == 0);
        chk("payload full of commands raises NO loop_clear_req", loop_clear_seen == 0);
        chk("payload full of commands raises NO timbre_req", timbre_seen == 0);
        chk("cmd_cnt_o did NOT count in-frame letters", cmd_cnt == 16'd0);
        //   ⭐ 8 个载荷字节全是命令字母 ⇒ ⭐ 忽略计数应为 8
        chk("in_frame_cnt_o counted all 8 ignored payload letters",
            (in_frame_cnt - ifc0) == 16'd8);
        chk("idx_o returned to 0 after the frame completed", idx_o === 4'd0);

        // ⭐⭐ 2026-09-29 新增：⭐ **`'D'` 在【载荷里】⛔ 绝不许被认出来** ✅
        //   ⭐ 为什么要单开一帧（⭐ 而不是塞进上面那帧）：
        //      ⚠️ 上面那帧的判据写死了"**8 个**载荷字节全是命令字母"
        //      ⇒ ⭐ 动它会**同时改掉已有判据的口径**（⛔ 违反"只加不改"）
        //   ⭐ 本帧构造：⭐ `0xA5` + 8 字节载荷，⭐ **8 个全是 `'D'`**（⭐ 最坏情况）
        //      ⇒ ⭐ 必须**一个脉冲都不出**、⭐ 但 ⭐ `in_frame_cnt_o` **+8**（⭐ 边界跟踪在干活）
        do_reset();
        ifc0 = in_frame_cnt;
        send_frame(D, D, D, D, D, D, D, D);
        chk("payload of eight 'D' letters raises NO drum_pattern_req", drum_pat_seen == 0);
        chk("payload of eight 'D' letters raises NO other command pulses",
            (tare_seen == 0) && (span_seen == 0) && (abort_seen == 0)
            && (test_mode_seen == 0) && (loop_rec_seen == 0)
            && (loop_play_seen == 0) && (loop_clear_seen == 0) && (timbre_seen == 0));
        chk("cmd_cnt_o did NOT count the in-frame 'D' letters", cmd_cnt == 16'd0);
        chk("in_frame_cnt_o counted all 8 in-frame 'D' letters",
            (in_frame_cnt - ifc0) == 16'd8);

        // ───────────────────────────────────────────────────────────────
        // ⭐ 判据⑧：`0xA5` 帧头本身 ⛔ 不当命令
        // ───────────────────────────────────────────────────────────────
        do_reset();
        send_byte(HDR);
        chk("0xA5 header itself raises no command", 
            tare_seen == 0 && span_seen == 0 && abort_seen == 0 && test_mode_seen == 0);

        // ───────────────────────────────────────────────────────────────
        // ⭐ 判据④：帧外非命令字节 ⇒ ⭐ 无脉冲，但计数
        //   ⭐ 例如 PC 串口助手敲的回车 `0x0D`
        // ───────────────────────────────────────────────────────────────
        do_reset();
        send_byte(8'h0D);
        send_byte(8'h0A);
        chk("non-command bytes outside a frame raise no pulses",
            tare_seen == 0 && span_seen == 0 && abort_seen == 0 && test_mode_seen == 0);
        chk("non-command bytes are counted in unknown_cnt_o", unknown_cnt == 16'd2);

        // ───────────────────────────────────────────────────────────────
        // ⭐⭐⭐ 判据⑤⑥：空闲归位 + 归位后命令恢复
        //   ⭐ 场景：⭐ 帧头发了、但载荷只发一半 ⇒ ⭐ PC 崩了
        //   ⚠️ 若无归位 ⇒ 🔴 **永久卡在帧内** ⇒ ⭐ 之后所有命令都被当载荷吞掉
        // ───────────────────────────────────────────────────────────────
        do_reset();
        send_byte(HDR);              // ⭐ 起了个头
        send_byte(T);                // ⭐ 这是【载荷】⇒ ⛔ 不该当命令
        send_byte(S);
        chk("half frame: payload letters do not fire commands",
            tare_seen == 0 && span_seen == 0);
        chk("half frame: idx_o is inside the frame (not 0)", idx_o !== 4'd0);

        //   ⭐ 长时间没有新字节 ⇒ ⭐ 应自动归位
        wait_idle_resync();
        chk("idle gap forces a resync back to idx 0", idx_o === 4'd0);
        chk("idle resync was counted (observable, not silent)", resync_cnt > 16'd0);

        //   ⭐⭐ 归位之后命令必须**重新可用**（⭐ 自愈真的恢复了功能）
        send_byte(X);
        chk("after idle resync, a command works again ('X' fires)",
            abort_seen == 1);

        // ───────────────────────────────────────────────────────────────
        // ⭐ 附加：连续多个命令（⭐ 确保不互相遮蔽）
        // ───────────────────────────────────────────────────────────────
        do_reset();
        send_byte(T); send_byte(S); send_byte(X); send_byte(M);
        chk("consecutive T,S,X,M each fire exactly once",
            tare_seen == 1 && span_seen == 1 && abort_seen == 1 && test_mode_seen == 1);
        chk("consecutive commands: cmd_cnt_o == 4", cmd_cnt == 16'd4);

        // ───────────────────────────────────────────────────────────────
        // ⭐ 附加：⭐ 两帧【连续】背靠背（⭐ 真实曲谱场景）
        //   ⭐ 中间的命令字母都不该被认出来
        // ───────────────────────────────────────────────────────────────
        do_reset();
        send_frame(HDR, HDR, T, S, X, HDR, T, T);   // ⭐ 载荷里连帧头都有
        send_frame(T, T, T, T, T, T, T, T);         // ⭐ 第二帧载荷全是 T
        chk("back-to-back frames with embedded T/S/X/HDR raise no commands",
            tare_seen == 0 && span_seen == 0 && abort_seen == 0 && test_mode_seen == 0);
        chk("back-to-back frames end with idx_o == 0", idx_o === 4'd0);

        $display("");
        if (errors == 0)
            $display("PASS: calib_cmd parses T/S/X/M only at frame boundaries, ignores payload letters, counts what it drops, and self-heals after a half frame");
        else
            $fatal(1, "FAIL: calib_cmd had %0d error(s)", errors);

        #100;
        $finish;
    end

endmodule
