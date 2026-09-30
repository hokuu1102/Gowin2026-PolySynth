/*
 * up_ring.c -- ⭐ 上行（FPGA → ESP32 → BLE）环形缓冲的实现
 * ============================================================================
 * 设计文档：files/20-代码/上行通路缓冲设计-20260930.md
 * 接口说明：见 up_ring.h 顶部
 *
 * ⭐⭐ 三个关键设计决定（⭐ 都在设计文档里论证过）
 * ---------------------------------------------------------------------------
 * ① **丢最旧（drop-oldest）**，⛔ 不是丢最新
 *    ⚠️ 与下行池的「宁可饿着，不可撑着」**方向相反** ——
 *    ⭐ 理由：上行回传的是**实时演奏/演奏状态**，⭐ **最新性 > 完整性**。
 *    🔴 代价（⭐ 必须说清）：丢弃会在字节流**中间挖洞** ⇒ 后续解析可能错位。
 *    ⭐ 缓解手段就是**记账**（`drop` / `drop_ev`），⛔ 不是假装没丢。
 *
 * ② **单任务**（⭐ 生产者与消费者都在 `task_uart_to_ble` 里）
 *    🔴 硬约束：`uart_read_bytes` 【同一个 UART 只能有一个读者】
 *    （⭐ 两个任务读会互相偷字节）⇒ ⭐ 这里**只提供 API**，
 *      ⛔ **绝不自己起任务、绝不自己读 UART**。
 *
 * ③ **临界区保护**（⭐ 而不是信号量）
 *    ⚠️ 临界区里只做 `memcpy`（⭐ 无阻塞、无分配）⇒ 用 `portMUX` 最省。
 *    ⚠️ 环形指针的读写必须原子 —— ⭐ 否则生产者/消费者交错会算错边界。
 * ============================================================================
 */

#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "esp_log.h"
#include "esp_heap_caps.h"

#include "up_ring.h"

static const char *TAG = "upring";

/* ---- 内部状态 ---------------------------------------------------------- */
static uint8_t       *s_buf      = NULL;
static size_t         s_cap      = 0;      /* 实际容量（字节） */
static bool           s_in_psram = false;

static volatile size_t s_head    = 0;      /* ⭐ 写指针（生产者） */
static volatile size_t s_tail    = 0;      /* ⭐ 读指针（消费者） */
static volatile size_t s_level   = 0;      /* ⭐ 当前字节数（即时） */

static volatile uint32_t s_in      = 0;    /* 累计入环 */
static volatile uint32_t s_out     = 0;    /* 累计出环（已交付 notify） */
static volatile uint32_t s_drop    = 0;    /* 🔴 丢弃字节数（⭐ 满时拒绝新数据） */
static volatile uint32_t s_drop_ev = 0;    /* 🔴 丢弃次数 */
static volatile uint32_t s_full_hits = 0;  /* ⭐ "满"发生过几次（⭐ 与 drop 分开看） */
static volatile uint32_t s_hwm     = 0;    /* ⭐ 高水位 */

static portMUX_TYPE s_mux = portMUX_INITIALIZER_UNLOCKED;

/* ===========================================================================
 * 分配（⭐ 策略照搬 pool.c 的 pool_alloc()：PSRAM → DRAM → 不 abort）
 * ===========================================================================
 * ⚠️ 与 pool.c:171-193 的区别：
 *    · ⛔ 不按帧对齐（⭐ 上行是**不透明字节流**，⛔ 没有 9 字节帧的概念）
 *    · ⭐ 降级时同样留 8 KB 余量（⛔ 不能把内部 DRAM 吃干，否则蓝牙栈 OOM）
 */
