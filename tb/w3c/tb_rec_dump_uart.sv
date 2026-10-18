`timescale 1ns/1ps
`default_nettype none
// ⭐⭐ 2026-10-14：⭐ **帧宽 9 B → 14 B 后同步本 tb** ✅
//   🔴 **为什么改**：⭐ `rec_dump` 原来发 `0xA5` + 8 B 事件字（**9 B**）
//      ⇒ ⚠️ 没有类型字节、没有校验 ⇒ 🔴 **ESP32 的 v1.1 解析器全部判"未知类型"** ✅
//   ✅ 现在是 **14 B v1.1 帧**（⭐ 与 `evt_upstream` 同构 ✅）
//   📌 ⭐ **参考值是【手工推算】的**（⭐ 见下面 `expected` 的推导注释）——
//      ⚠️ ⛔ 不用 RTL 的同一套公式反算，⭐ 否则两边同一个误解就测不出来 ✅
module tb_rec_dump_uart;
    reg clk=0,rst_n=0,req=0;
    always #10 clk=~clk;
    wire push,ready,done,dump_busy,ovf,start,uart_busy,serial,rx_done;
    wire [7:0] byte_value,drop,tx_data,rx_data;
    wire [15:0] frames;
    integer received=0;
    //  ⭐ 2 帧 × 14 B = 28 字节（⭐ 原来 2 × 9 = 18 ✅）
    reg [7:0] bytes [0:31];
    always @(posedge clk) if(rx_done) begin
        if(received<32) bytes[received]=rx_data;
        received=received+1;
    end
    rec_dump dut(.clk_i(clk),.rst_n_i(rst_n),.req_i(req),.idle_i(1'b1),
        .cnt_i(16'd2),.data_i(64'h0123456789abcdef),.clip_i(1'b0),
        .ready_i(ready),.push_o(push),.byte_o(byte_value),.busy_o(dump_busy),
        .done_o(done),.frame_cnt_o(frames));
    uart_tx_fifo fifo(.clk_i(clk),.rst_n_i(rst_n),.push_i(push),
        .data_i(byte_value),.ready_o(ready),.busy_i(uart_busy),.ovf_o(ovf),
        .tx_start_o(start),.tx_data_o(tx_data),.drop_cnt_o(drop),.ovf_clr_i(1'b0));
    uart_tx #(.BAUD_DIV(100)) tx(.clk_i(clk),.rst_n_i(rst_n),.tx_start_i(start),
        .tx_data_i(tx_data),.tx_o(serial),.busy_o(uart_busy));
    uart_rx #(.BAUD_DIV(100)) rx(.clk_i(clk),.rst_n_i(rst_n),.rx_i(serial),
        .rx_data_o(rx_data),.rx_done_o(rx_done));
    //  ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ **手工推算的参考帧**（⭐ 独立于 RTL ✅）
    //     源字 `word = 0x0123456789ABCDEF`（⭐ tb 喂给 `data_i` ✅）
    //     按 v1.1 位域（⭐ `tick[63:44] inc[43:23] axis[22:19] vel[18:11]
    //                    kind[10:9] timbre[8:7]`）逐个抠出来：
    //       tick    = bits63..44 = 0x01234      ⇒ tick32 = `00 00 12 34`
    //       inc     = bits43..23 = 0xACF13      ⇒ inc32  = `<<10` = `2B 3C 4C 00`
    //       axis    = bits22..19 = 0b0101 = 5
    //       vel     = bits18..11 = 0b01111001 = 0x79
    //       kind    = bits10..9  = 0b10 = 2     ⇒ ⛔ 不是 1 ⇒ type = **0x01**
    //       timbre  = bits8..7   = 0b11 = 3
    //       ⭐⭐ 2026-10-18：⭐ `byte[7] = {pad, is_drum, timbre[1:0], axis[3:0]}`
    //          = {1'b0, 1'b0, 2'b11, 4'b0101} = `0011_0101` = **0x35**
    //          🔴 改前这里只有 `axis`（`05`）⇒ 音色被丢掉 ⇒ ESP32 解出恒 0（BASS）✅
    //       XOR[0..12] = A5^01^00^00^00^12^34^35^2B^3C^4C^00^79 = **0x95**
    //     ⇒ 第 0 帧 = `A5 01 00 00 00 12 34 35 2B 3C 4C 00 79 95`
    //     📌 第 1 帧**只有 `seq` 与 XOR 变**（⭐ seq=1 ⇒ XOR 也 ^1 = 0x94 ✅）
    //  ═══════════════════════════════════════════════════════════════════════
    reg [111:0] expected;
    integer i;
    initial begin
        repeat(4) @(negedge clk);rst_n=1;req=1;
        @(negedge clk);req=0;
        repeat(30000) @(negedge clk);
        if(ovf || drop!=0 || received!=28 || frames!=2)
            $fatal(1,"FAIL: export frames=%0d drop=%0d bytes=%0d (expected 2 / 0 / 28)",frames,drop,received);
        expected=112'hA5_01_00_00_00_12_34_35_2B_3C_4C_00_79_95;
        for(i=0;i<14;i=i+1) begin
            if(bytes[i] !== expected[111-i*8 -: 8])
                $fatal(1,"FAIL: frame0 byte %0d corrupted (got %02h want %02h)",
                       i, bytes[i], expected[111-i*8 -: 8]);
        end
        //  ⭐ 第 1 帧：⭐ 头/类型/seq 必须对，⭐ 校验随 seq 变 ✅
        if(bytes[14]!==8'hA5 || bytes[15]!==8'h01 || bytes[16]!==8'h01)
            $fatal(1,"FAIL: frame1 header/type/seq wrong (got %02h %02h %02h)",
                   bytes[14],bytes[15],bytes[16]);
        if(bytes[27] !== 8'h94)
            $fatal(1,"FAIL: frame1 checksum wrong (got %02h want 94)", bytes[27]);
        $display("PASS: two complete 14-byte v1.1 frames through real FIFO and 500kbps UART");
        $finish;
    end
endmodule
`default_nettype wire
