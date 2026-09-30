/* ===========================================================================
 * uart_test_main.c —— ESP32-S3 UART1 发送自检固件（⭐ 一次性诊断用）
 * ===========================================================================
 *
 * ⭐ 目的：独立验证「UART1 (GPIO17 TX) 能否正确发出 9 字节帧」，
 *     ⛔ 不经过水池、⛔ 不依赖起播。
 *
 * 🔴 为什么需要它（2026-09-30 实测发现）：
 *    正式固件 esp32/ble 里 `pool_start()` 【零调用】（全仓库只有定义与声明）
 *    ⇒ 放水路径根本没接上 ⇒ GPIO17 永远不发数据。
 *    ⚠️ 直接拿正式固件验 UART 只会收到 0 字节 ——
 *       然后白白去怀疑接线 / 波特率 / 共地。
 *    ⭐ 本固件把 UART 通路单独隔离出来，验完即弃。
 *
 * ⭐ 自检信号（接地后 USB-TTL 应看到）：
 *    每 1 秒发 36 帧 = 324 字节，帧头全 0xA5，
 *    帧体 = 递增序号（0,1,2,...）⇒ ⭐ 收端能一眼看出丢帧/错位。
 *    发完 36 帧后打一行日志。连发 3 轮后停下（⛔ 不无限刷屏，
 *    免得收端缓冲区被灌爆后难判断）。
 *
 * ⚠️ 接线（交叉！）：
 *    ESP32 GPIO17 (TX) ──→ USB-TTL RX
 *    ESP32 GND ─────────── USB-TTL GND   🔴 必须共地
 *    ⛔ USB-TTL 的 5V/VCC 不要接（ESP32 自己从 USB 取电）
 *
 * ⚠️ 波特率 500000（⭐ 与正式固件 BLE_BAUD / FPGA 侧一致）
 *    ⭐ 为什么是 500 k 而不是 1 M（2026-09-30 更正）：
 *      · 🔴 FPGA 侧【2026-09-24 就降到 500 k】了
 *        （`FPGA2026/rtl/top.v:682/709/765/809/914`）
 *      · ⭐ 用户实测：**1 Mbps 经常出问题，500 k 比较稳定**
 *    ⚠️ 两侧【必须同档】—— 不同档会【静默乱码】（⛔ 不报错）。
 *    ⚠️ 若某 USB-TTL 跑不了 500 k，可用 `-DTEST_BAUD=115200` 覆盖（⭐ 见下方 `#ifndef`）
 * ===========================================================================
 */

#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/uart.h"
#include "driver/gpio.h"
#include "esp_log.h"

static const char *TAG = "uarttest";

/* ---- 与正式固件保持一致的参数（⭐ 这样验的才是同一条通路）-------------- */
#define TEST_UART_PORT   UART_NUM_1
#define TEST_PIN_TX      17
#define TEST_PIN_RX      18
/* ⭐ 做成可覆盖（⚠️ 与 `ble_config.h` 的 BLE_BAUD 同一写法）*/
#ifndef TEST_BAUD
#define TEST_BAUD        500000
#endif
#define TEST_TX_BUF      (9 * 114)     /* 1026 B，与正式固件一致 */
#define TEST_RX_BUF      (9 * 114)

#define FRAME_BYTES      9
#define HDR_EVENT        0xA5

#define FRAMES_PER_BURST 36            /* = 324 字节，9 的整数倍 */
#define BURST_INTERVAL_MS 1000
#define MAX_BURSTS       3             /* 连发 3 轮后停，便于判读 */

/* ---------------------------------------------------------------------------
 * 组一帧：帧头 0xA5 + 8 字节体（体 = 大端 64 位序号）
 * ⭐ 序号递增 ⇒ 收端可一眼判断有没有丢帧 / 错位 / 截断
 * ------------------------------------------------------------------------- */
static void make_frame(uint8_t *out, uint32_t seq)
{
    out[0] = HDR_EVENT;
    /* 序号放低 8 字节，大端 */
    out[1] = (uint8_t)((seq >> 56) & 0xFF);
    out[2] = (uint8_t)((seq >> 48) & 0xFF);
    out[3] = (uint8_t)((seq >> 40) & 0xFF);
    out[4] = (uint8_t)((seq >> 32) & 0xFF);
    out[5] = (uint8_t)((seq >> 24) & 0xFF);
    out[6] = (uint8_t)((seq >> 16) & 0xFF);
    out[7] = (uint8_t)((seq >> 8) & 0xFF);
    out[8] = (uint8_t)(seq & 0xFF);
}

