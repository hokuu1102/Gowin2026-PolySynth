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
 *   ⚠️ 门限随波特率【同比】变化（`GAP_BYTES = 16`，`evt_uart_rx.v:86`）：
 *      · **500 kbps（⭐ 当前档）** ⇒ 1 字节 = 20 µs ⇒ 门限 = **320 µs**
 *      · （⭐ 对照 1 Mbps：160 µs —— ⚠️ 已不用该档）
 *   ⚠️ 而 BLE 的数据是**按 ATT 包投递**的：一个 9 字节帧可能被切成两个包
 *      ⇒ 中间隔一个连接间隔（7.5~30 ms）⇒ 🔴 远超门限 ⇒ 必然截帧。
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
#include "up_ring.h"
#include "ws2812.h"

static const char *TAG = "blebridge";

/* ===========================================================================
 * 可观测计数（K-106：容量有限/会出错的东西必须看得见）
 * =========================================================================== */
static volatile uint32_t s_ble_rx_bytes   = 0;
/* ⭐⭐ 2026-10-01（实测修 bug）：**本曲**已收事件数 —— ⭐ 屏上 `t2` / 进度条用
 * ---------------------------------------------------------------------------
 * 🔴 **为什么不能直接用 `s_ble_rx_bytes / FRAME_BYTES`**：
 *    ⚠️ 那个是**自开机累计**（⛔ 从不复位），⭐ 而总数 `s_song_total` 是**本曲**的
 *    ⇒ 🔴 **分子累计、分母本曲** ⇒ 灌两次 200 帧就显示 `410/200`、百分比 `205%`
 *    （⭐ 实测：用户接上屏后第一次看到的就是这个）。
 * ⭐ 本计数在【复位标记】处清零（⭐ 那就是"新曲子开始"的信号）。
 */
static volatile uint32_t s_song_events_rx = 0;
static volatile uint32_t s_ble_rx_dropped = 0;
static volatile uint32_t s_uart_tx_bytes  = 0;
static volatile uint32_t s_uart_rx_bytes  = 0;
/* ⭐ 2026-09-30：识别到的起播触发字符数（'S'/'X'/'R'）。
 * 🔴 用途：把"发了 S 没反应"一刀切成三段（⭐ 见 status 打印处的注释）：
 *    · `u_rx` 不动 ⇒ 物理层；`u_rx` 动而 `trig=0` ⇒ 字符没认出；`trig>0` ⇒ 看起播逻辑。 */
static volatile uint32_t s_trig_cnt       = 0;
static volatile uint32_t s_ble_tx_bytes   = 0;
static volatile uint32_t s_ble_tx_failed  = 0;
/* ⭐⭐ 2026-09-30（B 子集）：CMD 口（`0xABF3`）的命令计数
 * ⚠️ 分开记"认得"与"不认得" —— ⭐ 这样"发了没反应"能一刀切开：
 *    · `cmd_ok` 涨 ⇒ ⭐ 命令认得，去看它干了什么
 *    · `cmd_unk` 涨 ⇒ 🔴 **命令格式对不上**（⭐ 不是"没生效"） */
static volatile uint32_t s_cmd_ok        = 0;
static volatile uint32_t s_cmd_unknown   = 0;

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
/* ⭐⭐ 2026-09-30：0xABF2 的 CCCD 句柄 + "对端是否已使能通知" 标志
 * 🔴 为什么需要：⭐ 客户端**必须写 CCCD=0x0001** 才收得到 notify。
 *    ⚠️ 原来固件只看 `s_connected` ⇒ 🔴 **连接一建立就放水**，
 *      而那一刻客户端**还没订阅** ⇒ ⭐ 数据**全丢**（⚠️ 且 `fail=0`，看不出来）。
 *    ⭐ 实测铁证（2026-09-30）：连上后 700 ms 内 `u_out` 从 4000→4500
 *      （环排空了），⚠️ 而 PC 侧 **0 个包**。 */
