// 探针：验证「对 integer 参数做位选」在 iverilog 下到底求值成什么
// 对应现场：rtl/w3a/event_extract.v:307 (FIFO_D[FW:0]) 与 :305 (REFRACT_N[15:0])
`timescale 1ns/1ps
`default_nettype none

module probe_intsel;
    localparam integer FIFO_D    = 4;
    localparam integer REFRACT_N = 60;
    localparam integer FW        = 2;

    // 三种写法并列，看哪一个在语义上等于原值
    wire [FW:0]  a_intsel = FIFO_D[FW:0];          // ⚠️ 现场写法（integer 位选）
    wire [2:0]   a_cast   = FIFO_D[2:0];
    wire [15:0]  r_intsel = REFRACT_N[15:0];       // ⚠️ 现场写法
    wire [15:0]  r_cast   = REFRACT_N[15:0];

    localparam [2:0]  FIXED_V = FIFO_D;            // ⭐ 官方推荐写法：先落定宽 localparam
    localparam [15:0] REF_V   = REFRACT_N;

    initial begin
        #1;
        $display("FIFO_D[FW:0]      = %0d (expect 4)", a_intsel);
        $display("FIFO_D[2:0]       = %0d (expect 4)", a_cast);
        $display("REFRACT_N[15:0]   = %0d (expect 60)", r_intsel);
        $display("localparam FIXED_V= %0d (expect 4)", FIXED_V);
        $display("localparam REF_V  = %0d (expect 60)", REF_V);
        // 关键判据：现场那种"位选"到底等不等于原值
        if (a_intsel !== 3'd4) $display("RED: FIFO_D[FW:0] != 4  => event_extract 的 FIFO 满判据被破坏");
        else                   $display("GREEN: FIFO_D[FW:0] == 4 => 该处安全");
        if (r_intsel !== 16'd60) $display("RED: REFRACT_N[15:0] != 60 => 不应期被清零");
        else                     $display("GREEN: REFRACT_N[15:0] == 60 => 该处安全");
        $finish;
    end
endmodule

`default_nettype wire
