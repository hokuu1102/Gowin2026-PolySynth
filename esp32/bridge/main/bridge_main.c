/*
 * bridge_main.c -- ESP32 经典蓝牙 SPP <-> UART2 透传桥
 * ============================================================================
 * 项目：FPGA2026 纯硬件实时音频合成 · ESP32 通路（模式 A）
 * 文档：files/20-代码/ESP32通路总体架构-20260922.md
 *       files/20-代码/ESP32通路交接文档-20260922.md
 *
 * 【本文件做什么】
 *   蓝牙 SPP 收到字节  ->  原样转发到 UART2（-> FPGA）
 *   UART2 收到字节     ->  原样转发到蓝牙
 *
 * ⛔ 不看内容、⛔ 不改内容、⛔ 不解析事件格式。它就是一根"无线的 USB 线"。
 *
 * 【为什么需要 9N 对齐 —— 本文件唯一的关键设计】
 *   FPGA 侧 rtl/w3c/evt_uart_rx.v:203 有空闲归位：
 *       idle_expired && (idx_q != 4'd0)   -> 只在一帧【中途】才触发
 *   => 帧与帧之间可以任意停顿；只有一帧【内部】被打断才会截帧。
 *   门限 = GAP_BYTES(16) 个字节时间：
 *       1 Mbps   -> 160 us
 *       115200   -> 1.39 ms
 *
 *   而 RFCOMM 是【字节流】，不保留 write() 边界 =>
 *   PC 的一次 write(9 字节) 到本机可能变成两次回调，
 *   中间隔一个任务调度周期（可达 ms 级）=> 远超门限 => 必然截帧。
 *
 *   => 所以：写 UART 的字节数【恒为 9 的整数倍】，余数留到下次。
 *      且块大小也必须是 9N（1024 不是 9 的倍数：1024 = 9*113 + 7；
 *      1026 = 9*114 才是对的）。
 *
 *   注意：这只数字节数，从不看字节内容 => 仍然算透传。
 *
 * 【为什么用 VFS】
 *   esp_spp_vfs_register() 把 SPP 暴露成一个文件描述符，
 *   读写就跟普通串口一样 => 不用手写 GATT/RFCOMM 逻辑。
 * ============================================================================
 */

#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"

#include "esp_log.h"
#include "esp_err.h"
#include "esp_check.h"
#include "nvs_flash.h"

#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_bt_device.h"
#include "esp_gap_bt_api.h"
#include "esp_spp_api.h"

#include "driver/uart.h"
#include "driver/gpio.h"

#include "bridge_config.h"
#include "pool.h"
#include "hmi.h"

static const char *TAG = "bridge";

/* ===========================================================================
 * 可观测计数（K-106 纪律：容量有限 / 会出错的东西必须能看见）
 * ===========================================================================
 * 这些计数会在每次状态打印时输出，是回环自测的判据来源之一。
 */
static volatile uint32_t s_bt_rx_bytes   = 0;  /* 蓝牙收到的字节数 */
static volatile uint32_t s_bt_rx_dropped = 0;  /* 因中间缓冲满而丢弃的字节 */
static volatile uint32_t s_uart_tx_bytes = 0;  /* 写进 UART2 的字节数 */
static volatile uint32_t s_uart_rx_bytes = 0;  /* UART2 收到的字节数 */
static volatile uint32_t s_bt_tx_bytes   = 0;  /* 发回蓝牙的字节数 */
static volatile uint32_t s_bt_tx_failed  = 0;  /* 发蓝牙失败次数 */

/* ---- ⭐ 帧头分类相关（⚠️ 必须定义在文件前部：gatts/SPP 数据回调要用）------- */
static volatile uint32_t s_total_frames_rx = 0;  /* ⭐ 收到的总数帧数 */
static volatile uint32_t s_reset_frames_rx = 0;  /* 复位标记帧数 */
static volatile uint32_t s_unknown_frames  = 0;  /* 🔴 未知帧头帧数（应恒为 0） */
static volatile uint32_t s_song_total      = 0;  /* ⭐ 曲谱总事件数（0=未知） */

