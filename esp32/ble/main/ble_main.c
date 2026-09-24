/*
 * ble_main.c -- ESP32-S3 BLE <-> UART 透传桥（⭐ S3 / BLE 版）
 * ============================================================================
 * 项目：FPGA2026 · ESP32 通路
 * 文档：files/20-代码/ESP32通路总体架构-20260922.md
 *       files/20-代码/FPGA侧对接清单-ESP32通路-20260922.md
 *
 * 【为什么有这一版】
 *   ⚠️ 初代 ESP32（有经典蓝牙 SPP）带 PSRAM 的开发板买不到，
 *   而手上那块 **ESP32-S3 有 PSRAM** ⇒ 用 S3 走 BLE 换大水池。
 *   🔴 代价：**BLE 在 PC 上不是 COM 口** ⇒ `evt2uart.py` 不能直接用。
 *
 * 【和 SPP 版的共同点（⭐ 这些是通路的核心，⛔ 两边必须一致）】
 *   ① 帧 = 9 字节（0xA5 + 8 字节大端事件）
 *   ② 🔴 **写 UART 恒为 9N 字节**（余数留到下次）—— 防帧被切分
 *   ③ 🔴 **一帧 9 字节一次写入 UART**
 *   ④ 复位序列 = 9 的整数倍（36 字节）
 *   ⑤ ⛔ 不解析事件内容（模式 A）
 *
 * 【⭐ 那条 9N 纪律为什么关键（两边一样）】
 *   FPGA 侧 rtl/w3c/evt_uart_rx.v:203 的空闲归位【只在帧中途】触发：
 *       idle_expired && (idx_q != 4'd0)
 *   ⇒ 帧间可任意停顿；🔴 只有一帧【内部】被打断才截帧。
 *   1 Mbps 下门限 = 16 字节时间 = 160 µs。
 *   ⚠️ 而 BLE 的数据是**按 ATT 包投递**的：一个 9 字节帧可能被切成两个包
 *      ⇒ 中间隔一个连接间隔（7.5~30 ms）⇒ 🔴 远超 160 µs ⇒ 必然截帧。
 *   ⇒ ⭐ 9N 对齐把"写进 UART 的永远凑成完整帧"这件事保证住。
 * ============================================================================
 */

#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "esp_log.h"
#include "esp_err.h"
#include "esp_check.h"
#include "nvs_flash.h"

#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_bt_device.h"
#include "esp_gap_ble_api.h"
#include "esp_gatts_api.h"
#include "esp_gatt_common_api.h"

#include "driver/uart.h"
#include "driver/gpio.h"

#include "esp_timer.h"

#include "ble_config.h"
#include "gatt_svc.h"
#include "pool.h"
#include "hmi.h"

static const char *TAG = "blebridge";

/* ===========================================================================
 * 可观测计数（K-106：容量有限/会出错的东西必须看得见）
 * =========================================================================== */
static volatile uint32_t s_ble_rx_bytes   = 0;
static volatile uint32_t s_ble_rx_dropped = 0;
static volatile uint32_t s_uart_tx_bytes  = 0;
static volatile uint32_t s_uart_rx_bytes  = 0;
static volatile uint32_t s_ble_tx_bytes   = 0;
static volatile uint32_t s_ble_tx_failed  = 0;

/* ---- ⭐ 帧头分类相关（⭐ 详见下面 frame_filter 的说明）--------------------
 * ⚠️ 必须定义在这里：⭐ gatts 回调（数据入口）就要读 s_song_total，
 *    而它出现在文件前部 ⇒ 若把定义放在 frame_filter 附近会【undeclared】。
 */
static volatile uint32_t s_total_frames_rx = 0;   /* ⭐ 收到的总数帧数 */
static volatile uint32_t s_reset_frames_rx = 0;   /* 复位标记帧数 */
static volatile uint32_t s_unknown_frames  = 0;   /* 🔴 未知帧头帧数 */
static volatile uint32_t s_song_total      = 0;   /* ⭐ 曲谱总事件数（0=未知） */

/* ===========================================================================
 * 9N 对齐缓冲（⭐ 核心）
 * ===========================================================================
 * 生产者：GATT 写回调（BLE 包到达）
 * 消费者：排空任务 -> UART（模式 A）或 -> 水池（模式 B）
 *
 * ⚠️ 容量取 9 的整数倍（1026 = 9×114），使块边界天然落在帧边界上。
 */
