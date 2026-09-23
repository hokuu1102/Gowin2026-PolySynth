/*
 * hmi.c -- 淘晶驰 TJC 串口屏驱动实现
 * ============================================================================
 * 见 hmi.h 顶部说明。这里只记【实现上的坑】。
 *
 * ⚠️ 本文件全程只做"拼文本 + 写串口"，⛔ 不含任何信号处理/可视化生成。
 * ============================================================================
 */

#include <string.h>
#include <stdio.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "esp_log.h"
#include "esp_check.h"       /* ⭐ ESP_RETURN_ON_ERROR 在这里（⛔ 不在 esp_err.h） */

#include "driver/uart.h"

#include "ble_config.h"
#include "hmi.h"

static const char *TAG = "hmi";

#if !BLE_HMI_ENABLE
/* ⭐ 不接屏时：全部退化为空操作，⛔ 不占用任何 UART/引脚/任务 */
esp_err_t hmi_init(void)                 { ESP_LOGI(TAG, "HMI disabled"); return ESP_OK; }
bool      hmi_ready(void)                { return false; }
void      hmi_set_song(const char *n)    { (void)n; }
void      hmi_set_progress(uint32_t s, uint32_t t) { (void)s; (void)t; }
void      hmi_set_events(uint32_t s, uint32_t t)   { (void)s; (void)t; }
void      hmi_set_state(hmi_state_t st)  { (void)st; }
void      hmi_set_bt_connected(bool c)   { (void)c; }
void      hmi_set_buffer_pct(uint8_t p)  { (void)p; }
esp_err_t hmi_send_cmd(const char *c)    { (void)c; return ESP_OK; }
esp_err_t hmi_send_raw(const uint8_t *d, size_t l) { (void)d; (void)l; return ESP_OK; }
void      hmi_task(void *a)              { (void)a; }

#else  /* BLE_HMI_ENABLE */

/* 淘晶驰命令结束符：3 个 0xFF（⭐ 官方要求，务必每条都带） */
static const uint8_t HMI_TAIL[3] = { 0xFF, 0xFF, 0xFF };

/*
 * 屏启动完成标志。
 * ⭐ 官方 QA24：「串口屏启动成功后会发 0x88 + 结束符」——
 *    ⭐ 等它比"死等 250 ms"可靠得多（⚠️ 而且 T 系列建议值文档里没写，
 *    只写了 T0/K0=250 ms、X3/X5=1.5 s，T1 只能推断）。
 */
#define HMI_BOOT_ACK_BYTE   0x88

static bool s_ready = false;
static bool s_inited = false;

/* ---------------------------------------------------------------------------
 * 显示状态缓存
 * ---------------------------------------------------------------------------
 * ⚠️ 为什么缓存：屏刷新靠任务周期性推送（200 ms）。
 *    若每个 set 都立刻发串口，⚠️ 一是刷屏卡顿（屏主控仅 64 MHz），
 *    二是同一字段可能被高频重复发送。
 * ⭐ 缓存后由任务做【变化检测】，只在变了才发 —— 省屏带宽，也省屏的渲染。
 */
typedef struct {
    char     song[40];
    uint32_t sent;
    uint32_t total;
    hmi_state_t state;
    bool     bt_conn;
    uint8_t  buf_pct;
    /* 上次已发送的值（用于变化检测） */
    char     last_song[40];
    uint32_t last_sent;
    uint32_t last_total;
    hmi_state_t last_state;
    int      last_bt_conn;      /* -1 = 未发送过 */
    int      last_buf_pct;
    bool     dirty;
} hmi_cache_t;

static hmi_cache_t s_c;

/* ---------------------------------------------------------------------------
 * 底层发送
 * --------------------------------------------------------------------------- */
esp_err_t hmi_send_raw(const uint8_t *data, size_t len)
{
    if (data == NULL || len == 0) {
        return ESP_ERR_INVALID_ARG;
    }
    int w = uart_write_bytes(BLE_HMI_UART_PORT, (const char *)data, len);
    return (w == (int)len) ? ESP_OK : ESP_FAIL;
}