static uint16_t s_handle_noti_cccd = 0;
static volatile bool s_noti_enabled = false;   /* ⭐ 对端已订阅 0xABF2 */

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
    /* 🔴 2026-09-24 上机诊断：先确认【回调本身有没有被调用】。
     *    ⚠️ 现象：config_adv_data_raw 返回 OK，但
     *       ADV_DATA_SET_COMPLETE_EVT 永不触发 ⇒ 广播起不来。
     *    ⭐ 若这行也不出现 ⇒ GAP 回调压根没注册成功（问题在注册处）；
     *       若出现而 SET_COMPLETE 不来 ⇒ 事件真的没产生。 */
    ESP_LOGI(TAG, "GAP cb: event=%d", (int)event);

    switch (event) {
    /* 🔴🔴 2026-09-24 上机实测：这里曾是本工程最隐蔽的一个 bug ——
     *   配置广播用的是 esp_ble_gap_config_adv_data_raw()，
     *   它回调的是 ESP_GAP_BLE_ADV_DATA_RAW_SET_COMPLETE_EVT（枚举值 = 4），
     *   ⛔【不是】ESP_GAP_BLE_ADV_DATA_SET_COMPLETE_EVT（= 0）。
     *   ⚠️ 原来只 case 了 =0 的那个 ⇒ raw 事件落到 default 分支
     *      ⇒ ble_start_advertising() 永不调用 ⇒ 🔴 广播从未启动
     *      ⇒ 手机永远扫不到 "FPGA2026-Synth"。
     *   ⭐ 教训：换 API（adv_data -> adv_data_raw）时，
     *      必须【同时】改回调里的事件常量 —— 两者是配对的。
     *   ✅ 现在两个事件都处理，两种 API 谁都能用。 */
    case ESP_GAP_BLE_ADV_DATA_SET_COMPLETE_EVT:
    case ESP_GAP_BLE_ADV_DATA_RAW_SET_COMPLETE_EVT:
        s_adv_configured = true;
        ESP_LOGI(TAG, "adv data set (evt=%d) -> start advertising", (int)event);
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

/* ⭐⭐ 2026-09-30 夜：CMD 要用到起播/停止动作，而它们定义在【下方】（L732+）
 * ⇒ ⭐ 必须先【前置声明】，⛔ 否则编译报 implicit declaration。 */
static void start_action_play(void);
static void start_action_stop(void);
/* ⭐⭐ 2026-10-01 补：**原来这里漏了 `reset` 的前向声明** —— 🔴 那正是缺陷的源头
 * ---------------------------------------------------------------------------
 * 🔴 症状（实测）：⭐ 发 CMD `0x01`（复位）后，⭐ 屏上状态字**仍是 `断链`**，
 *    ⛔ 永远进不了 `待机`（⭐ `HMI_ST_IDLE` 成了死代码）。
 * ⭐ 根因链（⭐ 一路追到【第一因】）：
 *    ① ⚠️ 本处**只有 `play` / `stop` 的前向声明**，⛔ 没有 `reset`
 *    ② ⇒ ⭐ 于是 `case 0x01` 里**写不出** `start_action_reset()`（⭐ 未声明）
 *    ③ ⇒ ⚠️ 只能退而直接调 `pool_reset()`
 *    ④ ⇒ 🔴 **绕过了 wrapper** ⇒ `hmi_set_state(HMI_ST_IDLE)` 永不执行
 *    ⚠️ 而 662 行的注释写的恰恰是「**复用 `start_action_play/stop/reset`**」
 *       —— 🔴 **注释与代码相反**（⭐ 0.11 第 4 类检查要抓的正是这个）。
 * ⭐ 修法（改【上游源头】，⛔ 不是在下游打补丁）：
 *    ⭐ **补上缺失的声明** ⇒ 绕过的**理由**自然消失 ⇒
 *    ⭐ `case 0x01` 就能和 `0x03`/`0x04` 走同一条路。
 * 📌 教训：⭐ **"为什么这里没走公共封装"往往不是疏忽，而是【调不到】**
 *    ⇒ ⭐ 追根因时要问「⭐ **他为什么没这么写？**」（⭐ 而不是"他忘了"）。 */
static void start_action_reset(void);

#if WS2812_ENABLE || WS2812_CLEAR_ON_BOOT || BLE_LED_ENABLE
/* ===========================================================================
 * ⭐⭐ 2026-09-30 夜：连接指示灯（⭐ 用户 Q4 裁定）
 *        2026-10-01：⭐ 默认【关闭】+ ⭐ 开机【清锁存】（⭐ 用户："安全第一"）
 * ===========================================================================
 * ⭐ 用途：⭐ **不接串口屏也能一眼看出蓝牙连上没有**（⭐ 屏要 5V + 接线，灯不用）。
 *
 * ⭐ 两种灯的【统一入口】`ind_*` —— ⛔ 调用点不关心用的是哪种：
 *    · ⭐ `WS2812_ENABLE`  ⇒ **板载** WS2812（⭐ `GPIO48`，⚠️ 需短接 R17 跳线）
 *    · ⚠️ `BLE_LED_ENABLE` ⇒ **外接**普通 LED（⭐ 要接线）
 *   ⭐ **两者可同时开**（⚠️ 通常只用一个）。见 `ble_config.h` §12。
 *
 * 🔴🔴 **`WS2812_CLEAR_ON_BOOT` 必须也在守卫里**（⭐ 2026-10-01 修的）：
 *    ⚠️ 原来写的是 `#if WS2812_ENABLE` ⇒ 🔴 **关掉指示灯时，"清锁存"整段不编译**
 *    ⇒ ⚠️ 而 WS2812 是【锁存】的 ⇒ 🔴 **灯会永远停在旧颜色上，清不掉**。
 *    ⭐ 正确守卫：`WS2812_ENABLE || WS2812_CLEAR_ON_BOOT`。
 */
static void ind_init(void)
{
#if WS2812_ENABLE || WS2812_CLEAR_ON_BOOT
    /* ⭐ 无条件调 —— `ws2812_init()` 内部【自己会先发一帧全 0】（⭐ 清锁存），
     *    ⚠️ 这一步在 `WS2812_ENABLE=0` 时**恰恰是最需要的**。 */
    ws2812_init();
#endif
#if WS2812_ENABLE
    ws2812_set_connected(false);          /* ⚠️ 上电先灭（⭐ 指示灯开着时才需要） */
#endif
#if BLE_LED_ENABLE
    gpio_config_t io = {
        .pin_bit_mask = (1ULL << BLE_LED_GPIO),
        .mode         = GPIO_MODE_OUTPUT,
        .pull_up_en   = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    if (gpio_config(&io) == ESP_OK) {
        gpio_set_level(BLE_LED_GPIO, BLE_LED_ACTIVE_HIGH ? 0 : 1);
        ESP_LOGI(TAG, "led: GPIO%d ready (%s active)",
                 BLE_LED_GPIO, BLE_LED_ACTIVE_HIGH ? "high" : "low");
    } else {
        ESP_LOGE(TAG, "led: gpio_config failed");
    }
#endif
}

static void ind_set(bool connected)
{
#if WS2812_ENABLE
    ws2812_set_connected(connected);
#endif
#if WS2812_ENABLE || WS2812_CLEAR_ON_BOOT || BLE_LED_ENABLE
    gpio_set_level(BLE_LED_GPIO,
                   connected ? (BLE_LED_ACTIVE_HIGH ? 1 : 0)
                             : (BLE_LED_ACTIVE_HIGH ? 0 : 1));
#endif
}
#endif /* WS2812_ENABLE || BLE_LED_ENABLE */

/* ===========================================================================
 * ⭐⭐ 2026-09-30（B 子集）：CMD 命令 —— 上报状态
 * ===========================================================================
 * ⭐ 语义：把当前状态**序列化成一行文本**，放进 `0xABF4`(STAT)。
 * 🔴 **STAT 是只读属性、⛔ 不能 notify** ⇒ 这只是"更新内容"，
 *    ⭐ **必须客户端主动读**才拿得到（⭐ 见 `gatt_svc.c` 的 `gatt_set_stat`）。
 *    ⇒ ⚠️ 所以这里**同时打日志** —— 否则分不清
 *      "命令没生效" 与 "生效了但客户端没读"。
 */
static void cmd_report_status(void)
{
    /* ⭐⭐ 2026-10-01（任务 2）：从"一行短文本"扩展成**八组完整状态**
     * -----------------------------------------------------------------------
     * 🔴 为什么扩：⚠️ 原来只有 `pool/sent/ovf/ring/u_drop` 几项
     *    ⇒ 🔴 **上位机看不到**：CMD 计数、环的 hwm/full、BLE 的 fail、
     *      MTU、订阅状态、帧统计、UART 触发计数… ⚠️ 只能盯串口日志。
     *
     * ⭐ 格式选择：⭐ **`key=value` 多行**（⭐ 既好读，⭐ 又好用正则解析）
     *    ⚠️ 不用二进制 —— 🔴 二进制在"人看一眼"时完全没用，
     *       而 ⭐ **排查现场最常见的就是"人看一眼"**。
     *
     * ⚠️ 容量：⭐ `s_val_stat` 是 **320 B**（⭐ 见 `gatt_svc.c`）
     *    ⇒ ⭐ 下面这段约 264 字符 ⇒ ✅ 装得下。
     * 🔴🔴 **但本地的 `buf` 必须【跟着一起扩】**（⭐ 2026-10-01 踩过）：
     *    ⚠️ 原来这里写的是 `char buf[256]`，⭐ 而 `s_val_stat` 已扩到 320
     *    ⇒ 🔴 **`snprintf` 在 256 处截断** ⇒ ⚠️ 最后一组 `cmd=` 只剩 `cmd=` + 垃圾
     *    （⭐ 实测原始字节：`...unk=0\ncmd=\x00\x00\x00\x00\x00\x1cG\x00\x00`）
     *    ⭐ **判据**：`stat_read.py` 的"八组齐全"检查**抓到了它**（⭐ 报"缺 cmd.ok/unk"）。
     *
     * 🔴🔴 **还有一个更危险的坑（⭐ 同一处，已修）**：
     *    ⚠️ **`snprintf` 的返回值是"【本该】写多少"**，⛔ **不是"实际写了多少"**
     *    ⇒ 原来写 `int n = snprintf(buf, sizeof(buf), ...); gatt_set_stat(buf, n);`
     *    ⇒ 🔴 截断时 `n = 264 > sizeof(buf) = 256`
     *    ⇒ 🔴 **从 256 字节的栈缓冲里读越界 8 字节**（⭐ 内存安全问题，⚠️ 而且不报错）
     *    ⇒ ⭐ **正解：用返回值之前先夹到 `sizeof(buf)`**（⭐ 见下面 `if (n > (int)sizeof(buf))`）。
     */
    char buf[320];
    pool_stats_t ps;
    up_ring_stats_t us;
    pool_stats(&ps);
    up_ring_stats(&us);

    /* ⭐⭐ 2026-10-01（C115 的第二层修法）：让【陈旧】变得可检测
     * -----------------------------------------------------------------------
     * 🔴 问题：⭐ `0xABF4` 是**请求时生成的快照** ⇒ ⚠️ 客户端**不请求就直读**
     *    会拿到**上一次**的内容，⚠️ 而**没有任何"这是旧的"标记**
     *    ⇒ 🔴 与真实状态**无法区分**（⭐ 实测：⭐ 池里明明有 200 帧，
     *       不请求直读却得到 `pool=0 sent=0` —— ⚠️ 而 0 看起来完全合理）。
     *
     * ⭐ 修法两层（⭐ 第一层在 PC 侧：读前先请求）：
     *    ① ⭐ `req=`  = **这是第几次快照**（⭐ 单调递增）
     *    ② ⭐ `up=`   = **生成快照时的开机毫秒数**
     *    ⇒ ⭐ 客户端**连读两次**：
     *        · `req` **没变** ⇒ 🔴 **数据是旧的**（⭐ 上次的）
     *        · `up` 与当前时间差太大 ⇒ 🔴 **快照很老**
     *    ⭐ 这就把"静默陈旧"变成了"**可判定的陈旧**" ✅
     * ⚠️ 同族经验：`C115`（⭐ 请求时才生成的快照接口）。 */
    static uint32_t s_stat_req = 0;
    s_stat_req++;
    int64_t up_ms = esp_timer_get_time() / 1000;

    /* ⭐ 屏→ESP32 诊断（⭐ 见 hmi.h） */
    uint32_t hmi_rx_b = 0, hmi_rx_t = 0;
    uint8_t  hmi_rx_last = 0;
    hmi_rx_stats(&hmi_rx_b, &hmi_rx_t, &hmi_rx_last);

    int n = snprintf(buf, sizeof(buf),
        "V1 mode=%s req=%lu up=%lldms\n"
        /* ⭐ 池：⭐ 已收/容量、已发、溢出、落后、应到/不符、限流截断、是否在跑 */
        "pool=%u/%u sent=%lu ovf=%lu late=%lu exp=%lu mm=%lu clamp=%lu run=%d\n"
        /* ⭐ 上行环：⭐ 水位/容量、入/出、丢弃次数/字节、满次数、高水位、落哪 */
        "ring=%lu/%u in=%lu out=%lu drop=%lu/%lu full=%lu hwm=%lu %s\n"
        /* ⭐ BLE：⭐ 收/发字节、失败、MTU、连接、订阅 */
        "ble=rx%lu tx%lu fail=%lu mtu=%u conn=%d sub=%d\n"
        /* ⭐ UART：⭐ 收字节、触发字符计数 */
        "uart=rx%lu trig=%lu\n"
        /* ⭐⭐ 2026-10-01：屏 → ESP32 方向（⭐ 诊断"屏有界面但数字不变"）
         *    ⭐ 判读：`hmi.rx` 涨 ⇒ 屏→ESP32 通 ⇒ 🔴 问题在反方向（ESP32→屏） */
        "hmi=rx%lu touch=%lu tx=%lu last=0x%02X\n"
        /* ⭐ 帧统计：⭐ 总数帧、曲谱总事件、复位帧、未知帧头 */
        "frame=total=%lu tf=%lu rst=%lu unk=%lu\n"
        /* ⭐ CMD：⭐ 认得 / 不认得 */
        "cmd=ok%lu unk%lu\n",
        /* ---- 参数（⭐ 顺序必须与上面的格式串【严格一致】）---- */
#if BLE_MODE == BLE_MODE_B_POOL
        "B",
#else
        "A",
#endif
        /* ⭐ C115 第二层：⭐ 快照序号 + 生成时刻（⭐ 让陈旧可判定） */
        (unsigned long)s_stat_req, (long long)up_ms,
        (unsigned)ps.frames, (unsigned)ps.capacity_frames,
        (unsigned long)ps.sent_frames,
        (unsigned long)ps.overflow_frames,
        (unsigned long)ps.late_ticks_max,
        (unsigned long)ps.expected_frames,
        (unsigned long)ps.total_mismatch,
        (unsigned long)ps.tick_clamped_cnt,
        (int)ps.running,
        (unsigned long)us.level, (unsigned)us.cap,
        (unsigned long)us.in, (unsigned long)us.out,
        (unsigned long)us.drop_ev, (unsigned long)us.drop,
        (unsigned long)us.full_hits, (unsigned long)us.hwm,
        us.in_psram ? "PSRAM" : "DRAM",
        (unsigned long)s_ble_rx_bytes, (unsigned long)s_ble_tx_bytes,
        (unsigned long)s_ble_tx_failed, (unsigned)s_mtu,
        (int)s_connected, (int)s_noti_enabled,
        (unsigned long)s_uart_rx_bytes, (unsigned long)s_trig_cnt,
        /* ⭐ 屏→ESP32 诊断（⭐ 见 hmi.h 的说明） */
        (unsigned long)hmi_rx_b, (unsigned long)hmi_rx_t, (unsigned long)hmi_tx_cmds(), (unsigned)hmi_rx_last,
        (unsigned long)s_total_frames_rx, (unsigned long)s_song_total,
        (unsigned long)s_reset_frames_rx, (unsigned long)s_unknown_frames,
        (unsigned long)s_cmd_ok, (unsigned long)s_cmd_unknown);

    if (n > 0) {
        /* 🔴🔴 必须夹住！⭐ `snprintf` 返回"本该写多少"，⚠️ 截断时会 > 缓冲大小
         *    ⇒ 不夹就**读越界**（⭐ 见上面注释里记的那个坑）。 */
        if (n > (int)sizeof(buf)) {
            ESP_LOGW(TAG, "STAT truncated: want %d, have %u", n, (unsigned)sizeof(buf));
            n = (int)sizeof(buf);
        }
        gatt_set_stat((const uint8_t *)buf, (size_t)n);
        /* ⚠️ 日志里**也打一份** —— ⭐ 否则分不清
         *    "命令没生效" 与 "生效了但客户端没读"（⭐ STAT 是只读的，⛔ 不会主动推） */
        ESP_LOGW(TAG, "STAT updated (%d B):\n%s", n, buf);
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
            /* ⭐⭐⭐ 2026-09-24 上机实测：改用【原始广播数据】API
             *
             * 经过（两级错误，逐个定位）：
             *   ① 原来 .service_uuid_len = 2 配 .p_service_uuid = &(uint16_t)
             *      ⇒ ⚠️ ESP-IDF 要求后者指向【16 字节完整 UUID】
             *      ⇒ 报 0x102 ESP_ERR_INVALID_ARG
             *      ⇒ ADV_DATA_SET_COMPLETE_EVT 永不触发 ⇒ 广播从未启动。
             *   ② 把 UUID 去掉（len=0）后，config 通过了，但启动广播报：
             *      🔴 BT_BTM: btm_ble_write_adv_enable_complete failed (0xD FAIL)
             *      ⚠️ 广播包只剩 Flags（结构体方式的隐式组装在
             *         include_name 未及时生效时可能产出无效包）。
             *
             * ⭐ 最终修法：用 esp_ble_gap_config_adv_data_raw() 【手工构造】
             *    标准 BLE 广播包 —— 每个字段的长度/类型都显式可控，
             *    ⛔ 不依赖结构体的隐式行为。
             *
             * ⭐ 包内容（标准 AD 结构，每条 = [长度][类型][数据]）：
             *    · Flags        : 02 01 06      (LE General Discoverable, BR/EDR Not Supported)
             *    · Complete Name: 0x0F 09 "FPGA2026-Synth"   (14 字符 + 类型 + 长度 = 16 B)
             *    ⚠️ 合计 3 + 16 = 19 B ≤ 31 B（BLE 4.x 广播包上限）✅
             */
            static uint8_t adv_raw[] = {
                0x02, 0x01, 0x06,                     /* Flags */
                0x0F, 0x09,                           /* len=15, type=完整本地名 */
                'F','P','G','A','2','0','2','6','-','S','y','n','t','h'
            };
            esp_err_t adv_err = esp_ble_gap_config_adv_data_raw(adv_raw,
                                                               sizeof(adv_raw));
            if (adv_err != ESP_OK) {
                ESP_LOGE(TAG, "config_adv_data_raw FAILED: 0x%X (%s)",
                         adv_err, esp_err_to_name(adv_err));
            } else {
                ESP_LOGI(TAG, "config_adv_data_raw OK (%u B), waiting for SET_COMPLETE",
                         (unsigned)sizeof(adv_raw));
            }
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
        /* ⭐ 记下 CCCD 的句柄 —— ⭐ 下方 WRITE_EVT 靠它识别"对端订阅了" */
        s_handle_noti_cccd = param->add_attr_tab.handles[gatt_idx_noti_cccd()];

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
#if WS2812_ENABLE || WS2812_CLEAR_ON_BOOT || BLE_LED_ENABLE
        /* ⭐⭐ 2026-09-30 夜：连上就点亮（⭐ 用户 Q4「让灯亮一下」）
         * ⚠️ 注意：⭐ 这里只是"物理连接"，⚠️ **还未订阅**（CCCD）。
         *    🔴 所以【放水】绝不能在这里开始 —— ⭐ 那会发进虚空
         *    （⭐ 实测：连上后 700ms 内环被排空，PC 侧 0 个包）。
         *    ⭐ 灯的语义是"连上了"，⭐ 放水的语义是"订阅了"，
         *    ⚠️ **两者刻意分开**（⭐ 灯早就亮，不代表数据能发）。 */
        ind_set(true);
#endif

        /* ⭐ 立刻请求大 MTU（⚠️ 默认 23 ⇒ 有效载荷仅 20 字节，整曲要 5200+ 包） */
        esp_ble_gatt_set_local_mtu(BLE_PREFERRED_MTU);
        break;

    case ESP_GATTS_DISCONNECT_EVT:
        s_connected = false;
#if WS2812_ENABLE || WS2812_CLEAR_ON_BOOT || BLE_LED_ENABLE
        ind_set(false);                   /* ⭐ 断开 ⇒ 灭 */
#endif
        /* ⭐⭐ 2026-09-30：订阅状态**随连接失效** ⇒ ⭐ 必须清掉
         *    ⚠️ 否则重连后、客户端**还没订阅**时，固件会以为"可以发了"
         *    ⇒ 🔴 又把数据发进虚空（⭐ 这正是本次要修的缺陷）。
         * ⭐ 清掉 ⇒ 回到**蓄水**态，⭐ 等新对端订阅后再放水。 */
        s_noti_enabled = false;
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

        /* ⭐⭐ 2026-09-30：**先识别 CCCD 写入** —— 这是"对端已就绪"的唯一可靠信号
         * -----------------------------------------------------------------
         * 🔴 为什么必须在这里判：⭐ 0xABF2 的 CCCD 写 `0x0001` 才代表
         *    客户端**真的开了通知**。⚠️ 在此之前任何 notify 都是**发进虚空**
         *    （⭐ 实测：连上后 700 ms 内环被排空，⚠️ 而 PC 收到 **0 个包**，
         *      且 `fail=0` ⇒ 🔴 完全看不出来）。
         * ⭐ 语义：⭐ **蓄水 → （对端订阅）→ 放水** ——
         *    ⚠️ 触发点是【订阅】，⛔ 不是【连接】。 */
        if (h == s_handle_noti_cccd && len >= 2) {
            uint16_t cccd = (uint16_t)(val[0] | (val[1] << 8));
            s_noti_enabled = (cccd & 0x0001) != 0;
            ESP_LOGW(TAG, "CCCD 0xABF2 = 0x%04X -> notifications %s",
                     (unsigned)cccd, s_noti_enabled ? "ENABLED" : "disabled");
            /* ⚠️ CCCD 写也要回响应（⭐ 它是 Write Request） */
            if (param->write.need_rsp) {
                esp_ble_gatts_send_response(gatts_if, param->write.conn_id,
                                            param->write.trans_id, ESP_GATT_OK, NULL);
            }
            break;
        }

        /* ⭐⭐ 2026-09-30（B 子集）：**`0xABF3`(CMD) 单独解析** —— ⛔ 不再当曲谱数据
         * -----------------------------------------------------------------
         * 🔴 **原来这里是个真缺陷**：判据写成
         *      `if (h == s_handle_recv || h == s_handle_cmd)`
         *    ⇒ ⚠️ 往 CMD 口写的东西**被当成曲谱数据塞进缓冲**
         *    ⇒ 🔴 **CMD 口等于废的**（⭐ 写了什么后果都不可控）。
         *
         * ⭐ 本步只实现【与架构无关】的两个命令（⭐ 见下）：
         *      `0x01` = 清池（`pool_reset`）      —— ✅ 无争议
         *      `0x02` = 上报状态（写 `0xABF4`）   —— ✅ 无争议
         * ⛔ **刻意不做**：起播 / 停止 / 清环
         *    ⇒ ⚠️ 因为"起播归谁管"**尚未裁定**（方案③ vs 模式B 互斥）
         *    ⇒ ⭐ 见 `files/20-代码/矛盾裁定单-方案3与模式B-20260930.md`
         *    ⛔ **不要顺手加** —— 那会与未定的架构冲突。 */
        if (h == s_handle_cmd) {
            for (uint16_t i = 0; i < len; i++) {
                uint8_t c = val[i];
                switch (c) {
                case 0x01:                       /* ⭐ 清池 */
                    ESP_LOGW(TAG, "CMD 0x01: pool reset");
                    /* ⭐⭐ 2026-10-01 修：⭐ 改走 `start_action_reset()`（⭐ 与 0x03/0x04 一致）
                     * -----------------------------------------------------------------
                     * 🔴 原来这里直接调 `pool_reset()` ⇒ ⚠️ **绕过了 wrapper**
                     *    ⇒ 🔴 `hmi_set_state(HMI_ST_IDLE)` 永不执行
                     *    ⇒ ⭐ 屏上状态字**永远进不了 `待机`**（⭐ 实测坐实）。
                     * ⚠️ 为什么原来会绕过：⭐ 见上方 `start_action_reset` 的前向声明处
                     *    —— 🔴 **它当时根本没被声明，所以调不到**。
                     * ⭐ wrapper 里做的是「`pool_reset()` ＋ 推屏状态」——
                     *    ⭐ 两件事必须**一起**发生，⛔ 不能只做一半。 */
                    start_action_reset();
                    s_cmd_ok++;
                    break;
                case 0x02:                       /* ⭐ 上报状态（写 0xABF4） */
                    ESP_LOGW(TAG, "CMD 0x02: status report requested");
                    cmd_report_status();
                    s_cmd_ok++;
                    break;
                /* ⭐⭐ 2026-09-30 夜新增（⭐ 用户 Q1 裁定后【不再被阻塞】）
                 * -----------------------------------------------------------------
                 * 🔴 **为什么原来不做**：⚠️ "起播归谁管"当时**未裁定**
                 *    （方案③ vs 模式B 互斥）⇒ ⭐ 怕与未定的架构冲突。
                 * ✅ **现已拍板**：⭐ **走模式 B，起播键在 ESP32**
                 *    ⇒ 📌 出处 `files/20-代码/用户裁定结果-20260930.md` §〇
                 *
                 * ⭐ 语义：
                 *    `0x03` ⇒ ⭐ **起播**（= 串口 `S` 的等价物）
                 *    `0x04` ⇒ ⭐ **停止**（= 串口 `X`）
                 * ⚠️ 复用 `start_action_play/stop/reset` ——
                 *    ⭐ 它们**已带判据**（池空则拒绝、已在跑则忽略），
                 *    ⛔ 不另写一套，避免两条路径行为不一致。 */
                case 0x03:                       /* ⭐ 起播 */
                    ESP_LOGW(TAG, "CMD 0x03: START (play)");
                    start_action_play();
                    s_cmd_ok++;
                    break;
                case 0x04:                       /* ⭐ 停止 */
                    ESP_LOGW(TAG, "CMD 0x04: STOP");
                    start_action_stop();
                    s_cmd_ok++;
                    break;
                /* ⭐⭐ 2026-10-01：CMD `0x20` = **探针**（⭐ 排查"屏上某栏不更新"）
                 * -----------------------------------------------------------------
                 * 🔴 症状（实测）：⭐ `t2`/`j0`/`n0` 都生效，⚠️ 但 `t3` 不生效
                 *    ⇒ ⚠️ 无法区分：① 屏上【没有】这个控件（⭐ 名字不对）
                 *                  ② 有控件但属性名/命令写错
                 * ⭐ 修法：⭐ **用 TJC 的 `get` 让屏【自己回答】** ——
                 *    · ⭐ 控件存在 ⇒ 屏回它的值（⭐ 会出现在 `hmi_poll_rx` 的日志里）
                 *    · 🔴 控件不存在 ⇒ **屏【不回复】**（⭐ 静默）
                 *    ⇒ ⭐ **"回没回"就是判据**，⛔ 不用猜。
                 * ⚠️ 同时问 `t2`（⭐ 已知能用的）当**对照组** ——
                 *    ⭐ 它一定回，⭐ 这样能证明"`get` 这条路本身是通的"。 */
                case 0x20:                       /* ⭐ 探针：问屏要几个控件的值 */
                    ESP_LOGW(TAG, "CMD 0x20: HMI probe (get)");
                    hmi_send_cmd("get t2.txt");  /* ⭐ 对照组：已知能用 */
                    hmi_send_cmd("get t3.txt");  /* 🔴 嫌疑：不生效 */
                    hmi_send_cmd("get t1.txt");  /* ⭐ 状态字 */
                    hmi_send_cmd("get g0.txt");  /* ⭐ 曲谱名 */
                    s_cmd_ok++;
                    break;
                /* ⭐⭐ CMD `0x21` = **直接给屏发一条原样命令**（⭐ 台面调测用）
                 *    ⚠️ 格式：`0x21` + ASCII 命令正文（⛔ 不用带 `FF FF FF`，固件补）
                 *    ⭐ 用途：⭐ 试"控件名/属性名/颜色值"到底哪个才对 ——
                 *       ⛔ 否则每试一次都要重新烧固件。 */
                case 0x21: {
                    char raw[BLE_HMI_CMD_MAX];
                    size_t rn = (len > (uint16_t)(i + 1)) ? (size_t)(len - i - 1) : 0;
                    if (rn >= sizeof(raw)) {
                        rn = sizeof(raw) - 1;
                    }
                    if (rn > 0) {
                        memcpy(raw, val + i + 1, rn);
                        raw[rn] = '\0';
                        ESP_LOGW(TAG, "CMD 0x21: raw HMI -> \"%s\"", raw);
                        hmi_send_cmd(raw);
                        s_cmd_ok++;
                    } else {
                        ESP_LOGW(TAG, "CMD 0x21: empty payload, ignored");
                    }
                    i = len;                     /* ⚠️ 正文已消费完 ⇒ 结束本批 */
                    break;
                }
                /* ⭐⭐ CMD `0x22` = **设置曲谱名**（⭐ 2026-10-01 新增，⭐ 用户裁定）
                 * -----------------------------------------------------------------
                 * 🔴 为什么需要它：⭐ 实测发现 `hmi_set_song()` **全工程零调用**
                 *    ⇒ ⭐ `s_c.song` 永远是初值 `----` ⇒ 🔴 **屏上曲名永远是 `----`**
                 *    ⚠️ 而 9 字节事件帧里**没有曲名字段**（⭐ `tick/inc/axis/vel/
                 *       kind/timbre` 已占满）⇒ ⭐ 曲名**只能由 PC 另外下发**。
                 * ⭐ 格式：`0x22` + UTF-8 曲名（⛔ 不需要结束符，长度由 BLE 写决定）
                 *    · ⭐ 空 payload ⇒ ⭐ 回落成 `----`（⭐ 见 `hmi_set_song`）
                 *    · ⭐ 屏上的 `g0` 是**滚动文本** ⇒ 长名字靠它滚
                 * ⚠️ 净化（⭐ 去双引号/控制字符）在 `hmi_set_song()` 里做 ——
                 *    ⭐ 那是**源头**，⛔ 不在这里做（⭐ 否则别的调用方又会漏）。 */
                case 0x22: {
                    char nm[BLE_HMI_CMD_MAX];
                    size_t nn = (len > (uint16_t)(i + 1)) ? (size_t)(len - i - 1) : 0;
                    if (nn >= sizeof(nm)) {
                        nn = sizeof(nm) - 1;
                    }
                    if (nn > 0) {
                        memcpy(nm, val + i + 1, nn);
                    }
                    nm[nn] = '\0';
                    ESP_LOGW(TAG, "CMD 0x22: song name -> \"%s\"", nm);
                    hmi_set_song(nm);            /* ⭐ 净化 + 置 dirty，由 hmi_task 下发 */
                    s_cmd_ok++;
                    i = len;                     /* ⚠️ 正文已消费完 ⇒ 结束本批 */
                    break;
                }
                default:
                    /* ⚠️ 未知命令【计数 + 报出来】，⛔ 不静默吞掉
                     *    （⭐ 静默吞会让人误以为"命令生效了但没反应"） */
                    s_cmd_unknown++;
                    ESP_LOGW(TAG, "CMD 0x%02X: UNKNOWN (ignored, cnt=%lu)",
                             c, (unsigned long)s_cmd_unknown);
                    break;
                }
            }
            if (param->write.need_rsp) {
                esp_ble_gatts_send_response(gatts_if, param->write.conn_id,
                                            param->write.trans_id, ESP_GATT_OK, NULL);
            }
            break;                              /* ⛔ 绝不继续往下当曲谱数据 */
        }

        if (h == s_handle_recv) {
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
            hmi_set_events(s_song_events_rx, s_song_total);   /* ⭐ 本曲计数，⛔ 不是累计 */
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
        /* ⭐⭐ 2026-09-30（B 子集）：**STAT(`0xABF4`) 要回【真实内容】**
         * -----------------------------------------------------------------
         * 🔴 原来这里【无条件**回 0 长度**】⇒ ⚠️ 任何特征读回来都是空串。
         *    对 `0xABF2`/`0xABF1` 无所谓（⭐ 那俩是 notify / write 口），
         *    ⚠️ 但 `0xABF4`(STAT) **是【靠读】取状态的** ⇒ 🔴 读不到就白做。
         * ⭐ 配套改动：`gatt_svc.c` 里 STAT 的响应方式由 `AUTO_RSP`
         *    改为 **`RSP_BY_APP`** ⇒ ⭐ 长度由这里说了算。
         * ⚠️ 必须 `esp_ble_gatts_send_response(...)` 回，⛔ 不能只 set 不回。 */
        if (param->read.handle == s_handle_stat) {
            const uint8_t *st = NULL;
            size_t stn = gatt_get_stat(&st);
            if (st != NULL && stn > 0) {
                if (stn > sizeof(rsp.attr_value.value)) {
                    stn = sizeof(rsp.attr_value.value);   /* ⚠️ 不能超出响应缓冲 */
                }
                memcpy(rsp.attr_value.value, st, stn);
                rsp.attr_value.len = (uint16_t)stn;
            }
            ESP_LOGI(TAG, "READ 0xABF4 -> %u bytes", (unsigned)rsp.attr_value.len);
        } else {
            rsp.attr_value.len = 0;
        }
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
    hmi_set_events(s_song_events_rx, s_song_total);   /* ⭐ 本曲计数，⛔ 不是累计 */

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
                /* ⭐⭐ 2026-10-01（实测修 bug）：复位标记 = 【新曲子开始】
                 *    ⇒ ⭐ 必须把【本曲已收事件数】清零。
                 * 🔴 不这么做的话，屏上的事件计数会**跨曲累加** ——
                 *    实测症状：灌两次 200 帧 ⇒ 屏上显示 `410/200`、
                 *    百分比 `205%`（⭐ 因为 `410*100/200`）。
                 * ⚠️ 根因：原来用的是 `s_ble_rx_bytes`（⭐ **自开机累计**，
                 *    ⛔ 从不复位）⇒ ⚠️ 而总数 `s_song_total` 是**本曲**的
                 *    ⇒ 🔴 **分子是累计、分母是本曲** ⇒ 越灌越离谱。 */
                s_song_events_rx = 0;
                continue;
            }
            /* ⭐ 事件帧 ⇒ 保留（⚠️ 原地压缩） */
            if (out != off) {
                memmove(chunk + out, p, FRAME_BYTES);
            }
            out += FRAME_BYTES;
            s_song_events_rx++;               /* ⭐ 本曲已收事件数 +1（⭐ 屏上 t2 用） */
        } else if (p[0] == FRAME_HDR_TOTAL) {
            frame_parse_total(p);             /* ⭐ 总数帧 ⇒ 自己留下 */
        } else {
            s_unknown_frames++;               /* 🔴 未知 ⇒ 丢弃 + 计数 */
            ESP_LOGW(TAG, "unknown frame hdr 0x%02X, dropped (total=%lu)",
                     p[0], (unsigned long)s_unknown_frames);
        }
    }
    /* ⭐⭐ 2026-10-01（实测修 bug）：**在这里**刷新屏上计数，⛔ 不在 BLE 回调里
     * -----------------------------------------------------------------------
     * 🔴 症状：灌 200 帧，⭐ 屏上停在 **`195/200`**（⚠️ 差几个，⛔ 不归位）。
     * ⭐ 根因：`hmi_set_events()` 原来在【BLE 写回调】里调 ——
     *    ⚠️ 而 `s_song_events_rx` 是在**这里**（`frame_filter`）才累加的，
     *    ⭐ 而 `frame_filter` 由 `task_drain` 在**之后**才跑
     *    ⇒ 🔴 **回调里读到的是【上一轮排空后】的旧值** ⇒ ⚠️ 显示**永久落后一拍**。
     * ⭐ 正解：⭐ **在计数【真正变化】的地方刷新**（⭐ 谁改谁负责）。
     *    ⚠️ 这也顺带修掉"最后一拍永远追不上" ——
     *       因为回调只在**还有新数据时**才触发，⭐ 而最后一拍之后就没有新数据了。 */
    if (out > 0) {
        hmi_set_events(s_song_events_rx, s_song_total);
    }
    /* ⭐⭐ 【灌完】→ 屏上显示 `就绪`（⭐ 用户裁定 A：灌完就进就绪）
     * -----------------------------------------------------------------------
     * 🔴 症状（2026-10-01 实测）：⭐ 灌完 200 帧，⭐ 屏上仍是 `灌谱中`。
     * ⭐ 根因：⭐ `HMI_ST_READY` **只有一个 set 点** —— 在【按 STOP】的处理里
     *    ⇒ ⚠️ 而 `hmi.h` 的注释写的是「就绪 —— 灌完，等上板按键起播」
     *    ⇒ 🔴 **注释与代码不一致**（⭐ 见 0.11 第 4 类检查）。
     * ⭐ 正解（改【上游源头】）：⭐ "灌完"的判据就在**这里** ——
     *    ⭐ `s_song_total` 是总数帧给的应到数，`s_song_events_rx` 是实到数
     *    ⇒ ⭐ **实到 == 应到（且应到 > 0）就是灌完**，⛔ 不用另设标志。
     * ⚠️ 只在 `LOADING` 时改：⛔ 不覆盖 `PLAYING` / `DONE` / `断链`
     *    （⭐ 否则重播中途收到重发的帧会把状态打回去）。 */
    if (s_song_total > 0 && s_song_events_rx >= s_song_total
        && hmi_get_state() == HMI_ST_LOADING) {
        ESP_LOGW(TAG, ">>> FEED COMPLETE (%lu/%lu) — ready to start <<<",
                 (unsigned long)s_song_events_rx, (unsigned long)s_song_total);
        hmi_set_state(HMI_ST_READY);
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
#if BLE_MODE == BLE_MODE_B_POOL
        /* ⭐⭐ 【自然放完】→ 屏上显示 `播完`
         * -----------------------------------------------------------------
         * ⭐ 判据来自 `pool_take_finished()` —— ⭐ 那是**池自己**在
         *    "游标追上了池内帧数"那个确定点上置的（见 pool.c 的 pool_pump）。
         * ⚠️ 必须用 take 语义：⭐ 本任务是【轮询】的，
         *    若只读不清 ⇒ ⚠️ 每轮都重设一次状态（遥测刷屏）。
         * ⭐ 放在循环【最前】：⛔ 不依赖"有没有新数据"，
         *    ⚠️ 放完那一刻往往已经没有新数据了。 */
        if (pool_take_finished()) {
            ESP_LOGW(TAG, ">>> PLAYBACK FINISHED (pool drained) <<<");
            hmi_set_state(HMI_ST_DONE);
        }
#endif
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
 * ⭐ 起播触发（2026-09-30 新增）
 * ===========================================================================
 * 🔴 为什么需要它：`pool_start()` 原本【零调用】⇒ `s_running` 恒 false
 *    ⇒ **`GPIO17` 永远不发数据**（`sent=` 恒 0）。
 *
 * ⚠️ 起播归属是一个【尚未裁定】的架构问题（方案③ vs 模式B 互斥）——
 *    ⭐ 详见 `files/20-代码/矛盾裁定单-方案3与模式B-20260930.md`。
 *    ⚠️ 本节**不预设裁定结果**，只让"能起播"这件事可测。
 *
 * ⭐ 三种触发（编译期由 `BLE_START_TRIGGER` 选，见 `ble_config.h` §9c）：
 *    · SERIAL —— 从 UART1 RX 收单字符（⭐ 默认，⛔ 无需接线）
 *                ⚠️ 解析点在 `task_uart_to_ble()` 里（⭐ 那个任务已持有读口）
 *    · GPIO   —— 外接按键（⭐ `BLE_BTN_GPIO`；⚠️ **2026-09-30 起是 `GPIO6`，⛔ 不是板载 BOOT 键 `GPIO0`**），⭐ 见 `task_start_trigger()`
 *    · NONE   —— 关闭
 * =========================================================================== */

/* ⭐ 统一的"起播/停/清"动作（⚠️ 触发源共用，逻辑只写一份） */
static void start_action_play(void)
{
    size_t n = pool_frames();
    if (n == 0) {
        /* ⚠️ 池空时起播没意义 —— `pool_start()` 会 `pool_peek_word(0)`，
         *    池空时返回 0 ⇒ `s_t0_tick = 0` ⇒ ⚠️ 不崩但无意义。 */
        ESP_LOGW(TAG, "START ignored: pool is EMPTY (feed frames first)");
        return;
    }
    if (pool_is_running()) {
        ESP_LOGW(TAG, "START ignored: already running (sent=%lu)",
                 (unsigned long)pool_frames_sent());
        return;
    }
    ESP_LOGW(TAG, ">>> START requested (pool=%u frames) <<<", (unsigned)n);
    pool_mark_done();     /* ⭐ 先"封口"：此后池只出不进（⭐ 并做 mismatch 校验） */
    pool_start();         /* ⭐ 真正开闸 */
    hmi_set_state(HMI_ST_PLAYING);
}

static void start_action_stop(void)
{
    ESP_LOGW(TAG, ">>> STOP requested <<<");
    pool_stop();
    hmi_set_state(HMI_ST_READY);
}

static void start_action_reset(void)
{
    ESP_LOGW(TAG, ">>> RESET requested (clear pool) <<<");
    pool_reset();
    hmi_set_state(HMI_ST_IDLE);
}

/* ===========================================================================
 * 任务 2：UART -> BLE（反向通路）+ ⭐ 起播触发（SERIAL 模式）
 * =========================================================================== */
static void task_uart_to_ble(void *arg)
{
    static uint8_t buf[512];
    (void)arg;

    for (;;) {
        int n = uart_read_bytes(BLE_UART_PORT, buf, sizeof(buf), pdMS_TO_TICKS(20));
        if (n > 0) {
        s_uart_rx_bytes += n;

        /* ⭐⭐ 2026-09-30：起播触发（⭐ SERIAL 模式）就在这里处理。
         * 🔴 **为什么放在这个任务里而不是单开一个任务**：
         *    ⚠️ `uart_read_bytes` 【同一个 UART 只能有一个读者】——
         *    开两个任务会【互相偷字节】（⭐ 各拿到一部分，两边都残缺）。
         *    ⭐ 本任务本来就持有这个读口 ⇒ 顺手解析，⛔ 不增加并发风险。
         * ⚠️ 触发字符是【裸 ASCII】（`S`/`X`/`R`），
         *    ⛔ 不是 9 字节帧 ⇒ 与下面的 notify 通路不冲突。 */
#if BLE_START_TRIGGER == BLE_START_TRIG_SERIAL
        for (int i = 0; i < n; i++) {
            uint8_t c = buf[i];
            if (c == 'S' || c == 's') {
                s_trig_cnt++;
                start_action_play();
            } else if (c == 'X' || c == 'x') {
                s_trig_cnt++;
                start_action_stop();
            } else if (c == 'R' || c == 'r') {
                s_trig_cnt++;
                start_action_reset();
            }
        }
#endif

        /* ⭐⭐ 2026-09-30（A 步）：先【无条件入环】
         * -----------------------------------------------------------------
         * 🔴 **入环必须在"是否已连接"判断【之前】** —— 这是本次修复的关键：
         *    ① ⭐ **尽快把 UART 驱动缓冲搬空**（⭐ 那只有 1026 B，见
         *       `ble_config.h:117`）⇒ ⚠️ 只要它被及时搬空，
         *       **就不再因为驱动缓冲溢出而丢字节**（⭐ 那是原来 389 字节的死因）。
         *    ② ⭐ 环是"收到多少"的**唯一账本**（`u_in`）——
         *       ⚠️ 若只在已连接时才入环，未连接期间的字节**凭空消失**
         *          ⇒ 🔴 又变成静默丢，⭐ 那就白做了。
         *    ③ ⚠️ 未连接期间环会积压 ⇒ ⭐ 满了就丢最旧 + **记账**
         *       （⭐ `u_drop` 会涨 ⇒ **看得见**，⛔ 不是无声无息）。
         * 📌 实测（2026-09-30）：环 32 KB 在 PSRAM；⭐ 512 B/次读取
         *    ⇒ ⭐ 正常情况下**一次 push 就装得下**。
         * ⚠️ 生产者与消费者是**同一个任务**（⭐ 硬约束：同一个 UART 只能有一个读者）
         *    ⇒ ⭐ 不引入并发竞争，但环本身仍做了临界区保护（⭐ 以防将来拆分）。 */
        up_ring_push(buf, (size_t)n);
        }   /* ⭐ 收尾：`n > 0` 分支到此为止 */

        /* ⭐⭐ 2026-09-30（A 步 · 关键修正）：**放水必须独立于"有没有新数据"**
         * -----------------------------------------------------------------
         * 🔴 **踩过的坑**：初版把"从环取出来发 notify"写在 `if (n > 0)` 里面
         *    ⇒ ⚠️ **只有收到新 UART 字节时才放水**。
         *    ⭐ 实测症状：蓄水 2000 字节后**接上蓝牙，`u_out` 仍是 0**
         *      —— 🔴 因为连接建立后**没有新字节进来** ⇒ 循环走不到放水那段 ⇒
         *      ⚠️ **存下来的东西永远发不出去**。
         * ⭐ 正解：**放水放在循环体里、与 `n` 无关**（⭐ 见下方），
         *    这样"连接一建立、环里还有存货"就能立刻开始放。 */
        if (s_connected && s_handle_noti != 0 && s_noti_enabled) {

        /* ⚠️ notify 单包不能超过 MTU-3 */
        size_t maxseg = (s_mtu > 3) ? (size_t)(s_mtu - 3) : 20;
        size_t off = 0;
        /* ⭐ 从环里取（⭐ 而不是直接用 `buf`）—— 这样"发出去的"与"收到的"
         *    走的是同一条账：`u_in` 入、`u_out` 出。 */
        size_t pending = (size_t)up_ring_level();
        while (off < pending) {
            size_t want = pending - off;
            uint8_t tmp[512];
            if (want > sizeof(tmp)) {
                want = sizeof(tmp);
            }
            size_t got = up_ring_pop(tmp, want);
            if (got == 0) {
                break;                          /* ⭐ 环空了 */
            }
            size_t seg_off = 0;
            while (seg_off < got) {
                size_t seg = ((got - seg_off > maxseg) ? maxseg : (got - seg_off));
                esp_err_t err = esp_ble_gatts_send_indicate(
                    /* 🔴🔴 2026-09-30 修复：这里原来传的是 `ESP_GATT_IF_NONE`（= 0xFF）。
                     *    ⚠️ 症状：蓝牙**已连接**、`s_handle_noti` 也非 0、字节也确实到了
                     *      `GPIO18`（`u_rx` 在涨），但 🔴 **上位机一个 notify 都收不到**。
                     *    ⭐ 日志铁证（ESP-IDF 蓝牙栈自己打的）：
                     *        E BT_APPL: Unknown connection ID: 255 fail sending notification
                     *    ⇒ 🔴 `ESP_GATT_IF_NONE` 就是 0xFF ⇒ 被当成 conn_id=255 ⇒ 必然失败。
                     *    ⭐ 正解：第一个参数要传【GATTS 接口】（`s_gatts_if`，
                     *      在 `ESP_GATTS_REG_EVT` 里由 `param->reg.gatts_if` 给出，见 L261），
                     *      ⛔ 不是 `ESP_GATT_IF_NONE`。
                     *    ⚠️ 注意与 `s_conn_id` 的区别：那是**连接** id，这是**接口** id，两个都要对。
                     *    📌 同一个错误在 `esp_ble_gatts_send_response` 的调用里【没有】——
                     *      那两处（L392/L403）用的是正确的 `gatts_if`。 */
                    s_gatts_if, s_conn_id, s_handle_noti, seg, tmp + seg_off, false);
                if (err != ESP_OK) {
                    s_ble_tx_failed++;
                    break;
                }
                s_ble_tx_bytes += seg;
                seg_off += seg;
                /* ⭐ 段间隔（⭐ 让蓝牙栈喘口气，⛔ 不要一口气塞满）
                 * 🔴🔴 2026-09-30 修复：**同类延时陷阱** —— 必须走 `AT_LEAST_1`。
                 *    · `BLE_TX_GAP_MS = 2`，⚠️ 而 `CONFIG_FREERTOS_HZ = 100`
                 *      ⇒ `pdMS_TO_TICKS(2)` = `2*100/1000` = 🔴 **0**
                 *      ⇒ `vTaskDelay(0)` **几乎不让出 CPU** ⇒ 本任务（优先级 8）
                 *        会贴近忙等 ⇒ ⚠️ 饿死低优先级任务 / 看门狗风险。
                 *    ⭐ 与 `task_drain` / `task_pool_pump` 那两处**同源**
                 *      （⭐ 见 `ble_config.h` §9b 与上机实测 `a310700`）。
                 *    ⚠️ **为什么本轮才修**：这条反向通路**一直没跑通**
                 *      （⭐ 刚修掉 `gatts_if` 的 bug，见上方注释）⇒
                 *      🔴 **这个延时从未被真正执行过** ⇒ 缺陷一直潜伏。
                 *    ⭐ 语义不变（"想等就得让出 CPU"），只是把 <1 tick 抬到 1 tick。 */
                vTaskDelay(BLE_DELAY_TICKS_AT_LEAST_1(BLE_TX_GAP_MS));
            }
            off += got;
            if (s_ble_tx_failed != 0) {
                break;                          /* ⚠️ 发失败了，本轮不再硬塞 */
            }
        }   /* while (off < pending) */
    }       /* if (s_connected && s_handle_noti != 0) —— 放水，
             *   ⭐ 注意它【不在】`if (n > 0)` 里面（⭐ 见上方修正说明） */
    }       /* for (;;) */
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
                 "exp=%lu mismatch=%lu clamp=%lu | "
                 /* ⭐ 2026-09-30：把 UART1【接收】字节数与触发字符计数打出来。
                  * 🔴 为什么需要它：起播触发（SERIAL 模式）走的是 UART1 RX
                  *    ⇒ ⚠️ 若"发了 S 却没反应"，光看 `sent=` 分不清是
                  *      【线没接上/波特率不对】还是【固件逻辑没触发】。
                  *    ⭐ 有了 `u_rx=`（收到的总字节）和 `trig=`（识别到的触发）
                  *      就能一刀切开：
                  *        · `u_rx` 不动 ⇒ 🔴 物理层（接线/波特率/共地）
                  *        · `u_rx` 动了但 `trig=0` ⇒ 🔴 引脚对但字符没认出
                  *        · `trig>0` 而 `sent=0` ⇒ 🔴 是起播逻辑的问题
                  * ⚠️ 之前只有模式 A 打 `uart_rx=`（见下方 #else），模式 B 缺。 */
                 "u_rx=%lu trig=%lu | mtu=%u | %s",
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
                 (unsigned long)s_uart_rx_bytes,       /* ⭐ UART1 收到的总字节 */
                 (unsigned long)s_trig_cnt,            /* ⭐ 识别到的触发字符数 */
                 (unsigned)s_mtu,
                 s_connected ? "CONN" : "----");
        /* ⭐⭐ 2026-09-30（A 步）：上行环单独一行 —— ⚠️ 上面那行已经很长了
         * 🔴 为什么必须打这几个数：这是本模块【唯一】的验收手段。
         *    ⭐ 判读表（⭐ 详见 files/20-代码/上行通路缓冲设计-20260930.md §六）：
         *      · ⭐ `u_in` = 2000（灌 2000 字节）⇒ ✅ 环生效
         *        🔴 若 `u_in` 只有 1611 ⇒ ⭐ **缓冲没生效**（⭐ 反向判据）
         *      · 🔴 `u_drop`/`u_drop_ev` **必须 0/0** ⇒ 非 0 说明环满
         *      · ⭐ `hwm` 应 ≤ 灌入量 ⇒ ⚠️ 恒 0 说明环【根本没被用上】
         *      · ⚠️ `level` 稳态应贴近 0 ⇒ 持续增长 = BLE 侧发不动
         *      · ⚠️ `u_rx - u_in` 若不为 0 ⇒ 🔴 读口逻辑有问题（⭐ 正常恒等） */
        up_ring_stats_t us;
        up_ring_stats(&us);
        ESP_LOGI(TAG,
                 "u_in=%lu u_out=%lu | ring=%lu/%lu(%s) hwm=%lu | "
                 "u_drop=%lu/%lu full=%lu | fail=%lu | cmd=%lu/%lu | %s",
                 (unsigned long)us.in, (unsigned long)us.out,
                 (unsigned long)us.level, (unsigned long)us.cap,
                 us.in_psram ? "PSRAM" : "DRAM",
                 (unsigned long)us.hwm,
                 (unsigned long)us.drop_ev, (unsigned long)us.drop,
                 (unsigned long)us.full_hits,
                 (unsigned long)s_ble_tx_failed,
                 /* ⭐ CMD 计数：`认得/不认得`（⭐ 见 s_cmd_ok 的声明处说明） */
                 (unsigned long)s_cmd_ok, (unsigned long)s_cmd_unknown,
                 s_noti_enabled ? "SUB" : "nosub");
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
 * 起播触发的 GPIO 变体（⭐ 仅 `BLE_START_TRIGGER == GPIO` 时编译）
 * ===========================================================================
 * ⚠️ 用**外接按键**（⭐ 低有效）：⭐ 引脚 = `BLE_BTN_GPIO`
 *    （⚠️ **2026-09-30 起是 `GPIO6`**，🔴 ⛔ **不是**板载 BOOT 键 `GPIO0`）。
 * ⭐ 轮询 + 消抖（⛔ 不用中断，⭐ 省事且够用）。
 * ⚠️ `BLE_BTN_POLL_MS` / `BLE_BTN_DEBOUNCE_MS` 都 ≥ 10 ms，
 *    ⛔ 不会被 `pdMS_TO_TICKS` 塌成 0（⭐ 见 ble_config.h §9b 的教训）。
 * =========================================================================== */
#if BLE_START_TRIGGER == BLE_START_TRIG_GPIO
void task_start_trigger(void *arg)
{
    (void)arg;
    int stable = 1;
    int low_ms = 0;

    ESP_LOGI(TAG, "start trigger = GPIO%d (BOOT button, active low)",
             BLE_BTN_GPIO);

    gpio_config_t io = {
        .pin_bit_mask = (1ULL << BLE_BTN_GPIO),
        .mode         = GPIO_MODE_INPUT,
        .pull_up_en   = GPIO_PULLUP_ENABLE,     /* ⭐ 板载键低有效 */
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_DISABLE,      /* ⭐ 轮询，⛔ 不用中断 */
    };
    ESP_ERROR_CHECK(gpio_config(&io));

    for (;;) {
        int now = gpio_get_level(BLE_BTN_GPIO);
        if (now == 0) {
            if (low_ms < BLE_BTN_DEBOUNCE_MS) {
                low_ms += BLE_BTN_POLL_MS;
            } else if (stable == 1) {
                stable = 0;                     /* ⭐ 消抖后确认"按下"边沿 */
                ESP_LOGI(TAG, "button pressed");
                start_action_play();
            }
        } else {
            low_ms = 0;
            stable = 1;
        }
        vTaskDelay(BLE_DELAY_TICKS_AT_LEAST_1(BLE_BTN_POLL_MS));
    }
}
#endif /* BLE_START_TRIGGER == BLE_START_TRIG_GPIO */

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

#if WS2812_ENABLE || WS2812_CLEAR_ON_BOOT || BLE_LED_ENABLE
    /* ⭐ 连接指示灯（⭐ 尽早初始化 —— ⚠️ 放在 NVS/蓝牙之前，
     *    这样"灯没亮"能立刻区分成"固件没跑起来"而不是"蓝牙没连上"） */
    ind_init();
#endif

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

    /* 🔴🔴 2026-09-24 上机实测：缺了这一步，广播使能被控制器拒绝！
     *   症状：E BT_BTM: btm_ble_write_adv_enable_complete failed
     *         E blebridge: adv start failed: 0xD
     *   ⭐ 定位：与 IDF 官方例子 ble_ibeacon 对照发现，
     *      官方在 controller_init 【之前】先调用了：
     *          esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT);
     *      ⭐ S3 硬件【只有 BLE】，经典蓝牙的内存若不放，
     *         控制器可用内存偏紧 ⇒ 广播这类"活动"申请资源失败。
     *   ⚠️ 官方【每一个】BLE 例子都有这一行，我们漏了。
     *   ⚠️ 必须在 esp_bt_controller_init() 之前调用。 */
    ESP_ERROR_CHECK(esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT));

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

    /* ⭐⭐ 2026-09-30（A 步）：上行环形缓冲初始化
     * 🔴 为什么需要它：反向通路原来**无缓冲** ⇒ 实测灌 2000 字节只收到 1611
     *    （🔴 丢 389 且**无任何报错**）。
     * ⚠️ 分配失败**不 abort** —— ⭐ 退化为原来的"直通 + 慢"行为，
     *    ⭐ 但那时 `u_in` 会停在 0、`u_drop` 也不动 ⇒ ⚠️ 一眼能看出没生效。
     * ⭐ 必须在 `task_uart_to_ble` 启动**之前**初始化（⭐ 否则会 push 到空环）。 */
    up_ring_init();

#if BLE_MODE == BLE_MODE_B_POOL
    /* ⭐ 开机初始化：⭐ 这里【允许】直接调 `pool_reset()`
     * -----------------------------------------------------------------
     * ⚠️ 理由：⭐ 此刻**屏还没初始化**（`hmi_init()` 在任务里才跑），
     *    而 `hmi_set_state()` 只是写结构体字段 ⇒ ⭐ 调了也是空转，
     *    ⚠️ 反而容易让人误以为"状态已经推给屏了"。
     * ⭐ 屏上状态本来就从 `HMI_ST_IDLE` 起（见 `hmi.c` 的 `hmi_init`）⇒
     *    ⭐ **不需要**在这里再推一次。
     * 📌 `ALLOW-DIRECT-POOL-CALL` 是给 `wrappers_check.py` 的**显式豁免标记**
     *    —— ⭐ 让"唯一一处例外"在代码里**看得见**，⛔ 不是靠记性。 */
    pool_reset();   /* ALLOW-DIRECT-POOL-CALL: 开机初始化，屏尚未就绪 */
    xTaskCreate(task_pool_pump, "pump", 4096, NULL, BLE_TASK_PRIO_DRAIN, NULL);
    ESP_LOGW(TAG, "MODE B (pool): feed whole score first.");

    /* ⭐ 起播触发（2026-09-30 新增）
     * ⚠️ 只有 GPIO 模式需要独立任务 ——
     *    SERIAL 模式的解析点在 `task_uart_to_ble()` 里
     *    （⭐ 那个任务已持有 UART 读口；🔴 开两个读者会【互相偷字节】）。 */
#if BLE_START_TRIGGER == BLE_START_TRIG_GPIO
    xTaskCreate(task_start_trigger, "start", 3072, NULL, BLE_TASK_PRIO_STATUS, NULL);
    ESP_LOGW(TAG, "START trigger = GPIO%d (BOOT button): press to start", BLE_BTN_GPIO);
#elif BLE_START_TRIGGER == BLE_START_TRIG_SERIAL
    ESP_LOGW(TAG, "START trigger = SERIAL: send 'S' to UART%d RX (GPIO%d) to start",
             BLE_UART_PORT, BLE_PIN_UART_RX);
#else
    ESP_LOGW(TAG, "START trigger = NONE: pool_start() will never be called");
#endif
#endif
    ESP_LOGI(TAG, "ready. scan for \"%s\" from phone/PC.", BLE_DEV_NAME);
}
