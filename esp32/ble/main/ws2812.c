/*
 * ws2812.c -- ⭐ 板载 WS2812 的实现（纯 RMT，⛔ 无外部依赖）
 * ============================================================================
 * 接口说明 / 硬件事实 / 那个"必须短接"的坑 ⇒ 见 ws2812.h 顶部。
 *
 * ⭐ 为什么用 RMT 而不是 GPIO 翻转：
 *   WS2812 靠【脉宽】编码 0/1（⚠️ 高电平 0.4 µs vs 0.8 µs），
 *   ⚠️ 而 FreeRTOS 任务里 `gpio_set_level` 的抖动远大于这个量级
 *   ⇒ 🔴 软件翻转必然花屏/不亮。⭐ RMT 是硬件时序发生器，⭐ 精度足够。
 * ============================================================================
 */

#include "ws2812.h"

#include "esp_log.h"
#include "esp_err.h"

#include "driver/rmt_tx.h"
#include "driver/rmt_encoder.h"

/* ⭐⭐ 守卫是【两个条件的或】—— 🔴 关键：
 *    `WS2812_ENABLE=0` 但 `WS2812_CLEAR_ON_BOOT=1` 时，⭐ **本文件仍要编译**，
 *    ⚠️ 否则"清锁存"那段代码根本不存在 ⇒ 🔴 **灯会停在旧颜色上清不掉**。
 *    （⭐ 见 ble_config.h §12 的说明：WS2812 是【锁存】的。） */
#if WS2812_ENABLE || WS2812_CLEAR_ON_BOOT

/* ⚠️ TAG 只在真正用到日志时才有意义 —— ⛔ 无条件定义会报 -Wunused-variable */
static const char *TAG = "ws2812";

/* ---- 参数 -------------------------------------------------------------- */
#define WS2812_RES_HZ      10000000u          /* ⭐ 10 MHz ⇒ 1 tick = 0.1 µs */
#define WS2812_LED_NUM     1                  /* ⚠️ 板载只有 1 颗 */

/*
 * ⭐ 时序（单位 = tick = 0.1 µs）
 *   ⚠️ 取值取"标称中心值"，留出裕量（WS2812B 容差 ±150 ns）
 *   `0` 码：高 0.4 µs / 低 0.85 µs      `1` 码：高 0.8 µs / 低 0.45 µs
 */
#define T0H   4
#define T0L   9
#define T1H   8
#define T1L   5
#define TRST  600                             /* 复位 = 60 µs 低 */

static rmt_channel_handle_t s_chan  = NULL;
static rmt_encoder_handle_t s_enc   = NULL;
static bool s_ready = false;

/* ---------------------------------------------------------------------------
 * ⭐ 自定义编码器：把 RGB 字节流编成 WS2812 的 RMT 符号
 * ---------------------------------------------------------------------------
 * ⚠️ RMT 的 `bytes_encoder` 是"一字节 → 固定符号"的，⛔ 不适合 WS2812
 *    （⭐ WS2812 是"**一位** → 一对高低电平"）⇒ ⭐ 必须自己写。
 */
typedef struct {
    rmt_encoder_t base;
    rmt_encoder_t *bytes_encoder;      /* ⚠️ 未用，⭐ 但结构里必须有 */
    rmt_encoder_t *copy_encoder;
    rmt_symbol_word_t bit0;
    rmt_symbol_word_t bit1;
    int state;
} ws2812_encoder_t;

static size_t ws2812_encode(rmt_encoder_t *encoder, rmt_channel_handle_t channel,
                            const void *primary_data, size_t data_size,
                            rmt_encode_state_t *ret_state)
{
    ws2812_encoder_t *enc = __containerof(encoder, ws2812_encoder_t, base);
    rmt_encode_state_t session_state = RMT_ENCODING_RESET;
    size_t encoded = 0;
    const uint8_t *src = (const uint8_t *)primary_data;

    /* ⭐ 逐【位】发：MSB first（⭐ WS2812 规定高位在前） */
    for (size_t i = 0; i < data_size; i++) {
        for (int bit = 7; bit >= 0; bit--) {
            rmt_symbol_word_t sym = (src[i] & (1 << bit)) ? enc->bit1 : enc->bit0;
            encoded += enc->copy_encoder->encode(enc->copy_encoder, channel,
                                                 &sym, sizeof(sym), &session_state);
        }
    }
    *ret_state = RMT_ENCODING_COMPLETE;
    return encoded;
}