esp_err_t hmi_send_cmd(const char *cmd)
{
    if (cmd == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    /* ⭐ 命令 + 0xFF 0xFF 0xFF 一次写出去（⛔ 不要分两次 write，
     *    ⚠️ 否则中间若被别的任务插入写操作，屏会把两条命令粘在一起） */
    uint8_t buf[BLE_HMI_CMD_MAX + sizeof(HMI_TAIL)];
    size_t n = strlen(cmd);
    if (n > BLE_HMI_CMD_MAX) {
        ESP_LOGW(TAG, "cmd too long (%u), truncated", (unsigned)n);
        n = BLE_HMI_CMD_MAX;
    }
    memcpy(buf, cmd, n);
    memcpy(buf + n, HMI_TAIL, sizeof(HMI_TAIL));
    return hmi_send_raw(buf, n + sizeof(HMI_TAIL));
}

/* ---------------------------------------------------------------------------
 * UART 初始化
 * --------------------------------------------------------------------------- */
static esp_err_t hmi_uart_init(void)
{
    const uart_config_t cfg = {
        .baud_rate  = BLE_HMI_BAUD,
        .data_bits  = UART_DATA_8_BITS,       /* ⭐ 屏【只支持 8N1】 */
        .parity     = UART_PARITY_DISABLE,
        .stop_bits  = UART_STOP_BITS_1,
        .flow_ctrl  = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };

    /* ⚠️ RX 缓冲留一点即可 —— 屏只会回极少量数据（0x88、触摸事件 0x65 等） */
    ESP_RETURN_ON_ERROR(
        uart_driver_install(BLE_HMI_UART_PORT, 256, 0, 0, NULL, 0),
        TAG, "hmi uart_driver_install");
    ESP_RETURN_ON_ERROR(uart_param_config(BLE_HMI_UART_PORT, &cfg),
                        TAG, "hmi uart_param_config");
    ESP_RETURN_ON_ERROR(uart_set_pin(BLE_HMI_UART_PORT,
                                     BLE_PIN_HMI_TX,
                                     BLE_PIN_HMI_RX,
                                     UART_PIN_NO_CHANGE,
                                     UART_PIN_NO_CHANGE),
                        TAG, "hmi uart_set_pin");
    ESP_LOGI(TAG, "UART%d ready: baud=%d tx=GPIO%d rx=GPIO%d",
             BLE_HMI_UART_PORT, BLE_HMI_BAUD,
             BLE_PIN_HMI_TX, BLE_PIN_HMI_RX);
    return ESP_OK;
}

/* ---------------------------------------------------------------------------
 * ⭐ 上电握手（⭐ 官方两点要求，这里都做）
 * --------------------------------------------------------------------------- */
static void hmi_boot_handshake(void)
{
#if BLE_HMI_BOOT_SYNC
    /*
     * ① 清屏的串口缓冲（官方 QA25）
     *    原因：上电瞬间串口引脚可能有杂波，屏已经收到乱数据 ⇒
     *    ⚠️ 第一条指令会被当成乱数据的延续而解析失败。
     *    ⭐ 0x00 FF FF FF 的作用是"结束当前指令"并清掉无关数据。
     */
    const uint8_t sync[4] = { 0x00, 0xFF, 0xFF, 0xFF };
    hmi_send_raw(sync, sizeof(sync));
    ESP_LOGI(TAG, "sent boot sync 0x00 FF FF FF");
#endif

    /*
     * ② 等屏启动完成（官方 QA24）
     *    ⭐ 优先级：等 0x88 应答 > 死等固定延时
     *    ⚠️ 超时也放行（不死等）—— 否则屏没接/坏了会把启动卡住。
     */
#if BLE_HMI_WAIT_BOOT_ACK
    {
        uint8_t b = 0;
        int r = uart_read_bytes(BLE_HMI_UART_PORT, &b, 1,
                                pdMS_TO_TICKS(BLE_HMI_BOOT_ACK_MS));
        if (r == 1 && b == HMI_BOOT_ACK_BYTE) {
            ESP_LOGI(TAG, "screen boot ACK 0x88 received");
            return;                       /* ⭐ 拿到应答，不用再等 */
        }
        ESP_LOGW(TAG, "no 0x88 ACK within %d ms (got r=%d b=0x%02X) -> "
                      "falling back to fixed delay",
                 BLE_HMI_BOOT_ACK_MS, r, b);
    }
#endif

    vTaskDelay(pdMS_TO_TICKS(BLE_HMI_BOOT_DELAY_MS));
    ESP_LOGI(TAG, "boot delay %d ms done", BLE_HMI_BOOT_DELAY_MS);
}

/* ---------------------------------------------------------------------------
 * 对外接口
 * --------------------------------------------------------------------------- */
esp_err_t hmi_init(void)
{
    if (s_inited) {
        return ESP_OK;
    }

    esp_err_t err = hmi_uart_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "uart init failed: %d", err);
        return err;
    }

    /* 初值 */
    memset(&s_c, 0, sizeof(s_c));
    snprintf(s_c.song, sizeof(s_c.song), "%s", "----");
    s_c.state     = HMI_ST_IDLE;
    s_c.bt_conn   = false;
    s_c.buf_pct   = 0;
    s_c.last_bt_conn = -1;
    s_c.last_buf_pct = -1;
    s_c.dirty     = true;

    hmi_boot_handshake();

    s_ready  = true;
    s_inited = true;

    xTaskCreate(hmi_task, "hmi", 3072, NULL, 3, NULL);
    ESP_LOGI(TAG, "HMI ready");
    return ESP_OK;
}

