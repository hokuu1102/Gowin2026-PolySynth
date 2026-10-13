`timescale 1ns/1ps
// ─────────────────────────────────────────────────────────────────────────────
// evt_buf.v · `U-19` 曲谱事件缓冲区（⭐ **滚动预灌** · ⭐ **8 KB / 1024 事件**）
//
// ⭐ **为什么需要它**（⭐ 这是 `play_seq` 一直没能例化的**唯一**原因 ✅）：
//    ⭐ `play_seq.v` 的读侧契约是**标准同步 FIFO** 语义
//       （`evt_valid_i` = "缓冲区有事件" ＋ `evt_data_i` = 队头 ＋ `evt_rd_o` = 取走）
//    🔴 而 `evt_uart_rx.evt_valid_o` 是**单拍脉冲**（⭐ 它不是 FIFO）
//       ⇒ ⭐ 直接对接 ⇒ 🔴 **凡是"tick 还没到"的事件【当拍就被丢掉】** ✅
//    ⇒ ⭐ 中间**必须**有一级缓冲 ⇒ ⭐ 本模块 ✅
//    📌 ⭐ 方案早已拍板：⭐ `整曲缓冲大小定案.md` §2.3
//       —— ⭐ **8 KB（1024 事件）**，⭐ ⛔ 不是最初的 2 KB
//       （⭐ 2 KB = 256 事件只够 **8 拍**；⭐ 8 KB 够**最密曲子的 8 小节**＋33% 余量 ✅）
//
// ⭐ **为什么必须【滚动预灌】而⛔ 不能"全曲预载"**：
//    ⭐ 三个真实曲子的实测：⭐ `09_Conjurer` 11,858 事件 = **92.6 KB**、
//       `夜洋风景` 11,564 事件 = **90.3 KB** ⇒ 🔴 **远超 8 KB**（⭐ 覆盖 8.6%）
//    ⇒ ⭐ **无论 2 KB 还是 8 KB 都必须滚动**（⭐ 差别只是"PC 卡多久才出事"）✅
//    📌 ⭐ 所以本模块的 `low_o`（低水位）是**给将来反向流控用的**——
//       ⚠️ 而"反向通道"按拍板**先不做**（⭐ `上位机与ESP32通路实施计划.md` §3.3）
//       ⇒ ⭐ 本轮它**只做可观测**（⭐ K-106）✅
//
// ⭐ **容量账（⭐ 实测口径）**：⭐ 1024 × 64 bit = **64 kbit**
//    ⇒ ⭐ 4 个 BSRAM（⭐ 每个 18 kbit）⇒ ⭐ 交付档 `T_Bsram 33 → 37`（⭐ 118 个里 ✅ 充裕）
//    📌 ⭐ 已按拍板"与 `looper` 争 BSRAM 的账要一起算"核过 ✅
//
// ⭐ **读侧 = FWFT（first-word-fall-through）**：
//    ⭐ BSRAM 读有 **1 拍延迟** ⇒ ⚠️ 若"取走才发起读" ⇒ 🔴 **每取一条就空一拍**
//    ⇒ ⭐ 本模块**每拍都预取"下一个队头"**（⭐ `rd_addr` 在 `take_ok` 时指 `rd_ptr+1`）
//       ⇒ ⭐ `rd_valid_o` 恒等于"非空"、⭐ `rd_data_o` **无空隙** ✅
//    📌 ⭐ 这对 `play_seq` 重要：⭐ 它**同一个 tick 内的多条事件要连续吐完**
//       （⭐ `play_seq.v` 的"缺陷 1"修法）⇒ ⚠️ 有 1 拍空隙虽然仍能吐完，
//       但会**多引入一次"缓冲区空"的假象** ⇒ ⭐ 干脆做成无空隙 ✅
//
// ⭐⭐ **`pos_reset_i`：⛔ 本模块【不】接**（⭐ 这是**有意的**，⛔ 不是漏了）
//    ⭐ `pos_reset_i`（= `top.v` 的 `met_start`）会重置 `beat_gen`/`play_seq` 的
//       **音乐位置** `cur_tick_r` ⇒ ⭐ 语义是"**从头开始**" ✅
//    ⚠️ 但它**⛔ 不能**重置本缓冲：⭐ 预期工作流是
//       **"先按 S2 起节拍（位置归零）⇒ PC 再灌谱子"** ✅
//       ⇒ ⭐ 若在这里也清空 ⇒ 🔴 **把用户刚灌进去的谱子丢掉** ✅
//    📌 ⭐ 已知局限（⭐ 诚实标注）：⭐ **播放中按 S2** ⇒ ⭐ `cur_tick_r` 归零
//       ⇒ ⚠️ 缓冲里"未来"的事件**全部立刻到期** ⇒ 🔴 **一次性地吐出来** ✅
//       ⇒ ⭐ 正确用法：⭐ **起拍之后不要中途按 S2**（⭐ 要重放就让 PC 重灌 ✅）
//
// ⛔ 纪律：⭐ Verilog-2001（`K-91`）· ⭐ 组合用 `assign`（`L67`）·
//    ⭐ **不对 `integer` 参数做位选**（`K-91`）· ⭐ 声明先于使用（`L66`）·
//    ⭐ 单时钟域 · ⭐ 同步复位低有效
// ─────────────────────────────────────────────────────────────────────────────
`default_nettype none

