/*
 * pool.h -- 模式 B：二级水池（缓存整曲 + 自己按谱子时间限速放水）
 * ============================================================================
 * 见 pool.c 顶部的设计说明。
 * ============================================================================
 */
#ifndef POOL_H
#define POOL_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    size_t   frames;            /* 池内已收帧数 */
    size_t   capacity_frames;   /* 池容量（帧，⭐ 实际拿到的） */
    size_t   capacity_bytes;    /* 池容量（字节，⭐ 实际拿到的） */
    bool     in_psram;          /* ⭐ 池是否落在 PSRAM（false = 退化到内部 DRAM） */
    uint32_t sent_frames;       /* 已写 UART 的帧数 */
    uint32_t overflow_frames;   /* 池满丢帧总数（⚠️ 必须为 0） */
    uint32_t tempo_events;      /* 已应用换速次数 */
    uint32_t late_ticks_max;    /* 最大落后（tick）—— "喂不饱"的量化 */
    uint32_t tick_inc;          /* 当前 tick_inc */
    bool     running;
    bool     done;              /* 发送端是否已宣布灌完 */

    /* ⭐⭐ 2026-09-23 新增（服务"看得见"） */
    uint32_t expected_frames;   /* ⭐ 应该收多少帧（0 = 未知） */
    uint32_t total_mismatch;    /* 🔴 实收与应到不符的次数（应恒为 0） */
    uint32_t tick_clamped_cnt;  /* tick 限流截断次数（大 = 老是落后） */

    /* ---- 播放位置（2026-10-13 新增，供 PC / 串口屏显示"播到哪了"）----
     *
     * 为什么需要它：`sent_frames` 只是"已喂给 FPGA 的帧数"，
     *   而放水纪律是「应发到 tick = t0_tick + elapsed - LEAD_TICKS」
     *   => 起播后 sent 很快冲到接近满，而 FPGA 还要再等约 10.4 秒才出声。
     *   => 拿 sent/total 当播放进度，游标会瞬间跑到最右边，时间轴必然对不上。
     *
     * 本组语义（都是音乐 tick，与谱面 tick 同量纲）：
     *   play_tick  = 此刻应该已经播到的谱面位置 = t0_tick + elapsed
     *   t0_tick    = 起播锚点在本曲里的位置
     *   lead_ticks = 提前量（BLE_POOL_LEAD_TICKS）
     *
     * 消费方算法：
     *   heard_tick = play_tick - t0_tick - lead_ticks   （还没出声时 <= 0）
     *   进度 = heard_tick / 本曲总 tick
     *
     * 注意：这是"主动放水的时间基准"，不是"FPGA 真的放到哪了" ——
     *   后者 FPGA 不回传，拿不到。两者理论上同步，late_ticks_max 是它的监控。
     */
    uint32_t play_tick;
    uint32_t t0_tick;
    uint32_t lead_ticks;
    uint32_t total_tick;        /* 本曲总长（末帧 tick）—— 播放进度的分母 */
    uint8_t  pos_valid;         /* 1 = 上面几个值有效（正在放水） */
} pool_stats_t;

/* 复位水池（清空、停表）。每次新曲子前调用。 */
void   pool_reset(void);

/* 灌入帧对齐的字节（长度必须是 9 的整数倍）。返回实际接收的字节数。 */
size_t pool_feed(const uint8_t *data, size_t n);

/* ⭐⭐ 告诉水池"应该收多少帧"（来自协议的总数帧；0 = 未知，则不校验）
 * 🔴 不设它的话，`pool_mark_done()` 无法发现"发送端发到一半就断了"。 */
void   pool_set_expected(size_t frames);

/* 声明"整曲灌完"。 */
void   pool_mark_done(void);

/* 开始放水（谱面时间 0 对齐到当下）。 */
void   pool_start(void);

/* ⭐ 停止放水（2026-09-30 新增）—— 保留池内容与进度，可再 `pool_start()`？ */
/*    ⚠️ 注意：`pool_start()` 会把游标重置到 0（从头播），
 *      所以 stop 后再 start = 【从头重播】，⛔ 不是续播。 */
void   pool_stop(void);

/* 状态查询 */
bool   pool_is_running(void);

/* ⭐⭐ 取走"这一曲【自然放完】"事件（⭐ 取走即清零 ⇒ 一次性，⛔ 不重复上报）
 * ---------------------------------------------------------------------------
 * ⭐ 与 `pool_stop()`（人为停）区分开：⭐ 只有"游标追上了池内帧数"才算本事件。
 * ⚠️ 消费方是**轮询**的 ⇒ ⭐ 必须用 take 语义，⛔ 不能用"读一个 bool"
 *    （否则每轮都上报一次）。 */
bool   pool_take_finished(void);
size_t pool_frames(void);
/* ⭐ 已放出的帧数（2026-09-30 新增）—— 给"起播触发"打日志用。 */
uint32_t pool_frames_sent(void);
void   pool_stats(pool_stats_t *out);

/* ⭐ 起播触发任务（2026-09-30 新增；⭐ 定义在 `ble_main.c`，见 ble_config.h §9c） */
void   task_start_trigger(void *arg);

/* 放水推进（由 task_pool_pump 周期调用；也可手动调）。 */
void   pool_pump(void);

/* 窥探一帧的事件字（大端 8 字节 -> 64 bit）。 */
uint64_t pool_peek_word(size_t idx);

/* FreeRTOS 任务入口 */
void   task_pool_pump(void *arg);

#ifdef __cplusplus
}
#endif

#endif /* POOL_H */