static size_t up_ring_alloc(void)
{
    const size_t want = UP_RING_BYTES;

    /* ---- ① 优先 PSRAM ---- */
    if (heap_caps_get_total_size(MALLOC_CAP_SPIRAM) > 0) {
        s_buf = (uint8_t *)heap_caps_malloc(want, MALLOC_CAP_SPIRAM);
        if (s_buf != NULL) {
            s_in_psram = true;
            ESP_LOGW(TAG, "up_ring: %u B in PSRAM", (unsigned)want);
            return want;
        }
        ESP_LOGW(TAG, "up_ring: PSRAM present but %u B alloc failed -> internal",
                 (unsigned)want);
    } else {
        ESP_LOGI(TAG, "up_ring: no PSRAM -> internal DRAM");
    }

    /* ---- ② 退化到内部 DRAM ---- */
    size_t avail = heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    const size_t reserve = 8 * 1024;            /* ⚠️ 留余地给蓝牙栈 */
    size_t usable = (avail > reserve) ? (avail - reserve) : 0;
    size_t take = (usable < want) ? usable : want;
    /* ⚠️ 至少 1 KB 才有意义；太小不如不做（⭐ 但也不 abort） */
    if (take >= 1024) {
        s_buf = (uint8_t *)heap_caps_malloc(take, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
        if (s_buf != NULL) {
            ESP_LOGW(TAG, "up_ring: DEGRADED to internal DRAM: %u B (want %u)",
                     (unsigned)take, (unsigned)want);
            return take;
        }
    }

    /* ---- ③ 全失败：⛔ 不 abort —— 上行退化为原来的"直通"行为 ---- */
    ESP_LOGE(TAG, "up_ring: ALLOC FAILED (want=%u, largest internal=%u). "
                  "Upstream falls back to the old (lossy) passthrough.",
             (unsigned)want, (unsigned)avail);
    return 0;
}

/* ===========================================================================
 * 对外接口
 * =========================================================================== */
size_t up_ring_init(void)
{
    if (s_buf == NULL) {
        s_cap = up_ring_alloc();
        if (s_cap == 0) {
            return 0;
        }
    }
    up_ring_reset();
    return s_cap;
}

void up_ring_reset(void)
{
    portENTER_CRITICAL(&s_mux);
    s_head  = 0;
    s_tail  = 0;
    s_level = 0;
    s_hwm   = 0;
    /* ⚠️ 累计账（in/out/drop）【不清】—— ⭐ 那是"上电以来"的口径，
     *    清掉会让"到底丢过没有"这个判据失效。 */
    portEXIT_CRITICAL(&s_mux);

    ESP_LOGW(TAG, "up_ring reset (cap=%u B, %s)", (unsigned)s_cap,
             s_in_psram ? "PSRAM" : "DRAM");
}

size_t up_ring_push(const uint8_t *src, size_t n)
{
    if (s_buf == NULL || s_cap == 0 || src == NULL || n == 0) {
        return 0;
    }

    size_t dropped = 0;
    size_t wrote   = 0;

    portENTER_CRITICAL(&s_mux);

    /*
     * ⭐⭐ 满策略：**拒绝新的（drop-newest）**，⛔ 不是丢最旧
     * -----------------------------------------------------------------------
     * 🔴🔴 2026-09-30 **策略更正**（⭐ 用户拍板）：本环的定位是
     *     「**蓄水 / 放水**」—— 与下行的曲谱池**完全对称**：
     *        未连接  ⇒ ⭐ **蓄水**（只入不出）
     *        已连接  ⇒ ⭐ **放水**（边入边出）
     *     蓄水满了 ⇒ ⭐ **不管后面的，只发前面的**（⭐ 保住【最早】的一段）
     *
     * ⚠️ **这与本文件初版相反**（初版写的是"丢最旧"，⭐ 依据是"实时流的新鲜度更重要"，
     *    🔴 **那个前提是错的** —— 本通路**不是实时监视**，⭐ 而是**回传存档**：
     *    "发了的就存进来，需要时再传回 PC"）⇒ ⭐ 因此**完整性 > 新鲜度**。
     *
     * 🔴 **为什么"丢最旧"对存档是错的**：它会在流**中间挖洞**
     *    ⇒ ⚠️ 录下来的东西缺一段，⭐ 比"截尾"更难处理（⭐ 位置还对不上）。
     *    ⭐ 而"拒绝新的"只**截尾**，⭐ 已录的部分**始终完整且连续**。
     *
     * ⭐ 代价（⭐ 说清）：满了之后**新数据会丢**，⚠️ 由 `u_drop`/`u_drop_ev` 记账，
     *    🔴 **⛔ 不是静默丢**。⭐ 且 `u_full` 会置位 ⇒ ⚠️ PC 侧能看出"录满了"。
     */
    if (s_level + n > s_cap) {
        /* ⚠️ 装不下 ⇒ 只写能写下的部分（⭐ 保住前面已有的），其余计入丢弃。
         * ⭐ 注意：这里【不动 s_tail】—— ⭐ 已录的数据一个字节都不丢。 */
        size_t room = (s_cap > s_level) ? (s_cap - s_level) : 0;
        /* ⚠️ 只按【整块能放下的部分】写；⭐ 余下全部拒绝。
         * 📌 不做"部分写入"的下限判断 —— 能写多少写多少，
         *    因为这里是不透明字节流，⭐ 没有"帧边界"必须对齐的要求。 */
        dropped = n - room;
        n       = room;
        if (dropped > 0) {
            s_full_hits++;          /* ⭐ 记录"满过几次"（⭐ 与 drop 分开计数） */
        }
    }

    if (n > 0) {
        /* ---- 写入（⭐ 可能回绕，分两段） ---- */
        size_t first = s_cap - s_head;
        if (first > n) {
            first = n;
        }
        memcpy(s_buf + s_head, src, first);
        if (n > first) {
            memcpy(s_buf, src + first, n - first);
        }
        s_head  = (s_head + n) % s_cap;
        s_level += n;
        wrote    = n;
    }

    s_in += (uint32_t)n;
    if (dropped > 0) {
        s_drop    += (uint32_t)dropped;
        s_drop_ev += 1;
    }
    if (s_level > s_hwm) {
        s_hwm = (uint32_t)s_level;      /* ⭐ 高水位（⭐ 越接近 cap 越危险） */
    }

    portEXIT_CRITICAL(&s_mux);
    return wrote;
}

size_t up_ring_pop(uint8_t *dst, size_t cap)
{
    if (s_buf == NULL || s_cap == 0 || dst == NULL || cap == 0) {
        return 0;
    }

    size_t got = 0;

    portENTER_CRITICAL(&s_mux);

    size_t n = (s_level < cap) ? s_level : cap;
    if (n > 0) {
        size_t first = s_cap - s_tail;
        if (first > n) {
            first = n;
        }
        memcpy(dst, s_buf + s_tail, first);
        if (n > first) {
            memcpy(dst + first, s_buf, n - first);
        }
        s_tail  = (s_tail + n) % s_cap;
        s_level -= n;
        s_out   += (uint32_t)n;
        got = n;
    }

    portEXIT_CRITICAL(&s_mux);
    return got;
}

void up_ring_stats(up_ring_stats_t *out)
{
    if (out == NULL) {
        return;
    }
    portENTER_CRITICAL(&s_mux);
    out->in       = s_in;
    out->out      = s_out;
    out->drop     = s_drop;
    out->drop_ev  = s_drop_ev;
    out->full_hits = s_full_hits;
    out->hwm      = s_hwm;
    out->level    = (uint32_t)s_level;
    out->cap      = s_cap;
    out->in_psram = s_in_psram;
    portEXIT_CRITICAL(&s_mux);
}

size_t up_ring_capacity(void)
{
    return s_cap;
}

uint32_t up_ring_level(void)
{
    uint32_t v;
    portENTER_CRITICAL(&s_mux);
    v = (uint32_t)s_level;
    portEXIT_CRITICAL(&s_mux);
    return v;
}
