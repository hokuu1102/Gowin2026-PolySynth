// Gowin primitive boundary: bit zero is transmitted first.
module tmds_serializer (
    input wire pixel_clk,
    input wire serial_clk,
    input wire rst,
    input wire [9:0] blue,
    input wire [9:0] green,
    input wire [9:0] red,
    output wire [2:0] tmds_d_p_0,
    output wire [2:0] tmds_d_n_0,
    output wire tmds_clk_p_0,
    output wire tmds_clk_n_0
);
    wire [3:0] serial;
    wire [9:0] lane [0:3];
    assign lane[0] = blue;
    assign lane[1] = green;
    assign lane[2] = red;
    assign lane[3] = 10'b0000011111;
    genvar j;
    generate for (j=0; j<4; j=j+1) begin : lanes
        //  ⭐⭐ 2026-10-17（recovery 修复）：⭐ **删掉这一级 FF，直接透传** ✅
        //   🔴 原写在 125 MHz 域末尾又插了一级：`always @(posedge serial_clk)
        //        lane_reset <= rst;` —— 而 `rst` 已经是 `hdmi_scope.v:53-55` 的
        //        `rstn_ser` 3 级【本域 FF 输出】（⭐ `:56 serial_reset = ~rstn_ser[2]` ✅）
        //      ⇒ ⭐ 多这一级 = 把"同沿释放"破坏成"晚 1 个 serial_clk 沿释放"（8 ns ✅）
        //      ⇒ 🔴 正好撞进 `OSER10.RESET` 的 t_REC 窗口 ✅
        //         ⭐ PnR 实测：recovery slack −0.910 / −0.652 / −0.555 / −0.504 ns ✅
        //   ✅ 现在 `assign` 透传 ⇒ ⭐ 同一条路径换参考沿即翻正 ✅
        //        （⭐ `[R]->[R]` = +3.088 ~ +3.494 ns ✅）
        //   🔴 **必须同时删掉 `(* syn_preserve = 1 *)`** —— 留着会得到
        //        "被保留的空驱动"，反而可能触发综合告警 ✅
        //   ⭐ `initial = 1'b1` 的语义（上电先保持复位）由 **OSER10 原语自身的
        //      INIT** 保证，⛔ 不依赖这个 FF ✅
        //   ⭐ `constr/top.sdc:117-119` 明令禁止用 `set_false_path` 藏这类检查：
        //        "当前 recovery +1.490 ns、removal +0.217 ns，都是必须保留的检查"
        //        ⇒ ⚠️ 那条注释写的时候 recovery 是**正值**，现在掉到 **−0.910**
        //        ⇒ ⭐ **当初留下的检查正在报警** ✅
        wire lane_reset = rst;
        OSER10 u_oser (
            .Q(serial[j]), .D0(lane[j][0]), .D1(lane[j][1]),
            .D2(lane[j][2]), .D3(lane[j][3]), .D4(lane[j][4]),
            .D5(lane[j][5]), .D6(lane[j][6]), .D7(lane[j][7]),
            .D8(lane[j][8]), .D9(lane[j][9]),
            .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(lane_reset)
        );
        if (j < 3) begin : data_pair
            TLVDS_OBUF u_diff (.I(serial[j]), .O(tmds_d_p_0[j]), .OB(tmds_d_n_0[j]));
        end
    end endgenerate
    TLVDS_OBUF u_clock_pair (.I(serial[3]), .O(tmds_clk_p_0), .OB(tmds_clk_n_0));
endmodule