module evt_buf #(
    //  ⭐ **深度 = 1024 事件**（⭐ 已拍板，⛔ 不要改小 —— ⭐ 见文件头的容量账 ✅）
    parameter integer DEPTH  = 1024,
    parameter integer EVT_W  = 64,
    //  ⭐ **低水位**：⭐ `cnt <= LOW_WM` ⇒ `low_o` 拉高（⭐ 供将来反向流控 + 可观测 ✅）
    //     📌 ⭐ 256 = 8 KB 的 1/4（⭐ 与"提前 8 小节"的拍板口径同量级 ✅）
    parameter integer LOW_WM = 256,
    //  ⭐⭐⭐⭐ 2026-10-11（⭐ ESP32 侧清单 §2.3 的 **L1 要求**）：⭐ **高水位（sticky）** ✅
    //
    //  ⭐ **它要解决什么**（⭐ 清单原文）：⭐ *"它**在真正丢失【之前】**就置位 ⇒
    //     ⭐ 调试时能在"**还没丢**"的时候就发现余量不够，⛔ 而不是等丢了才知道"* ✅
    //  🔴 **为什么 `ovf_o` 不够**：⭐ `ovf_o` 是"**已经丢了**"（⭐ 写满才置位 ✅）
    //     ⇒ ⚠️ 它告诉你"**来不及了**"，⛔ 不告诉你"**快来不及了**" ✅
    //  📌 ⭐ **取值**：⭐ 默认 **`DEPTH - LOW_WM`**（⭐ 交付档 1024 − 256 = **768** ⇒ 75% 满 ✅）
    //     —— ⭐ 与"低水位 1/4"**对称** ⇒ ⭐ 两者之间的 512 事件是**正常余量带** ✅
    //     🔴🔴 **为什么必须【随 DEPTH 派生】而⛔ 不是写死 768**（⭐ 本轮实测踩到）：
    //        ⚠️ `tb/w3c/tb_evt_buf.sv` 的**小实例**是 `DEPTH=8, LOW_WM=2` ✅
    //        ⇒ ⭐ 写死 `768` ⇒ ⚠️ `cnt_next >= 768` **永远不成立**（⭐ `cnt` 最大 8 ✅）
    //        ⇒ 🔴 **`high_water_o` 恒 0** ⇒ ⭐ 判据**结构上不可能红**（⭐ 空洞 ✅）
    //        ＋ ⭐ 对 `DEPTH=8` 的缓冲来说，"高水位 768"**本身就没有意义** ✅
    //     ✅ **派生写法**：⭐ `(DEPTH > LOW_WM) ? (DEPTH - LOW_WM) : 1`
    //        —— ⭐ 保证 **`1 <= HIGH_WM <= DEPTH`**（⭐ 任何参数组合下都成立 ✅）
    parameter integer HIGH_WM = (DEPTH > LOW_WM) ? (DEPTH - LOW_WM) : 1
) (
    input  wire              clk_i,
    input  wire              rst_n_i,

    // ── ⭐ 写侧：⭐ 来自 `evt_uart_rx`（⭐ **单拍脉冲**，⭐ 当拍有效即入队 ✅）────
    input  wire              wr_valid_i,
    input  wire [EVT_W-1:0]  wr_data_i,

    // ── ⭐ 读侧：⭐ **标准同步 FIFO 语义** ⇒ ⭐ 直连 `play_seq` ✅ ────────────
    //     ⭐ `rd_ack_i` 高的**下一个沿**才推进队头（⭐ 与 `play_seq.evt_rd_o` 同语义 ✅）
    output wire              rd_valid_o,     // ⭐ 非空（⭐ = `play_seq.evt_valid_i`）
    output wire [EVT_W-1:0]  rd_data_o,      // ⭐ 队头（⭐ **无空隙** ✅）
    input  wire              rd_ack_i,       // ⭐ 单拍：取走一条

    // ── 🔴 可观测性（⭐ `K-106`：能失败的路径必须留痕）────────────────────
    output wire              ovf_o,          // ⭐ sticky：曾写满（⭐ 丢过事件）
    output wire [15:0]       drop_cnt_o,     // ⭐ 饱和计数：累计丢弃事件数（⭐ ⛔ 不回绕）
    output wire [15:0]       cnt_o,          // ⭐ 当前深度（⭐ 便于上板核对）
    output wire              low_o,          // ⭐ 低水位（⭐ 缓冲区将空）
    //  ⭐⭐ 2026-10-11：⭐ **高水位（sticky）** —— ⭐ "**还没丢，但余量告急**" ✅
    //     📌 语义与 `ovf_o` **并列**：⭐ `ovf_o` = 已经丢了 · ⭐ `high_water_o` = 快满了 ✅
    //     📌 ⭐ 清除口径**与 `ovf_o` 共用 `ovf_clr_i`**（⭐ 读走后一起清 ✅）
    output wire              high_water_o,
    input  wire              ovf_clr_i       // ⭐ 读走后清零（⭐ 电平或脉冲皆可）
);

    // ── ⭐ 常量（⭐ 全部先算好再赋值给定宽 —— `K-91`）──────────────────────
    localparam integer  AW     = (DEPTH <= 1) ? 1 : $clog2(DEPTH);   // ⭐ 1024 ⇒ 10
    localparam [AW:0]   DEPTHV = DEPTH;                              // ⭐ ⛔ 不对 integer 做位选
    localparam [AW-1:0] ONE    = {{(AW-1){1'b0}}, 1'b1};
    localparam [AW:0]   ZERO   = {(AW+1){1'b0}};

    // ── ⭐ 存储与指针（⭐ 声明先于使用 —— `L66`）──────────────────────────
    reg  [EVT_W-1:0] mem [0:DEPTH-1];    // ⭐ **BSRAM**（⭐ 1 写口 + 1 读口 ✅）
    reg  [AW-1:0]    wr_ptr;
    reg  [AW-1:0]    rd_ptr;
    reg  [AW:0]      cnt;
    reg              ovf_r;
//  ⭐⭐ 2026-10-11：⭐ **高水位 sticky 位**（⭐ 与 `ovf_r` 并列，⭐ 共用清除 ✅）
reg              hw_r;
    reg  [15:0]      drop_r;
    reg  [EVT_W-1:0] rd_data_r;

    // ── ⭐ 组合：满 / 空 / 可否收 / 可否取 ─────────────────────────────────
    wire full    = (cnt == DEPTHV);
    wire empty   = (cnt == ZERO);

    //  ⚠️ ⭐ **声明顺序**：⭐ `take_ok` 必须**先于** `push_ok`（⭐ `L66`：声明先于使用 ✅）
    wire take_ok = rd_ack_i   & (~empty);              // ⭐ 本拍真的取走一条
    //  ⭐⭐ `push_ok` 里那个 `| take_ok` 是**必需的**：
    //     ⚠️ 若只写 `~full` ⇒ 🔴 **"满 + 同拍取走"时这一条会被【白丢】** ✅
    //        （⭐ 明明腾出了一个位置，⭐ 却因为"本拍 `cnt` 还是满的"而丢掉 ✅）
    //     📌 ⭐ 加上它之后，"满时同拍取+推" = ⭐ **净 0**、⭐ 且**推的这条真的进去了** ✅
    wire push_ok = wr_valid_i & ((~full) | take_ok);   // ⭐ 本拍真的收下一条

    //  ⭐⭐ FWFT 预取地址：⭐ **取走的同一拍就把地址指向【下一个】队头** ✅
    //     ⇒ ⭐ 下一个沿 `rd_data_r` 就是新队头 ⇒ ⭐ **无空隙** ✅
    wire [AW-1:0] rd_addr = rd_ptr + (take_ok ? ONE : {AW{1'b0}});

    //  ⭐⭐⭐⭐ 2026-10-11 **写穿旁路（write-through bypass）** —— ⭐ 一个**真 bug 的修法**
    //
    //  🔴🔴 **缺陷现场（⭐ 由 `tb/w3c/tb_score_chain.sv` 首次抓出）**：
    //     ⭐ **"空 ⇒ 非空"的那一拍**：⭐ `wr_ptr == rd_ptr`（⭐ 两者都指向 0）
    //        ⇒ ⭐ 同一沿上：⭐ **写** `mem[0] <= wr_data_i` ，
    //           ⭐ 而**预取读**也读 `mem[rd_addr] = mem[0]` ✅
    //        ⇒ 🔴 **读拿到的是【写之前】的值**（⭐ Verilog 非阻塞语义 ✅）
    //        ⇒ 🔴 于是 `rd_data_r` = **未初始化值**（⭐ 仿真里是 `X`）
    //     🔴 **后果（⭐ 两层）**：
    //        ① ⭐ **仿真**：⭐ `X` 顺着 `play_seq.evt_data_i` ⇒ `evt_tick = X`
    //           ⇒ `evt_due = 1 & (X <= cur_tick_r) = X` ⇒ ⭐ `evt_rd_o = X`
    //           ⇒ 🔴 **回灌进本模块的 `take_ok`** ⇒ **`cnt` 整条变 `X`**（⭐ 实测 ✅）
    //        ② ⭐⭐ **硬件（⭐ 更严重）**：⭐ 没有 `X`，⭐ `rd_data_r` 会拿着
    //           **上一次的残留位型** ⇒ ⚠️ 若那个残留 `tick` **恰好 `<= cur_tick_r`**
    //           ⇒ 🔴 **`play_seq` 发一次"伪读"** ⇒ ⭐ **那一条真事件被取走却没被吐出来**
    //           ⇒ 🔴 **静默丢事件**（⭐ `K-106` 头号缺陷族 ✅）
    //     📌 ⭐ 这正是"**新判据抓出真缺陷**"的又一例（⭐ 与 `P0-31` 的时基坑同族）✅
    //
    //  ✅ **修法**：⭐ **同址时直接写穿**（⭐ 把写数据当作读数据 ✅）
    //     · ⭐ 语义上就是 **BSRAM 的 bypass / write-through 模式**的行为 ✅
    //     · ⭐ 于是"空⇒非空"那一拍，⭐ **队头【立刻】就是新写进去的那条** ✅
    //     · ⭐ 而"读走最后一条"那一拍：⭐ `cnt` 归零 ⇒ ⭐ `rd_valid_o = 0`
    //       ⇒ ⭐ 那之后 `rd_data_r` 的垃圾值**被 `rd_valid_o` 掩掉** ✅（⭐ 不需要额外处理 ✅）
    //  📌 **代价**：⭐ 一个 `AW` 位比较器 ＋ 一个 `EVT_W` 位 2:1 mux
    //     （⭐ 综合实测：⭐ 含在 `+40 LUT` 里，⭐ 可忽略 ✅）
    wire rd_wr_same = push_ok & (wr_ptr == rd_addr);

    //  ⭐ 读侧输出：⭐ 队头**始终**摆在这里，⭐ 由 `rd_valid_o` 说明它有没有意义 ✅
    assign rd_valid_o = ~empty;
    assign rd_data_o  = rd_data_r;

    //  ⭐ `cnt` 的**唯一**组合表达式（⭐ 学 `uart_tx_fifo.v` 的教训 ✅）
    //     🔴 **原来的坑**：⭐ "取走"写 `cnt <= cnt-1`、"推入"写 `cnt <= cnt+1`
    //        ⇒ ⚠️ **同一拍两条非阻塞赋值 ⇒ 只有后面那条生效** ⇒ 🔴 计数虚高/虚低 ✅
    //     ✅ 修法：⭐ 先算 `cnt_next`，⭐ `always` 里**只写一次** ✅
    wire [AW:0] cnt_next = (push_ok & (~take_ok)) ? (cnt + {{AW{1'b0}}, 1'b1})
                         : (take_ok & (~push_ok)) ? (cnt - {{AW{1'b0}}, 1'b1})
                         :                          cnt;

    assign ovf_o      = ovf_r;
//  ⭐⭐ 2026-10-11：⭐ **高水位输出**（⭐ sticky ✅）
assign high_water_o = hw_r;
    assign drop_cnt_o = drop_r;
    assign cnt_o      = cnt;        // ⭐ 11 位赋给 16 位输出 ⇒ ⭐ 自动零扩展 ✅
    assign low_o      = (cnt <= LOW_WM);

    // ── ⭐ 时序 ────────────────────────────────────────────────────────────
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            wr_ptr    <= {AW{1'b0}};
            rd_ptr    <= {AW{1'b0}};
            cnt       <= ZERO;
            ovf_r     <= 1'b0;
            hw_r      <= 1'b0;      // ⭐ 2026-10-11：⭐ 高水位随复位清 ✅
            drop_r    <= 16'd0;
            rd_data_r <= {EVT_W{1'b0}};
        end else begin
            // ── ① ⭐ 写侧：⭐ 满则**丢弃并留痕**（⭐ ⛔ 绝不静默 —— `K-106`）──────
            if (wr_valid_i) begin
                if (push_ok) begin
                    mem[wr_ptr] <= wr_data_i;
                    wr_ptr      <= wr_ptr + ONE;
                end else begin
                    ovf_r <= 1'b1;
                    if (drop_r != 16'hFFFF) drop_r <= drop_r + 16'd1;
                end
            end

            // ── ② ⭐ 读侧：⭐ 推进队头 ────────────────────────────────────────
            if (take_ok)
                rd_ptr <= rd_ptr + ONE;

            // ── ③ ⭐ FWFT 预取（⭐ 每拍都读 —— ⭐ 这就是"无空隙"的全部实现 ✅）──
            //     ⭐⭐ **同址写穿**（⭐ 见 `rd_wr_same` 的长注释 —— ⭐ 那是真 bug 的修法 ✅）
            rd_data_r <= rd_wr_same ? wr_data_i : mem[rd_addr];

            // ── ④ ⭐ 计数（⭐ 唯一一次赋值 ✅）────────────────────────────────
            cnt <= cnt_next;

            // ── ④b ⭐⭐ 2026-10-11：⭐ **高水位 sticky**（⭐ ESP32 侧清单 §2.3 的 L1 ✅）──
            //     ⭐ 判据用 **`cnt_next`（⭐ 下一拍的水位）**，⛔ 不是 `cnt` ——
            //        ⚠️ 这样"**写进去的那一拍就置位**"，⭐ 与 `ovf_r` 的时序口径**一致** ✅
            //     📌 ⭐ 只在**升高**时置位 ⇒ ⭐ 一旦置位就**保持**（⭐ sticky ✅），
            //        ⭐ 直到 `ovf_clr_i`（⭐ 与 `ovf_o` 共用 ✅）
            if (cnt_next >= HIGH_WM) hw_r <= 1'b1;

            // ── ⑤ ⭐ 读走清零（⭐ 优先级最高 ⇒ ⚠️ 同拍"清 + 又丢"时【以丢为准】✅）──
            //     📌 语义：⭐ 清掉的只是"已读走的那个标记"，
            //        ⭐ 同拍新丢的会**重新置位** ⇒ ⚠️ **不丢信息** ✅
            if (ovf_clr_i) begin
                ovf_r  <= wr_valid_i && !push_ok;
                drop_r <= (wr_valid_i && !push_ok) ? 16'd1 : 16'd0;
                //  ⭐⭐ 2026-10-11：⭐ **高水位与 `ovf` 一起清**（⭐ 共用 `ovf_clr_i` ✅）
                hw_r   <= wr_valid_i && (cnt_next >= HIGH_WM);
            end
        end
    end

    // ── ⭐ 参数自检（⭐ `K-106`：⛔ 不许静默失效）──────────────────────────
    //    ⭐ 判据：⭐ 深度必须是 **2 的幂**（⭐ 这样"满"可以只用一个比较器，
    //       且 ⭐ `wr_ptr`/`rd_ptr` 的回绕与 `cnt` **天然自洽** ✅）
    //    ⚠️ 若不是 ⇒ ⭐ **必须报错**，⛔ 不是"悄悄按 2 的幂跑" ✅
    initial begin
        if ((DEPTH & (DEPTH - 1)) != 0)
            $display("ERROR [evt_buf] DEPTH=%0d must be a power of two", DEPTH);
        if (DEPTH < 2)
            $display("ERROR [evt_buf] DEPTH=%0d too small", DEPTH);
    end

    //  ⭐⭐⭐⭐ 2026-10-11（`P1-53`）：⭐ **【综合期】硬失败守卫** ✅
    //     🔴 **为什么 `initial` 里那两条不够**（⭐ 实测证据）：
    //        ⭐ Gowin 综合**明确忽略 `$display` / `$fatal`**
    //        （⭐ 它自己的警告：`EX3858` / `EX2488` … `is ignored for synthesis` ✅）
    //        ⇒ ⭐ 而且 **`gw_sh` 退出码仍是 `0`** ⇒ 🔴 **位流照样生成** ✅
    //     ✅ **修法**：⭐ 例化一个**故意不存在**的模块 ⇒ ⭐ 综合与仿真**都**报
    //        `Unknown module type: <名字>` ⇒ 🔴 **构建失败**，⭐ 而**信息在名字里** ✅
    //     📌 ⭐ 参数合法时该分支**不参与详细阐述** ⇒ ⭐ **零逻辑 / 零 FF** ✅
    //     📌 ⭐ **本模块在 `generate` 区【外】**（⭐ 模块级实例）⇒ ⭐ 这里**需要**
    //        `generate`/`endgenerate` 包住（⭐ 与 `top.v` 的 `g_sound` 内**不同** ✅）
    //  ⭐⭐⭐⭐ 2026-10-11（`P1-53`）：⭐ **参数守卫**（⭐ 由构建脚本提升为硬失败 ✅）
    //     🔴 **实测结论（⭐ 三种写法都试过，⛔ 不是猜的）**：⭐ **Gowin 综合【不会】硬失败** ——
    //        | 写法 | 工具反应 | 退出码 |
    //        |---|---|---|
    //        | ⭐ `$fatal` / `$display` | ⭐ `EX2488` / `EX3858` … **is ignored for synthesis** | ⭐ **0** |
    //        | ⭐ 例化**未声明模块** | ⭐ `EX3793` **Instantiating unknown empty module** | ⭐ **0** |
    //        | ⭐ **负重复次数** `{(1-2){1'b0}}` | ⭐ `EX2195` **must be positive** | ⭐ **0** |
    //        ⇒ 🔴 **RTL 层面的"综合期断言"在本工具链上【做不到】** ✅
    //     ✅ **所以本守卫的判据不是"综合退出码"，⭐ 而是"综合日志里出现了 `EX3793`"** ——
    //        ⭐ `sim/gowin_build.ps1` 里有一道门：⭐ **见到 `EX3793` 就 `exit 1`** ✅
    //        ⇒ ⭐ 于是 **RTL 仍是唯一真相源**（⭐ 条件就写在这里），
    //          ⭐ 而"硬失败"由构建脚本提供 ✅
    //     📌 ⭐ 参数合法时该分支**不参与详细阐述** ⇒ ⭐ **零逻辑 / 零 FF**（⭐ 实测资源一字不变 ✅）
    generate
        if (((DEPTH & (DEPTH - 1)) != 0) || (DEPTH < 2)) begin : g_param_bad
            P1_53_EVT_BUF_PARAM_ERROR__DEPTH_must_be_a_power_of_two_and_ge_2 u_param_guard();
        end
    endgenerate

endmodule

`default_nettype wire