#define ALIGN_BUF_CAP  (FRAME_BYTES * 114)   /* 1026 B */

static uint8_t s_buf[ALIGN_BUF_CAP];
static size_t  s_head = 0, s_tail = 0, s_cnt = 0;
static portMUX_TYPE s_buf_mux = portMUX_INITIALIZER_UNLOCKED;

/* GATT 状态 */
static esp_gatt_if_t s_gatts_if  = ESP_GATT_IF_NONE;
static uint16_t s_conn_id        = 0;
static uint16_t s_mtu            = 23;    /* ⚠️ 默认；协商后更新 */
static volatile bool s_connected = false;
static bool s_adv_configured     = false;

/* 属性句柄（⭐ 由属性表创建回调填） */
static uint16_t s_handle_recv = 0;   /* 对端写这里 */
static uint16_t s_handle_noti = 0;   /* 我们 notify 这里 */
static uint16_t s_handle_cmd  = 0;
static uint16_t s_handle_stat = 0;

/* ===========================================================================
 * 环形缓冲（只搬运，⛔ 不解析）
 * =========================================================================== */
static size_t ble_buf_push(const uint8_t *src, size_t n)
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
 * ⭐ 取出【9 的整数倍】个字节 —— 本文件的灵魂。
 * 只有凑够一帧才吐，且吐出的块大小也是 9N。
 */
