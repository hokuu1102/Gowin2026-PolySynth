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
 *   ⚠️ 以下按 **500 kbps**（⭐ 2026-09-30 起两侧统一档位）核算：
 *      · 500 k 线速 = 50,000 B/s = 5,555 事件/s   =>  全速灌，164 ms 就满
 *      · （⭐ 对照 1 Mbps：11,111 事件/s ⇒ 92 ms —— ⚠️ 已不用该档）
 *   而 FPGA 消费只有 ~69.5 事件/s（最密曲 @168 BPM）
 *   ⇒ ⭐ 放水需求仅 626 B/s ⇒ 占用 500 k 链路的 **1.25%**（⭐ 余量 80 倍）
 *
 *   => 一旦本模块"放水"节奏算快了一点点，缓冲就积压 => 溢出 => 丢事件。
 *   => 而 §4.4 已拍板【不做反向通道】=> FPGA 满了我们【不知道】。
 *
 *   所以本文件的策略是【宁可饿着，不可撑着】：
 *     · 提前量取保守值（BLE_POOL_LEAD_TICKS 远小于 FPGA 缓冲容量）
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

#include "ble_config.h"
#include "pool.h"
#include "hmi.h"          /* 2026-10-13：把播放位置推给串口屏 */

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
static bool s_cleanup_done = true;
static uint32_t s_cleanup_sent = 0;
static bool pool_close_submitted_locked(void);

/* 节拍：当前每 tick 的相位增量（由 kind=2 事件改写） */
static uint32_t  s_tick_inc = BLE_POOL_DEFAULT_TICK_INC;

/* 物理时钟基准：开始放水时的 (谱面 tick, 单调微秒) */
static uint32_t  s_t0_tick = 0;
static int64_t   s_t0_us   = 0;
static bool      s_running = false;

/* 2026-10-13：最近一次放水时算出的"此刻应播到的谱面 tick"。
 * 供 pool_stats() 上报，让 PC / 串口屏能显示真实的播放位置。
 * 不参与任何控制逻辑 —— 纯粹是"把内部真值暴露出来"（K-106）。 */
static uint32_t  s_play_tick = 0;

/* 2026-10-14：实测放水速率与 pump 周期 —— 用来验证"限流上限是否顶住了音乐速率"。
 *
 * ═══ 为什么必须有它 ═══
 * 限流上限 = `BLE_POOL_MAX_TICK_ADVANCE / P`（P = pump 的实际周期），
 * 而 `vTaskDelay(2ms)` **只是"至少 2 ms"** ⇒ P 远大于名义值。
 * ⚠️ 若上限速率 < 音乐速率（1920 tick/s @120BPM/960PPQN），
 *    固件会被上限【顶住】⇒ 必然偏慢。
 * 🔴 实测（2026-10-14）：sent 44 秒只涨 66 帧 << 期望 11 帧/秒
 *    ⇒ 明显被顶住。
 * ⭐ 有了这两个数就能【定量】定参数，⛔ 不靠拍脑袋（AGENTS 0.11 第 3 步）。 */
static volatile uint32_t s_rate_tick_per_s = 0;   /* 实测放水速率（tick/s） */
static volatile uint32_t s_pump_period_us  = 0;   /* 实测 pump 周期（微秒） */
static int64_t           s_rate_last_us    = 0;
static uint64_t          s_rate_last_pos   = 0;

/* 本曲的提前量（tick）—— 由 pool_compute_lead_ticks() 决定。
 *
 * ═══ 2026-10-14：这里连错两次，把失败路径留下来 ═══
 *
 * ── 第一版（错）：按谱面密度"填满缓冲" ──
 *     模型：提前 tick = HIGH_WM / E   （E = 每 tick 平均事件数）
 *     🔴 实测：demo_scale 的 E=0.0011 => 694393 tick = 【363 秒】
 *     => 荒谬。根因：把"填满缓冲"当成了目的，
 *        而提前量的唯一作用是【抗 BLE 抖动】。
 *
 * ── 第二版（错）：按"攒够一次停顿的量" ──
 *     模型：N_min = E × 1920 × STALL_SEC ；lo = N_min / E
 *     🔴 会计算一下就知道：lo = 1920 × STALL_SEC = 【常数 192 tick】
 *        —— E 被约掉了，"下界"根本不随谱面变 => 模型没信息。
 *     ⭐ 离线自检的方向性判据当场抓到（见 _lead_model_check.py）。
 *
 * ── 第三版（本实现）：承认它基本是个常数 ──
 *     提前量 = 抗住一次 BLE 停顿所需的【事件存货】对应的音乐时间。
 *     而"存货 = 该停顿期间本会消耗的事件数" => 两者恰好抵消
 *     => ⭐ 结果与谱面密度【无关】，就是个常数（≈ STALL_SEC）。
 *     只有【极密】谱面（768/E 小于这个常数）才需要往下压 ——
 *     因为那时的硬约束变成"缓冲装不下"。
 *
 * 📌 结论：⭐ 我方原以为的"按谱面密度动态算"是【伪需求】。
 *    真正该做的是：把固定值 20000（10.4 秒）降到常数级（0.625 秒）。
 *    20000 之所以历来安全，是因为它按【最密谱面】定的 ——
 *    对稀疏谱面它只是白白让人多等 10 秒。
 *
 * ⚠️ 待验证（下一轮）：这个缩短是否真的不引起 underrun。
 *    判据：连跑多轮，看 `late` 与 FPGA 侧的 `eb_ovf`/underrun 计数。
 */