static esp_err_t ws2812_encoder_reset(rmt_encoder_t *encoder)
{
    ws2812_encoder_t *enc = __containerof(encoder, ws2812_encoder_t, base);
    rmt_encoder_reset(enc->copy_encoder);
    enc->state = 0;
    return ESP_OK;
}

static esp_err_t ws2812_encoder_del(rmt_encoder_t *encoder)
{
    ws2812_encoder_t *enc = __containerof(encoder, ws2812_encoder_t, base);
    if (enc->copy_encoder) {
        rmt_del_encoder(enc->copy_encoder);
    }
    free(enc);
    return ESP_OK;
}

/* ---------------------------------------------------------------------------
 * 初始化
 * --------------------------------------------------------------------------- */
int ws2812_init(void)
{
    rmt_tx_channel_config_t tx = {
        .clk_src           = RMT_CLK_SRC_DEFAULT,
        .gpio_num          = WS2812_GPIO,
        .mem_block_symbols = 64,               /* ⚠️ 24 bit × 1 颗 ⇒ 48 符号，够用 */
        .resolution_hz     = WS2812_RES_HZ,
        .trans_queue_depth = 4,
    };
    esp_err_t err = rmt_new_tx_channel(&tx, &s_chan);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "rmt_new_tx_channel failed: %s", esp_err_to_name(err));
        return -1;
    }

    /* ⭐ 一个"拷贝"编码器 —— 我们把每个符号算好后交给它发 */
    rmt_copy_encoder_config_t cp = {};
    err = rmt_new_copy_encoder(&cp, &s_enc);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "rmt_new_copy_encoder failed: %s", esp_err_to_name(err));
        return -1;
    }

    /* ⭐ 自定义编码器挂在 copy 之上 */
    ws2812_encoder_t *enc = calloc(1, sizeof(ws2812_encoder_t));
    if (enc == NULL) {
        ESP_LOGE(TAG, "no mem for encoder");
        return -1;
    }
    enc->copy_encoder = s_enc;
    /* ⚠️ RMT 的符号是"两个电平段"：level0/duration0 + level1/duration1 */
    enc->bit0 = (rmt_symbol_word_t){
        .level0 = 1, .duration0 = T0H,
        .level1 = 0, .duration1 = T0L,
    };
    enc->bit1 = (rmt_symbol_word_t){
        .level0 = 1, .duration0 = T1H,
        .level1 = 0, .duration1 = T1L,
    };
    enc->base.encode = ws2812_encode;
    enc->base.reset  = ws2812_encoder_reset;
    enc->base.del    = ws2812_encoder_del;
    s_enc = &enc->base;                        /* ⭐ 用自定义那个发数据 */

    err = rmt_enable(s_chan);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "rmt_enable failed: %s", esp_err_to_name(err));
        return -1;
    }

    s_ready = true;

    /* ⭐⭐ 开机【显式清一次锁存】—— 🔴 这是"安全默认"的核心
     * -----------------------------------------------------------------------
     * ⭐ 用户 2026-10-01：「WS2812 好像有锁存，**一定要确保关掉**」
     * ⚠️ 完全正确：⭐ WS2812 把最后一次收到的 24 位值**锁住**，
     *    🔴 **即使固件停了 / GPIO 空闲 / ESP32 重启，它都会一直亮**
     *    ⇒ ⭐ **"不用它"⛔ 不等于"它是灭的"**。
     * ⭐ 唯一可靠的灭法：⭐ **再发一帧全 0**（⭐ 下面就是）。
     * ⚠️ 而且这一步**必须在 `WS2812_ENABLE=0` 时也执行** ——
     *    ⚠️ 否则关掉指示灯后，灯会**停在旧颜色上清不掉**。
     *    📌 所以 `ws2812_init()` 的编译守卫是
     *       `WS2812_ENABLE || WS2812_CLEAR_ON_BOOT`（⭐ 见本文件顶部）。 */
    uint8_t black[3] = { 0, 0, 0 };              /* ⭐ GRB 全 0 ＝ 灭 */
    rmt_transmit_config_t tc = { .loop_count = 0 };
    if (rmt_transmit(s_chan, s_enc, black, sizeof(black), &tc) == ESP_OK) {
        rmt_tx_wait_all_done(s_chan, 100);       /* ⚠️ 等发完，否则复位期可能不够 */
        ESP_LOGW(TAG, "LED forced OFF (latched value cleared)");
    } else {
        ESP_LOGE(TAG, "LED clear FAILED -- it may stay at its latched colour");
    }

    ESP_LOGI(TAG, "WS2812 ready: GPIO%d, RMT @%u Hz, indicator=%s",
             WS2812_GPIO, (unsigned)WS2812_RES_HZ,
             WS2812_ENABLE ? "ON" : "OFF(safe default)");
    return 0;
}