/* ===========================================================================
 * 9N 对齐缓冲
 * ===========================================================================
 * 只做"凑够 9 的整数倍才吐"这一件事。
 *
 * 设计成环形缓冲 + 只读/只写各一个任务，避免加锁：
 *   - 生产者：SPP 回调（或 SPP 读任务）调用 bridge_feed()
 *   - 消费者：UART 排空任务调用 bridge_take_aligned()
 *
 * 容量刻意取 9 的整数倍（1026 = 9*114），这样即使一次取满整块，
 * 块边界也天然落在帧边界上。
 */
#define ALIGN_BUF_CAP  (FRAME_BYTES * 114)   /* 1026 B */

static uint8_t  s_buf[ALIGN_BUF_CAP];
static size_t   s_head = 0;   /* 写指针 */
static size_t   s_tail = 0;   /* 读指针 */
static size_t   s_cnt  = 0;   /* 当前字节数 */

/* 单生产者单消费者，用临界区保护（可选，见 s_use_critical） */
static portMUX_TYPE s_buf_mux = portMUX_INITIALIZER_UNLOCKED;

/* SPP 连接句柄（0 表示未连接） */
static uint32_t s_spp_handle = 0;
static volatile bool s_spp_connected = false;

/* ===========================================================================
 * 环形缓冲（只做搬运，不解析）
 * =========================================================================== */
/*
 * 剩余空间（⭐ 目前只用于状态打印；保留以便将来做背压判断）。
 * ⚠️ 加了 __attribute__((unused)) 而不是删掉 —— 因为它是 pool.c / 将来的
 *    背压逻辑都可能用到的查询口，删了反而容易漏。
 */
__attribute__((unused))
static size_t bridge_free(void)
{
    return ALIGN_BUF_CAP - s_cnt;
}

/* 写入 n 字节；返回实际写入数（满时少于 n） */
static size_t bridge_push(const uint8_t *src, size_t n)
{
    size_t wrote = 0;

    portENTER_CRITICAL(&s_buf_mux);
    while (wrote < n && s_cnt < ALIGN_BUF_CAP) {
        s_buf[s_head] = src[wrote];
        s_head = (s_head + 1) % ALIGN_BUF_CAP;
        s_cnt++;
        wrote++;
    }
    portEXIT_CRITICAL(&s_buf_mux);

    return wrote;
}

/*
 * 取出【9 的整数倍】个字节。
 *
 * 这是本文件的核心：只有当缓冲里有 >= 9 字节时，才取出
 * floor(cnt / 9) * 9 字节 —— 保证取出的永远是完整帧，
 * 且取出的块大小也是 9N。
 *
 * 返回实际取出的字节数（恒为 9 的整数倍；0 表示还不够一帧）。
 */
static size_t bridge_take_aligned(uint8_t *dst, size_t dst_cap)
{
    size_t take = 0;

    portENTER_CRITICAL(&s_buf_mux);
    {
        size_t aligned = (s_cnt / FRAME_BYTES) * FRAME_BYTES;
        if (aligned > dst_cap) {
            /* 目标缓冲装不下整个对齐量 -> 只取能装下的最大 9N */
            aligned = (dst_cap / FRAME_BYTES) * FRAME_BYTES;
        }
        for (take = 0; take < aligned; take++) {
            dst[take] = s_buf[s_tail];
            s_tail = (s_tail + 1) % ALIGN_BUF_CAP;
            s_cnt--;
        }
    }
    portEXIT_CRITICAL(&s_buf_mux);

    return take;
}

/* ===========================================================================
 * UART2 初始化 —— 帧内 9 字节必须连续，所以 TX 缓冲要够大
 * =========================================================================== */
