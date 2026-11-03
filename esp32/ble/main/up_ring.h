/*
 * up_ring.h -- ⭐ 上行（FPGA → ESP32 → BLE）环形缓冲
 * ============================================================================
 * 项目：FPGA2026 纯硬件实时音频合成 · ESP32 通路
 * 设计：files/20-代码/上行通路缓冲设计-20260930.md
 *
 * 【它解决什么】
 *   🔴 反向通路原来【没有缓冲】：`task_uart_to_ble` 读出 UART 就立刻 notify。
 *   实测（2026-09-30）：PC 往 `GPIO18` 灌 2000 字节 ⇒ 固件【只收到 1611】，
 *   🔴 **丢 389 字节且没有任何报错**。
 *   ⭐ 根因是 UART 驱动 RX 环形缓冲只有 1026 B（ble_config.h:117），
 *      而搬运每段要等 ≥1 tick（10 ms）⇒ 搬得没比进得快 ⇒ 溢出。
 *
 * 【它【不】解决什么】
 *   ⚠️ 缓冲只吸收【突发】。⭐ 若 FPGA 持续以线速（50 KB/s）超发，
 *      ⭐ 环迟早会满 ⇒ **仍会丢**（⭐ 但至少【有账可查】）。
 *   🔴 **根治要靠 FPGA 侧按节拍发** —— 本模块与它【互补，⛔ 不可替代】。
 *
 * 【与 pool.c 的关系】
 *   ⚠️ **完全独立的两套状态**，⛔ 不共用：
 *       pool  = 下行曲谱，帧对齐，按 tick 放水，"宁可饿着"
 *       up_ring = 上行回传，不透明字节流，满了丢最旧，"最新性优先"
 *   ⭐ 只有【分配策略】照搬 `pool_alloc()`（PSRAM 优先 + DRAM 降级 + 不 abort）。
 * ============================================================================
 */
#ifndef UP_RING_H
#define UP_RING_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * ⭐ 上行环容量（字节）。可用 -DUP_RING_BYTES=... 覆盖。
 *
 * ⭐⭐ **本环的定位：与下行的曲谱池【完全对称】的"蓄水 / 放水"**
 * ---------------------------------------------------------------------------
 *   ⭐ **未连接 ⇒ 蓄水**（只入不出）      ⭐ **已连接 ⇒ 放水**（边入边出）
 *   ⭐ **蓄水满了 ⇒ 拒绝新的**（保住【最早】的一段，⛔ 不在中间挖洞）
 *
 * ⚠️ **它不是"实时监视"通道** —— ⭐ 用户明确："发了的就存进来，
 *    需要传回 PC 的时候传回 PC" ⇒ ⭐ **完整性 > 新鲜度**。
 *
 * ⭐ 取值依据（⚠️ 算出来的，⛔ 不是拍的）：
 *   · 线速突发：500 kbps 8N1 ⇒ 50,000 B/s
 *   · 音乐节拍：~626 B/s（与下行同量级）
 *   · ⭐ **取 160 KB** —— ⭐ **与下行池（`BLE_POOL_BYTES`）对齐**，
 *     便于"两边余量可比"；⚠️ 也是用户拍板的"先扩，等实测再定"。
 *
 * ⚠️ 容量选择的**已知局限（⭐ 必须记账，⛔ 不假装够用）**：
 *   · 按 50 KB/s ⇒ **3.3 s** 就满
 *   · 按 626 B/s ⇒ **262 s** 才满
 *   ⇒ 🔴 **若 FPGA 持续高速回传，任何容量都会满** ⇒
 *     ⭐ **故本环必须把"拒绝了多少"记成账**（`drop`/`drop_ev`/`full_hits`）。
 *   ⭐ 最终容量应**按实测的回传速率**再定（⭐ 见 files/20-代码/上行通路缓冲设计-20260930.md）。
 */
#ifndef UP_RING_BYTES
#define UP_RING_BYTES   (160 * 1024)
#endif

/* 状态快照（⭐ 供日志打印，⛔ 不暴露内部指针） */
typedef struct {
    uint32_t in;        /* ⭐ 入环字节总数（单调增） */
    uint32_t out;       /* ⭐ 成功出环（已交给 notify）的字节总数（单调增） */
    uint32_t drop;      /* 🔴 因环满而被【拒绝】的字节数 —— 正常应恒为 0 */
    uint32_t drop_ev;   /* 🔴 因环满而被拒绝的【次数】 */
    uint32_t full_hits; /* ⭐ "装不下"发生过几次（⭐ 与 drop 分开，便于判读） */
    uint32_t hwm;       /* ⭐ 高水位：上电以来环内最深占用（字节） */
    uint32_t level;     /* ⭐ 当前环内字节数（即时值） */
    size_t   cap;       /* ⭐ 环的实际容量（降级后会更小；0 = 分配失败） */
    bool     in_psram;  /* ⭐ 环是否落在 PSRAM */
} up_ring_stats_t;

/* 分配 + 复位。⭐ 幂等：重复调用只复位，不重新分配。返回实际容量（0 = 失败）。 */
size_t up_ring_init(void);

/* 复位（清空 + 清零 hwm/level，⛔ 不清 in/out/drop —— 那是累计账）。 */
void   up_ring_reset(void);

/*
 * ⭐ 入环。返回实际写入的字节数（< n 表示环满，差额被计入 drop）。
 * ⚠️ 会被 task 上下文调用；内部用临界区保护（⛔ 不在 ISR 用）。
 */
size_t up_ring_push(const uint8_t *src, size_t n);

/*
 * ⭐ 出环（读走即消费）。返回实际取出的字节数（0 = 环空）。
 * ⚠️ 调用方取走多少，就算"已转发"多少 —— ⭐ 由调用方负责真的发出去。
 */
size_t up_ring_pop(uint8_t *dst, size_t cap);

/* Single consumer: inspect without consuming, then commit accepted bytes.
 * The UART producer/notify consumer are the same task. Reset ends a session. */
size_t up_ring_peek(uint8_t *dst, size_t cap);
size_t up_ring_discard(size_t n);

/* 取状态快照。 */
void   up_ring_stats(up_ring_stats_t *out);

/* ⭐ 当前环内字节数（即时值，⛔ 非累计）—— 供消费者决定"这轮能取多少"。 */
uint32_t up_ring_level(void);

/* 容量查询（0 = 未初始化/失败）。 */
size_t up_ring_capacity(void);

#ifdef __cplusplus
}
#endif

#endif /* UP_RING_H */
