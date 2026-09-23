/*
 * pool.c -- 模式 B：二级水池（缓存整曲 + 自己按谱子时间限速放水）
 * ============================================================================
 * 项目：FPGA2026 纯硬件实时音频合成 · ESP32 通路
 * 文档：files/20-代码/ESP32通路总体架构-20260922.md  §2.2 / §四
 *
 * 【和模式 A 的区别】
 *   模式 A：PC 限速 -> ESP32 原样转发（ESP32 完全不懂事件格式）
 *   模式 B：PC 一次性灌整曲 -> ESP32 缓存 -> ESP32 自己算发送时刻
 *
 * 【模式 B 换来什么】⭐ 蓝牙断了 / 卡很久，音乐还能继续播
 * 【模式 B 付什么】  🔴 必须读 tick/kind + 有溢出风险（FPGA 无反向通道 => 盲发）
 *
 * ============================================================================
 * 🔴 溢出：为什么这是模式 B 的头号风险
 * ============================================================================
 *   FPGA 侧事件缓冲 = 8 KB = 1024 事件（U-19，⭐ 待拍板）
 *   1 Mbps 线速 = 11,111 事件/s   =>  全速灌，92 ms 就满
 *   而 FPGA 消费只有 ~69.5 事件/s（最密曲 @168 BPM）
 *
 *   => 一旦本模块"放水"节奏算快了一点点，缓冲就积压 => 溢出 => 丢事件。
 *   => 而 §4.4 已拍板【不做反向通道】=> FPGA 满了我们【不知道】。
 *
 *   所以本文件的策略是【宁可饿着，不可撑着】：
 *     · 提前量取保守值（BRIDGE_POOL_LEAD_TICKS 远小于 FPGA 缓冲容量）
 *     · 🔴 一旦发现"发送落后于谱子时间"，只追到当前时刻，⛔ 不补发爆发
 *     · ⭐ 发送偏慢只会 evt_underrun（FPGA 侧可见）；发送偏快会静默丢失
 * ============================================================================
 */

#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"

#include "driver/uart.h"

#include "bridge_config.h"
#include "pool.h"

static const char *TAG = "pool";

/* ===========================================================================
 * 事件位域 —— ⚠️ 必须与下面两处【逐位一致】，⛔ 改一处就要改三处
 *   · tools/evt2uart.py  : tick_of() / is_tempo()
 *   · files/20-代码/play_seq接口冻结契约.md §1.1
 * ===========================================================================
 *   bit 63..44   tick      (20 bit)   音乐时间，PPQN = 960
 *   bit 43..23   inc       (21 bit)   phase_inc；⭐ kind==2 时改存 tick_inc
 *   bit 22..19   axis      (4 bit)
 *   bit 18..11   vel       (8 bit)
 *   bit 10..9    kind      (2 bit)    0=note_on, 1=note_off, 2=换速
 *   bit  8..7    timbre    (2 bit)
 *   bit  6..0              (7 bit)    保留，必须 0
 */
#define TICK_SHIFT      44
#define TICK_MASK       0xFFFFFu          /* 20 bit */

#define INC_SHIFT       23
#define INC_MASK        0x1FFFFFu         /* 21 bit */

#define KIND_SHIFT      9
#define KIND_MASK       0x3u

#define KIND_NOTE_ON    0u
#define KIND_NOTE_OFF   1u
#define KIND_TEMPO      2u

#define PPQN            960u

static inline uint32_t ev_tick(uint64_t w) { return (uint32_t)((w >> TICK_SHIFT) & TICK_MASK); }
static inline uint32_t ev_inc (uint64_t w) { return (uint32_t)((w >> INC_SHIFT)  & INC_MASK);  }
static inline uint32_t ev_kind(uint64_t w) { return (uint32_t)((w >> KIND_SHIFT) & KIND_MASK); }