bool hmi_ready(void) { return s_ready; }

void hmi_set_song(const char *name)
{
    const char *p = (name && *name) ? name : "----";
    if (strncmp(s_c.song, p, sizeof(s_c.song)) != 0) {
        snprintf(s_c.song, sizeof(s_c.song), "%s", p);
        s_c.dirty = true;
    }
}

void hmi_set_progress(uint32_t sent, uint32_t total)
{
    if (s_c.sent != sent || s_c.total != total) {
        s_c.sent  = sent;
        s_c.total = total;
        s_c.dirty = true;
    }
}

void hmi_set_events(uint32_t sent, uint32_t total)
{
    /* ⚠️ 与 set_progress 共用 sent/total（同一份数据的两种呈现） */
    hmi_set_progress(sent, total);
}

void hmi_set_state(hmi_state_t st)
{
    if (s_c.state != st) {
        s_c.state = st;
        s_c.dirty = true;
    }
}

void hmi_set_bt_connected(bool connected)
{
    if (s_c.bt_conn != connected) {
        s_c.bt_conn = connected;
        s_c.dirty   = true;
    }
}

void hmi_set_buffer_pct(uint8_t pct)
{
    if (pct > 100) {
        pct = 100;
    }
    if (s_c.buf_pct != pct) {
        s_c.buf_pct = pct;
        s_c.dirty   = true;
    }
}

/*
 * 状态字 -> 中文文本
 * ---------------------------------------------------------------------------
 * ⚠️ 三种"故障"要语义并列、⛔ 不要混：
 *      · `断链`     = 🔴 **蓝牙链路断了**（物理层没了）
 *      · `供数不足` = 🔴 **链路在，但数据没跟上**（evt_underrun）
 *      · `溢出!`    = 🔴 **喂太快，FPGA 缓冲满了**
 *   ⭐ 原用「喂不饱」，⚠️ 太口语 ⇒ 改成「供数不足」（书面、且与另两个并列清晰）。
 */
static const char *state_text(hmi_state_t st)
{
    switch (st) {
    case HMI_ST_IDLE:       return "待机";
    case HMI_ST_LOADING:    return "灌谱中";
    case HMI_ST_READY:      return "就绪";
    case HMI_ST_PLAYING:    return "播放中";
    case HMI_ST_UNDERRUN:   return "供数不足";
    case HMI_ST_LINK_LOST:  return "断链";
    case HMI_ST_OVERFLOW:   return "溢出!";
    case HMI_ST_DONE:       return "播完";
    default:                return "???";
    }
}

/* ---------------------------------------------------------------------------
 * ⭐ 刷新任务：把缓存里变了的字段推给屏
 * ---------------------------------------------------------------------------
 * ⚠️ 只在【变化】时发 —— 省屏带宽，也避免屏渲染卡顿
 *    （屏主控只有 64 MHz，运行内存仅 3584 字节）。
 */