static esp_err_t uart2_init(void)
{
    const uart_config_t cfg = {
        .baud_rate  = BRIDGE_BAUD,
        .data_bits  = UART_DATA_8_BITS,
        .parity     = UART_PARITY_DISABLE,
        .stop_bits  = UART_STOP_BITS_1,
        .flow_ctrl  = UART_HW_FLOWCTRL_DISABLE,   /* 无流控（冻结接口） */
        .source_clk = UART_SCLK_DEFAULT,
    };

    ESP_RETURN_ON_ERROR(uart_driver_install(BRIDGE_UART_PORT,
                                            BRIDGE_UART_RX_BUF,
                                            BRIDGE_UART_TX_BUF,
                                            0, NULL, 0),
                        TAG, "uart_driver_install");
    ESP_RETURN_ON_ERROR(uart_param_config(BRIDGE_UART_PORT, &cfg),
                        TAG, "uart_param_config");
    ESP_RETURN_ON_ERROR(uart_set_pin(BRIDGE_UART_PORT,
                                     BRIDGE_PIN_UART_TX,
                                     BRIDGE_PIN_UART_RX,
                                     UART_PIN_NO_CHANGE,
                                     UART_PIN_NO_CHANGE),
                        TAG, "uart_set_pin");
    /* 撤销上电后的默认引脚分配（否则 GPIO 上会同时挂两份信号） */
    ESP_RETURN_ON_ERROR(uart_set_pin(BRIDGE_LOG_UART_PORT,
                                     BRIDGE_PIN_LOG_TX,
                                     BRIDGE_PIN_LOG_RX,
                                     UART_PIN_NO_CHANGE,
                                     UART_PIN_NO_CHANGE),
                        TAG, "uart_set_pin(log)");

    ESP_LOGI(TAG, "UART%d ready: baud=%d tx=GPIO%d rx=GPIO%d",
             BRIDGE_UART_PORT, BRIDGE_BAUD, BRIDGE_PIN_UART_TX, BRIDGE_PIN_UART_RX);
    return ESP_OK;
}

/* ===========================================================================
 * ⭐ 模式 B 的控制通道（⚠️ 只在模式 B 用）
 * ===========================================================================
 * 问题：整曲灌完之后，总得有人告诉 ESP32"开始放水"。而冻结接口里
 *       ⛔ 没有"开始播放"这种命令（🔴 这是协议层的一个缺口，
 *       见 FPGA 侧对接清单 §五 问题 1）。
 *
 * 做法：控制命令走【带外】—— 用一个不会与事件帧混淆的短前缀。
 *       控制字节【永远不进水池】，所以 ⛔ 不会污染事件流。
 *
 *   ESC 'S'  -> start：开始放水
 *   ESC 'D'  -> done ：声明"整曲灌完"
 *   ESC 'R'  -> reset：清空水池
 *   ESC '?'  -> stats：回一段状态文本（走蓝牙回传，便于台面确认）
 *
 * ⚠️ 为什么用 ESC(0x1B) 前缀：
 *       事件帧恒以 0xA5 开头，0x1B 不可能出现在帧首 =>
 *       只要我们【按字节状态机】扫描，就能安全地区分控制与数据。
 *       ⚠️ 代价：数据流里若【真的】出现 0x1B，会被误判。
 *       ⇒ 所以发送端必须确保：0x1B 只在控制命令里出现。
 *       ⭐ 若做不到，就改用"暂停一段时间 + 特定序列"的方案，
 *         或者干脆让 PC 侧发完就断开 SPP（断连 = 开始）。
 */
#define CTRL_ESC   0x1B
#define CTRL_START 'S'
#define CTRL_DONE  'D'
#define CTRL_RESET 'R'
#define CTRL_STATS '?'

/* 状态机：0=正常数据，1=刚见到 ESC，正在等命令字节 */
static uint8_t s_ctrl_state = 0;

static void send_status_text(const char *txt)
{
    if (s_spp_connected && s_spp_handle != 0) {
        esp_spp_write(s_spp_handle, (int)strlen(txt), (uint8_t *)txt);
    }
}

