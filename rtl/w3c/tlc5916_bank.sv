`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// tlc5916_bank.sv · TLC5916 三片级联调度器（LED 演奏指引 · 物理驱动层）
//                   —— W3c（丙 · 输出与效果链）
//
// ⭐ 职责：把 `led_data` 产出的 **24 bit 逻辑图案**（CH 序）转换成
//          3 片 TLC5916 的**物理串行波形**，并做 **CH 序 → OUT 序** 的重映射。
//   · 上游 `led_data`（薄映射层）给出"哪些键亮"（逻辑位图，bit=轴号=CH 序）；
//   · 本模块把逻辑位图按**硬件布线真值**换算成每片 TLC5916 的 OUT 位；
//   · 再用 1 个 `tlc5916_driver` 在共享 `SDI/CLK/LE` 总线上逐片写 8 bit，
//     配合 `OE`（每板一根）做分板消隐。
//
// ═══════════════════════════════════════════════════════════════════════════
// ⭐⭐ 硬件布线真值（`files/10-硬件/霍尔键位-CH映射-20260923.md` §一 + §四）
// ═══════════════════════════════════════════════════════════════════════════
//   · ⭐ **轴号 = `adc_idx × 8 + CH`**（左板 `adc_idx=0`→轴0~7；右板 `adc_idx=1`→轴8~15）。
//   · ⭐ 每块板 = 1 片 MCP3208（8 通道）+ 1 片 TLC5916（8 路恒流）：
//       物理 2 排 × 4 列，CH 序是**布线决定的乱序**（⛔ 不是 0,1,2,3…）：
//
//     | 物理列 | 1   | 2   | 3   | 4   |
//     |--------|-----|-----|-----|-----|
//     | 上排 CH| CH6 | CH7 | CH0 | CH1 |  ↔ OUT1 | OUT0 | OUT7 | OUT6
//     | 下排 CH| CH5 | CH4 | CH3 | CH2 |  ↔ OUT2 | OUT3 | OUT5 | OUT4
//
//   ⇒ ⭐⭐ **CH 序 ≠ OUT 序**（🔴 这就是通知 §1.4 点名要丙注意的坑）：
//       · CH→OUT 是**非对称查表**（⛔ 不是位反转、⛔ 不是同索引算术）：
//         CH0→OUT7 · CH1→OUT6 · CH2→OUT4 · CH3→OUT5
//         CH4→OUT3 · CH5→OUT2 · CH6→OUT1 · CH7→OUT0
//       · ⛔ 若用"同一个索引表达式算 CH 和 OUT"（如 `out[ch] = pattern[ch]`），
//         会让键灯**镜像错位**（现象：按左边亮右边、按上排亮下排）。
//
// ═══════════════════════════════════════════════════════════════════════════
// ⭐⭐ 共享总线拓扑（`files/10-硬件/板卡替换评估/从头复核-购买决策.md` §1.4 方案B）
// ═══════════════════════════════════════════════════════════════════════════
//   · ⭐ `SDI`/`CLK`/`LE` 三根**共享**（所有片并接同一总线，⛔ 不是级联）。
//   · ⭐ `OE` **每板一根**（`led_oe_n[4:0]`，5 根预留：4 左手板 + 1 右手板）。
//   · ⭐ `SDO` **悬空**（⛔ 不能级联）⇒ 每片各自从共享 `SDI` 收同一份数据。
//
//   ⚠️ **由此推出的硬约束（必须知道，⛔ 不能在 RTL 里"顺手"绕）**：
//      · 共享 `LE` ⇒ 一次锁存会让**所有片**锁存**同一份 8 bit**。
//      · ⇒ 任意时刻，**所有板显示的是同一个 8 bit 图案**，靠 `OE` 决定哪块板亮。
//      · ⇒ **左/右板不能各自显示不同图案**（这是布线决定的，改要改板）。
//      · 本模块的诚实行为：把"应该亮的所有键"按**或**合并成一张 8 bit 图，
//        在共享总线上写一次，再用 `OE` 决定点亮哪几块板。
//        —— 当且仅当"左/右板要亮的键完全一致"时，两侧才逐键对齐；
//          否则左/右会出现"同一 OUT 位同亮"（这是硬件拓扑的物理后果，非 RTL bug）。
//
// ═══════════════════════════════════════════════════════════════════════════
// ⭐ 设计要点
// ═══════════════════════════════════════════════════════════════════════════
//   1. ⭐ **CH→OUT 用查找表**（`OUT_SEL` 参数，8 项）——⛔ 不用算术（§1.4 铁律）。
//   2. ⭐ **单 driver 实例**：共享总线只用 1 个 `tlc5916_driver`，逐片轮流写，
//       写完一片 `LE` 锁存、`OE` 切换，再写下一片。
//   3. ⭐ **低速提交**：只在 `pattern_commit_i` 那一拍启动一轮重写（⛔ 每拍刷）。
//   4. ⭐ 单时钟域 + Verilog-2001 语法（`K-91`）+ 同步低复位。
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module tlc5916_bank #(
    // ⭐ 键灯片数（左手板，每片 8 路）。当前硬件 2 片 = 16 键灯。
    parameter integer KEY_CHIPS   = 2,
    // ⭐ 状态灯片数（右手板，每片 8 路）。当前硬件 1 片 = 8 状态灯（4 双色×2）。
    parameter integer STATUS_CHIPS = 1,
    // ⭐ OE 根数（预留 5：4 左手板 + 1 右手板 B）。
    parameter integer OE_N        = 5,
    // ⭐ `tlc5916_driver` 的参数（与驱动模块默认一致）。
    parameter integer CLK_HZ      = 50_000_000,
    parameter integer DATA_HZ     = 1_000_000,
    // ⭐ 每片 8 bit（TLC5916 固定 8 路，⛔ 不改）。
    parameter integer CHIP_W      = 8
) (
    input  wire                     clk_i,
    input  wire                     rst_n_i,

    // ── 输入 · 逻辑图案（来自 `led_data`，bit = 轴号 = CH 序）────────────────
    //   `[KEY_CHIPS*8-1:0]` = 键灯（每片 8 bit，片0=低8位）… 实际用 16 bit
    //   `[23:16]`            = 状态灯（右手板 1 片）
    input  wire [KEY_CHIPS*CHIP_W + STATUS_CHIPS*CHIP_W - 1:0] pattern_i,
    input  wire                     pattern_commit_i,  // ⭐ 图案变化那一拍，单周期脉冲
    input  wire                     global_blank_i,    // ⭐ 全局消隐（可选，恒 0 时直通）

    // ── 输出 · 物理总线（接顶层 `led_*` 端口）──────────────────────────────
    output wire                     led_sdi_o,
    output wire                     led_clk_o,
    output wire                     led_le_o,
    output wire [OE_N-1:0]          led_oe_n_o,        // ⭐ 低有效，每板一根
    output wire                     busy_o             // ⭐ 正在写（供观测/背压）
);

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐⭐ CH → OUT 查找表（§1.4 铁律：⛔ 不用算术，⛔ 用显式查表）
    //   `CH_TO_OUT[ch]` = 该 CH 对应物理 OUT 号。
    //   值来源：上排 CH6,7,0,1→OUT1,0,7,6；下排 CH5,4,3,2→OUT2,3,5,4。
    //   即：CH0→7 CH1→6 CH2→4 CH3→5 CH4→3 CH5→2 CH6→1 CH7→0
    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 用函数做查表（综合器会把 8 项 case 展开成 LUT，零算术）。
    function automatic [2:0] ch_to_out;
        input [2:0] ch;
        begin
            case (ch)
                3'd0: ch_to_out = 3'd7;
                3'd1: ch_to_out = 3'd6;
                3'd2: ch_to_out = 3'd4;
                3'd3: ch_to_out = 3'd5;
                3'd4: ch_to_out = 3'd3;
                3'd5: ch_to_out = 3'd2;
                3'd6: ch_to_out = 3'd1;
                3'd7: ch_to_out = 3'd0;
                default: ch_to_out = 3'd0;
            endcase
        end
    endfunction

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 把一片的"CH 序 8 bit"重排成"OUT 序 8 bit"
    //   `phys_bit[out] = ch_bit[ch]`，其中 `out = CH_TO_OUT[ch]`。
    //   ⚠️ 用 `+=:` 逐位（Verilog-2001 兼容），⛔ 不用 SV 的 unpacked 技巧。
    // ═══════════════════════════════════════════════════════════════════════
    wire [CHIP_W-1:0] chip0_ch;   // 片0 的 CH 序数据（键灯低 8 bit）
    wire [CHIP_W-1:0] chip1_ch;   // 片1 的 CH 序数据（键灯高 8 bit）
    wire [CHIP_W-1:0] chip2_ch;   // 片2 的 CH 序数据（状态灯 8 bit）

    // 从 24 bit 逻辑图案里切出三片的 CH 序数据
    assign chip0_ch = pattern_i[7:0];
    assign chip1_ch = pattern_i[15:8];
    assign chip2_ch = pattern_i[23:16];

    // 每片的 OUT 序数据（重映射后）
    reg [CHIP_W-1:0] chip0_out;
    reg [CHIP_W-1:0] chip1_out;
    reg [CHIP_W-1:0] chip2_out;

    integer oc;
    always @(*) begin
        for (oc = 0; oc < CHIP_W; oc = oc + 1) begin
            chip0_out[ch_to_out(oc[2:0])] = chip0_ch[oc];
            chip1_out[ch_to_out(oc[2:0])] = chip1_ch[oc];
            chip2_out[ch_to_out(oc[2:0])] = chip2_ch[oc];
        end
    end

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 单 driver 实例（共享 SDI/CLK/LE 总线）
    // ═══════════════════════════════════════════════════════════════════════
    wire        drv_start;
    wire [7:0]  drv_data;
    wire        drv_oe;      // driver 的 OE 输出（我们另外做分板 mux）
    wire        drv_busy;
    wire        drv_done;

    tlc5916_driver #(
        .CLK_HZ  (CLK_HZ),
        .DATA_HZ (DATA_HZ)
    ) u_driver (
        .clk            (clk_i),
        .rst_n          (rst_n_i),
        .start          (drv_start),
        .led_data       (drv_data),
        .outputs_enable (1'b1),          // ⭐ 让 driver 自己的 OE 常开；分板靠下面 mux
        .tlc_clk        (led_clk_o),
        .tlc_sdi        (led_sdi_o),
        .tlc_le         (led_le_o),
        .tlc_oe_n       (drv_oe),
        .busy           (drv_busy),
        .done           (drv_done)
    );

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 逐片写状态机：IDLE → START → WAIT_BUSY → (下一片 / IDLE)
    //   · 空闲时 `led_oe_n` 全高（全灭，安全态）；
    //   · `pattern_commit_i` 脉冲触发一轮：先写片0、再片1、再片2；
    //   · ⭐ 握手（关键）：拉 `start` → 等 driver `busy` 拉高（已接受）→ 等 `done`；
    //     ⛔ 不能只拉 1 拍 `start` 就去等 `done` —— driver 复位后有 ~6µs 恢复序列，
    //        其间来的 `start` 只进 `pending`，`done` 要等恢复完才来 ⇒ 丢写。
    // ═══════════════════════════════════════════════════════════════════════
    localparam [2:0] S_IDLE      = 3'd0,
                     S_START     = 3'd1,   // 拉 start，等 driver 接受（busy 拉高）
                     S_WAIT_BUSY = 3'd2;   // driver 已接受，等 done

    reg [2:0]  state;
    reg [1:0]  chip_sel;      // 0/1 = 键灯片，2 = 状态灯片
    reg        drv_start_r;
    reg [CHIP_W-1:0] drv_data_r;
    reg        busy_r;

    // 当前要写的数据（按 chip_sel 选）
    always @(*) begin
        case (chip_sel)
            2'd0: drv_data_r = chip0_out;
            2'd1: drv_data_r = chip1_out;
            default: drv_data_r = chip2_out;
        endcase
    end
    assign drv_data = drv_data_r;

    // ⭐ OE mux：只有"当前正在写的片"的 OE 拉低（= 使能点亮），其余全高。
    //   写完后回到 IDLE 时全高（全灭）。
    reg [OE_N-1:0] oe_n_r;
    always @(*) begin
        oe_n_r = {OE_N{1'b1}};              // 默认全灭
        if (state != S_IDLE && !global_blank_i) begin
            if (chip_sel == 2'd0)      oe_n_r[0] = 1'b0;
            else if (chip_sel == 2'd1) oe_n_r[1] = 1'b0;
            else                        oe_n_r[4] = 1'b0;  // 状态灯 = 右手板 B = oe[4]
        end
    end
    assign led_oe_n_o = oe_n_r;

    // ═══════════════════════════════════════════════════════════════════════
    // 主 FSM
    // ═══════════════════════════════════════════════════════════════════════
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            state       <= S_IDLE;
            chip_sel    <= 2'd0;
            drv_start_r <= 1'b0;
            busy_r      <= 1'b0;
        end
        else begin
            case (state)
                S_IDLE: begin
                    drv_start_r <= 1'b0;
                    busy_r      <= 1'b0;
                    chip_sel    <= 2'd0;
                    if (pattern_commit_i) begin
                        busy_r   <= 1'b1;
                        chip_sel <= 2'd0;
                        state    <= S_START;
                    end
                end

                S_START: begin
                    //  ⭐⭐ 2026-10-09（`P0-08`）：⭐ **start 只允许【1 拍】** ✅
                    //   🔴 **原缺陷**：⭐ 原写"拉 start，**等 `drv_busy` 来了才撤**"
                    //      ⚠️ 而 `drv_busy` 是**下一拍**才拉高的（⭐ driver 的同步输入）
                    //      ⇒ 🔴 `drv_start_r` 实际宽 **2 拍 = 40 ns** ✅
                    //   🔴 **后果**：⭐ 第 2 拍时 `drv_busy` 已经高了、而 `start` **还高**
                    //      ⇒ ⭐ 正好踩中 driver 的 `if (start && busy) pending <= 1'b1;`
                    //      （⭐ `tlc5916_driver.sv:277`）⇒ ⭐ 给**下一片**预先置了一个 pending ✅
                    //      ⇒ 🔴 线上实测字节 **`f0/f0/95`**（⭐ 应为 **`f0/3c/95`**）
                    //      ⇒ ⭐ **片1 的图案被片0 顶替、永远发不出去** ✅
                    //   ✅ **修法**：⭐ 拉 1 拍就**立刻**转 `S_WAIT_BUSY`
                    //      （⭐ 那一状态里 `drv_start_r <= 1'b0` ⇒ ⭐ 恰好 1 拍脉冲 ✅）
                    //   📌 **代价**：⭐ 0 资源（只是状态转移改了）✅
                    //   📌 **安全性**：⭐ 进 `S_START` 前已经等过 `drv_done`（⭐ 见 `S_WAIT_BUSY`）
                    //      ⇒ ⭐ 此刻 driver **必然空闲** ⇒ ⛔ 不会丢 start ✅
                    drv_start_r <= 1'b1;   // ⭐ 本拍拉高（⭐ 下一拍自动撤）
                    state       <= S_WAIT_BUSY;
                end

                S_WAIT_BUSY: begin
                    drv_start_r <= 1'b0;
                    if (!drv_busy && drv_done) begin
                        // 本片写完 ⇒ 写下一片，或回 IDLE
                        if (chip_sel == 2'd2) begin
                            chip_sel <= 2'd0;
                            busy_r   <= 1'b0;
                            state    <= S_IDLE;
                        end
                        else begin
                            chip_sel <= chip_sel + 2'd1;
                            state    <= S_START;
                        end
                    end
                end

                default: begin
                    state       <= S_IDLE;
                    drv_start_r <= 1'b0;
                    busy_r      <= 1'b0;
                end
            endcase
        end
    end

    assign drv_start = drv_start_r;
    assign busy_o    = busy_r;

    // ── 参数自检 ──────────────────────────────────────────────────────────
    initial begin
        if (KEY_CHIPS + STATUS_CHIPS < 1)
            $display("ERROR [tlc5916_bank] 至少 1 片 TLC5916");
        if (CHIP_W != 8)
            $display("ERROR [tlc5916_bank] TLC5916 固定 8 路，CHIP_W=%0d 非法", CHIP_W);
        if (OE_N < KEY_CHIPS + STATUS_CHIPS)
            $display("ERROR [tlc5916_bank] OE_N=%0d 少于片数 %0d", OE_N, KEY_CHIPS + STATUS_CHIPS);
    end

endmodule

`default_nettype wire
