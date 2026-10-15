`timescale 1ns/1ps
// tb_top_hb_center.sv -- ⭐⭐ 2026-10-15：⭐ **"摇杆在中位"接到心跳灯**的端到端判据
//
//   ⭐ **被测语义（⭐ 用户明确要求）**：
//      · ⭐ **摇杆在中位** ⇒ ⭐ `led_heartbeat` **常亮**（⭐ 恒 `1'b1`）✅
//      · ⭐ **离开中位** ⇒ ⭐ **恢复正常的心跳闪**（⭐ 慢闪 / 故障快闪**照旧**）✅
//      · ⭐ 拨弦时会**灭一下** ⇒ ⭐ 那一下就是"**事件被采到**"的现场证据 ✅
//
//   ⭐ **为什么要单独一条 tb**（⛔ 不是"重复覆盖"）：
//      🔴 `pluck_center_w` 是**跨 `generate` 作用域**的线（⭐ 源在 `g_sound`、
//         消费者在模块级的心跳灯）⇒ ⭐ **这正是本项目栽过的那一类**：
//         ⭐ `fault_any_w` 当初就因"声明晚于使用"被工具**隐式建网线**
//         （⭐ `warning: implicit definition`；⭐ `default_nettype none` 下是硬错误）
//      ⇒ ⭐ 所以必须有一条**跑真 `top.v`** 的判据钉住"**声明在模块级** ＋ **两分支都驱动**" ✅
//
//   ⭐ **判据（⭐ 每条都能失败 ✅）**：
//      ① ⭐ **真中位**（⭐ `pluck_up_i = pluck_down_i = 0` ⇒ ⭐ 走**真输入通路**）：
//         · ⭐ `pluck_center_w === 1'b1`（⭐ 中位判定本身必须成立 —— **非空洞前置**）
//         · ⭐ `dut.hb` **在翻**（⭐ 非空洞：心跳本体的确在跑 ✅）
//         · 🔴 `led_heartbeat` **恒 `1'b1`**（⭐ **常亮** —— ⭐ 这就是本轮的交付语义）
//      ② ⭐ **离开中位**（⭐ `pluck_up_i = 1`）：
//         · ⭐ `pluck_center_w === 1'b0`
//         · 🔴 `led_heartbeat` **必须跟随 `hb`**（⭐ 逐拍相等 ＋ ⭐ **真的在翻转**）
//      ③ ⭐ **`force` 中位**（⭐ 输入仍是"离开中位"）⇒ ⭐ 常亮**优先于** `hb`：
//         ⭐ `dut.hb` 照翻，⭐ 而 `led_heartbeat` **恒 1** ⇒ ⭐ 证明 mux 真的在看 `pluck_center_w`
//      ④ ⭐ **`force` 非中位**（⭐ 输入是"中位"）⇒ ⭐ 恢复闪：
//         ⭐ 证明 `pluck_center_w = 0` 那一支**不依赖输入通路**（⭐ 两条腿都钉住）
//
//   🔴 **能红实证（⭐ 必做）**：⭐ 把 `top.v` 的
//      `assign led_heartbeat = pluck_center_w ? 1'b1 : hb;`
//      ⭐ 改回 `assign led_heartbeat = hb;` ⇒ ⭐ 判据 ① 与 ③ **必须红** ✅
//      （⭐ 因为那时中位也是闪的 ⇒ ⭐ "中位常亮"这条**根本不存在**）
//
//   ⚠️ **为什么把 `HEARTBEAT_DIV` 缩到 8**：⭐ 交付值是 2500 万拍（⭐ 半周期 0.5 s）⇒
//      🔴 仿真里根本等不到一次翻转 ⇒ ⭐ 判据会变成"**空洞**"（⭐ 永远看不到闪）✅
//      📌 ⭐ 只动**参数**（⭐ `defparam` 都不用），⛔ **不动 RTL** ✅
//
//   📌 **配置与 `tb_top_merge_startup.sv` 一致**（⭐ `SCOPE_MODE=0` ＋ 3 片 ADC 模型）——
//      ⭐ 那条 tb 已实测"心跳会翻"（⭐ 它的 `edges < 300` 会红）⇒ ⭐ 本 tb 沿用同一环境 ✅
//
//   ⛔ 纪律：⭐ Verilog-2001（`K-91`）· ⭐ 同步复位低有效 · ⭐ 单时钟域 50 MHz ✅
//   ⚠️ ⭐ **本文件必须【无 BOM】**（⭐ 见 `tools/check_no_bom.ps1` ✅）