static void ctrl_dispatch(uint8_t cmd)
{
    switch (cmd) {
    case CTRL_START:
        pool_start();
        break;
    case CTRL_DONE:
        pool_mark_done();
        break;
    case CTRL_RESET:
        pool_reset();
        break;
    case CTRL_STATS: {
        pool_stats_t ps;
        char buf[192];
        pool_stats(&ps);
        snprintf(buf, sizeof(buf),
                 "STAT frames=%u/%u sent=%u ovf=%u tempo=%u late=%u inc=%u\r\n",
                 (unsigned)ps.frames, (unsigned)ps.capacity_frames,
                 (unsigned)ps.sent_frames, (unsigned)ps.overflow_frames,
                 (unsigned)ps.tempo_events, (unsigned)ps.late_ticks_max,
                 (unsigned)ps.tick_inc);
        send_status_text(buf);
        break;
    }
    default:
        ESP_LOGW(TAG, "unknown control cmd 0x%02X", cmd);
        break;
    }
}

/*
 * 按字节过滤控制命令。
 * 返回：本次应【继续当作数据】的字节区间 —— 这里用回调式处理更简单，
 *       所以直接写成"逐字节分类 + 分别投递"。
 */
/*
 * 按字节过滤控制命令（⭐ 只在模式 B 用）。
 *
 * ⚠️ 模式 A 下本函数不被调用 ⇒ 会报 -Wunused-function。
 *    用 __attribute__((unused)) 标注，⛔ 不删 —— 因为模式 B 要用，
 *    而两模式共用一份源码（⭐ 切换靠 bridge_config.h 的 BRIDGE_MODE）。
 */
__attribute__((unused))
static void feed_filtered(const uint8_t *p, size_t n)
{
    size_t run_start = 0;      /* 当前连续数据段的起点 */
    size_t i;

    for (i = 0; i < n; i++) {
        uint8_t b = p[i];

        if (s_ctrl_state == 1) {
            /* 上一个字节是 ESC —— 这个字节是命令 */
            ctrl_dispatch(b);
            s_ctrl_state = 0;
            run_start = i + 1;         /* 命令字节本身也不当数据 */
            continue;
        }

        if (b == CTRL_ESC) {
            /* 先冲掉 ESC 之前的数据段 */
            if (i > run_start) {
                size_t wrote = bridge_push(p + run_start, i - run_start);
                if (wrote < i - run_start) {
                    s_bt_rx_dropped += (uint32_t)((i - run_start) - wrote);
                }
            }
            s_ctrl_state = 1;
            run_start = i + 1;
            continue;
        }
    }

    /* 尾段 */
    if (n > run_start) {
        size_t wrote = bridge_push(p + run_start, n - run_start);
        if (wrote < n - run_start) {
            s_bt_rx_dropped += (uint32_t)((n - run_start) - wrote);
        }
    }
}
/* ===========================================================================
 * SPP 回调（纯事件处理，⛔ 不做任何解析）
 * =========================================================================== */