/* ---------------------------------------------------------------------------
 * 发送
 * --------------------------------------------------------------------------- */
void ws2812_set(ws2812_color_t c)
{
    if (!s_ready) {
        return;
    }
    /* ⭐ WS2812 的字节序是 **GRB**（⛔ 不是 RGB）—— ⚠️ 写错会"红蓝互换" */
    uint8_t grb[3] = { c.g, c.r, c.b };

    rmt_transmit_config_t tc = { .loop_count = 0 };
    esp_err_t err = rmt_transmit(s_chan, s_enc, grb, sizeof(grb), &tc);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "rmt_transmit failed: %s", esp_err_to_name(err));
        return;
    }
    /* ⚠️ 等发完 —— ⭐ 否则"复位低电平"可能不够长 ⇒ 🔴 灯乱闪或不变 */
    rmt_tx_wait_all_done(s_chan, 100);
}

void ws2812_set_connected(bool connected)
{
#if !WS2812_ENABLE
    /* 🔴🔴 安全默认（⭐ 2026-10-01，用户："先把灯关了，安全第一"）：
     *    ⭐ **不做连接指示** —— ⛔ **一律灭**，⚠️ 不管连没连。
     *    ⚠️ 注意：这里**仍然发全 0**（走下面的 `ws2812_set`），
     *       ⭐ 这样即便之前被锁存成某个颜色，⚡ 也会被**再清一次**。
     *    📌 为什么不能直接 `return`：⭐ WS2812 **锁存** ——
     *       ⛔ "不管它" ≠ "它会灭"，⚠️ 它会一直停在旧颜色上。 */
    (void)connected;
    ws2812_set((ws2812_color_t){ 0, 0, 0 });
    return;
#else
    /* ⭐ 语义（⭐ 集中在这里，⛔ 不散落到调用点）：
     *     · ⛔ 未连接 ⇒ **灭**
     *     · ✅ 已连接 ⇒ **绿**（⚠️ 亮度取 32/255 —— 板载 WS2812 很刺眼，
     *                   ⭐ 满亮度会晃眼且费电） */
    ws2812_color_t c = connected ? (ws2812_color_t){ 0, 32, 0 }
                                 : (ws2812_color_t){ 0, 0, 0 };
    ws2812_set(c);
#endif
}

#else  /* 既不用灯、也不清锁存 ⇒ ⭐ 全部空操作（⚠️ 此时才是真正的"不碰它"） */

int  ws2812_init(void) { return 0; }
void ws2812_set(ws2812_color_t c) { (void)c; }
void ws2812_set_connected(bool connected) { (void)connected; }

#endif /* WS2812_ENABLE */