static size_t ble_buf_take_aligned(uint8_t *dst, size_t dst_cap)
{
    size_t take = 0;
    portENTER_CRITICAL(&s_buf_mux);
    {
        size_t aligned = (s_cnt / FRAME_BYTES) * FRAME_BYTES;
        if (aligned > dst_cap) {
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
 * UART（给 FPGA）
 * =========================================================================== */
static esp_err_t uart_fpga_init(void)
{
    const uart_config_t cfg = {
        .baud_rate  = BLE_BAUD,
        .data_bits  = UART_DATA_8_BITS,
        .parity     = UART_PARITY_DISABLE,
        .stop_bits  = UART_STOP_BITS_1,
        .flow_ctrl  = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    ESP_RETURN_ON_ERROR(
        uart_driver_install(BLE_UART_PORT, BLE_UART_RX_BUF, BLE_UART_TX_BUF, 0, NULL, 0),
        TAG, "uart_driver_install");
    ESP_RETURN_ON_ERROR(uart_param_config(BLE_UART_PORT, &cfg), TAG, "uart_param_config");
    ESP_RETURN_ON_ERROR(uart_set_pin(BLE_UART_PORT, BLE_PIN_UART_TX, BLE_PIN_UART_RX,
                                     UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE),
                        TAG, "uart_set_pin");
    /* 顺手把日志口钉到默认脚，避免 GPIO 上挂两份信号 */
    ESP_RETURN_ON_ERROR(uart_set_pin(BLE_LOG_UART_PORT, BLE_PIN_LOG_TX, BLE_PIN_LOG_RX,
                                     UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE),
                        TAG, "uart_set_pin(log)");

    ESP_LOGI(TAG, "UART%d ready: baud=%d tx=GPIO%d rx=GPIO%d",
             BLE_UART_PORT, BLE_BAUD, BLE_PIN_UART_TX, BLE_PIN_UART_RX);
    return ESP_OK;
}

/* ===========================================================================
 * BLE：广播
 * =========================================================================== */
static esp_ble_adv_params_t s_adv_params = {
    .adv_int_min        = 0x20,     /* 20 ms */
    .adv_int_max        = 0x40,     /* 40 ms */
    .adv_type           = ADV_TYPE_IND,
    .own_addr_type      = BLE_ADDR_TYPE_PUBLIC,
    .channel_map        = ADV_CHNL_ALL,
    .adv_filter_policy  = ADV_FILTER_ALLOW_SCAN_ANY_CON_ANY,
};

static void ble_start_advertising(void)
{
    esp_ble_gap_start_advertising(&s_adv_params);
}

/* GAP 回调：⭐ 广播数据配好之后才真正开始广播 */
static void gap_event_handler(esp_gap_ble_cb_event_t event,
                              esp_ble_gap_cb_param_t *param)
{
    switch (event) {
    case ESP_GAP_BLE_ADV_DATA_SET_COMPLETE_EVT:
        s_adv_configured = true;
        ESP_LOGI(TAG, "adv data set -> start advertising");
        ble_start_advertising();
        break;

    case ESP_GAP_BLE_ADV_START_COMPLETE_EVT:
        /* ⚠️ adv_start_cmpl.status 的类型是 esp_bt_status_t，
         *    ⛔ 不能和 esp_gatt_status_t 的 ESP_GATT_OK 比
         *    （实测报 -Werror=enum-compare：两种枚举不同源）。
         *    ⭐ 该类型自己的成功值是 ESP_BT_STATUS_SUCCESS。 */
        if (param->adv_start_cmpl.status != ESP_BT_STATUS_SUCCESS) {
            ESP_LOGE(TAG, "adv start failed: 0x%X", param->adv_start_cmpl.status);
        } else {
            ESP_LOGI(TAG, "advertising as \"%s\"", BLE_DEV_NAME);
        }
        break;

    default:
        break;
    }
}

/* ===========================================================================
 * GATT 事件 —— ⭐ 全工程【唯一】的 gatts 回调
 * ===========================================================================
 * ⚠️ ESP-IDF 的 esp_ble_gatts_register_callback() 是【全局】的：
 *    注册两次会互相覆盖 ⇒ 症状是"回调只触发一半"，极难查。
 *    ⇒ ⭐ 属性表在 gatt_svc.c，事件处理全在这里。
 */
static void gatts_event_handler(esp_gatts_cb_event_t event,
                                esp_gatt_if_t gatts_if,
                                esp_ble_gatts_cb_param_t *param)
{
    switch (event) {
    case ESP_GATTS_REG_EVT:
        s_gatts_if = gatts_if;
        ESP_LOGI(TAG, "GATTS registered, app_id=%d if=%d", param->reg.app_id, gatts_if);
        esp_ble_gap_set_device_name(BLE_DEV_NAME);

        /* ⭐ 先把属性表建起来（句柄要从创建回调里拿） */
        esp_ble_gatts_create_attr_tab(gatt_get_db(), gatts_if,
                                      gatt_idx_count(), 0);

        /* 再配广播数据（⭐ GAP 回调里真正启动广播） */
        {
            esp_ble_adv_data_t adv = {
                .set_scan_rsp        = false,
                .include_name        = true,
                .include_txpower     = false,
                .min_interval        = 0x06,
                .max_interval        = 0x10,
                .appearance          = 0x00,
                .manufacturer_len    = 0,
                .p_manufacturer_data = NULL,
                .service_data_len    = 0,
                .p_service_data      = NULL,
                /* ⚠️ 服务 UUID 是【16 位】（0xABF0）⇒ 长度填 2，⛔ 不是 16 */
                .service_uuid_len    = 2,
                .p_service_uuid      = (uint8_t *)&gatt_service_uuid16,
                .flag = (ESP_BLE_ADV_FLAG_GEN_DISC | ESP_BLE_ADV_FLAG_BREDR_NOT_SPT),
            };
            esp_ble_gap_config_adv_data(&adv);
        }
        break;

    case ESP_GATTS_CREAT_ATTR_TAB_EVT:
        if (param->add_attr_tab.status != ESP_GATT_OK) {
            ESP_LOGE(TAG, "create attr tab FAILED: 0x%X", param->add_attr_tab.status);
            break;
        }
        if (param->add_attr_tab.num_handle != gatt_idx_count()) {
            /* 🔴 句柄数不符 ⇒ 后面的索引全错位 ⇒ 必须当场报出来 */
            ESP_LOGE(TAG, "attr num mismatch: got %d want %d",
                     param->add_attr_tab.num_handle, gatt_idx_count());
            break;
        }
        s_handle_recv = param->add_attr_tab.handles[gatt_idx_recv()];
        s_handle_noti = param->add_attr_tab.handles[gatt_idx_noti()];
        s_handle_cmd  = param->add_attr_tab.handles[gatt_idx_cmd()];
        s_handle_stat = param->add_attr_tab.handles[gatt_idx_stat()];

        gatt_log_layout(param->add_attr_tab.handles[0], s_handle_recv,
                        s_handle_noti, s_handle_cmd, s_handle_stat);

        esp_ble_gatts_start_service(param->add_attr_tab.handles[0]);
        ESP_LOGI(TAG, "service started");
        break;

    case ESP_GATTS_CONNECT_EVT:
        s_conn_id   = param->connect.conn_id;
        s_connected = true;
        ESP_LOGI(TAG, "BLE CONNECTED conn_id=%d", s_conn_id);
        hmi_set_bt_connected(true);

        /* ⭐ 立刻请求大 MTU（⚠️ 默认 23 ⇒ 有效载荷仅 20 字节，整曲要 5200+ 包） */
        esp_ble_gatt_set_local_mtu(BLE_PREFERRED_MTU);
        break;

    case ESP_GATTS_DISCONNECT_EVT:
        s_connected = false;
        ESP_LOGW(TAG, "BLE DISCONNECTED, reason=0x%02X", param->disconnect.reason);
        /* ⭐ 屏上：蓝牙断开 + 状态字切"断链"
         *    ⚠️ 这正是模式 B 的核心卖点，⭐ 必须让人【看得见】 */
        hmi_set_bt_connected(false);
        hmi_set_state(HMI_ST_LINK_LOST);
        ble_start_advertising();          /* 重连 */
        break;

    case ESP_GATTS_MTU_EVT:
        s_mtu = param->mtu.mtu;
        ESP_LOGI(TAG, "MTU negotiated = %d (payload %d)", s_mtu, s_mtu - 3);
        break;

    /*
     * ⭐ 收到对端写数据 —— 这是"数据入口"
     * ⚠️ 注意：这里【只入缓冲区】，真正的转发由排空任务做。
     *    ⛔ 不要在回调里做重活（官方 SPP 示例明确警告会阻塞蓝牙栈）。
     */
    case ESP_GATTS_WRITE_EVT: {
        uint16_t h = param->write.handle;
        uint16_t len = param->write.len;
        const uint8_t *val = param->write.value;

        if (h == s_handle_recv || h == s_handle_cmd) {
            s_ble_rx_bytes += len;
            hmi_set_state(HMI_ST_LOADING);

            size_t wrote = ble_buf_push(val, len);
            if (wrote < len) {
                s_ble_rx_dropped += (uint32_t)(len - wrote);
                ESP_LOGE(TAG, "ALIGN BUF FULL, dropped %u of %u (total=%lu)",
                         (unsigned)(len - wrote), (unsigned)len,
                         (unsigned long)s_ble_rx_dropped);
                hmi_set_state(HMI_ST_OVERFLOW);
            }
            /* ⭐ 屏上事件计数：已收字节/9 = 已收事件数（⭐ 与守恒等式同口径）
             * 🔴 修了一个真 bug（2026-09-23）：
             *    这里原来【硬编码 total=0】⇒ 屏上一直是 `4820/0`、
             *    进度条和百分比【永远是 0】（⚠️ 恰恰是最该看的两个信息）。
             *    根因：⚠️ ESP32 本来【无从得知总数】—— 协议里没有这个信息。
             * ⭐ 现在：总数由【总数帧】提供（帧头 0x00），存在 s_song_total 里。
             *    ⚠️ 还没收到总数帧时 s_song_total == 0 ⇒ ⭐ 显示层会退化成
             *       "只显示已收数"，⛔ 不会除零（见 hmi.c 的 total>0 判断）。 */
            hmi_set_events((uint32_t)(s_ble_rx_bytes / FRAME_BYTES), s_song_total);
        }

        /* ⚠️ Write Request 需要回响应，否则对端会等超时 */
        if (param->write.need_rsp) {
            esp_ble_gatts_send_response(gatts_if, param->write.conn_id,
                                        param->write.trans_id, ESP_GATT_OK, NULL);
        }
        break;
    }

    case ESP_GATTS_READ_EVT: {
        esp_gatt_rsp_t rsp;
        memset(&rsp, 0, sizeof(rsp));
        rsp.attr_value.handle = param->read.handle;
        rsp.attr_value.len    = 0;
        esp_ble_gatts_send_response(gatts_if, param->read.conn_id,
                                    param->read.trans_id, ESP_GATT_OK, &rsp);
        break;
    }

    default:
        break;
    }
}

/* ===========================================================================
 * ⭐⭐⭐ 帧头分类 + 过滤（⭐ 这是"总数帧"能工作的关键）
 * ===========================================================================
 * ESP32 是【中转站】，所以【帧头由它来分辨】：
 *
 *   帧头 = 0xA5 且【不是】全 9 字节 0xA5  ⇒ ⭐ 事件帧 ⇒ ✅ 转发给 FPGA
 *   帧头 = 0xA5 且【全 9 字节都是】0xA5  ⇒ ⭐ 复位标记 ⇒ ⛔ 丢弃
 *                                            （⚠️ 与 FPGA 侧同一定义）
 *   帧头 = 0x00                          ⇒ ⭐ 总数帧 ⇒ ⛔ 自己留下，解析
 *   其他帧头                              ⇒ 🔴 未知 ⇒ ⛔ 丢弃 + 计数
 *
 * 🔴 为什么必须在这里过滤（⭐ 而不是让 FPGA 去认）：
 *    ⭐ FPGA 只认 `0xA5` 帧头。⚠️ 任何别的帧头到了它那里
 *      都会 → `hdr_err_cnt_o++`（⚠️ 而它本该是 0，是验收判据）
 *      并且载荷会被当成一个【真事件】⇒ 🔴 弹出随机音符。
 *    ⇒ ⭐ 所以"不是事件帧的东西"必须【在 ESP32 就拦掉】。
 */

/* 统计（⭐ 可观测，K-106 纪律：会出错的东西必须看得见）
 * ⚠️ 这四个变量【定义在文件前部】（见"s_ble_rx_bytes"那一段），
 *    因为 gatts 数据回调也要用 s_song_total。 */

/*
 * ⭐ 判断"这一帧是不是全 0xA5"（⭐ 复位标记）
 * ⚠️ 只看前 9 字节；调用方保证 n >= FRAME_BYTES。
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

/*
 * ⭐ 解析总数帧：byte 0 = 0x00，byte 1..8 = 大端 uint64 的总事件数
 * ⚠️ 只取低 32 位（⚠️ 本工程事件数远小于 2^32，够用）。
 */
static void frame_parse_total(const uint8_t *p)
{
    uint64_t v = 0;
    for (int i = 1; i < FRAME_BYTES; i++) {
        v = (v << 8) | p[i];
    }
    s_song_total = (uint32_t)v;
    s_total_frames_rx++;
    ESP_LOGI(TAG, "SONG TOTAL = %lu events", (unsigned long)s_song_total);

    /* ⭐ 屏上：立刻把总数告诉显示层（⚠️ 否则进度条永远是 0） */
    hmi_set_events((uint32_t)(s_ble_rx_bytes / FRAME_BYTES), s_song_total);

#if BLE_MODE == BLE_MODE_B_POOL
    /* ⭐⭐ 模式 B：把"应该收多少帧"告诉水池
     *    🔴 不给它的话，`pool_mark_done()` 无法发现
     *       "PC 发到一半就断了" —— ⚠️ 会把半曲当成整曲播。 */
    pool_set_expected((size_t)s_song_total);
#endif
}

/*
 * ⭐ 逐帧过滤（⭐ 输入必须是 9 的整数倍）
 * 返回【真正要转发给 FPGA 的字节数】—— ⭐ 原地压缩 chunk，非事件帧被摘掉。
 *
 * ⚠️ 为什么原地压缩：避免再开一个 1026 B 的缓冲（⭐ ESP32 内存紧）。
 */
static size_t frame_filter(uint8_t *chunk, size_t n)
{
    size_t out = 0;
    for (size_t off = 0; off + FRAME_BYTES <= n; off += FRAME_BYTES) {
        uint8_t *p = chunk + off;

        if (p[0] == FRAME_HDR_EVENT) {
            if (frame_is_all_a5(p)) {
                s_reset_frames_rx++;          /* ⭐ 复位标记 ⇒ 丢弃 */
                continue;
            }
            /* ⭐ 事件帧 ⇒ 保留（⚠️ 原地压缩） */
            if (out != off) {
                memmove(chunk + out, p, FRAME_BYTES);
            }
            out += FRAME_BYTES;
        } else if (p[0] == FRAME_HDR_TOTAL) {
            frame_parse_total(p);             /* ⭐ 总数帧 ⇒ 自己留下 */
        } else {
            s_unknown_frames++;               /* 🔴 未知 ⇒ 丢弃 + 计数 */
            ESP_LOGW(TAG, "unknown frame hdr 0x%02X, dropped (total=%lu)",
                     p[0], (unsigned long)s_unknown_frames);
        }
    }
    return out;
}

/* ===========================================================================
 * 任务 1：对齐排空（模式 A -> UART，模式 B -> 水池）
 * =========================================================================== */
static void task_drain(void *arg)
{
    static uint8_t chunk[ALIGN_BUF_CAP];
    (void)arg;

    ESP_LOGI(TAG, "drain task started (mode=%s)",
#if BLE_MODE == BLE_MODE_B_POOL
             "B/pool"
#else
             "A/passthrough"
#endif
            );

    for (;;) {
        size_t n = ble_buf_take_aligned(chunk, sizeof(chunk));
        if (n == 0) {
            /* 🔴 必须【至少 1 tick】—— ⚠️ `pdMS_TO_TICKS(1)` 在 100 Hz 下 = 0
             * ⇒ `vTaskDelay(0)` 不真正让出 ⇒ 本任务（优先级 9）立刻被调度回来
             * ⇒ 忙循环饿死同核 IDLE0 ⇒ 5 s 后 Task watchdog 触发。
             * ⭐ 上机实测于 2026-09-24（COM29），详见 ble_config.h §9b。 */
            vTaskDelay(BLE_DELAY_TICKS_AT_LEAST_1(1));
            continue;
        }
        /* ⭐ n 恒为 9 的整数倍 */

        /* ⭐⭐⭐ 先过滤：摘掉复位标记/未知帧，把总数帧自己留下 */
        size_t fwd = frame_filter(chunk, n);
        if (fwd == 0) {
            continue;                      /* ⭐ 这一批全是非事件帧 */
        }

#if BLE_MODE == BLE_MODE_B_POOL
        pool_feed(chunk, fwd);
#else
        int w = uart_write_bytes(BLE_UART_PORT, (const char *)chunk, fwd);
        if (w > 0) {
            s_uart_tx_bytes += w;
        }
#endif
    }
}

/* ===========================================================================
 * 任务 2：UART -> BLE（反向通路）
 * =========================================================================== */
static void task_uart_to_ble(void *arg)
{
    static uint8_t buf[512];
    (void)arg;

    for (;;) {
        int n = uart_read_bytes(BLE_UART_PORT, buf, sizeof(buf), pdMS_TO_TICKS(20));
        if (n <= 0) {
            continue;
        }
        s_uart_rx_bytes += n;

        if (!s_connected || s_handle_noti == 0) {
            continue;
        }
        /* ⚠️ notify 单包不能超过 MTU-3 */
        size_t maxseg = (s_mtu > 3) ? (size_t)(s_mtu - 3) : 20;
        size_t off = 0;
        while (off < (size_t)n) {
            size_t seg = ((size_t)n - off > maxseg) ? maxseg : ((size_t)n - off);
            esp_err_t err = esp_ble_gatts_send_indicate(
                ESP_GATT_IF_NONE, s_conn_id, s_handle_noti, seg, buf + off, false);
            if (err != ESP_OK) {
                s_ble_tx_failed++;
                break;
            }
            s_ble_tx_bytes += seg;
            off += seg;
            vTaskDelay(pdMS_TO_TICKS(BLE_TX_GAP_MS));
        }
    }
}

/* ===========================================================================
 * 任务 3：状态打印
 * =========================================================================== */
static void task_status(void *arg)
{
    (void)arg;
#if BLE_MODE != BLE_MODE_B_POOL
    /* ⚠️ 只在模式 A 的打印里用来算增量（模式 B 打的是池水位） */
    uint32_t last_rx = 0;
#endif
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(BLE_STATUS_PERIOD_MS));
        uint32_t rx = s_ble_rx_bytes;
#if BLE_MODE == BLE_MODE_B_POOL
        pool_stats_t ps;
        pool_stats(&ps);
        ESP_LOGI(TAG,
                 "ble_rx=%lu | pool=%u/%u (%s) sent=%lu | ovf=%lu late=%lu | "
                 "total=%lu tf=%lu rst=%lu unk=%lu | "
                 "exp=%lu mismatch=%lu clamp=%lu | mtu=%u | %s",
                 (unsigned long)rx,
                 (unsigned)ps.frames, (unsigned)ps.capacity_frames,
                 ps.in_psram ? "PSRAM" : "DRAM",
                 (unsigned long)ps.sent_frames,
                 (unsigned long)ps.overflow_frames,
                 (unsigned long)ps.late_ticks_max,
                 (unsigned long)s_song_total,          /* ⭐ 曲谱总事件数 */
                 (unsigned long)s_total_frames_rx,     /* ⭐ 收到的总数帧数 */
                 (unsigned long)s_reset_frames_rx,     /* ⭐ 复位标记帧数 */
                 (unsigned long)s_unknown_frames,      /* 🔴 未知帧头数（应恒为 0） */
                 (unsigned long)ps.expected_frames,    /* ⭐ 应到帧数 */
                 (unsigned long)ps.total_mismatch,     /* 🔴 实收≠应到（应恒为 0） */
                 (unsigned long)ps.tick_clamped_cnt,   /* ⚠️ tick 限流截断次数 */
                 (unsigned)s_mtu,
                 s_connected ? "CONN" : "----");
#else
        ESP_LOGI(TAG,
                 "ble_rx=%lu uart_tx=%lu | d_rx=%lu | uart_rx=%lu ble_tx=%lu | "
                 "dropped=%lu fail=%lu | buf=%u/%u | mtu=%u | %s",
                 (unsigned long)rx, (unsigned long)s_uart_tx_bytes,
                 (unsigned long)(rx - last_rx),
                 (unsigned long)s_uart_rx_bytes, (unsigned long)s_ble_tx_bytes,
                 (unsigned long)s_ble_rx_dropped, (unsigned long)s_ble_tx_failed,
                 (unsigned)s_cnt, (unsigned)ALIGN_BUF_CAP,
                 (unsigned)s_mtu,
                 s_connected ? "CONN" : "----");
#endif
#if BLE_MODE != BLE_MODE_B_POOL
        last_rx = rx;
#endif
    }
}

/* ===========================================================================
 * 入口
 * =========================================================================== */
void app_main(void)
{
    ESP_LOGI(TAG, "=== ESP32-S3 BLE <-> UART bridge ===");
    ESP_LOGI(TAG, "mode = %s",
#if BLE_MODE == BLE_MODE_B_POOL
             "B / POOL (buffer whole score, self-paced)"
#else
             "A / PASSTHROUGH (relay as they arrive)"
#endif
            );
    ESP_LOGI(TAG, "uart=%d baud=%d tx=GPIO%d rx=GPIO%d frame=%dB name=%s",
             BLE_UART_PORT, BLE_BAUD, BLE_PIN_UART_TX, BLE_PIN_UART_RX,
             FRAME_BYTES, BLE_DEV_NAME);

    /* NVS（蓝牙栈要求） */
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    /*
     * ⚠️ S3 只有 BLE ⇒ 控制器模式必须是 BLE_ONLY（或 BTDM）。
     *    🔴 这里【必须】在 sdkconfig.defaults 里显式设
     *       CONFIG_BTDM_CTRL_MODE_BLE_ONLY=y（⚠️ SPP 版踩过"默认不是它"的坑）。
     */
    esp_bt_controller_config_t bt_cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_bt_controller_init(&bt_cfg));
    ESP_ERROR_CHECK(esp_bt_controller_enable(ESP_BT_MODE_BLE));
    ESP_ERROR_CHECK(esp_bluedroid_init());
    ESP_ERROR_CHECK(esp_bluedroid_enable());

    ESP_ERROR_CHECK(uart_fpga_init());

    /* ⭐ 串口屏（UART2）—— ⚠️ 放在蓝牙之后，别抢启动时间 */
    hmi_init();

    /* ⭐ 注册服务（属性表在 gatt_svc.c；⭐ 回调只有这一个） */
    ESP_ERROR_CHECK(esp_ble_gatts_register_callback(gatts_event_handler));
    ESP_ERROR_CHECK(esp_ble_gap_register_callback(gap_event_handler));
    ESP_ERROR_CHECK(esp_ble_gatts_app_register(0));

    xTaskCreate(task_drain,        "drain", 4096, NULL, BLE_TASK_PRIO_DRAIN, NULL);
    xTaskCreate(task_uart_to_ble,  "u2ble", 4096, NULL, BLE_TASK_PRIO_UART_RX, NULL);
    xTaskCreate(task_status,       "stat",  3072, NULL, BLE_TASK_PRIO_STATUS, NULL);

#if BLE_MODE == BLE_MODE_B_POOL
    pool_reset();
    xTaskCreate(task_pool_pump, "pump", 4096, NULL, BLE_TASK_PRIO_DRAIN, NULL);
    ESP_LOGW(TAG, "MODE B (pool): feed whole score first.");
#endif
    ESP_LOGI(TAG, "ready. scan for \"%s\" from phone/PC.", BLE_DEV_NAME);
}