static void spp_cb(esp_spp_cb_event_t event, esp_spp_cb_param_t *param)
{
    switch (event) {
    case ESP_SPP_INIT_EVT:
        ESP_LOGI(TAG, "SPP init -> start server");
        esp_spp_start_srv(ESP_SPP_SEC_NONE, ESP_SPP_ROLE_SLAVE, 0, BRIDGE_BT_NAME);
        break;

    case ESP_SPP_START_EVT:
        ESP_LOGI(TAG, "SPP server up, scn=%d, name=%s", param->start.scn, BRIDGE_BT_NAME);
        /* 便于手机/PC 找到：设置可被发现 */
        esp_bt_gap_set_scan_mode(ESP_BT_CONNECTABLE, ESP_BT_GENERAL_DISCOVERABLE);
        break;

    case ESP_SPP_SRV_OPEN_EVT:
        s_spp_handle = param->srv_open.handle;
        s_spp_connected = true;
        ESP_LOGI(TAG, "SPP CONNECTED handle=%lu", (unsigned long)s_spp_handle);
        /* ⭐ 屏上 t3：蓝牙已连接 */
        hmi_set_bt_connected(true);
        break;

    case ESP_SPP_CLOSE_EVT:
        s_spp_connected = false;
        s_spp_handle = 0;
        ESP_LOGW(TAG, "SPP CLOSED");
        /* ⭐ 屏上 t3：蓝牙断开；⭐ 同时把状态字切到"断链"
         *    ⚠️ 这正是模式 B 的核心卖点（断链容忍）—— ⭐ 必须让人【看得见】 */
        hmi_set_bt_connected(false);
        hmi_set_state(HMI_ST_LINK_LOST);
        break;

    /* 收数据：丢进对齐缓冲；由下游任务决定是"直接吐 UART"还是"攒进水池" */
    case ESP_SPP_DATA_IND_EVT: {
        size_t n = param->data_ind.len;
        const uint8_t *p = param->data_ind.data;

        s_bt_rx_bytes += n;

        /* ⭐ 屏上状态字：一收到数据就进"灌谱中" */
        hmi_set_state(HMI_ST_LOADING);

#if BRIDGE_MODE == BRIDGE_MODE_B_POOL
        /* ⭐ 模式 B：先过控制字节过滤器，纯数据才进对齐缓冲 */
        feed_filtered(p, n);
#else
        /* ⭐ 模式 A：无控制通道，原样进对齐缓冲 */
        {
            size_t wrote = bridge_push(p, n);
            if (wrote < n) {
                /* 缓冲满：发送端不受限速时才会发生。必须可见。 */
                s_bt_rx_dropped += (uint32_t)(n - wrote);
                ESP_LOGE(TAG, "ALIGN BUF FULL, dropped %u of %u bytes (total dropped=%lu)",
                         (unsigned)(n - wrote), (unsigned)n,
                         (unsigned long)s_bt_rx_dropped);
                /* ⭐ 屏上状态字：溢出必须显眼（K-106 纪律） */
                hmi_set_state(HMI_ST_OVERFLOW);
            }
        }
#endif
        /* ⭐ 事件计数：已收字节 / 9 = 已收事件数（⭐ 与守恒等式同口径） */
        /* ⭐ 屏上事件计数（⭐ 与守恒等式同口径）
         * 🔴 修了真 bug（2026-09-23）：原来【硬编码 total=0】
         *    ⇒ 屏上一直 `4820/0`、进度条永远 0。总数改由【总数帧】提供。 */
        hmi_set_events((uint32_t)(s_bt_rx_bytes / FRAME_BYTES), s_song_total);
        break;
    }

    case ESP_SPP_WRITE_EVT:
        if (!param->write.cong) {
            s_bt_tx_bytes += param->write.len;
        }
        break;

    case ESP_SPP_CONG_EVT:
        break;

    default:
        break;
    }
}

/* ===========================================================================
 * 任务 1：对齐排空
 * ===========================================================================
 *  ⭐ 模式 A：对齐缓冲 -> UART2（直接透传）
 *  ⭐ 模式 B：对齐缓冲 -> 水池（再由 pool 按谱子时间放水）
 *
 * 两种模式都保证：交给下游的永远是【完整帧】。
 */
/* ===========================================================================
 * ⭐⭐⭐ 帧头分类 + 过滤（⭐ 与 BLE 版同构，⛔ 两版行为必须一致）
 * ===========================================================================
 *   帧头 0xA5 且非全 0xA5  ⇒ ⭐ 事件帧 ⇒ ✅ 转发
 *   帧头 0xA5 且全 9 字节 A5 ⇒ ⭐ 复位标记 ⇒ ⛔ 丢弃
 *   帧头 0x00              ⇒ ⭐ 总数帧 ⇒ ⛔ 自己留下并解析
 *   其他                    ⇒ 🔴 未知 ⇒ ⛔ 丢弃 + 计数
 */
static bool frame_is_all_a5(const uint8_t *p)
{
    for (int i = 0; i < FRAME_BYTES; i++) {
        if (p[i] != FRAME_HDR_EVENT) {
            return false;
        }
    }
    return true;
}