void hmi_task(void *arg)
{
    (void)arg;
    char cmd[BLE_HMI_CMD_MAX];

    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(BLE_HMI_REFRESH_MS));

        if (!s_ready || !s_c.dirty) {
            continue;
        }
        s_c.dirty = false;

        /* ① 曲谱名 -> g0.txt（⭐ g0 是【滚动文本】，长歌名靠它）
         *    ⚠️ 固定标签「曲谱：」在 t0 里，是初值，⛔ 固件不用发 */
        if (strncmp(s_c.last_song, s_c.song, sizeof(s_c.song)) != 0) {
            snprintf(cmd, sizeof(cmd), "g0.txt=\"%s\"", s_c.song);
            hmi_send_cmd(cmd);
            snprintf(s_c.last_song, sizeof(s_c.last_song), "%s", s_c.song);
        }

        /* ② 进度条 + 百分比数字
         *    ⭐ 百分比让【屏自己算】—— 只发一条 n0.val=sent*100/total
         *    ⚠️ 屏不支持浮点 ⇒ 必须"先乘 100 再除"（官方 QA134 的写法）
         *    ⚠️ 布局去掉了 "%" 后缀 —— 旁边就是进度条，不会误解 */
        if (s_c.sent != s_c.last_sent || s_c.total != s_c.last_total) {
            uint32_t pct = (s_c.total > 0)
                         ? (uint32_t)((uint64_t)s_c.sent * 100ull / s_c.total)
                         : 0;
            if (pct > 100) {
                pct = 100;
            }
            snprintf(cmd, sizeof(cmd), "j0.val=%u", (unsigned)pct);
            hmi_send_cmd(cmd);

            if (s_c.total > 0) {
                /* ⭐ 屏自己算百分比（省一条我们这边的除法/格式化） */
                snprintf(cmd, sizeof(cmd), "n0.val=%u*100/%u",
                         (unsigned)s_c.sent, (unsigned)s_c.total);
            } else {
                snprintf(cmd, sizeof(cmd), "n0.val=0");
            }
            hmi_send_cmd(cmd);

            /* ③ 事件计数 -> t2.txt（⭐ 去掉 "事件：" 前缀，省屏宽）
             *    ⚠️ 与蓝牙【分属两个控件】—— 因为 t3.pco 改的是【整个控件】的颜色，
             *       合并的话数字会跟着一起变红/变绿 */
            snprintf(cmd, sizeof(cmd), "t2.txt=\"%u/%u\"",
                     (unsigned)s_c.sent, (unsigned)s_c.total);
            hmi_send_cmd(cmd);

            s_c.last_sent  = s_c.sent;
            s_c.last_total = s_c.total;
        }

        /* ④ 状态字 -> t1.txt（⭐ 去掉 "状态：" 前缀） */
        if (s_c.state != s_c.last_state) {
            snprintf(cmd, sizeof(cmd), "t1.txt=\"%s\"", state_text(s_c.state));
            hmi_send_cmd(cmd);
            s_c.last_state = s_c.state;
        }

        /* ⑤ 蓝牙连接 -> t3.txt + t3.pco（⭐ 独立控件，所以能单独变色）
         *    ⭐ 用 "BT OK" / "BT --" 而不是勾叉 ——
         *       ⚠️ "✓/✗"(U+2713/2717) 是 Unicode 符号，字库里多半没有 ⇒ 会显示成方块；
         *       ⭐ 而 ASCII 字库必有 ⇒ 零风险。 */
        if ((int)s_c.bt_conn != s_c.last_bt_conn) {
            snprintf(cmd, sizeof(cmd), "t3.txt=\"BT %s\"",
                     s_c.bt_conn ? "OK" : "--");
            hmi_send_cmd(cmd);

            /* ⭐ 颜色（官方 HMI 颜色表：GREEN=2016 / RED=63488）
             *    ⚠️ pco 是【整个控件】的字体色 —— 这正是 t3 要独立的原因 */
            snprintf(cmd, sizeof(cmd), "t3.pco=%u",
                     s_c.bt_conn ? 2016u : 63488u);
            hmi_send_cmd(cmd);

            s_c.last_bt_conn = (int)s_c.bt_conn;
        }

        /* ⑥ 缓冲水位 -> ⚠️ 本轮布局【已去掉这个控件】（屏只有 320×240，位置不够）
         *    ⚠️ 保留代码但⛔ 不发命令 —— 免得屏报 "控件不存在"
         *    ⭐ 若将来又加回 t4，把下面这段的 #if 打开即可 */
#if 0
        if ((int)s_c.buf_pct != s_c.last_buf_pct) {
            snprintf(cmd, sizeof(cmd), "t4.txt=\"%u%%\"", (unsigned)s_c.buf_pct);
            hmi_send_cmd(cmd);
            s_c.last_buf_pct = (int)s_c.buf_pct;
        }
#endif
    }
}

#endif /* BLE_HMI_ENABLE */