`default_nettype none

module tb_top_hb_center;

    reg clk    = 1'b0;
    reg rst_n  = 1'b0;
    reg pluck_up   = 1'b0;
    reg pluck_down = 1'b0;
    always #10 clk = ~clk;                      // ⭐ 50 MHz

    wire       sclk, mosi, hb;
    wire [5:0] cs, miso;

    top #(
        .SCOPE_MODE       (0),
        .RIGHT_ADC_ENABLE (1),
        //  ⭐ 半周期 = 8 拍（160 ns）⇒ ⭐ 64 拍窗口里能数出 ~8 次翻转 ✅
        .HEARTBEAT_DIV    (8)
    ) dut (
        .clk(clk), .rst_n(rst_n), .uart_rx(1'b1), .esp_uart_rx_i(1'b1),
        .timbre_btn_i(1'b1), .pluck_up_i(pluck_up), .pluck_down_i(pluck_down),
        .pedal_sus_i(1'b1), .pedal_loop_rec_i(1'b1), .pedal_loop_play_i(1'b1),
        .enc_a_i(1'b1), .enc_b_i(1'b1), .enc_sw_i(1'b1), .ctrl_col_i(4'b0000),
        .spi_sclk(sclk), .spi_mosi(mosi), .spi_cs_n(cs), .spi_miso(miso),
        .led_heartbeat(hb)
    );

    //  ⭐ 三个 ADC 模型（⭐ 与 `tb_top_merge_startup` 同一套 ✅）
    mcp3208_model #(.IDVAL(12'h800)) adc0(.cs_n(cs[0]),.sclk(sclk),.mosi(mosi),.miso(miso[0]));
    mcp3208_model #(.IDVAL(12'h800)) adc1(.cs_n(cs[1]),.sclk(sclk),.mosi(mosi),.miso(miso[1]));
    mcp3208_model #(.IDVAL(12'h800)) adc2(.cs_n(cs[2]),.sclk(sclk),.mosi(mosi),.miso(miso[2]));
    assign miso[5:3] = 3'b111;

    integer errors = 0;
    task chk;
        input         cond;
        input [1023:0] name;
        begin
            if (!cond) begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end else
                $display("  ok  : %0s", name);
        end
    endtask

    //  ═══════════════════════════════════════════════════════════════════════
    //  ⭐ 采样窗口（⭐ 全部临时量**声明在模块级** —— ⭐ iverilog ⛔ 不接受
    //     `begin : name` 块内的 `reg` 声明，⭐ 见 `tb_top_ctrl_wire.sv` 的纪律 ✅）
    //
    //     ⭐ 计数含义：
    //       · `hb_tr`    = `dut.hb` 的翻转次数（⭐ 非空洞证据：心跳本体在跑 ✅）
    //       · `lhb_tr`   = `led_heartbeat` 的翻转次数（⭐ "闪"就是它 ✅）
    //       · `lhb_off`  = `led_heartbeat !== 1'b1` 的采样数（⭐ 常亮判据用 ✅）
    //       · `lhb_neq`  = **非中位**时 `led_heartbeat !== dut.hb` 的采样数
    //                      （⭐ "跟随 `hb`"判据用 ✅）
    //     📌 ⭐ 在 `negedge` 采样：⭐ `hb`（posedge 更新）与组合的 `led_heartbeat`
    //        那时都已稳定 ⇒ ⭐ 不会采到中间态 ✅
    //  ═══════════════════════════════════════════════════════════════════════
    integer hb_tr, lhb_tr, lhb_off, lhb_neq, wi;
    reg     hb_d, lhb_d;

    task sample_window;
        input integer n;
        begin
            hb_tr = 0; lhb_tr = 0; lhb_off = 0; lhb_neq = 0;
            hb_d  = dut.hb; lhb_d = hb;
            for (wi = 0; wi < n; wi = wi + 1) begin
                @(negedge clk);
                if (dut.hb !== hb_d) begin hb_tr = hb_tr + 1; hb_d = dut.hb; end
                if (hb     !== lhb_d) begin lhb_tr = lhb_tr + 1; lhb_d = hb; end
                if (hb !== 1'b1) lhb_off = lhb_off + 1;
                if ((dut.pluck_center_w === 1'b0) && (hb !== dut.hb)) lhb_neq = lhb_neq + 1;
            end
        end
    endtask

    initial begin
        repeat (12) @(negedge clk);
        rst_n = 1'b1;
        repeat (2000) @(negedge clk);            // ⭐ 等同步链 / 启动稳定

        // ══ 判据 ①：⭐ **真中位**（⭐ 两路输入都低 ⇒ ⭐ 走真输入通路）⇒ ⭐ 必须【常亮】══
        begin : center_blk
            pluck_up = 1'b0; pluck_down = 1'b0;
            repeat (8) @(negedge clk);
            chk(dut.pluck_center_w === 1'b1,
                "*** real centered joystick (both inputs LOW) => pluck_center_w == 1 ***");
            sample_window(64);
            chk(hb_tr >= 4,
                "*** non-vacuity: the heartbeat toggler dut.hb really IS running in this window ***");
            chk(lhb_tr == 0,
                "*** CENTERED => led_heartbeat does NOT toggle: it is SOLID ON ***");
            chk(lhb_off == 0,
                "*** CENTERED => led_heartbeat is 1'b1 at EVERY sample (steady ON, not a stuck 0) ***");
        end

        // ══ 判据 ②：⭐ **离开中位**（⭐ 后拉）⇒ ⭐ 恢复心跳闪，⭐ 且必须跟随 `hb` ══
        begin : offcenter_blk
            pluck_up = 1'b1;                     // ⭐ 离开中位（⭐ 只动输入，⛔ 不 force）
            repeat (8) @(negedge clk);
            chk(dut.pluck_center_w === 1'b0,
                "*** joystick pulled OFF center => pluck_center_w == 0 ***");
            sample_window(64);
            chk(hb_tr >= 4,
                "*** non-vacuity: dut.hb still toggles while off center ***");
            chk(lhb_tr >= 4,
                "*** OFF CENTER => led_heartbeat BLINKS again (the normal heartbeat is restored) ***");
            chk(lhb_neq == 0,
                "*** OFF CENTER => led_heartbeat follows dut.hb at EVERY sample ***");
        end

        // ══ 判据 ③：⭐ **`force` 中位**（⭐ 输入仍是"离开中位"）⇒ ⭐ 常亮【优先于】`hb` ══
        //     ⭐ 这条直接证明 mux **真的在看 `pluck_center_w`**（⭐ 而不是碰巧）——
        //        ⚠️ 因为此刻 `dut.hb` **照翻**，⭐ 而 `led_heartbeat` 必须**恒 1** ✅
        begin : force_center_blk
            force dut.pluck_center_w = 1'b1;
            repeat (4) @(negedge clk);
            sample_window(64);
            chk(hb_tr >= 4,
                "*** non-vacuity: dut.hb KEEPS toggling underneath the forced center ***");
            chk(lhb_tr == 0 && lhb_off == 0,
                "*** FORCED CENTER wins over hb: led_heartbeat stays SOLID ON even though hb is blinking ***");
            release dut.pluck_center_w;
        end

        // ══ 判据 ④：⭐ **`force` 非中位**（⭐ 输入是"中位"）⇒ ⭐ 恢复闪 ══
        //     ⭐ 证明 `pluck_center_w = 0` 那一支**不依赖输入通路**（⭐ 两条腿都钉住）✅
        begin : force_offcenter_blk
            pluck_up = 1'b0;                     // ⭐ 输入回到"中位"
            force dut.pluck_center_w = 1'b0;
            repeat (4) @(negedge clk);
            sample_window(64);
            chk(hb_tr >= 4,
                "*** non-vacuity: dut.hb toggles in this window ***");
            chk(lhb_tr >= 4 && lhb_neq == 0,
                "*** FORCED OFF CENTER => led_heartbeat follows hb again (blinking, not latched) ***");
            release dut.pluck_center_w;
        end

        $display("");
        if (errors == 0)
            $display("PASS: joystick center on the heartbeat LED -- centered => SOLID ON, off-center => the normal heartbeat blink returns, and pluck_both_low now has a real consumer (it can no longer be pruned)");
        else
            $fatal(1, "FAIL: tb_top_hb_center had %0d error(s)", errors);

        #100;
        $finish;
    end

    initial begin
        #2000000;                                // ⭐ 2 ms 上限
        $display("FAIL: tb_top_hb_center timed out");
        $fatal(1, "timeout");
    end

endmodule