static void frame_parse_total(const uint8_t *p)
{
    uint64_t v = 0;
    for (int i = 1; i < FRAME_BYTES; i++) {
        v = (v << 8) | p[i];
    }
    s_song_total = (uint32_t)v;
    s_total_frames_rx++;
    ESP_LOGI(TAG, "SONG TOTAL = %lu events", (unsigned long)s_song_total);

    /* ⭐ 立刻告诉显示层（⚠️ 否则进度条永远是 0） */
    hmi_set_events((uint32_t)(s_bt_rx_bytes / FRAME_BYTES), s_song_total);

#if BRIDGE_MODE == BRIDGE_MODE_B_POOL
    /* ⭐⭐ 模式 B：把"应该收多少帧"告诉水池
     *    🔴 不给它的话，pool_mark_done() 无法发现"PC 发到一半就断了"。 */
    pool_set_expected((size_t)s_song_total);
#endif
}

/* ⭐ 逐帧过滤；原地压缩，返回【真正要转发的字节数】 */
static size_t frame_filter(uint8_t *chunk, size_t n)
{
    size_t out = 0;
    for (size_t off = 0; off + FRAME_BYTES <= n; off += FRAME_BYTES) {
        uint8_t *p = chunk + off;

        if (p[0] == FRAME_HDR_EVENT) {
            if (frame_is_all_a5(p)) {
                s_reset_frames_rx++;
                continue;
            }
            if (out != off) {
                memmove(chunk + out, p, FRAME_BYTES);
            }
            out += FRAME_BYTES;
        } else if (p[0] == FRAME_HDR_TOTAL) {
            frame_parse_total(p);
        } else {
            s_unknown_frames++;
            ESP_LOGW(TAG, "unknown frame hdr 0x%02X, dropped (total=%lu)",
                     p[0], (unsigned long)s_unknown_frames);
        }
    }
    return out;
}

static void task_drain_to_uart(void *arg)
{
    static uint8_t chunk[ALIGN_BUF_CAP];
    (void)arg;

    ESP_LOGI(TAG, "drain task started (mode=%s)",
#if BRIDGE_MODE == BRIDGE_MODE_B_POOL
             "B/pool"
#else
             "A/passthrough"
#endif
            );

    for (;;) {
        size_t n = bridge_take_aligned(chunk, sizeof(chunk));
        if (n == 0) {
            /* 还不够一帧 —— 等新数据 */
            vTaskDelay(pdMS_TO_TICKS(1));
            continue;
        }
        /* n 恒为 9 的整数倍 */

        /* ⭐⭐⭐ 先过滤：摘掉复位标记/未知帧，总数帧自己留下 */
        size_t fwd = frame_filter(chunk, n);
        if (fwd == 0) {
            continue;
        }

#if BRIDGE_MODE == BRIDGE_MODE_B_POOL
        /* ⭐ 模式 B：攒进水池，⛔ 不直接写 UART */
        pool_feed(chunk, fwd);
#else
        /* ⭐ 模式 A：一次性写 UART，帧内无空隙 */
        int written = uart_write_bytes(BRIDGE_UART_PORT, (const char *)chunk, fwd);
        if (written > 0) {
            s_uart_tx_bytes += written;
        }
#endif
    }
}

/* ===========================================================================
 * 任务 2：UART2 -> 蓝牙（反向通路，判据 5）
 * =========================================================================== */
static void task_uart_to_bt(void *arg)
{
    static uint8_t buf[512];
    (void)arg;

    ESP_LOGI(TAG, "uart->bt task started");

    for (;;) {
        int n = uart_read_bytes(BRIDGE_UART_PORT, buf, sizeof(buf),
                                pdMS_TO_TICKS(20));
        if (n <= 0) {
            continue;
        }
        s_uart_rx_bytes += n;

        if (!s_spp_connected || s_spp_handle == 0) {
            continue;   /* 没连接就丢（反向通路非本轮重点） */
        }

        /*
         * 分块发，避免单次过大触发拥塞。
         * 注意：SPP 官方建议在看到 ESP_SPP_WRITE_EVT 且 cong==false 后再发下一次；
         * 这里用保守的固定块 + 短延时，够本项目的低速率反向用。
         */
        size_t off = 0;
        while (off < (size_t)n) {
            size_t seg = (n - off > BRIDGE_BT_TX_CHUNK) ? BRIDGE_BT_TX_CHUNK : (n - off);
            esp_err_t err = esp_spp_write(s_spp_handle, seg, buf + off);
            if (err != ESP_OK) {
                s_bt_tx_failed++;
                break;
            }
            off += seg;
            vTaskDelay(pdMS_TO_TICKS(BRIDGE_BT_TX_GAP_MS));
        }
    }
}