/* ===========================================================================
 * 水池本体 —— ⭐ 动态分配（⛔ 不是静态数组）
 * ===========================================================================
 * 🔴🔴 为什么必须动态分配（⭐ 由首次 `idf.py build` 实测抓到的真问题）：
 *
 *   第一版是 `static uint8_t s_pool[128*1024];` ⇒ 进 `.dram0.bss`。
 *   ⚠️ 实测链接失败：
 *        region `dram0_0_seg' overflowed by 51448 bytes
 *        section `.dram0.bss' will not fit
 *
 *   实测数字（ESP32 经典版，BR/EDR-only，模式 A 基线）：
 *        DRAM 可用总量   = 124,580 B
 *        模式 A 已用     =  44,900 B
 *        剩余            =  79,680 B   (77.8 KB)
 *        整曲水池需求    = 106,785 B   (104.3 KB, 09_Conjurer 11,865 事件 × 9 B)
 *        => 🔴 缺口 27,105 B ⇒ 内部 DRAM 【装不下整曲】
 *
 *   ⇒ ⭐ 两条路一起走：
 *      ① 动态分配（⛔ 不占 .bss）—— 这样即使容量取大也不会链接失败
 *      ② ⭐ **优先 PSRAM** —— 模组带 PSRAM 时能放整曲（如 WROOM-32E-N8R2 / WROVER）
 *         没有 PSRAM 时【优雅降级】到内部 DRAM 能给的最大块
 *
 *   ⚠️ 关键：**降级不是失败**。内部 DRAM 能放 ~64 KB ⇒ 断链容忍约 60 秒；
 *      有 PSRAM ⇒ 整曲（~300 秒）。⭐ 两种都能跑，只是"断链能撑多久"不同。
 *      🔴 而旧写法（静态数组）是**直接链接失败** ⇒ ⛔ 比降级糟糕得多。
 */
static uint8_t  *s_pool = NULL;           /* ⭐ 动态分配（优先 PSRAM） */
static size_t    s_pool_cap_bytes = 0;    /* 实际拿到的字节数 */
static size_t    s_pool_cap_frames = 0;   /* 实际能放的帧数 */

static size_t    s_frames = 0;            /* 池内已收帧数 */
static bool      s_pool_done = false;     /* 发送端是否已宣布"灌完" */

/* 播放游标（帧号） */
static size_t    s_play_idx = 0;

/* 节拍：当前每 tick 的相位增量（由 kind=2 事件改写） */
static uint32_t  s_tick_inc = BRIDGE_POOL_DEFAULT_TICK_INC;

/* 物理时钟基准：开始放水时的 (谱面 tick, 单调微秒) */
static uint32_t  s_t0_tick = 0;
static int64_t   s_t0_us   = 0;
static bool      s_running = false;

static SemaphoreHandle_t s_lock = NULL;

/* 可观测计数（K-106：会出错的容量必须看得见） */
static volatile uint32_t s_pool_overflow_frames = 0;   /* 池满丢掉的帧数 */
static volatile uint32_t s_sent_frames          = 0;   /* 已写 UART 的帧数 */
static volatile uint32_t s_late_ticks_max       = 0;   /* 最大落后（tick） */
static volatile uint32_t s_tempo_events         = 0;   /* 已应用的换速次数 */
static bool              s_pool_in_psram        = false; /* ⭐ 池是否落在 PSRAM */

/* ===========================================================================
 * ⭐ 水池内存分配：优先 PSRAM，退化到内部 DRAM
 * ===========================================================================
 * 返回实际拿到的字节数（0 = 全失败）。⛔ 不 abort —— 让它降级而不是崩。
 *
 * ⚠️ 为什么要 PSRAM 优先：
 *    内部 DRAM 剩 ~77.8 KB，装不下整曲 104.3 KB；
 *    PSRAM 一般有 2~8 MB ⇒ 绰绰有余。
 *
 * ⚠️ PSRAM 的注意点：
 *    ① ⚠️ 它比内部 SRAM 慢，且【不能用于 DMA 描述符/中断上下文】——
 *       本池只被 task 读写（⛔ 不在 ISR 里碰），✅ 安全。
 *    ② ⚠️ 模组带 PSRAM 时 GPIO16/17 可能被占用 —— 见 bridge_config.h 的引脚说明。
 *    ③ ⚠️ 需要 `CONFIG_SPIRAM=y`（见 sdkconfig.defaults 的说明）；
 *       未开时 `heap_caps_malloc(MALLOC_CAP_SPIRAM)` 会直接失败 ⇒ 自动降级。
 */
