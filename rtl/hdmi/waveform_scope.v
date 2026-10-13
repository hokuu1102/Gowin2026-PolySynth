`timescale 1ns/1ps
// Passive audio tap. The source must not exceed one sample / 1024 sys clocks.
// At 50/25 MHz the 640-word blanking copy takes 25.7 us, far below the
// 384-sample (7.86 ms) overwrite margin of the 1024-word history.
//
// ⭐ 2026-10-09 新增 SCOPE_MODE：同一条历史缓冲上挂【两种渲染器】
//    · SCOPE_MODE = 0 → 波形（按列光栅扫描，原行为，逐字保留）
//    · SCOPE_MODE = 1 → 李萨如（XY 点阵帧缓冲 + 打点）
//  依据 files/20-代码/李萨如显示-设计-20261009.md
//  ⛔ 音频通路零影响（本模块只读 master_mix 的旁接样本）
module waveform_scope #(
    //  XY 模式：Y 取【延迟多少个样本】当 X 轴（64 ≈ 1.3 ms）
    parameter integer XY_DELAY    = 64,
    //  XY 模式：增益（整数）。⭐ 图形大小 ∝ XY_GAIN；量化台阶 = XY_GAIN/8 像素。
    //    · 1  = 旧行为（满幅才占 80% 宽 ⇒ 小信号图形极小）
    //    · 4  = 当前默认（⭐ 用户反馈"太小"后提高）
    //    ⚠️ 调大 ⇒ 大声时削到帧缓冲边缘（示波器式溢出，用户已接受该表现）
    parameter integer XY_GAIN     = 8
) (
    input wire sample_clk, sample_rst_n,
    input wire SCOPE_MODE,          // ⭐ 资源实验：运行时显示模式
    input wire signed [23:0] sample_i,
    input wire valid_i,
    input wire pixel_clk, pixel_rst_n,
    input wire [9:0] x_i, y_i,
    input wire de_i, hs_i, vs_i,
    output reg [7:0] r_o, g_o, b_o,
    output reg de_o, hs_o, vs_o
);
    reg signed [23:0] history [0:1023];
    // Mode crosses as a quasi-static request. Commit it only in vertical
    // blanking so addresses, FSM and RGB use one mode throughout a frame.
    reg mode_launch;
    reg mode_meta, mode_sync, mode_pixel;
    always @(negedge sample_clk) begin
        if (!sample_rst_n) mode_launch <= 1'b0;
        else mode_launch <= SCOPE_MODE;
    end
    wire mode_boundary = (x_i == 0) && (y_i == 480);
    always @(posedge pixel_clk) begin
        if (!pixel_rst_n) begin
            mode_meta <= 1'b0;
            mode_sync <= 1'b0;
            mode_pixel <= 1'b0;
        end else begin
            mode_meta <= mode_launch;
            mode_sync <= mode_meta;
            if (mode_boundary) mode_pixel <= mode_sync;
        end
    end
    reg [9:0] wr_ptr, wr_gray;
    reg history_full;
    wire [9:0] wr_next = wr_ptr + 10'd1;
    // No array reset: infer a true dual-clock block RAM. Unwritten memory is
    // never displayed; history_full is sticky after the first complete wrap.
    always @(posedge sample_clk) begin
        if (!sample_rst_n) begin
            wr_ptr <= 0;
            wr_gray <= 0;
            history_full <= 0;
        end else if (valid_i) begin
            history[wr_ptr] <= sample_i;
            wr_ptr <= wr_next;
            wr_gray <= (wr_next >> 1) ^ wr_next;
            if (wr_ptr == 10'd1023) history_full <= 1;
        end
    end

    // The PLL pixel rising edge coincides with a source rising edge. Launch
    // the CDC bundle on the source falling edge to provide a real 10 ns
    // setup/hold separation instead of relying on a false-path exception.
    // This changes only the passive display pointer, never the audio stream.
    //  ⚠️⚠️ 2026-10-10（实测踩到）：这两个寄存器**必须保留** ——
    //     它们是【故意做的半周期 CDC 延迟】（见上），而且 `constr/top.sdc:102`
    //     用寄存器名 `u_hdmi/u_scope/gray_launch_*_s0` 抓对象来下 max_delay 约束。
    //     加李萨如打点逻辑后综合器把 `gray_launch` 整个优化掉（网表里出现 0 次）
    //     ⇒ SDC 报 `ERROR (TA2003): Can't set timing constraint to object` ⇒ **构建中止**。
    //     ⇒ 用 `syn_preserve`（本工程既有写法，见 `note_manager.v:714`）钉住。
    (* syn_preserve = 1 *) reg [9:0] gray_launch;
    (* syn_preserve = 1 *) reg full_launch;
    always @(negedge sample_clk) begin
        if (!sample_rst_n) begin gray_launch <= 0; full_launch <= 0; end
        else begin gray_launch <= wr_gray; full_launch <= history_full; end
    end

    // Registered Gray pointer and two receiving stages. Both clocks derive
    // from the same 50 MHz reference; every crossing remains timed by SDC.
    reg [9:0] gray_meta, gray_sync;
    reg full_meta, full_sync;
    reg [9:0] wr_seen;
    integer k;
    always @* begin
        wr_seen[9] = gray_sync[9];
        for (k=8; k>=0; k=k-1) wr_seen[k] = wr_seen[k+1] ^ gray_sync[k];
    end
    always @(posedge pixel_clk) begin
        if (!pixel_rst_n) begin
            gray_meta <= 0; gray_sync <= 0;
            full_meta <= 0; full_sync <= 0;
        end else begin
            gray_meta <= gray_launch; gray_sync <= gray_meta;
            full_meta <= full_launch; full_sync <= full_meta;
        end
    end

    // ═══════════════════════════════════════════════════════════════════════
    // 波形模式的 Y 映射（⛔ 逐字保留原行为）
    // ═══════════════════════════════════════════════════════════════════════
    function [8:0] sample_y;
        input signed [23:0] s;
        reg signed [10:0] y_calc;
        begin
            // 2026-10-09（用户指令 · 第二次）：显示分度再调小一档（x4，÷16384）
            y_calc = 11'sd240 - $signed(s[23:14]);   // x4（原 P0-18: s[23:16] = x1）
            if (y_calc < 0) sample_y = 9'd0;
            else if (y_calc > 479) sample_y = 9'd479;
            else sample_y = y_calc[8:0];
        end
    endfunction

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 李萨如（XY）模式的映射 —— 输出【帧缓冲坐标】而不是屏幕坐标
    //   ⭐ 2026-10-10（用户指令 C：帧缓冲升到 640×480 全分辨率）：
    //      · X 中心 **320**、范围 ±320；Y 中心 **240**、范围 ±240
    //      · ⚠️ 分辨率翻倍 ⇒ 同样增益下图形会【相对变小一半】⇒ `XY_GAIN` 必须 4 → **8**
    //        （G=8 ⇒ `(s>>>13)×8>>>3 = s>>>13` ⇒ 量化台阶 1 个屏幕像素，⭐ 比旧版更细）
    //   ⚠️ 两者都必须【饱和夹取】，⛔ 不许回绕（本项目纪律）
    // ═══════════════════════════════════════════════════════════════════════
    function [9:0] xy_x;                       // 0 .. 639
        input signed [23:0] s;
        reg signed [13:0] v;
        reg signed [15:0] c;
        begin
            v = (($signed(s) >>> 13) * XY_GAIN) >>> 3;
            c = 16'sd320 + v;
            if (c < 16'sd0) xy_x = 10'd0;
            else if (c > 16'sd639) xy_x = 10'd639;
            else xy_x = c[9:0];
        end
    endfunction

    function [9:0] xy_y;                       // 0 .. 479
        input signed [23:0] s;
        reg signed [13:0] v, v15;
        reg signed [15:0] c;
        begin
            v   = (($signed(s) >>> 13) * XY_GAIN) >>> 3;
            v15 = v - (v >>> 4);               // ×15/16
            c   = 16'sd240 - v15;
            if (c < 16'sd0) xy_y = 10'd0;
            else if (c > 16'sd479) xy_y = 10'd479;
            else xy_y = c[9:0];
        end
    endfunction

    // ═══════════════════════════════════════════════════════════════════════
    // 快照（波形模式：把 640 个样本转成 Y 坐标）
    // ⭐ 两种模式都需要的公共部分：`copy_base`（窗口起点）在 vblank 起点锁存
    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-10-10（解法 D）：波形的 640 个 Y 值用【自己的 32 位宽小内存】`wave_y`
    //     🔴 为什么不是 9 位宽的 `frame_y`：实测 9 位宽【推断不出 BSRAM】⇒ 白烧 11,293 个寄存器
    //     ✅ 32 位宽与 `xy_fb` 同形 ⇒ 工具能推断（1024×32 = 32,768 bit ⇒ 约 2 块 BSRAM）
    //     ✅ 好处：`xy_fb` 的写口【只由李萨如驱动】、`wave_y` 只由波形驱动 ⇒ 两边都干净
    //  ⭐ 恢复成甲的原版形态（9 位宽）—— ⭐ 它能推断成 BSRAM，只要【读不加门控】
    reg [8:0] frame_y [0:1023];
    reg [9:0] copy_base, copy_index, copy_index_q;
    reg copying, copy_valid_q, frame_ready;
    reg signed [23:0] history_q;
    // Snapshot only in vertical blanking. The image is immutable during all
    // 480 active lines; a ring wrap can never splice two different frames.
    wire vblank_start = (x_i == 0) && (y_i == 480) && full_sync;
    always @(posedge pixel_clk) begin
        if (!pixel_rst_n) begin
            copy_base <= 0; copy_index <= 0; copy_index_q <= 0;
            copying <= 0; copy_valid_q <= 0; frame_ready <= 0;
        end else begin
            copy_valid_q <= copying;
            if (vblank_start) begin
                copy_base <= wr_seen - 10'd640;
                copy_index <= 0;
                //  ⭐⭐ 解法 D：⛔ 写使能链里【不能出现 SCOPE_MODE】—— 否则 BSRAM 推断失败（实测 11k 寄存器）
                //     ✅ 安全性：李萨如模式下多跑一次 wave_y 快照无害（那模式不读 wave_y）
                copying <= 1'b1;
            end else if (copying) begin
                copy_index <= copy_index + 1'b1;
                if (copy_index == 639) copying <= 0;
            end
            if (copying) copy_index_q <= copy_index;
            if (copy_valid_q && copy_index_q == 639) frame_ready <= 1;
        end
    end

    // ═══════════════════════════════════════════════════════════════════════
    // ⭐ 李萨如：XY 帧缓冲（320×240×1bit，每字 8 像素 ⇒ 9600 字节）
    //   BSRAM：76800 bit ⇒ 约 5 块（现用 33/118 ⇒ 装得下）
    //   渲染时【上采样 2×】⇒ 显示仍是 640×480，⛔ 零额外逻辑
    // ═══════════════════════════════════════════════════════════════════════
    //   ⭐ 2026-10-10（用户指令 C）：帧缓冲升到 **640×480 全分辨率** ⇒ ⛔ 不再上采样 2×
    //      ⇒ 每个像素就是 1 个屏幕像素（消掉"2×2 方块感"）
    //   ⚠️ 为了把【清屏耗时】压住，采用 **32 像素/字**（而不是 8 像素/字）：
    //      每行 640/32 = 20 字、共 480 行 = 9600 字 ⇒ 清屏仍是 9600 拍 ✅（与旧版相同！）
    //      ⚠️ 若用 8 像素/字 ⇒ 38400 字 ⇒ 清屏 38400 拍 > vblank 的 36000 拍 ❌ 装不下
    // ═══════════════════════════════════════════════════════════════════════
    localparam integer FB_WPB  = 32;            // ⭐ 每字 32 像素
    localparam integer FB_WPR  = 20;            // 640/32 = 每行字数
    localparam integer FB_N    = 9600;          // 480 × 20
    localparam [13:0]  FB_LAST = 14'd9599;      // ⚠️ 用有宽度的常量做比较（⛔ 不对 integer 参数做位选）
    reg [31:0] xy_fb [0:FB_N-1];

    // ── 打点状态机（⭐ 2026-10-10 加【连线】—— 用户反馈"波形都是点点点"）
    //  🔴 原因：每个 k 只置 1 个像素 ⇒ 相邻样本之间没有像素 ⇒ 复音/有谐波时轨迹跑得快
    //     （相邻样本常隔 5~10 px）⇒ 看上去就是"点点点"
    //  ✅ 做法：在【当前 x 列】把 y_prev → y_cur 之间填满
    //     —— 与波形模式 `on_trace` 的"每列画竖线"同一手法
    //  🔴🔴 曾用 Bresenham（含 dx/err/e2/两个比较/三路 err 更新）实测：CLS 顶到 82%、
    //     setup 违例 34 条、clk_sys 掉到 49.700 MHz（< 50 MHz 物理时钟）⇒ ⛔ 不可交付
    //     ⇒ ⭐ 换成竖直填充后逻辑少得多（去掉 dx/err/e2/do_x/do_y 约 100 LUT）
    //  ⚠️ 单段上限 `MAX_SEG` 限住最坏耗时
    //     预算 = 清屏 9600 + 1024 点 ×(4 建立 + ≤MAX_SEG×2) ；MAX_SEG=8 ⇒ 30,080 < 36000 ✅
    localparam [2:0] XY_IDLE = 3'd0, XY_CLR = 3'd1, XY_PLOT = 3'd2;
    localparam integer MAX_SEG = 8;    // ⚠️ 最坏 = 1024×(2×8+6)+9600 = 32128 < 36000（89%）
    localparam [9:0]   PT_LAST = 10'd1023;   // ⭐ 用【全部 1024 个样本】⇒ 点更密（免费）
    reg [2:0]  xy_st;
    reg [13:0] clr_idx;                          // 0..9599
    reg [9:0]  pt_idx;                           // 0..639
    reg [2:0]  pt_step;                          // 0..5
    reg signed [23:0] h_q;                       // ⭐ 历史缓冲统一读口的输出（优化③：不再需要 hx_q/hy_q）
    reg [9:0]  px_q, py_q;                       // 本点
    reg [9:0]  px_p, py_p;                       // 上一点（线段起点）
    reg [9:0]  bx, by;                           // 当前要画的像素（沿主轴走）
    reg        sx, sy;                           // ⭐ 优化⑤：步进方向只需 1 位（1 = +1）
    reg        major_q;                          // ⭐ 本段沿哪个轴补（1 = 横向、0 = 纵向）
    reg [4:0]  seg_n, seg_len;                   // ⭐ 5 位（MAX_SEG ≤ 15）
    reg [13:0] fb_waddr;                         // ⭐ 优化④：不再需要 32 位 fb_mask
    reg        xy_ready;

    // ── 连线几何（组合）⭐ 2026-10-10 加【横向填充】治虚线：
    //    · 沿【主轴】走：|Δx| > |Δy| ⇒ 横向补（y 固定在 py_q）；否则纵向补（x 固定在 px_q）
    //    · 🔴 为什么：只做竖直填充时，曲线接近水平的段落填不上 ⇒ 露成虚线（用户照片实证）
    //    · ⚠️ 这是"沿主轴走"而不是真 Bresenham（省掉 err/e2/两比较约 100 LUT —— 那版实测打崩时序）
    //    ⭐ `pt_idx==0` 时起点就是本点（只画一个像素）
    wire [9:0] x0   = (pt_idx == 10'd0) ? px_q : px_p;
    wire [9:0] y0   = (pt_idx == 10'd0) ? py_q : py_p;
    wire [9:0] dxu  = (px_q >= x0) ? (px_q - x0) : (x0 - px_q);
    wire [9:0] dyu  = (py_q >= y0) ? (py_q - y0) : (y0 - py_q);
    wire       xup  = (px_q >= x0);
    wire       yup  = (py_q >= y0);
    wire       major_x = (dxu > dyu);
    wire [9:0] major_d = major_x ? dxu : dyu;

    wire [9:0] hx_addr = pt_idx;                 // ⭐ 全 1024 深度 ⇒ 直接用 pt_idx（无需 copy_base）
    //  ⚠️ `XY_DELAY` 是 integer 参数 ⇒ ⛔ 不做位选；中间按 32 位算、赋给 10 位时
    //     按模 2^10 截断 ⇒ 正好等于环形缓冲的 (idx-D) mod 1024 ✅
    wire [9:0] hy_addr = pt_idx - XY_DELAY;
    wire [9:0] history_addr = (mode_pixel == 0)
        ? (copy_base + copy_index)
        : ((pt_step == 3'd0) ? hx_addr : hy_addr);

    // ⭐ 帧缓冲读写地址：全分辨率 ⇒ 直接用屏幕坐标（⛔ 不再 >>1 上采样）
    //   `fx`/`fy` 是【全分辨率】的 0..639 / 0..479
    wire [9:0] fx = x_i;                         // 640 列
    wire [9:0] fy = y_i;                         // 480 行
    //  ⭐⭐ 2026-10-11 修法（DSP 冲突）：⛔ 不能用 `fy * FB_WPR` ——
    //     `FB_WPR=20` 是【变量 × 常量】乘法 ⇒ Gowin 会实例化 MULT12X12 硬宏（固定位置）
    //     ⇒ ⭐ 与 `top.cst` 的区域约束 `GRP_LOC` 冲突（实测报 CT1005）
    //     ✅ 改法：20 = 16 + 4 ⇒ 用【移位 + 加法】代替乘法（⭐ 结果完全等价，⛔ 不改功能）
    wire [13:0] row_off = ({5'b0, fy[8:0]} << 4) + ({7'b0, fy[8:0]} << 2);   // fy × 20
    wire [13:0] by_off  = ({5'b0, by[8:0]} << 4) + ({7'b0, by[8:0]} << 2);   // by × 20
    wire [13:0] render_addr = row_off + {9'b0, fx[9:5]};
    wire [13:0] plot_addr   = by_off  + {9'b0, bx[9:5]};

    //  ⭐⭐ 资源实验：把 BSRAM 的【地址】先过一级寄存器 —— 组合 mux 直接喂地址会让
    //     工具【推断不出 BSRAM】⇒ 退化成上万个寄存器（实测 u_scope +11392 个）
    reg [9:0] history_addr_r;
    always @(posedge pixel_clk) history_addr_r <= history_addr;

    always @(posedge pixel_clk) begin
        // 历史缓冲统一读口（波形模式读 copy 窗口；XY 模式读 hx/hy）
        //  ⚠️ 必须写【独立的 h_q】，⛔ 不能直接写 hx_q ——
        //     否则 hx_q 会被本块与打点 FSM 两个 always 同时驱动（多驱动冲突）
        //  \u2b50\u2b50 2026-10-11 \u4fee\u6cd5\uff1a\u8bfb\u76ee\u6807\u5f84\u5b58\u5668\u4e0d\u80fd\u4f9d\u8d56 SCOPE_MODE\uff08\u5426\u5219 11,237 \u4e2a\u5bc4\u5b58\u5668\uff09
        history_q <= history[history_addr];
        h_q       <= history[history_addr];
        //  ⭐ 解法 D：波形的 Y 值写进【自己的 wave_y】（写使能【不含】运行时 mux ⇒ 端口干净）
        if (copy_valid_q) frame_y[copy_index_q] <= sample_y(history_q);
    end

    always @(posedge pixel_clk) begin
        if (!pixel_rst_n) begin
            xy_st <= XY_IDLE; clr_idx <= 0; pt_idx <= 0; pt_step <= 0;
            px_q <= 0; py_q <= 0; px_p <= 0; py_p <= 0;
            bx <= 0; by <= 0; sx <= 0; sy <= 0; major_q <= 0;
            seg_n <= 0; seg_len <= 0;
            fb_waddr <= 0;
            xy_ready <= 0;
        end else begin
            case (xy_st)
                XY_IDLE: begin
                    // Finish an in-flight job even if a new mode is requested.
                    // Jobs start only during blanking in the requested XY mode.
                    if (vblank_start && mode_sync) begin
                        clr_idx <= 0; xy_st <= XY_CLR; xy_ready <= 0;
                    end
                end
                XY_CLR: begin
                    //  ⭐ 清屏的【写】已移到下方【单一写口】块（⛔ 两处写会让工具看到两个写口 ⇒ BSRAM 推断失败）
                    if (clr_idx == FB_LAST) begin
                        pt_idx <= 0; pt_step <= 0; xy_st <= XY_PLOT;
                    end else clr_idx <= clr_idx + 14'd1;
                end
                XY_PLOT: begin
                    //  ⭐⭐ 2026-10-10 优化③⑤：⭐ 省掉 `hx_q`/`hy_q` 两个 24 位寄存器
                    //     —— `h_q` 到达的那一拍【直接算】px_q / py_q，并顺手少一步（7 步 → 6 步）
                    //     ⭐ 另把 `sx`/`sy` 从 11 位缩到 **1 位**（其实只有 ±1）
                    case (pt_step)
                        3'd1: px_q <= xy_x(h_q);              // h_q = hx ⇒ 直接算 px
                        3'd2: py_q <= xy_y(h_q);              // h_q = hy ⇒ 直接算 py
                        3'd3: begin                            // ⭐ 连线建立（沿主轴）
                            //  横向补：x 从 x0 走到 px_q，y 固定在 py_q
                            //  纵向补：y 从 y0 走到 py_q，x 固定在 px_q
                            bx      <= major_x ? x0   : px_q;
                            by      <= major_x ? py_q : y0;
                            sx      <= xup;
                            sy      <= yup;
                            major_q <= major_x;
                            seg_n   <= 5'd0;
                            seg_len <= (major_d > MAX_SEG) ? MAX_SEG[4:0] : major_d[4:0];
                        end
                        3'd4: fb_waddr <= plot_addr;           // 画当前像素（读由共用读口给）
                        3'd5: begin                            // 写回（由下方【单一写口】统一做）+ 沿主轴推进
                            if (seg_n >= seg_len) begin
                                px_p <= px_q; py_p <= py_q;    // 本段完成
                                if (pt_idx == PT_LAST) begin
                                    xy_st <= XY_IDLE; xy_ready <= 1;
                                end else begin
                                    pt_idx  <= pt_idx + 10'd1;
                                    pt_step <= 3'd0;
                                end
                            end else begin
                                if (major_q) bx <= sx ? (bx + 10'd1) : (bx - 10'd1);
                                else         by <= sy ? (by + 10'd1) : (by - 10'd1);
                                seg_n <= seg_n + 5'd1;
                                pt_step <= 3'd4;               // 回到画点
                            end
                        end
                        default: ;                             // step0：等 hx 读出
                    endcase
                    //  ⚠️ 只有 step5 自己决定去向（回 step4 继续画 / 回 step0 换下一点）
                    if (pt_step != 3'd5) pt_step <= pt_step + 3'd1;
                end
                default: xy_st <= XY_IDLE;
            endcase
        end
    end

    // ⭐⭐ 2026-10-10 优化②：`xy_fb` 【合并成单一读口】
    //  🔴 原来有两条独立读语句（打点期的 RMW + 渲染期的读）⇒ 综合器很可能【复制整块内存】
    //     证据：9600×32bit = 307200 bit，BSRAM 最优（512×36）应占 ~19 块，实测占 48 块（效率仅 35%）
    //  ✅ 打点在 vblank、渲染在有效行 ⇒ 【时段互斥】⇒ 可以共用同一读口
    //     ⚠️ 用 `xy_st == XY_PLOT` 选地址即可
    //  ⭐⭐ 2026-10-10（用户指令 B）：⭐ 【单一写口】—— 两种模式共用同一个写端口
    //     波形：把该列的 Y 值（9 位）写进 `xy_fb[0..639]` 的低 9 位
    //     李萨如：读-改-写，把当前像素位置 1
    //     ⚠️ 必须只有一个写口，否则综合器会【复制整块内存】（这正是之前 BSRAM 82% 的教训）
    //
    //  🔴🔴 ⭐⭐ **2026-10-13：⭐ 这两个声明【必须在这里】—— 修一处前向引用** ✅
    //     ⚠️ ⭐ 它们原来声明在下方 `:394-395` ✅，⭐ 但：
    //        · ⭐ `fb_q`      在 ⭐ `:374`（`fb_wdata`）和 ⭐ `:381`（写口）**就被用了** ✅
    //        · ⭐ `fb_rdaddr` 在 ⭐ `:391`（`fb_rdaddr_r` 打拍）**就被用了** ✅
    //     ⇒ 🔴 ⭐ **前向引用** ✅（⭐ 本模块反复强调的头号教训：⭐ "声明必须在使用之前" ✅）
    //     🔴 ⭐ **实测后果**：⭐ **iverilog 直接编译失败** ✅
    //        `error: Unable to bind wire/reg/memory 'fb_q'`
    //        ⇒ ⭐ **28 个例化 `top` 的 tb 全部编译不过**（⭐ 含 `tb_top_m0`/`tb_top_sound` ✅）
    //     🔴🔴 ⭐ ⭐ **而 Gowin 综合【静默接受】了它** —— ⭐ 队友那一版 PnR 报 `0/0`
    //        并出了位流 ✅ ⇒ ⚠️ 说明综合器很可能把 `fb_q` 当成**隐式 1 位 wire** ✅
    //        ⇒ 🔴 ⭐ **李萨如（XY）显示在板上很可能是坏的，而没人知道** ✅
    //        📌 ⭐ 这正是本项目最怕的**静默类**缺陷（⭐ `K-106` ✅）——
    //           ⭐ **仿真器报错反而是好事** ✅
    //     ✅ ⭐ **修法**：⭐ 把这两行【上移】到首次使用之前 ✅ ——
    //        ⭐ ⭐ **纯声明顺序调整，⛔ 零逻辑、⛔ 零面积变化** ✅
    wire [13:0] fb_rdaddr = (xy_st == XY_PLOT) ? plot_addr : render_addr;
    reg  [31:0] fb_q;                              // ⭐ 唯一读口输出（打点/渲染共用）

    wire        fb_we     = (SCOPE_MODE == 0)
                            ? copy_valid_q
                            : (xy_st == XY_PLOT && pt_step == 3'd5);
    wire [13:0] fb_waddr_m = (SCOPE_MODE == 0) ? {4'b0, copy_index_q} : fb_waddr;
    reg        fb_we_r;
    reg [13:0] fb_waddr_r;
    reg [31:0] fb_wdata_r;
    wire [31:0] fb_wdata   = (SCOPE_MODE == 0)
                            ? {23'b0, sample_y(history_q)}
                            : (fb_q | (32'h1 << bx[4:0]));
    //  ⭐⭐ 解法 D：`xy_fb` 的写口【只由李萨如驱动】⇒ 端口干净 ⇒ 能推断 BSRAM
    //     波形改用【自己的 32 位小内存】`wave_y`（见上）⇒ 各写各的，互不 mux
    always @(posedge pixel_clk) begin
        if (xy_st == XY_CLR) begin
            xy_fb[clr_idx] <= 32'h0;
        end else if (xy_st == XY_PLOT && pt_step == 3'd5) begin
            xy_fb[fb_waddr] <= fb_q | (32'h1 << bx[4:0]);
        end
    end

    //  ⭐ B：波形模式 ⇒ 读 `xy_fb[x_i]`（低 9 位 = 该列的 Y）；
    //        李萨如 ⇒ 打点期用 plot_addr、渲染期用 render_addr
    //  ⚠️ 波形模式必须读【下一列】(x_i+1)：因为 `fb_q` 在 T 拍持有的是 T-1 拍地址的数据，
    //     而 `point_q` 要在 T+1 拍给出第 X 列的 Y ⇒ 地址必须提前一拍。
    //     ⚠️ 回绕（x_i 799→0）要单独处理，否则第 0 列会拿到越界数据（实测踩到）
    reg  [13:0] fb_rdaddr_r;
    always @(posedge pixel_clk) fb_rdaddr_r <= fb_rdaddr;
    //  ⭐ 修法：xy_fb 的读地址【不含运行时 mux】—— 波形走自己的 frame_y，不再读这里
    //  ⭐ 解法 D：`xy_fb` 的读地址【不含运行时 mux】（波形读自己的 wave_y）
    //  🔴 2026-10-13：⭐ `fb_rdaddr` / `fb_q` 的【声明已上移】到首次使用之前 ✅
    //     ⚠️ 原来在这里声明 ⇒ ⭐ 前向引用 ⇒ 🔴 iverilog 编译失败 ✅（⭐ 见上方长注释 ✅）
    reg  [4:0]  fb_bit_q;
    always @(posedge pixel_clk) begin
        fb_q <= xy_fb[fb_rdaddr];
        if (mode_pixel != 0 && de_i) fb_bit_q <= fx[4:0];
    end
    wire xy_hit = fb_q[fb_bit_q];

    // ═══════════════════════════════════════════════════════════════════════
    // 渲染（两种模式共用同一套两级流水 ⇒ 时序契约不变）
    // ═══════════════════════════════════════════════════════════════════════
    //  ⭐⭐ 2026-10-11（乙 · 重新审视后纠正）：⛔ **删掉 `wave_y` 整块** ——
    //     🔴 我之前的判断错了：不是"9 位宽推断不出 BSRAM"，
    //        而是【我给 `frame_y` 的读加了 `SCOPE_MODE` 门控】才害它推断失败。
    //     ✅ 对照甲的原版（`origin/main:rtl/hdmi/waveform_scope.v`）：
    //          reg [8:0] frame_y [0:1023];
    //          if (de_i) point_q <= frame_y[x_i];      ← ⭐ 读【无任何门控】
    //        ⇒ ⭐ 它的 Register 总数是 17,353（正常）✅
    //     ✅ 所以正确的最小修法是：恢复 `frame_y` + **只去掉读上的 `SCOPE_MODE` 门控**
    //        （见下方渲染块里的 `if (de_i) point_q <= frame_y[x_i];`）
    //     📌 收益：网表回到【甲的原版 + 李萨如】⇒ 布局偏离小 ⇒ 不再挤坏 note_manager

    reg [8:0] point_q, previous_y;
    reg [9:0] x_q, y_q;
    reg de_q, hs_q, vs_q;
    wire [8:0] segment_previous = (x_q == 0) ? point_q : previous_y;
    wire on_trace = frame_ready &&
        (((y_q >= point_q) && (y_q <= segment_previous)) ||
         ((y_q >= segment_previous) && (y_q <= point_q)));
    // Synchronous RAM read, then registered pixel: RGB and all timing signals
    // have the same two-register latency. Column zero never joins to x=639.
    always @(posedge pixel_clk) begin
        //  ⭐ 2026-10-10 优化①：⛔ 门控 rame_y 的读 —— 李萨如模式下它【永不被写】
        //     却不被门控地读 ⇒ 工具会照样建出这块 9bit×1024 的内存（约 10~15 块 BSRAM）⚠️
        //  ⭐⭐ 修法：读地址【先寄存一拍】(wy_a)，并用 x_i+1 补偿那一拍（与 xy_fb 同手法）

        //  ⭐⭐⭐ 关键修法：读【不加任何门控】（甲的原版就是这一行）
        //     🔴 之前写成 if (de_i && SCOPE_MODE == 0) ⇒ BSRAM 推断失败 ⇒ 11,293 个寄存器
        if (de_i) point_q <= frame_y[x_i];
        if (!pixel_rst_n) begin
            x_q <= 0; y_q <= 0; de_q <= 0; hs_q <= 1; vs_q <= 1;
            previous_y <= 240;
            r_o <= 0; g_o <= 0; b_o <= 0;
            de_o <= 0; hs_o <= 1; vs_o <= 1;
        end else begin
            x_q <= x_i; y_q <= y_i;
            de_q <= de_i; hs_q <= hs_i; vs_q <= vs_i;
            de_o <= de_q; hs_o <= hs_q; vs_o <= vs_q;
            if (de_q) previous_y <= point_q;
            r_o <= 0; g_o <= 0; b_o <= 0;
            if (de_q) begin
                if (mode_pixel == 0) begin
                    if (on_trace) begin
                        r_o <= 8'h00; g_o <= 8'hff; b_o <= 8'h00;
                    end else if (y_q == 240) begin
                        r_o <= 8'h28; g_o <= 8'h28; b_o <= 8'h28;
                    end
                end else begin
                    // ⭐ 李萨如：亮绿点阵 + 暗灰中心十字（便于判断居中）
                    if (xy_ready && xy_hit) begin
                        r_o <= 8'h00; g_o <= 8'hff; b_o <= 8'h00;
                    end else if ((y_q == 240) || (x_q == 320)) begin
                        r_o <= 8'h28; g_o <= 8'h28; b_o <= 8'h28;
                    end
                end
            end
        end
    end
endmodule