/* ===========================================================================
 * 任务 3：状态打印（可观测性 —— 台面调测靠它）
 * =========================================================================== */
static void task_status(void *arg)
{
    (void)arg;
#if BRIDGE_MODE != BRIDGE_MODE_B_POOL
    /* ⚠️ 这两个只在模式 A 的打印里用（模式 B 打的是池水位） */
    uint32_t last_rx = 0, last_tx = 0;
#endif

    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(BRIDGE_STATUS_PERIOD_MS));

        uint32_t rx = s_bt_rx_bytes;
#if BRIDGE_MODE != BRIDGE_MODE_B_POOL
        uint32_t tx = s_uart_tx_bytes;
#endif
#if BRIDGE_MODE == BRIDGE_MODE_B_POOL
        pool_stats_t ps;
        pool_stats(&ps);
        ESP_LOGI(TAG,
                 "bt_rx=%lu | pool=%u/%u (%s) sent=%lu | ovf=%lu tempo=%lu late_max=%lu | %s",
                 (unsigned long)rx,
                 (unsigned)ps.frames, (unsigned)ps.capacity_frames,
                 ps.in_psram ? "PSRAM" : "DRAM",
                 (unsigned long)ps.sent_frames,
                 (unsigned long)ps.overflow_frames,
                 (unsigned long)ps.tempo_events,
                 (unsigned long)ps.late_ticks_max,
                 s_spp_connected ? "CONN" : "----");
#else
        ESP_LOGI(TAG,
                 "bt_rx=%lu uart_tx=%lu | d_bt_rx=%lu d_uart_tx=%lu | "
                 "uart_rx=%lu bt_tx=%lu | dropped=%lu bt_tx_fail=%lu | buf=%u/%u %s",
                 (unsigned long)rx, (unsigned long)tx,
                 (unsigned long)(rx - last_rx), (unsigned long)(tx - last_tx),
                 (unsigned long)s_uart_rx_bytes, (unsigned long)s_bt_tx_bytes,
                 (unsigned long)s_bt_rx_dropped, (unsigned long)s_bt_tx_failed,
                 (unsigned)s_cnt, (unsigned)ALIGN_BUF_CAP,
                 s_spp_connected ? "CONN" : "----");
#endif
#if BRIDGE_MODE != BRIDGE_MODE_B_POOL
        last_rx = rx;
        last_tx = tx;
#endif
    }
}

/* ===========================================================================
 * 入口
 * =========================================================================== */