static uint32_t s_lead_ticks = BLE_POOL_LEAD_MIN_TICKS;

/* 提前量门控的【一次性】阈值（谱面 tick）
 * ---------------------------------------------------------------------------
 * 2026-10-01 修 bug 新增。原来的门控写的是：
 *     uint64_t lead_end = (uint64_t)s_t0_tick + BLE_POOL_LEAD_TICKS;
 *     if (elapsed_ticks > lead_end) { ... }
 * 它把【已过 tick 数】(elapsed_ticks，一个"时长") 与【锚点的谱面 tick 位置】
 * (s_t0_tick，一个"位置") 相加后比大小 —— 量纲混了。
 *
 * 起播时 s_t0_tick = 首帧 tick（真谱面为 0）=> 恰好等价于 "elapsed > LEAD"，
 * 所以这个混用一直没暴露。但【中段换速】会把 s_t0_tick 重锚成一个很大的位置
 * => 门控变成 "elapsed > 该位置 + LEAD"，而 elapsed 同时被重置为 0
 * => 在歌曲剩余时间里【不可满足】=> 喂水停住。
 *
 * 实测预测（09_Conjurer，第 2 条 tempo 在 tick=414720，谱面总长 814080）：
 *     sent 会停在 7445（tick<=414720 的事件数），停约 226 秒。
 *
 * 修法：门控改用这个【在 pool_start 时算一次】的常量阈值，与重锚解耦。
 * 行为等价性：真谱面首帧 tick=0 => 新旧门控在起播段【逐位相同】。
 */
static uint64_t  s_lead_end = 0;
/* ⭐⭐ "这一曲【自然放完】了"—— 一次性标志，⭐ 由消费方取走（take）
 * ---------------------------------------------------------------------------
 * 🔴 为什么需要它（2026-10-01 新增）：
 *    ⚠️ 实测发现：⭐ 池**自然放完**后 `s_running` 仍是 `true`
 *       （⛔ 只有 `pool_stop()` / `pool_reset()` 才清它）
 *    ⇒ 🔴 **没有任何地方能发现"放完了"** ⇒ ⭐ 屏上 `播完` 永远显示不出来（死代码）。
 *    ⚠️ 附带后果：⭐ 放完后再按 START 会被 "already running" 拒掉。
 * ⭐ 修法（改【上游源头】）：⭐ 在 `pool_pump()` 里【已经知道放完】的那个判据点上
 *    （原来只打遥测日志）⭐ **同时**清 `s_running` ＋ 置本标志。
 * ⚠️ volatile：⭐ 跨任务（pump 任务写，drain 任务读）。 */
static volatile bool s_finished = false;

static SemaphoreHandle_t s_lock = NULL;

/* ⭐⭐ 放水收尾遥测（2026-09-30，⭐ 由临时诊断转正）
 * 整曲放完时打【一行】，用于一眼核对放水节奏对不对。
 * ⚠️ 一次性：用 s_feed_done_logged 去重，⛔ 不每轮打（pump 在优先级 9 的任务里）。 */
static bool s_feed_done_logged = false;

/* ⭐ 可观测计数（K-106：会出错的容量必须看得见） */
static volatile uint32_t s_pool_overflow_frames = 0;   /* 池满丢掉的帧数 */
static volatile uint32_t s_sent_frames          = 0;   /* 已写 UART 的帧数 */
static volatile uint32_t s_late_ticks_max       = 0;   /* 最大落后（tick） */
static volatile uint32_t s_tempo_events         = 0;   /* 已应用的换速次数 */
static bool              s_pool_in_psram        = false; /* ⭐ 池是否落在 PSRAM */

/* ⭐⭐ 2026-09-23 新增：tick 限流 + "应到帧数"（⭐ 两件都服务于"看得见"） */
static volatile uint32_t s_tick_clamped_cnt     = 0;   /* tick 限流截断次数 */
static int64_t           s_due_tick_last        = -1;  /* 上轮推进到的 tick（-1=未开始） */
static volatile uint32_t s_expected_frames      = 0;   /* ⭐ 应该收多少帧（0=未知） */
static volatile uint32_t s_total_mismatch       = 0;   /* 🔴 实收与应到不符（应恒为 0） */

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
    const size_t want = BLE_POOL_BYTES;

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
 *   ⇒ ⭐ 所以本函数**只用于增量**（调用方保证 dus 是"小差值"）。
 *      若要跨越长时间，请**分次**调用（pump 本身就是周期性的）。
 *
 * 🔴🔴 2026-09-30 修复：**"夹紧"这个做法本身是错的 —— 它会静默把长时长截短**
 * ---------------------------------------------------------------------------
 * ⭐ 现象（实测）：起播后 `sent=` **永远是 0**，`pool_pump()` 一帧都不发。
 *
 * 🔴 根因：`pool_pump()` 传进来的是**绝对经过时间**
 *    （`now_us - s_t0_us`，⭐ 起播后可能十几秒），
 *    ⚠️ 而这里把它**夹到 500 ms** ⇒ `elapsed_ticks` **最大只有 960**
 *    ⇒ 🔴 而放水要求 `elapsed_ticks > lead_end`（当时写作 `s_t0_tick + 20000`；
 *       ⚠️ 那个写法本身还有【第二个】缺陷，见 `s_lead_end` 的注释，2026-10-01 已修）
 *    ⇒ ⚠️ **21000 vs 960 ⇒ 数学上永远达不到** ⇒ `allow_emit` 恒 false。
 *
 * ⭐⭐ 两个量纲本来就矛盾：
 *    · `BLE_POOL_LEAD_TICKS = 20000` ticks ≈ **10.4 s**（音乐时间）
 *    · `BLE_POOL_MAX_DELTA_US = 500 ms`（墙钟时间，⭐ 为防中间量溢出）
 *    ⇒ 只要"提前量 > 500 ms 对应的 tick 数"，就**必然**触发本缺陷。
 *
 * ✅ 修法：**把"夹紧"改成"分段累加"** ——
 *    ⭐ 大 dus 拆成若干个 ≤ 500 ms 的小段分别换算再相加。
 *    ⇒ 既保住"中间量不溢出"的原意，⛔ 又不再截短结果。
 *    ⭐ 这一步是**结构性**的：只要单段 ≤ 500 ms，位宽就恒在 63 bit 以内。
 */