static size_t pool_alloc(void)
{
    const size_t want = BRIDGE_POOL_BYTES;

    /* ---- ① 优先 PSRAM ---- */
    if (heap_caps_get_total_size(MALLOC_CAP_SPIRAM) > 0) {
        s_pool = (uint8_t *)heap_caps_malloc(want, MALLOC_CAP_SPIRAM);
        if (s_pool != NULL) {
            s_pool_in_psram = true;
            ESP_LOGW(TAG, "pool: %u B in PSRAM (whole-score capable)", (unsigned)want);
            return want;
        }
        ESP_LOGW(TAG, "pool: PSRAM present but %u B alloc failed -> trying internal",
                 (unsigned)want);
    } else {
        ESP_LOGI(TAG, "pool: no PSRAM on this module -> using internal DRAM");
    }

    /* ---- ② 退化到内部 DRAM：拿"当前能拿到的最大块" ---- */
    size_t avail = heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    /* ⚠️ 留 8 KB 余量：⛔ 不能把 DRAM 吃干，否则蓝牙栈运行时会 OOM */
    const size_t reserve = 8 * 1024;
    size_t usable = (avail > reserve) ? (avail - reserve) : 0;
    size_t take = (usable < want) ? usable : want;
    take = (take / FRAME_BYTES) * FRAME_BYTES;      /* ⭐ 对齐到整帧 */

    if (take >= FRAME_BYTES) {
        s_pool = (uint8_t *)heap_caps_malloc(take, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
        if (s_pool != NULL) {
            float secs = (float)take / 9.0f / 69.5f;    /* 按最密曲 69.5 事件/s 折算 */
            ESP_LOGW(TAG, "pool: DEGRADED to internal DRAM: %u B (%u frames, ~%.0f s of music)",
                     (unsigned)take, (unsigned)(take / FRAME_BYTES), secs);
            ESP_LOGW(TAG, "      whole-score (%u B) does NOT fit -> link/disconnect "
                          "tolerance is limited to the above", (unsigned)want);
            return take;
        }
    }

    /* ---- ③ 全失败：⛔ 不 abort，让模式 A 仍可用 ---- */
    ESP_LOGE(TAG, "pool: ALLOC FAILED (want=%u, largest internal block=%u). "
                  "Mode B is unavailable; mode A still works.", (unsigned)want,
             (unsigned)avail);
    return 0;
}

/*
 * 释放池内存（⭐ 目前只在"全部失败"的清理路径与将来换曲时用）。
 * ⚠️ 加 __attribute__((unused)) 而不是删掉 —— 保留给"切换曲目/重新分配"的场景，
 *    删了将来要用时容易漏。
 */
__attribute__((unused))
static void pool_free(void)
{
    if (s_pool != NULL) {
        free(s_pool);                 /* ⭐ PSRAM/内部都能用 free() */
        s_pool = NULL;
    }
    s_pool_cap_bytes  = 0;
    s_pool_cap_frames = 0;
    s_pool_in_psram   = false;
}

/* ===========================================================================
 * tick <-> 微秒  （⭐ 增量式，⛔ 不是"先算每 tick 多少 us 再乘"）
 * ===========================================================================
 *   tick 频率 f_tick = (BPM/60) * PPQN
 *   tick_inc = round(2^32 * f_tick / F_CLK)      （F_CLK = 50 MHz）
 *   => f_tick = tick_inc * F_CLK / 2^32
 *
 *   dticks 个 tick 的时长：
 *       us = dticks * 1e6 / f_tick
 *          = dticks * 1e6 * 2^32 / (tick_inc * F_CLK)          ……(★)
 *
 * 🔴🔴 式 (★) 踩过【两个真 bug】（⭐ 都由 tools/pool_math_check.py 离线抓到）：
 *
 *   ① 直接按 (★) 乘：`dticks * 2^32 * 1e6`
 *      ⚠️ dticks=814,080（09_Conjurer 的 max_tick）时需要 **72 bit** =>
 *         静默回绕 => 算出 867,256 us（0.9 s），而正确值是 ~303 s（差 350 倍！）
 *      ⇒ 这跟 K-57（32 位溢出算出 -15 ns）是同一族。
 *
 *   ② 改成"先算 per1k = 每 1000 tick 多少 us，再乘 dticks/1000"：
 *      ⚠️ 能防溢出，但 per1k 只有 7 位有效数字（1041671.37 → 取 1041671），
 *         整曲 814,080 tick 累积绝对误差 **154 us**（⭐ 实测值，非估算）。
 *      ⚠️ 想靠放大分子补精度 => 需要 72 bit，⛔ 64 位放不下（已实测）。
 *
 *   ⇒ ⭐⭐ 最终方案：**只算增量，⛔ 不算绝对时刻**
 *      pump 时只需回答"下一帧还差多少微秒"，而这个增量很小
 *      （一次 pump 周期量级，<= 几十 ms 谱面时间）：
 *          us * tick_inc * F_CLK   在 500 ms 增量下才 63 bit ✅ 安全
 *      => 用 (★) 的【变形】直接从"已过微秒"反解 tick：
 *          dticks = us * tick_inc * F_CLK / (2^32 * 1e6)
 *      全程只乘不除（除数是常量 2^32 * 1e6 = 4.295e15），零累积误差。
 *
 * ⭐ 换句话说：比较"谱面进度"和"墙钟进度"，而不是给每帧算一个绝对时刻。
 * ===========================================================================
 */
#define PHASE_BITS      32u
#define F_CLK_HZ        50000000ull

/* 常量除数：2^32 * 1e6 = 4.295e15 （✅ 放得下 64 位） */
#define US_NUM_DEN      ((1ull << PHASE_BITS) * 1000000ull)

/*
 * 已过的微秒 dus 对应多少个 tick。
 *
 *   dticks = dus * tick_inc * F_CLK / (2^32 * 1e6)
 *
 * ⚠️ 中间量 `dus * tick_inc * F_CLK` 的位宽随 dus 增长：
 *      dus = 500 ms   -> 63 bit  ✅
 *      dus = 3 s      -> 65 bit  🔴 溢出
 *   ⇒ ⭐ 所以本函数【只用于增量】（调用方保证 dus 是"小差值"）。
 *      若要跨越长时间，请【分次】调用（pump 本身就是周期性的）。
 *
 * 🔴 调用方约束：dus 必须 <= BRIDGE_POOL_MAX_DELTA_US（见下）。
 */
#define BRIDGE_POOL_MAX_DELTA_US   500000ll      /* 500 ms，对应 63 bit 上限 */

static inline uint64_t delta_us_to_ticks(int64_t dus, uint32_t tick_inc)
{
    if (dus <= 0 || tick_inc == 0) {
        return 0;
    }
    if (dus > BRIDGE_POOL_MAX_DELTA_US) {
        dus = BRIDGE_POOL_MAX_DELTA_US;      /* ⚠️ 夹紧，防中间量溢出 */
    }
    return ((uint64_t)dus * (uint64_t)tick_inc * F_CLK_HZ) / US_NUM_DEN;
}

/* ===========================================================================
 * 对外接口
 * =========================================================================== */
void pool_reset(void)
{
    if (s_lock == NULL) {
        s_lock = xSemaphoreCreateMutex();
    }

    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_frames        = 0;
    s_play_idx      = 0;
    s_pool_done     = false;
    s_running       = false;
    s_tick_inc      = BRIDGE_POOL_DEFAULT_TICK_INC;
    s_t0_tick       = 0;
    s_t0_us         = 0;
    xSemaphoreGive(s_lock);

    /* ⭐ 首次调用时分配池内存（优先 PSRAM，退化内部 DRAM） */
    if (s_pool == NULL) {
        size_t got = pool_alloc();
        if (got == 0) {
            ESP_LOGE(TAG, "pool reset: NO MEMORY -> mode B unusable");
            return;
        }
        s_pool_cap_bytes  = got;
        s_pool_cap_frames = got / FRAME_BYTES;
    }

    ESP_LOGI(TAG, "pool reset. cap=%u B = %u frames (%s)",
             (unsigned)s_pool_cap_bytes, (unsigned)s_pool_cap_frames,
             s_pool_in_psram ? "PSRAM" : "internal DRAM");
}

/*
 * 灌入一批【帧对齐】的字节（长度必须是 9 的整数倍）。
 * 返回实际收到的字节数；< n 表示池满，多出来的被丢弃并计入 overflow。
 */
size_t pool_feed(const uint8_t *data, size_t n)
{
    size_t nframes = n / FRAME_BYTES;
    size_t room, take_frames, take_bytes;

    if (n % FRAME_BYTES != 0) {
        /* ⚠️ 上游没做 9N 对齐 —— 这会破坏帧相位，必须报出来 */
        ESP_LOGE(TAG, "pool_feed: len=%u not multiple of %u, REJECTED",
                 (unsigned)n, (unsigned)FRAME_BYTES);
        return 0;
    }

    xSemaphoreTake(s_lock, portMAX_DELAY);
    room = (s_pool_cap_frames > s_frames) ? (s_pool_cap_frames - s_frames) : 0;
    take_frames = (nframes < room) ? nframes : room;
    take_bytes  = take_frames * FRAME_BYTES;

    if (take_bytes > 0) {
        memcpy(s_pool + s_frames * FRAME_BYTES, data, take_bytes);
        s_frames += take_frames;
    }
    xSemaphoreGive(s_lock);

    if (take_frames < nframes) {
        s_pool_overflow_frames += (uint32_t)(nframes - take_frames);
        ESP_LOGE(TAG, "POOL FULL: dropped %u frames (total dropped=%lu)",
                 (unsigned)(nframes - take_frames),
                 (unsigned long)s_pool_overflow_frames);
    }
    return take_bytes;
}

/* 发送端宣布"整曲灌完"——此后池只出不进 */
void pool_mark_done(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_pool_done = true;
    xSemaphoreGive(s_lock);
    ESP_LOGI(TAG, "pool marked DONE: %u frames (%.2f KB)",
             (unsigned)s_frames, s_frames * (double)FRAME_BYTES / 1024.0);
}

/* 开始放水（从池内第 0 帧起，谱面时间 0 对齐到当下） */
void pool_start(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_play_idx = 0;
    s_t0_tick  = (uint32_t)ev_tick(pool_peek_word(0));
    s_t0_us    = esp_timer_get_time();
    s_running  = true;
    xSemaphoreGive(s_lock);
    ESP_LOGW(TAG, "pool START from tick=%lu at t0_us=%lld",
             (unsigned long)s_t0_tick, (long long)s_t0_us);
}

bool pool_is_running(void) { return s_running; }

size_t pool_frames(void)
{
    size_t v;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    v = s_frames;
    xSemaphoreGive(s_lock);
    return v;
}

void pool_stats(pool_stats_t *out)
{
    if (!out) return;
    out->frames          = s_frames;
    out->capacity_frames = s_pool_cap_frames;
    out->capacity_bytes  = s_pool_cap_bytes;
    out->in_psram        = s_pool_in_psram;
    out->sent_frames     = s_sent_frames;
    out->overflow_frames = s_pool_overflow_frames;
    out->tempo_events    = s_tempo_events;
    out->late_ticks_max  = s_late_ticks_max;
    out->tick_inc        = s_tick_inc;
    out->running         = s_running;
    out->done            = s_pool_done;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * 核心：按谱子时间放水
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * 判据不是"给每帧算一个绝对发送时刻"，而是：
 *
 *     把【已经过的墙钟时间】换算成【谱面 tick 进度】，
 *     只要下一帧的 tick 已经落在这个进度之内 => 就该发了。
 *
 *   elapsed_ticks = delta_us_to_ticks(now_us - t_start_us, tick_inc)
 *   应发到 tick   = t0_tick + elapsed_ticks - LEAD_TICKS
 *
 * ⭐ 为什么这么做（而不是算绝对时刻）：
 *   绝对时刻要算 `dticks * 2^32 * 1e6`，整曲跨度需 72 bit => 64 位放不下。
 *   增量式里 `us * inc * F_CLK` 只随【本次 pump 的间隔】增长（<= 500 ms => 63 bit）✅
 *   ⇒ 零累积误差，且不溢出。
 *
 * 🔴 防溢出安全约束：
 *     若发现已经晚了，【不补发】—— 只把当前该发的发掉，然后继续按原节奏。
 *     ⛔ 绝不"追赶式爆发"。
 *     因为：慢 => FPGA evt_underrun（⭐ 可见）；快 => FPGA 缓冲溢出（🔴 静默丢）。
 */
void pool_pump(void)
{
    if (!s_running) {
        return;
    }

    int64_t now_us   = esp_timer_get_time();
    int64_t elapsed  = now_us - s_t0_us;
    uint32_t budget  = BRIDGE_POOL_MAX_FRAMES_PER_PUMP;

    /* 允许发送到的谱面 tick（含提前量的反向扣除） */
    uint64_t elapsed_ticks = delta_us_to_ticks(elapsed, s_tick_inc);
    int64_t  due_tick;

    if (elapsed_ticks > (uint64_t)s_t0_tick + BRIDGE_POOL_LEAD_TICKS) {
        due_tick = (int64_t)(s_t0_tick + elapsed_ticks - BRIDGE_POOL_LEAD_TICKS);
    } else {
        due_tick = 0;                 /* 还在提前量之内，先不发 */
    }

    while (budget-- > 0) {
        uint32_t tick, kind, inc;

        xSemaphoreTake(s_lock, portMAX_DELAY);

        if (s_play_idx >= s_frames) {
            xSemaphoreGive(s_lock);
            break;                                  /* 池空 / 播完 */
        }

        const uint8_t *fp = s_pool + s_play_idx * FRAME_BYTES;
        uint64_t word = 0;
        for (int k = 0; k < 8; k++) {
            word = (word << 8) | fp[1 + k];          /* 大端 -> 64 bit */
        }

        tick = ev_tick(word);
        kind = ev_kind(word);
        inc  = ev_inc(word);

        if ((int64_t)tick > due_tick) {
            xSemaphoreGive(s_lock);
            break;                                  /* 还没到点，等下一轮 */
        }

        /* ⚠️ 落后记账（但不追赶）：due_tick 超过本帧 tick 多少 */
        if (due_tick > (int64_t)tick) {
            uint32_t late = (uint32_t)(due_tick - (int64_t)tick);
            if (late > s_late_ticks_max) {
                s_late_ticks_max = late;
            }
        }

        /* ⭐ 换速：必须【重锚】时间基准
         * ---------------------------------------------------------------
         * 🔴 这是个容易漏的坑：
         *     elapsed_ticks = (now - t0_us) 按【当前 tick_inc】换算。
         *     一旦 tick_inc 变了，同一个 (now - t0_us) 会换算出不同的 tick 数
         *     => 若不重锚，换速瞬间 due_tick 会【跳变】，导致：
         *        变快：due_tick 猛增 => 突发灌水 => 🔴 FPGA 缓冲溢出
         *        变慢：due_tick 猛降 => 停发     => ⚠️ FPGA underrun
         *     ⇒ 所以：以【本帧的 tick】为新基准，把 t0_us 重置为"当前时刻"，
         *       并把 s_t0_tick 设为本帧 tick。等价于"从此处重新计时"。
         *     ⚠️ 注意：新基准下提前量会从头累积，所以发送端要先灌够提前量。
         */
        if (kind == KIND_TEMPO && inc > 0) {
            s_tick_inc = inc;
            s_tempo_events++;
            ESP_LOGI(TAG, "tempo @tick=%lu -> tick_inc=%lu (time base re-anchored)",
                     (unsigned long)tick, (unsigned long)inc);

            /* ⭐ 重锚：本帧 tick 作为新原点，时刻取当下 */
            s_t0_tick = tick;
            s_t0_us   = now_us;

            /* ⚠️ 重锚后 due_tick 从头算，所以本帧必须【立刻发出去】，
             *    否则会卡在"还没到提前量"里。这里直接放行并 continue 到写 UART。 */
            xSemaphoreGive(s_lock);
            goto emit;
        }

        xSemaphoreGive(s_lock);

emit:
        /* 🔴 一帧 9 字节【一次写入】—— 保证帧内无空隙 */
        {
            int w = uart_write_bytes(BRIDGE_UART_PORT, (const char *)fp, FRAME_BYTES);
            if (w == FRAME_BYTES) {
                s_sent_frames++;
                s_play_idx++;
            } else {
                ESP_LOGE(TAG, "uart_write_bytes short: %d", w);
                break;
            }
        }
    }
}

/* 供 pool_start 用：窥一帧（不加锁，调用方已持锁） */
uint64_t pool_peek_word(size_t idx)
{
    uint64_t word = 0;
    if (idx >= s_frames) {
        return 0;
    }
    const uint8_t *fp = s_pool + idx * FRAME_BYTES;
    for (int k = 0; k < 8; k++) {
        word = (word << 8) | fp[1 + k];
    }
    return word;
}

/* 放水任务 */
void task_pool_pump(void *arg)
{
    (void)arg;
    ESP_LOGI(TAG, "pool pump task started");

    for (;;) {
        if (s_running) {
            pool_pump();
            vTaskDelay(pdMS_TO_TICKS(BRIDGE_POOL_PUMP_PERIOD_MS));
        } else {
            vTaskDelay(pdMS_TO_TICKS(10));
        }
    }
}
