`timescale 1ns/1ps
module tb_top_dump_atomic;
    reg clk=0,rst_n=0,command_rx=1;
    reg [11:0] hall=12'h7c1;
    always #10 clk=~clk;
    wire sck,mosi,board_tx,esp_tx;
    wire [5:0] cs,miso;
    wire [3:0] ctrl_row_w;
    reg  [3:0] ctrl_col_r;
    top #(.SCOPE_MODE(0),.TEST_MODE_EN(0),.RIGHT_ADC_ENABLE(0),
        .AUTOTARE_DELAY_CLK(100000),.DEMO_NOTE_DELAY(10000000)) dut (
        .clk(clk),.rst_n(rst_n),.uart_rx(command_rx),.uart_tx(board_tx),
        .esp_uart_rx_i(1'b1),.esp_uart_tx_o(esp_tx),.timbre_btn_i(1'b1),
        .pluck_up_i(1'b0),.pluck_down_i(1'b0),.spi_sclk(sck),
        .spi_mosi(mosi),.spi_cs_n(cs),.spi_miso(miso),
        //  ⭐⭐ 2026-10-17：⭐ **控制板矩阵口接出来**（⭐ 为 idx 13「loop 发送」判据 ✅）
        //     ⚠️ 原 tb 把这两个口**完全悬空**（⭐ `ctrl_col_i` 靠 Z-safe 归一读成"未按"）
        //        ⇒ ⭐ 那时"没有按键"是被动成立的 ✅
        //     ✅ 现在接真模型 ⇒ ⭐ 才能**主动驱动 idx 13** ✅
        .ctrl_row_o(ctrl_row_w),
        .ctrl_col_i(ctrl_col_r)
    );
    mcp3208_model #(.IDVAL(12'h7c1)) adc0(.cs_n(cs[0]),.sclk(sck),.mosi(mosi),
        .miso(miso[0]),.ch_mask_i(8'h01),.ch_val_i(hall));
    mcp3208_model #(.IDVAL(12'h7c1)) adc1(.cs_n(cs[1]),.sclk(sck),.mosi(mosi),.miso(miso[1]));
    assign miso[5:2]=4'b1111;
    wire rx_done;
    wire [7:0] rx_data;
    //  ⭐ 2026-10-28 改档：⭐ 板载 TX 已是 115200 ⇒ 监听器同步改 434 ✅
    uart_rx #(.BAUD_DIV(434)) monitor(.clk_i(clk),.rst_n_i(rst_n),.rx_i(board_tx),
        .rx_data_o(rx_data),.rx_done_o(rx_done));
    //  ⭐⭐ 镜像判据改为【字节流】级（⛔ 不再逐拍比波形）✅
    //     🔴 板载口改 115200（434）后两口速率不同 ⇒ 波形必然不同
    //        ⇒ 旧 `board_tx!==esp_tx` 逐拍比较必红（⛔ 不是功能坏了）
    //     ✅ 新口径：⭐ ESP 口另配 500 k（100）解码器，逐字节比对 ✅
    wire esp_rx_done;
    wire [7:0] esp_rx_data;
    uart_rx #(.BAUD_DIV(100)) esp_monitor(.clk_i(clk),.rst_n_i(rst_n),.rx_i(esp_tx),
        .rx_data_o(esp_rx_data),.rx_done_o(esp_rx_done));
    integer mirror_cnt_b=0, mirror_cnt_e=0;
    reg [7:0] mirror_b [0:255];
    reg [7:0] mirror_e [0:255];
    always @(posedge clk) if(rst_n) begin
        if(esp_rx_done) begin
            if(mirror_cnt_e<256) mirror_e[mirror_cnt_e]=esp_rx_data;
            mirror_cnt_e=mirror_cnt_e+1;
        end
        if(rx_done) begin
            if(mirror_cnt_b<256) mirror_b[mirror_cnt_b]=rx_data;
            mirror_cnt_b=mirror_cnt_b+1;
            if(mirror_cnt_e < mirror_cnt_b)
                $fatal(1,"FAIL: UART mirrors disagree (ESP missing byte %0d)",mirror_cnt_b-1);
            else if(mirror_b[mirror_cnt_b-1]!==mirror_e[mirror_cnt_b-1])
                $fatal(1,"FAIL: UART mirrors disagree (byte %0d board=%02h esp=%02h)",
                       mirror_cnt_b-1,mirror_b[mirror_cnt_b-1],mirror_e[mirror_cnt_b-1]);
        end
    end
    //  ⭐⭐ 控制板 4x4 矩阵（⭐ 2026-10-17 新增 idx 13「loop 发送」判据 ✅）
    //     📌 `top` 的 `ctrl_row_o` / `ctrl_col_i` **没有默认值**
    //        ⇒ ⭐ 原 tb 把它们**完全悬空**
    //        ⚠️ 而 `top.v` 的 Z-safe 归一把悬空列读成 `1`（未按）
    //           ⇒ ⭐ 不接 model 也能跑（⭐ 这就是原 tb 一直成立的原因 ✅）
    //     ✅ 现在给出一个**真矩阵模型**（⭐ 与 `tb_top_ctrl_wire.sv` 同一套）——
    //        ⭐ 否则 idx 13 那条"按键 ⇒ 真导出"的判据无从驱动 ✅
    //  ⚠️ **提速**：⭐ `SCAN_DIV 12500→4` · `DEB_N 8→2`（⛔ 只 defparam，不改 RTL ✅）
    //  ⚠️ **EC11 不在这里 defparam**：⭐ 本 tb 不驱动 `enc_*`（恒上拉）
    //     ⇒ ⭐ 默认去抖（5 ms）只会让 `enc_*` 永远不动 ⇒ ⭐ 不影响本条判据 ✅
    //  ⚠️ `defparam` 必须写在 `dut` 例化**之后**（⭐ iverilog 要求已解析该实例 ✅）
    defparam dut.u_ctrl_keypad.SCAN_DIV = 4;   // ⭐ 0.25 ms → 80 ns
    defparam dut.u_ctrl_keypad.DEB_N    = 2;   // ⭐ 8 次扫描 → 2 次
    reg [15:0] pressed = 16'd0;
    integer krow, kcol;
    always @(*) begin
        ctrl_col_r = 4'b1111;
        for (krow = 0; krow < 4; krow = krow + 1) begin
            if (!ctrl_row_w[krow]) begin
                for (kcol = 0; kcol < 4; kcol = kcol + 1) begin
                    if (pressed[krow*4 + kcol]) ctrl_col_r[kcol] = 1'b0;
                end
            end
        end
    end
    task press_idx;
        input integer idx;
        begin
            @(negedge clk); pressed[idx] = 1'b1;
            repeat (400) @(negedge clk);   // ⭐ ≥2 次扫描 + 2 次去抖 ✅
        end
    endtask
    task release_all_idx;
        begin
            @(negedge clk); pressed = 16'd0;
            repeat (400) @(negedge clk);
        end
    endtask
    reg capture=0;
    integer count=0;          // ⭐ 已收字节数（⭐ 原文件这行在 `capture` 之后 ✅）
    reg [7:0] bytes[0:255];
    reg [7:0] first_dump[0:27];
    // Optional public-pin trace for cycle-exact before/after timing experiments.
    // No internal register or simulated producer is forced.
    integer trace_fd=0;
    reg [4095:0] trace_path;
    initial begin
        if($value$plusargs("TRACE_PATH=%s",trace_path)) begin
            trace_fd=$fopen(trace_path,"w");
            if(!trace_fd) $fatal(1,"FAIL: cannot open public-pin trace");
        end
    end
    always @(negedge clk) if(rst_n && trace_fd)
        $fdisplay(trace_fd,"%b%b%b%b%b%b%b%b",board_tx,esp_tx,cs,sck,mosi,
                  dut.HP_BCK,dut.HP_WS,dut.HP_DIN);
    always @(posedge clk) if(rst_n) begin
        if(capture && rx_done) begin
            if(count<256) bytes[count]=rx_data;
            count=count+1;
        end
    end
    task send(input [7:0] b);
        integer k;
        begin
            //  115200 board UART: 434 clk/bit (2026-10-28 re-baud, tb adapted)
            @(negedge clk);command_rx=0;repeat(434) @(negedge clk);
            for(k=0;k<8;k=k+1) begin command_rx=b[k];repeat(434) @(negedge clk);end
            command_rx=1;repeat(650) @(negedge clk);
        end
    endtask
    integer i;
    integer probe_value;
    reg [111:0] footer="y000200020003\n";
    initial begin
        repeat(12) @(negedge clk);rst_n=1;
        repeat(200000) @(negedge clk);
        send("R");
        hall=12'h4d9;repeat(60000) @(negedge clk);
        hall=12'h7c1;repeat(60000) @(negedge clk);
        send("R");repeat(2000) @(negedge clk);
        capture=1;count=0;
        //  ⭐⭐ 2026-10-14：⭐ **等待从 40000 加到 200000 拍** ✅
        //     🔴 **为什么**：⭐ `rec_dump` 的帧从 9 B 变成 **14 B**
        //        ⇒ ⭐ 导出本身变长（⭐ 2 帧从 18 → 28 字节）
        //        ⇒ ⚠️ 原来 40000 拍只够发到"3 个拒绝通知"，
        //           🔴 **`'P'` 的探针回复还没排到** ⇒ 判据看不到它 ✅
        //     📌 ⭐ 实测（⭐ dump 出来的字节）：⭐ 40000 拍时 count=45 =
        //        28 帧 ＋ 14 尾 ＋ 3 拒绝 ⇒ ⭐ **正好缺那 11 字节的探针回复** ✅
        send("Y");send("P");send("L");send("R");send("C");send("E");
        repeat(350000) @(negedge clk);
        //  ⭐ 53 字节 @ 115200 ≈ 230020 拍 ⇒ 2026-10-28 改档后从 200000 放大 ✅
        //  ⭐⭐ 2026-10-14：⭐ **帧宽 9 B → 14 B ⇒ dump 帧之后的偏移全部 +10** ✅
        //     📌 旧账：2×9 = 18 帧字节 ＋ 14 尾 ＋ 11 探针 = **43**
        //     📌 新账：2×14 = 28 帧字节 ＋ 14 尾 ＋ 11 探针 = **53** ✅
        //     🔴 **为什么必须改**：⭐ `rec_dump` 已改成 14 B v1.1 帧
        //        （⭐ 治 ESP32 上行解析器全判"未知类型" ✅）
        //  ⭐⭐ 2026-10-14：⭐ **不匹配时把实际字节 dump 出来**（⛔ 别猜布局 ✅）
        //     📌 上一版我按"2×14 + 14 + 11 = 53"算 ⇒ ⚠️ 实测 count=45
        //        ⇒ 🔴 说明**实际布局与我的假设不同** ⇒ ⭐ 先看数据再改判据 ✅
        if(count!=53 || bytes[0]!==8'hA5 || bytes[14]!==8'hA5) begin
            $display("  [dump] count=%0d", count);
            for(i=0;i<60;i=i+1) $display("    [%0d] = %02h", i, bytes[i]);
            $fatal(1,"FAIL: atomic export absent/corrupt count=%0d",count);
        end
        for(i=0;i<14;i=i+1)
            if(bytes[i+28]!==footer[111-i*8 -: 8])
                $fatal(1,"FAIL: footer/interleaving at %0d got=%02h",i,bytes[i+28]);
        for(i=0;i<28;i=i+1) first_dump[i]=bytes[i];
        // Probe reports the chip's live scan value. At rest, every channel in
        // this external ADC model is in 1985..1992 (inverted 2103..2110).
        if({bytes[42],bytes[43],bytes[44],bytes[45],bytes[46]} !== "!!!P0" ||
            bytes[51]!=13 || bytes[52]!=10) $fatal(1,"FAIL: deferred probe framing");
        probe_value=0;
        for(i=47;i<=50;i=i+1) begin
            if(bytes[i]<"0" || bytes[i]>"9") $fatal(1,"FAIL: probe digits");
            probe_value=probe_value*10+bytes[i]-"0";
        end
        if(probe_value<2103 || probe_value>2110) $fatal(1,"FAIL: deferred probe snapshot %0d",probe_value);
        count=0;send("Y");repeat(200000) @(negedge clk);
        if(count<32) $fatal(1,"FAIL: R/L/C changed layer while exporting");
        //  ⭐⭐ 2026-10-14：⭐ **只比"事件内容"，⛔ 不比传输层的 `seq` 与 XOR** ✅
        //     🔴 **为什么**：⭐ `seq` 是**自由运行计数器**（⭐ 每次导出继续递增）
        //        ⇒ ⚠️ 两次导出的 `seq` **天然不同**（⭐ 且 XOR 覆盖 seq ⇒ 也跟着变）
        //        ⇒ 🔴 原来"28 字节逐字节全比"会**误报"录音变了"** ✅
        //     📌 ⭐ 帧内偏移（⭐ 14 B）：⭐ 0=头 · 1=类型 · **2=seq（跳过）** ·
        //        3..6=tick · 7=axis · 8..11=inc · 12=vel · **13=XOR（跳过）** ✅
        //     📌 ⭐ **本判据的原意没变**：⭐ "导出期间 R/L/C **不许改动录音内容**"
        //        ⇒ ⭐ 比的是**事件载荷**（⭐ 类型/tick/轴/音高/力度）✅
        for(i=0;i<28;i=i+1)
            if((i%14)!=2 && (i%14)!=13)
                if(bytes[i]!==first_dump[i]) $fatal(1,"FAIL: recording changed at byte %0d",i);
        // ═══════════════════════════════════════════════════════════════════
        //  ⭐⭐⭐⭐ 判据 ⑰（2026-10-17）：⭐ **键 idx 13（列 1 / 行 3）⇒ 真导出** ✅
        //
        //  ⭐ 用户需求：*"控制板加一个 loop 发送按钮"* ——
        //     ⭐ 它必须做**与串口 `'Y'` 完全相同的事**：把该层已录事件经双 UART 导出 ✅
        //
        //  🔴 **为什么必须整条放进本 tb**（⛔ 不是"凑个判据"）：
        //     ⚠️ 上面 `tb_top_ctrl_wire.sv` 那条判据看的是
        //        **拒绝计数器**（`rd_reject_event`）—— ⚠️ 那个 tb 的 looper 是空的
        //        （`looper_evt_cnt == 0`）⇒ ⭐ 只能证明"脉冲到了 `cmd_recdump_req`"
        //        ⚠️ **不能证明"真的导出了字节"** ✅
        //     ⭐ 而**本 tb 已经录了两条真 Hall 事件**（`evt_cnt = 2`）⇒
        //        ⭐ 天然就是"满条件导出"的现场 ⇒ ⭐ 一条按键就能看到**真字节流** ✅
        //     ⭐ ⇒ 两条判据**互补**：一条证"接线到了"、一条证"行为一样" ✅
        //
        //  🔴 **必须能红**（⭐ 改前必红，⛔ 缺了就是 C83 假绿 ✅）：
        //     ⚠️ 改动前 `km_loop_send_req` 在 `top.v` 里**不存在**
        //        ⇒ ⭐ `u_ctrl_key_map.loop_send_req_o` **悬空**（无消费者）
        //        ⇒ ⭐ `cmd_recdump_req` 收不到这个脉冲 ⇒ **一个字节都不导出**
        //        ⇒ ⭐ `count` 停在 0 ⇒ 🔴 **本判据 FAIL** ✅
        //     ⭐ 接线后 ⇒ ⭐ `cmd_recdump_req = calib_cmd.recdump_req_o | km_loop_send_req`
        //        ⇒ ⭐ 完整走一遍 `rd_pending_r` ⇒ `rec_dump` FSM ⇒ 双 UART ⇒ 🔴 **本判据 PASS** ✅
        //
        //  📌 **观测点全部是公开行为**（⛔ 不 force 任何内部寄存器 ✅）：
        //     ⭐ GPIO `board_tx` 上数到的字节 ＋ 帧内容 ✅
        //
        //  ⚠️⚠️ **为什么必须先 drain（⭐ 第一版就栽在这里 ✅）**：
        //     🔴 上面第 148 行那次 `'Y'` 导出**测完时还没发完**
        //        （⭐ 42 字节 × 1000 拍/字节 = 42000 拍，⭐ 而只等了 40000 拍 ✅）
        //     ⇒ ⭐ 立刻按 idx 13 时 `rd_lock` 仍为 1 ⇒ 🔴 **脉冲被拒**（回 `'!'`）
        //     ⇒ ⭐ 实测字节 `[0]=33 [1]=0a [2]=21`（⭐ `"3\n"` ＋ `'!'` ✅）
        //     ✅ **修法**：⭐ 先空转 100000 拍让上一次导出**彻底发完** ✅
        // ═══════════════════════════════════════════════════════════════════
        repeat(250000) @(negedge clk);       // ⭐ drain 上一次导出（42 B × 4340 拍/B ≈ 182k，改档后从 100000 放大）
        count=0;                             // ⭐ 现在才从零开始数 ✅
        press_idx(13);                       // ⭐ 列 1 / 行 3（⭐ 短按即发 ✅）
        repeat(250000) @(negedge clk);        // ⭐ 42 B × 4340 拍/B ≈ 182k ⇒ 留余量 ✅
        release_all_idx;
        //  ⭐ 必须 ≥ 42 = 2 帧 × 14 B ＋ 14 B footer（⭐ 与第一次 `'Y'` 的布局**逐项相同** ✅）
        //     ⚠️ 这里**没有**再发 `'P'`/`'L'`/`'R'`/`'C'`
        //        ⇒ ⭐ 只有导出本身，⛔ 没有探针回复、⛔ 没有拒绝通知 ✅
        if(count<42 || bytes[0]!==8'hA5 || bytes[14]!==8'hA5) begin
            $display("  [idx13 export] count=%0d", count);
            for(i=0;i<48;i=i+1) $display("    [%0d] = %02h", i, bytes[i]);
            $fatal(1,"FAIL: key idx 13 (loop send) did NOT trigger a real export on the UART");
        end
        //  ⭐ 帧内容必须与 `'Y'` 那次**逐字节相同**（⭐ 只跳过 `seq`/XOR ✅）
        //     📌 这同时证明：⭐ 按键导出与串口导出**是同一条 FSM、同一份数据** ✅
        for(i=0;i<28;i=i+1)
            if((i%14)!=2 && (i%14)!=13)
                if(bytes[i]!==first_dump[i])
                    $fatal(1,"FAIL: idx-13 export payload differs from the 'Y' export at byte %0d",i);
        //  ⭐ 非空洞：⭐ **松开之后不许再导出**（⭐ 一次按键 = 一次导出 ✅）
        //     📌 证明它是**边沿触发**、⛔ 不是电平连发 ✅
        count=0;
        repeat(60000) @(negedge clk);
        if(count!=0) begin
            $display("  [after-release] count=%0d", count);
            for(i=0;i<16;i=i+1) $display("    [%0d] = %02h", i, bytes[i]);
            $fatal(1,"FAIL: bytes appeared AFTER idx 13 was released (it must be edge, not level)");
        end
        if(mirror_cnt_b!=mirror_cnt_e)
            $fatal(1,"FAIL: UART mirrors disagree (byte counts %0d vs %0d)",
                   mirror_cnt_b,mirror_cnt_e);
        $display("PASS: real Hall recording, atomic dual UART export, deferred P, rejected R/L/C, unchanged re-export, and key idx 13 (loop send) driving a byte-identical real export");
        $finish;
    end
    //  ⭐⭐ 2026-10-17：⭐ **看门狗预算 20M → 45M** ✅
    //     🔴 **为什么**：⭐ 新增判据 ⑰（键 idx 13 ⇒ 真导出）要
    //        `100000` 拍 drain ＋ `800` 拍按键 ＋ `80000` 拍等导出 ＋ `60000` 拍验"不连发"
    //     ⚠️ 上限仍是**充裕**的：⭐ 记录态跑完约 11.4M 拍（⭐ 见原 PASS 的时间戳）
    //        ⇒ ⭐ 45M 留 ~3.5 倍余量（⛔ 不放松到"永不触发"✅）
    initial begin #90000000;$fatal(1,"FAIL: top dump watchdog");end
endmodule
