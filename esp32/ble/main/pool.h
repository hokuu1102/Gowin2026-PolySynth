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
    uint32_t tick_clamped_cnt;  /* tick 限流截断次数（⚠️ 大 = 老是落后） */
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

/* 放水推进（由 task_pool_pump 周期调用；也可手动调）。 */
void   pool_pump(void);

/* 状态查询 */
bool   pool_is_running(void);
size_t pool_frames(void);
void   pool_stats(pool_stats_t *out);

/* 窥探一帧的事件字（大端 8 字节 -> 64 bit）。 */
uint64_t pool_peek_word(size_t idx);

/* FreeRTOS 任务入口 */
void   task_pool_pump(void *arg);

#ifdef __cplusplus
}
#endif

#endif /* POOL_H */