/* ---------------------------------------------------------------------------
 * ⭐ 引脚自证：把 TX 脚短暂当输入读一次电平，证明脚没被别的东西占着
 *    （⚠️ 只是诊断信息，不影响发送）
 * ------------------------------------------------------------------------- */
static void pin_selfcheck(void)
{
    gpio_set_direction(TEST_PIN_TX, GPIO_MODE_INPUT);
    gpio_set_pull_mode(TEST_PIN_TX, GPIO_FLOATING);
    vTaskDelay(pdMS_TO_TICKS(5));
    int lvl = gpio_get_level(TEST_PIN_TX);
    ESP_LOGI(TAG, "pin self-check: GPIO%d floating level = %d", TEST_PIN_TX, lvl);
    /* 交还给 UART */
    gpio_set_direction(TEST_PIN_TX, GPIO_MODE_OUTPUT);
}

void app_main(void)
{
    ESP_LOGI(TAG, "=== ESP32-S3 UART1 TX self-test ===");
    ESP_LOGI(TAG, "uart=%d baud=%d tx=GPIO%d rx=GPIO%d",
             TEST_UART_PORT, TEST_BAUD, TEST_PIN_TX, TEST_PIN_RX);
    ESP_LOGI(TAG, "burst = %d frames = %d bytes, every %d ms, %d bursts",
             FRAMES_PER_BURST, FRAMES_PER_BURST * FRAME_BYTES,
             BURST_INTERVAL_MS, MAX_BURSTS);
    ESP_LOGI(TAG, "WIRING: ESP32 GPIO%d(TX) -> USB-TTL RX ; GND -- GND (cross + common ground)",
             TEST_PIN_TX);

    /* ---- 配 UART ------------------------------------------------------- */
    const uart_config_t cfg = {
        .baud_rate  = TEST_BAUD,
        .data_bits  = UART_DATA_8_BITS,
        .parity     = UART_PARITY_DISABLE,
        .stop_bits  = UART_STOP_BITS_1,
        .flow_ctrl  = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };

    ESP_ERROR_CHECK(uart_driver_install(TEST_UART_PORT,
                                        TEST_RX_BUF, TEST_TX_BUF,
                                        0, NULL, 0));
    ESP_ERROR_CHECK(uart_param_config(TEST_UART_PORT, &cfg));
    ESP_ERROR_CHECK(uart_set_pin(TEST_UART_PORT,
                                 TEST_PIN_TX, TEST_PIN_RX,
                                 UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE));

    pin_selfcheck();

    ESP_LOGI(TAG, "UART ready. sending in 2 s ...");
    vTaskDelay(pdMS_TO_TICKS(2000));

    /* ---- 发 3 轮 ------------------------------------------------------- */
    uint8_t frame[FRAME_BYTES];
    uint32_t seq = 0;

    for (int burst = 0; burst < MAX_BURSTS; burst++) {
        /* ⚠️ 一次性组好整块再写 —— ⭐ 保持"一帧 9 字节一次写入、块大小 9N" */
        static uint8_t block[FRAMES_PER_BURST * FRAME_BYTES];
        for (int i = 0; i < FRAMES_PER_BURST; i++) {
            make_frame(&block[i * FRAME_BYTES], seq++);
        }

        int w = uart_write_bytes(TEST_UART_PORT, (const char *)block, sizeof(block));
        ESP_LOGI(TAG, "burst %d/%d: wrote %d bytes (%d frames), seq up to %lu",
                 burst + 1, MAX_BURSTS, w, FRAMES_PER_BURST,
                 (unsigned long)(seq - 1));

        if (w != (int)sizeof(block)) {
            ESP_LOGE(TAG, "SHORT WRITE: expected %d, got %d",
                     (int)sizeof(block), w);
        }

        /* ⭐ 等 UART FIFO 真的吐完再进下一轮 */
        ESP_ERROR_CHECK(uart_wait_tx_done(TEST_UART_PORT, pdMS_TO_TICKS(500)));

        vTaskDelay(pdMS_TO_TICKS(BURST_INTERVAL_MS));
    }

    ESP_LOGI(TAG, "=== test done: %lu frames (%lu bytes) sent ===",
             (unsigned long)seq, (unsigned long)(seq * FRAME_BYTES));
    ESP_LOGI(TAG, "if USB-TTL saw %lu bytes of 0xA5 frames -> UART path is GOOD",
             (unsigned long)(seq * FRAME_BYTES));

    /* ⭐ 不再发送，但保持存活（⛔ 不重启，免得收端看到重复数据） */
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(5000));
        ESP_LOGI(TAG, "idle (test finished)");
    }
}