void app_main(void)
{
    ESP_LOGI(TAG, "=== ESP32 SPP<->UART bridge ===");
    ESP_LOGI(TAG, "mode = %s",
#if BRIDGE_MODE == BRIDGE_MODE_B_POOL
             "B / POOL (buffer whole score, self-paced)"
#else
             "A / PASSTHROUGH (relay as they arrive)"
#endif
            );
    ESP_LOGI(TAG, "baud=%d  uart=UART%d tx=GPIO%d rx=GPIO%d  frame=%dB",
             BRIDGE_BAUD, BRIDGE_UART_PORT,
             BRIDGE_PIN_UART_TX, BRIDGE_PIN_UART_RX, FRAME_BYTES);
    ESP_LOGI(TAG, "align buf=%d bytes (= %d frames), block=%d frames",
             ALIGN_BUF_CAP, ALIGN_BUF_CAP / FRAME_BYTES, BRIDGE_UART_TX_BUF / FRAME_BYTES);

    /* NVS 是蓝牙栈的要求 */
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    /*
     * 控制器模式说明（⭐ 这里踩过一个会【静默失效】的坑）：
     *
     *   🔴 `sdkconfig.defaults` 里【必须】显式设
     *        CONFIG_BTDM_CTRL_MODE_BR_EDR_ONLY=y
     *      ⚠️ 不设的话，`BTDM_CTRL_MODE` 这个 choice 默认取【第一个选项】
     *      ⇒ 默认是 `BLE_ONLY` ⇒ 🔴 **控制器层面根本没有 BR/EDR**。
     *      ⚠️ 而那时 `CONFIG_BT_CLASSIC_ENABLED=y` / `BT_SPP_ENABLED=y`
     *         **仍然显示是开的**（主机栈开了，控制器没有）⇒ 编译不报错，
     *         烧上去**设备搜不到、SPP 连不上**。
     *
     *   ⇒ 现在编译期已定为 BR_EDR_ONLY ⇒ 无需在运行时释放 BLE 内存
     *     （`mem_release(ESP_BT_MODE_BLE)` 在 BR_EDR_ONLY 下只走 ROM 释放，
     *       而且 note 里写明"后续可能升级控制器模式就不要调用"）。
     *     ⚠️ 所以这里【只在 BTDM 双模配置下】才释放 BLE 那半边。
     */
#if defined(CONFIG_BTDM_CTRL_MODE_BTDM)
    ESP_ERROR_CHECK(esp_bt_controller_mem_release(ESP_BT_MODE_BLE));
    ESP_LOGW(TAG, "BTDM dual-mode build: released BLE controller memory");
#endif

    esp_bt_controller_config_t bt_cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_bt_controller_init(&bt_cfg));
    ESP_ERROR_CHECK(esp_bt_controller_enable(ESP_BT_MODE_CLASSIC_BT));
    ESP_ERROR_CHECK(esp_bluedroid_init());
    ESP_ERROR_CHECK(esp_bluedroid_enable());

    /* 设备名 —— 手机/PC 靠它认设备 */
    ESP_ERROR_CHECK(esp_bt_gap_set_device_name(BRIDGE_BT_NAME));

    ESP_ERROR_CHECK(uart2_init());

    /* ⭐ 串口屏（UART1）—— ⚠️ 放在 SPP 初始化之后：
     *    hmi_init 里要等屏回 0x88（最多 2 s），⛔ 不该和蓝牙抢启动时间 */
    hmi_init();

    /* SPP 用 VFS 模式：拿到文件描述符，读写像串口 */
    ESP_ERROR_CHECK(esp_spp_register_callback(spp_cb));
    esp_spp_cfg_t spp_cfg = {
        .mode = ESP_SPP_MODE_CB,       /* 回调模式；VFS 见下方说明 */
        .enable_l2cap_ertm = true,     /* 增强重传模式，提高可靠性 */
        .tx_buffer_size = 0,
    };
    ESP_ERROR_CHECK(esp_spp_enhanced_init(&spp_cfg));

    xTaskCreate(task_drain_to_uart, "drain", 4096, NULL, BRIDGE_TASK_PRIO_DRAIN, NULL);
    xTaskCreate(task_uart_to_bt,    "u2bt",  4096, NULL, BRIDGE_TASK_PRIO_UART_RX, NULL);
    xTaskCreate(task_status,        "stat",  3072, NULL, BRIDGE_TASK_PRIO_STATUS, NULL);

#if BRIDGE_MODE == BRIDGE_MODE_B_POOL
    pool_reset();
    xTaskCreate(task_pool_pump,     "pump",  4096, NULL, BRIDGE_TASK_PRIO_DRAIN, NULL);
    ESP_LOGW(TAG, "MODE B (pool): feed whole score, then send control byte to start.");
#else
    ESP_LOGI(TAG, "MODE A (passthrough): relay bytes as they arrive.");
#endif

    ESP_LOGI(TAG, "ready. pair from PC/phone and open the SPP serial port.");
}