#define BLE_POOL_MAX_DELTA_US   500000ll      /* 500 ms，单段上限（对应 63 bit） */

static inline uint64_t delta_us_to_ticks(int64_t dus, uint32_t tick_inc)
{
    if (dus <= 0 || tick_inc == 0) {
        return 0;
    }

    /* ⭐ 分段累加：每段 ≤ BLE_POOL_MAX_DELTA_US ⇒ 中间量恒定安全 */
    uint64_t ticks = 0;
    while (dus > 0) {
        uint64_t seg = ((uint64_t)dus > (uint64_t)BLE_POOL_MAX_DELTA_US)
                     ? (uint64_t)BLE_POOL_MAX_DELTA_US
                     : (uint64_t)dus;
        ticks += (seg * (uint64_t)tick_inc * F_CLK_HZ) / US_NUM_DEN;
        dus -= (int64_t)seg;
    }
    return ticks;
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
    if (!pool_close_submitted_locked()) {
        xSemaphoreGive(s_lock);
        return;
    }
    s_frames        = 0;
    s_play_idx      = 0;
    s_pool_done     = false;
    s_running       = false;
    s_play_tick     = 0;          /* 播放位置归零，避免上报上一曲的残留 */
    /* 2026-10-14：实测速率也归零（否则新曲会读到上一曲的残留值） */
    s_rate_tick_per_s = 0;
    s_pump_period_us  = 0;
    s_rate_last_us    = 0;
    s_rate_last_pos   = 0;
    s_tick_inc      = BLE_POOL_DEFAULT_TICK_INC;
    s_t0_tick       = 0;
    s_t0_us         = 0;
    xSemaphoreGive(s_lock);

    /* ⭐ 2026-09-23：新状态也要清（⚠️ 否则上一曲的值会污染这一曲）
     * ⚠️ s_due_tick_last 用 **-1 当哨兵** —— 表示"还没开始推进"，
     *    这样 tick 限流的第一轮不会被"上一曲的末尾位置"卡住。 */
    s_due_tick_last     = -1;
    s_expected_frames   = 0;
    s_total_mismatch    = 0;
    s_tick_clamped_cnt  = 0;
    s_late_ticks_max    = 0;
    s_tempo_events      = 0;
    s_sent_frames       = 0;
    s_pool_overflow_frames = 0;

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

    /* ⭐ 允许下一曲再打一次收尾遥测（见 pool_pump 末尾的 "feed done"） */
    s_feed_done_logged = false;
    /* ⭐ 清掉上一曲遗留的"自然放完"事件 ⇒ ⚠️ 否则新曲一开就误报 `播完` */
    s_finished = false;
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

/* ⭐⭐ 告诉水池"应该收多少帧"（⭐ 来自协议里的总数帧；0 = 未知，则不校验）
 * ---------------------------------------------------------------------------
 * 🔴 为什么需要它（2026-09-23 新增）：
 *    旧逻辑判"灌完"只看 `pool_mark_done()` —— ⚠️ 而那是【发送端自己说的】。
 *    ⇒ 🔴 **PC 发到一半断链，池里只有一半，也会被当成"灌完"** ⇒
 *       播到一半就没声了，⚠️ 而日志上"一切正常"。
 * ⭐ 有了期望值后：`pool_mark_done()` 会比对实收与应到，
 *    ⭐ **对不上 ⇒ `s_total_mismatch++`（🔴 必须看得见）**。
 */
void pool_set_expected(size_t frames)
{
    s_expected_frames = (uint32_t)frames;
    ESP_LOGI(TAG, "pool expected = %u frames (%.2f KB)",
             (unsigned)frames, frames * (double)FRAME_BYTES / 1024.0);
}

/* 发送端宣布"整曲灌完"——此后池只出不进 */
void pool_mark_done(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_pool_done = true;
    xSemaphoreGive(s_lock);

    /* ⭐⭐ 校验"实收 == 应到"（⭐ 未设期望值时跳过，⛔ 不误报） */
    if (s_expected_frames > 0 && (uint32_t)s_frames != s_expected_frames) {
        s_total_mismatch++;
        ESP_LOGE(TAG,
                 "TOTAL MISMATCH: got %u frames, expected %u (diff %+d) — "
                 "sender may have been cut off!",
                 (unsigned)s_frames, (unsigned)s_expected_frames,
                 (int)((int32_t)s_frames - (int32_t)s_expected_frames));
    }

    ESP_LOGI(TAG, "pool marked DONE: %u frames (%.2f KB)%s",
             (unsigned)s_frames, s_frames * (double)FRAME_BYTES / 1024.0,
             (s_expected_frames > 0) ? "" : "  [expected unknown]");
}

/* 决定本曲的提前量（tick）。
 *
 * ═══ 算法（第三版 —— 前两版都错，见 s_lead_ticks 的注释）═══
 *   base = 抗住一次 BLE 停顿所需的音乐时间
 *        = TICKS_PER_SEC × STALL_SEC（1920 × 0.1 = 192 tick ≈ 0.1 秒）
 *   lead = max(BLE_POOL_LEAD_MIN_TICKS, base)      // 下限保护
 *   若谱面【极密】，使 "768/E" 小于 lead
 *        => 硬约束变成"缓冲装不下" => lead = 768/E（往下压）
 *
 * ⭐ 关键认知：lead 与谱面密度【基本无关】——
 *    因为"存货事件数"与"该存货对应的音乐时间"恰好抵消。
 *
 * ⚠️ 只用【极密判定】才需要算 E，所以这里只在必要时遍历一次池。
 */
static uint32_t pool_compute_lead_ticks(void)
{
    /* 基准：抗一次 BLE 停顿（换算成音乐时间）。 */
    uint64_t base = (uint64_t)(BLE_POOL_STALL_SEC * 1000.0f
                               * (float)BLE_POOL_TICKS_PER_SEC / 1000.0f);
    uint32_t lead = (base > BLE_POOL_LEAD_MIN_TICKS)
                  ? (uint32_t)base : BLE_POOL_LEAD_MIN_TICKS;

    if (s_frames == 0) {
        return lead;                                /* 空池：用基准值 */
    }

    /* ---- 极密判定：算 E，看 768/E 是否比基准还小 ---- */
    uint32_t t_first = ev_tick(pool_peek_word(0));
    uint32_t t_last  = 0;
    for (uint32_t i = 0; i < s_frames; i++) {
        uint32_t t = ev_tick(pool_peek_word(i));
        if (t > t_last) t_last = t;
    }
    uint32_t span = (t_last > t_first) ? (t_last - t_first) : 0;
    if (span == 0) {
        return lead;                        /* 全挤在一个 tick：用基准值 */
    }

    /* E 用百万分定点（⚠️ 千分标度会截断成 0，踩过：见 git 历史） */
    uint32_t e_micro = (uint32_t)(((uint64_t)s_frames * 1000000ull) / span);
    if (e_micro == 0) e_micro = 1;

    uint64_t hi = ((uint64_t)BLE_FPGA_EVT_BUF_HIGH_WM * 1000000ull) / e_micro;

    if (hi < lead) {
        /* ⚠️ 太密：连基准的存货都装不下 => 只能按缓冲容量来 */
        lead = (uint32_t)hi;
        ESP_LOGW(TAG, "lead: score too DENSE (E=%.6f) -> capped by HIGH_WM: "
                 "%lu ticks", (double)e_micro / 1000000.0, (unsigned long)lead);
    } else {
        ESP_LOGI(TAG, "lead: E=%.6f ev/tick, hi=%lu -> lead=%lu ticks (%.2f s)",
                 (double)e_micro / 1000000.0, (unsigned long)hi,
                 (unsigned long)lead,
                 (double)lead * 60.0 / (120.0 * 960.0));
    }
    if (lead < BLE_POOL_LEAD_MIN_TICKS) lead = BLE_POOL_LEAD_MIN_TICKS;
    return lead;
}

/* 开始放水（从池内第 0 帧起，谱面时间 0 对齐到当下） */
void pool_start(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (!pool_close_submitted_locked()) {
        xSemaphoreGive(s_lock);
        return;
    }
    s_cleanup_done = false;
    s_cleanup_sent = 0;
    s_play_idx = 0;
    s_t0_tick  = (uint32_t)ev_tick(pool_peek_word(0));
    s_t0_us    = esp_timer_get_time();
    /* 提前量门控的阈值：只在这里算一次，此后【不随换速重锚而变】 */
    s_lead_ticks = pool_compute_lead_ticks();
    s_lead_end   = (uint64_t)s_t0_tick + (uint64_t)s_lead_ticks;
    s_running  = true;
    xSemaphoreGive(s_lock);
    ESP_LOGW(TAG, "pool START from tick=%lu at t0_us=%lld, lead=%lu ticks (%.1f s)",
             (unsigned long)s_t0_tick, (long long)s_t0_us,
             (unsigned long)s_lead_ticks,
             (double)s_lead_ticks * 60.0 / (120.0 * 960.0));

    /* ⭐ 允许本曲再打一次收尾遥测（见 pool_pump 末尾的 "feed done"） */
    s_feed_done_logged = false;
    /* ⭐ 起播前清掉旧的"自然放完"事件（⚠️ 重播同一首时，上一轮的完成事件必须清掉） */
    s_finished = false;
}

bool pool_is_running(void) { return s_running; }

/* ⭐⭐ 取走"自然放完"事件（⭐ 取走即清零 ⇒ ⭐ 一次性，⛔ 不会重复上报）
 * ---------------------------------------------------------------------------
 * ⚠️ 为什么要 take 语义（⛔ 不是"读一个 bool"）：
 *    ⭐ 消费方（`task_drain`）是【轮询】的 ⇒ ⚠️ 若只读不清，
 *       它会**每一轮都上报一次** ⇒ ⭐ 屏上状态被反复重设（⚠️ 且遥测刷屏）。
 *    ⭐ take 语义让"事件"只被消费一次，⭐ 与"电平"区分开。 */
bool pool_take_finished(void)
{
    if (!s_finished) {
        return false;
    }
    s_finished = false;
    return true;
}

/* ⭐ 停止放水（2026-09-30 新增）
 * ⚠️ 语义说清：⛔ 不"暂停/续播" —— `pool_start()` 会把 `s_play_idx` 重置到 0
 *    ⇒ ⭐ **stop 之后再 start = 【从头重播】**。
 * ⚠️ 保留池内容（⛔ 不清空）⇒ 若只是想停，之后仍可重播同一首。 */
/* Caller holds s_lock. Reconstruct outstanding references from submitted events.
 * Keep the original identity and flags; repeated ONs each require an OFF. */
static bool pool_close_submitted_locked(void)
{
    enum { MAX_OPEN = 64 };
    struct open_note { uint64_t word; uint32_t refs; };
    static struct open_note open[MAX_OPEN];
    uint32_t n_open = 0;
    size_t sent = s_play_idx < s_frames ? s_play_idx : s_frames;
    s_running = false;
    if (s_cleanup_done) return true;
    const uint64_t identity = ((uint64_t)INC_MASK << INC_SHIFT)
                            | ((uint64_t)15 << 19) | 31;
    for (size_t i = 0; i < sent; ++i) {
        uint64_t w = pool_peek_word(i);
        uint32_t kind = ev_kind(w);
        if (kind > 1) continue;
        uint32_t j;
        for (j = 0; j < n_open; ++j)
            if ((open[j].word & (identity | 0x1e0)) == (w & (identity | 0x1e0))) break;
        /* OFF may omit timbre flags. Keep routing distinct: guide-only OFFs
         * cannot close audible notes, and drum OFFs cannot close melody. */
        if (kind == 1 && j == n_open) {
            for (j = 0; j < n_open; ++j)
                if ((open[j].word & (identity | 0x60)) == (w & (identity | 0x60))) break;
            if (j == n_open && !(w & 0x60)) {
                for (j = 0; j < n_open; ++j)
                    if ((open[j].word & identity) == (w & identity)
                        && (open[j].word & 0x40)) break;
            }
        }
        if (kind == 0) {
            if (j < n_open) ++open[j].refs;
            else if (n_open < MAX_OPEN) {
                open[n_open].word = w;
                open[n_open++].refs = 1;
            } else {
                ESP_LOGE(TAG, "cleanup identity capacity exceeded");
                return false;
            }
        } else if (j < n_open) {
            if (--open[j].refs == 0) open[j] = open[--n_open];
        }
    }
    uint32_t tick = sent ? ev_tick(pool_peek_word(sent - 1)) : 0;
    uint32_t close_index = 0;
    for (uint32_t j = 0; j < n_open; ++j) {
        uint64_t w = open[j].word;
        w &= ~(((uint64_t)TICK_MASK << TICK_SHIFT)
             | ((uint64_t)255 << 11) | ((uint64_t)3 << KIND_SHIFT));
        w |= ((uint64_t)tick << TICK_SHIFT) | ((uint64_t)1 << KIND_SHIFT);
        uint8_t frame[FRAME_BYTES];
        frame[0] = FRAME_HDR_EVENT;
        for (int k = 0; k < 8; ++k)
            frame[1+k] = (uint8_t)(w >> (8*(7-k)));
        for (uint32_t ref = 0; ref < open[j].refs; ++ref) {
            if (close_index++ < s_cleanup_sent) continue;
            if (uart_write_bytes(BLE_UART_PORT, (const char *)frame, FRAME_BYTES) != FRAME_BYTES) {
                ESP_LOGE(TAG, "cleanup UART short write");
                return false;
            }
            ++s_sent_frames;
            ++s_cleanup_sent;
        }
    }
    s_cleanup_done = true;
    return true;
}

void pool_stop(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    (void)pool_close_submitted_locked();
    xSemaphoreGive(s_lock);
}

/* ⭐ 已放出的帧数（2026-09-30 新增）—— 给"起播触发"打日志用。 */
uint32_t pool_frames_sent(void)
{
    uint32_t v;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    v = s_sent_frames;
    xSemaphoreGive(s_lock);
    return v;
}

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

    /* ⭐ 2026-09-23 新增 */
    out->expected_frames  = s_expected_frames;
    out->total_mismatch   = s_total_mismatch;
    out->tick_clamped_cnt = s_tick_clamped_cnt;

    /* 播放位置（2026-10-13 新增）——
     * 消费方算法：heard_tick = play_tick - t0_tick - lead_ticks */
    out->play_tick  = s_play_tick;
    out->t0_tick    = s_t0_tick;
    out->lead_ticks = s_lead_ticks;   /* 2026-10-14：按谱面算出来的，⛔ 不是固定值 */
    /* 本曲总长 = 池内【所有帧 tick 的最大值】。
     *
     * 🔴🔴 2026-10-14 修：原来取的是「末帧的 tick」，那是错的。
     * ═══ 为什么错（实测踩到）═══
     * 谱面可以是【多轴交织】的 —— 每个轴是一条独立的时间线，
     * 交织存放后**整池的 tick 不单调**，末帧未必是时间最晚的那一帧。
     * 实测（demo_scale.hex，111 帧）：
     *     axis=0:  31 帧, tick 0 .. 7200
     *     axis=1:  48 帧, tick 8160 .. 100320     <= 时间最晚的在轴 1
     *     axis=2:  32 帧, tick 3840 .. 19200      <= 而末帧属于轴 2
     *   => 末帧 tick = 19200，但全曲真正到 100320（52.25 秒 vs 10 秒）
     * 🔴 后果：消费方（网页 / 串口屏）拿 19200 当分母
     *   => 播放进度条【跑飞 / 早早到 100%】——
     *      这就是"灌谱进度与播放进度对不上"的根因。
     * ⭐ 取最大值才对：它是"这一曲要播多久"的唯一正确来源。
     * ⚠️ 代价：O(帧数) 每次 pool_stats() 都扫一遍。
     *   实测池上限 18204 帧 => 最多 1.8 万次比较，可接受；
     *   ⭐ 且 pool_stats() 只在客户端轮询时调用（~2 Hz），不是热路径。 */
    out->total_tick = 0;
    for (uint32_t i = 0; i < s_frames; i++) {
        uint32_t t = ev_tick(pool_peek_word(i));
        if (t > out->total_tick) {
            out->total_tick = t;
        }
    }
    out->pos_valid  = s_running ? 1 : 0;

    /* 2026-10-14：实测速率与周期（见 pool.h 的说明） */
    out->rate_tick_per_s = s_rate_tick_per_s;
    out->pump_period_us  = s_pump_period_us;
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
 *
 * ⭐⭐ 2026-09-23 重做：**两条限流一起上**
 *   ① ⭐ **tick 限流**：单轮最多把 `due_tick` 推进 `MAX_TICK_ADVANCE` 个 tick
 *      （🔴 这是新加的 —— 原来看的是"帧数"，⚠️ 那管不住"被调度延迟后突然发一大坨"）
 *   ② ⚠️ **帧数硬上限**：防"某 tick 内海量事件"这种病态情况
 *   ⭐ 两条都【不追赶】：落后只记账（`late_ticks_max`），⛔ 不补发。
 */
void pool_pump(void)
{
    if (!s_running) {
        return;
    }

    int64_t now_us   = esp_timer_get_time();
    int64_t elapsed  = now_us - s_t0_us;
    uint32_t budget  = BLE_POOL_MAX_FRAMES_PER_PUMP;   /* ⚠️ 帧数硬上限（病态兜底） */

    /* 允许发送到的谱面 tick（含提前量的反向扣除） */
    uint64_t elapsed_ticks = delta_us_to_ticks(elapsed, s_tick_inc);
    int64_t  due_tick;
    bool     allow_emit;

    /* ⭐ 2026-09-23 修：把"还在提前量内"与"谱面 tick 就是 0"【明确分开】
     * 🔴 旧写法在 else 分支里写 `due_tick = 0`，语义含糊 ——
     *    它同时表示"先不发"和"允许发 tick <= 0 的帧"，
     *    ⚠️ 于是"首帧 tick 恰好是 0"时行为取决于巧合。
     * ⭐ 现在用一个显式布尔，⛔ 不靠 due_tick 的取值去暗示。 */
    /* ⭐ 当前位置（谱面 tick）。用【当前】s_tick_inc 换算，且在换速改
     *    s_tick_inc 之前算好 —— 换速重锚要靠它保持位置连续（见下方换速段）。 */
    int64_t pos_now = (int64_t)s_t0_tick + (int64_t)elapsed_ticks;

    /* 2026-10-13：把"此刻应该播到哪"缓存下来，供 pool_stats() 读。
     * 为什么在这里算而不在 pool_stats() 里算：
     *   pos_now 依赖 elapsed_ticks，而它的换算要 s_tick_inc 与 s_t0_us
     *   —— 这两者都只在本函数里用。放这里算一次最省事，也保证
     *   "上报的位置"和"实际用的门控"用的是同一个值（不会两处漂）。
     * 为什么用 32 位：谱面 tick 本身是 32 位（BLE_POOL_LEAD 也是），
     *   曲长 20 bit/960PPQN 早已超出任何真实曲子 => 不会溢出。 */
    s_play_tick = (uint32_t)pos_now;

    /* 2026-10-14：算【实测速率】与【实测 pump 周期】。
     * 算法：与上一次调用比，看墙钟过了多少、位置推进了多少。
     * ⚠️ 只在"位置真的推进了"时更新 —— 否则提前量期间（位置不动但时间在走）
     *    会把速率算成 0，掩盖真实值。 */
    {
        int64_t now_us2 = esp_timer_get_time();
        if (s_rate_last_us != 0) {
            int64_t d_us = now_us2 - s_rate_last_us;
            int64_t d_pos = pos_now - (int64_t)s_rate_last_pos;
            if (d_us > 0) {
                /* pump 周期：直接就是两次调用的间隔（滑动一下，避免抖动） */
                uint32_t p = (uint32_t)d_us;
                s_pump_period_us = (s_pump_period_us == 0)
                                 ? p : (uint32_t)((s_pump_period_us * 7u + p) / 8u);
            }
            if (d_us > 0 && d_pos > 0) {
                uint32_t r = (uint32_t)((uint64_t)d_pos * 1000000ull
                                        / (uint64_t)d_us);
                s_rate_tick_per_s = (s_rate_tick_per_s == 0)
                                  ? r : (uint32_t)((s_rate_tick_per_s * 7u + r) / 8u);
            }
        }
        s_rate_last_us  = now_us2;
        s_rate_last_pos = (uint64_t)pos_now;
    }

    /* 🔴 2026-10-01 修 bug：门控原来写 `elapsed_ticks > s_t0_tick + LEAD`，
     *    把"时长"与"位置"混着比。起播时 s_t0_tick=0 恰好等价，但中段换速
     *    重锚成一个大位置后条件不可满足 => 喂水停住（详见 s_lead_end 的注释）。
     *    ⭐ 现在比【位置】：pos_now > s_lead_end（一次性阈值）。 */
    if (pos_now > (int64_t)s_lead_end) {
        due_tick   = pos_now - (int64_t)s_lead_ticks;
        allow_emit = true;
    } else {
        due_tick   = 0;
        allow_emit = false;                 /* ⭐ 还在提前量之内，本轮一帧都不发 */
    }

    /* ⭐⭐ tick 限流（🔴 2026-09-23 新增；⚠️ 2026-09-30 修【首轮顺序缺陷】）
     * ---------------------------------------------------------------------
     * 🔴 为什么必须限：`vTaskDelay(2ms)` 只是"至少 2 ms"——
     *    被调度器延迟后 `elapsed` 会变大 ⇒ `due_tick` 一步跳很远
     *    ⇒ ⚠️ 一轮内连发一大批 ⇒ 可能把 FPGA 缓冲灌满。
     * ⭐ 做法：单轮最多把"允许发到的 tick"从上一轮的位置往前推 N 个 tick。
     *    ⚠️ 落后的部分【不补】（本轮追不上就留着下轮），
     *       代价是 `late_ticks_max` 变大、可能 underrun —— ⭐ 那是可见的、可接受的。
     *
     * 🔴🔴 2026-09-30 修复：**哨兵分支必须【先于】钳位**（原顺序反了）
     * -------------------------------------------------------------------
     * ⭐ 实测症状：放水**偏快** —— pace = **0.782**（比音乐时间快 22%），
     *    且 `clamp=168`。⚠️ 两次独立测量一致（0.7823 / 0.7822）⇒ 真实偏差。
     *
     * 🔴 根因（原代码把哨兵判断放在钳位【之后】）：
     *    首轮 `s_due_tick_last = -1`（哨兵"未开始"）
     *      cap = -1 + 31 = 30
     *      due_tick（真值 ~2004）> 30  ⇒ 🔴 **被截断成 30**
     *      然后 `if (s_due_tick_last < 0) s_due_tick_last = due_tick` ⇒ 记下 **30**
     *    ⇒ 🔴 **把"被打残的 30"固化成了合法起点** ⇒ 永久欠下 ~1974 tick
     *    ⇒ 此后 pump 只能以天花板速率（31 tick/轮）**追赶** ⇒
     *      ⚠️ 而墙钟每轮只涨 19.2 tick ⇒ 追了 **~1.67 s**（⭐ 几乎整个采集窗口）
     *    ⇒ 所以实测速率 = **2454 tick/s**（介于音乐 1920 与天花板 3100 之间）
     *
     * ⭐⭐ **量纲错误**：钳位的语义是"**单轮【推进】**不超过 N"，
     *    而首轮**没有"上一轮"** ⇒ 不存在需要限制的"推进量"。
     *    原代码把 **绝对值** 当 **增量** 限制 ⇒ 🔴 与 `delta_us_to_ticks`
     *    那个"夹紧 vs 分段累加"的缺陷**同族**（⭐ 见本文件上方 §夹紧）。
     *
     * ✅ 修法：**先判哨兵、再做钳位** —— 首轮直接采纳真值（⛔ 不施加钳位）。
     *    ⭐ 判据：改完 `clamp` 应从 **168 → 0**，`pace` 应 → **1.0**。
     */
    if (allow_emit) {
        /* ⭐ 首轮：哨兵 ⇒ 直接采纳真值，⛔ 不钳位（此刻不存在"推进量"） */
        if (s_due_tick_last < 0) {
            s_due_tick_last = due_tick;
        } else {
            int64_t cap = s_due_tick_last + (int64_t)BLE_POOL_MAX_TICK_ADVANCE;
            if (due_tick > cap) {
                due_tick = cap;                 /* ⭐ 截断：本轮只推进这么多 */
                s_tick_clamped_cnt++;           /* ⚠️ 可观测：被截断过多少次 */
            }
            if (due_tick > s_due_tick_last) {
                s_due_tick_last = due_tick;     /* ⭐ 记住本轮推进到的位置 */
            }
        }
    }

    while (budget-- > 0) {
        uint32_t tick, kind, inc;

        /* ⭐ 没到起播提前量 ⇒ 本轮一帧都不发（⛔ 不是靠 due_tick==0 暗示） */
        if (!allow_emit) {
            break;
        }

        xSemaphoreTake(s_lock, portMAX_DELAY);

        if (!s_running || s_play_idx >= s_frames) {
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

            /* ⭐ 重锚：把【当前音乐位置】作为新原点，时刻取当下。
             * 🔴 2026-10-01 修 bug：原来写的是 `s_t0_tick = tick`（本帧自己的 tick），
             *    而 due_tick = 位置 - 提前量 ⇒ 本帧 tick 比【真实位置】小了整整
             *    一个提前量 ⇒ 重锚会把位置【往回拉 20000 tick】⇒ 门控随之
             *    不可满足 ⇒ 喂水停住（实测预测见 s_lead_end 的注释）。
             *    ⭐ 正确做法：用 pos_now（换速前、用旧 tick_inc 算好的当前位置）
             *    ⇒ 位置【连续】⇒ due_tick 既不跳增（突发灌水）也不跳降（停发）。 */
            s_t0_tick = (uint32_t)pos_now;
            s_t0_us   = now_us;

            /* ⚠️ 重锚后 due_tick 从头算，所以本帧必须【立刻发出去】，
             *    否则会卡在"还没到提前量"里。这里直接放行并 continue 到写 UART。 */
            goto emit;
        }

        // Keep the single-frame handoff and cursor update serialized with
        // STOP/RESET. They can compensate only frames already committed.
emit:
        /* 🔴 一帧 9 字节【一次写入】—— 保证帧内无空隙 */
        {
            int w = uart_write_bytes(BLE_UART_PORT, (const char *)fp, FRAME_BYTES);
            if (w == FRAME_BYTES) {
                s_sent_frames++;
                s_play_idx++;
            } else {
                ESP_LOGE(TAG, "uart_write_bytes short: %d", w);
                xSemaphoreGive(s_lock);
                break;
            }
        }
        xSemaphoreGive(s_lock);
    }

    /* ⭐ 放水收尾遥测（一次性，⛔ 不每轮打）
     * -----------------------------------------------------------------
     * 判据只看"游标追上了池内帧数" —— 即**这一曲放完了**。
     * ⛔ 不用 elapsed 之类的量做判据（那是被观测的对象，会自证）。
     *
     * ⭐ `rate` = 实测 tick 速率 = elapsed_ticks * 1e6 / elapsed_us。
     *    ⭐ 这是最有价值的一个数：120 BPM / PPQN 960 下应读 **~1920 tick/s**。
     *       ≈1920 ⇒ 放水节奏正确；明显 >1920 ⇒ 放快了（🔴 FPGA 缓冲会积压）；
     *       明显 <1920 ⇒ 放慢了（⚠️ 会 evt_underrun）。 */
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_running && !s_feed_done_logged && s_frames > 0 && (s_play_idx >= s_frames)) {
        s_feed_done_logged = true;

        /* ⭐⭐ 【上游源头】就在这里：⭐ 此刻"这一曲放完了"是【确定的】
         * -----------------------------------------------------------------
         * ⚠️ 原来这里【只打日志】⇒ 🔴 `s_running` 一直挂着 `true`
         *    ⇒ ⭐ ① 屏上 `播完` 不可达（死代码）
         *       ⭐ ② 放完后再按 START 会被 "already running" 拒掉
         * ⭐ 所以必须【在这里】把状态收干净，⛔ 不是在别处打补丁。 */
        s_running  = false;      /* ⭐ 真的停了 ⇒ `pool_is_running()` 不再说谎 */
        s_finished = true;       /* ⭐ 通知消费方"自然放完"（⭐ 与 STOP 区分开） */
        xSemaphoreGive(s_lock);

        int64_t  done_us  = esp_timer_get_time();
        int64_t  elapsed  = done_us - s_t0_us;
        uint64_t eticks   = delta_us_to_ticks(elapsed, s_tick_inc);
        uint32_t rate     = (elapsed > 0)
                          ? (uint32_t)(eticks * 1000000ull / (uint64_t)elapsed)
                          : 0u;

        ESP_LOGI(TAG, "feed done: sent=%lu/%lu rate=%lu tick/s (expect ~1920) "
                      "elapsed=%lld ms",
                 (unsigned long)s_sent_frames, (unsigned long)s_frames,
                 (unsigned long)rate, (long long)(elapsed / 1000));
    } else {
        xSemaphoreGive(s_lock);
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

            /* 2026-10-13：把"播到哪了"推给串口屏。
             * 为什么放在这里而不是 ble_main.c：
             *   play_tick 只在本文件里维护，就近取用不用加锁跨模块传。
             * 为什么每轮都推：播放位置是【连续变化量】，
             *   hmi.c 那边按百分比做变化检测，只有整数百分比变了才真发命令
             *   => 不会刷屏（屏 115200 baud，刷不起）。
             * 为什么用 frames>0 判总长：池空时末帧 tick 没意义，传 0 让显示层退回。 */
            {
                uint32_t tot = (s_frames > 0)
                             ? (uint32_t)ev_tick(pool_peek_word(s_frames - 1)) : 0;
                hmi_set_play_pos(s_play_tick, s_t0_tick,
                                 (uint32_t)s_lead_ticks, tot, true);
            }

            /* 必须【至少 1 tick】—— `BLE_POOL_PUMP_PERIOD_MS = 2`
             * ⇒ `pdMS_TO_TICKS(2)` 在 100 Hz 下 = 0 ⇒ 忙循环 ⇒ 饿死 IDLE0。
             * 与 `task_drain` 同因，详见 ble_config.h §9b。 */
            vTaskDelay(BLE_DELAY_TICKS_AT_LEAST_1(BLE_POOL_PUMP_PERIOD_MS));
        } else {
            /* 停下来了：把位置标成无效，让屏上的进度条退回"灌谱百分比"，
             * ⛔ 不要停在一个"看起来还在播"的位置。 */
            hmi_set_play_pos(0, 0, 0, 0, false);
            vTaskDelay(BLE_DELAY_TICKS_AT_LEAST_1(10));
        }
    }
}
