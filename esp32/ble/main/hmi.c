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
void      hmi_set_play_pos(uint32_t pt, uint32_t t0, uint32_t lead,
                           uint32_t total, bool valid)
                                       { (void)pt; (void)t0; (void)lead;
                                         (void)total; (void)valid; }
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
    /* 播放位置（2026-10-13 新增）。
     * 灌完之后 sent/total 恒为 100%，进度条就"死"了；
     * 而用户真正想知道的是"放到哪了"。
     * 消费方算法：heard = play_tick - play_t0 - play_lead（还没出声时 <= 0）。 */
    uint32_t play_tick;         /* 此刻应播到的谱面 tick */
    uint32_t play_t0;           /* 起播锚点 */
    uint32_t play_lead;         /* 提前量（tick） */
    uint32_t play_total;        /* 本曲总 tick（分母；0 = 未知，退回灌谱百分比） */
    bool     play_valid;        /* 位置是否有效（正在放水） */
    /* 上次已发送的值（用于变化检测） */
    char     last_song[40];
    uint32_t last_sent;
    uint32_t last_total;
    hmi_state_t last_state;
    int      last_bt_conn;      /* -1 = 未发送过 */
    int      last_buf_pct;
    int      last_play_pct;     /* -1 = 未发送过；播放进度的变化检测 */
    bool     dirty;
} hmi_cache_t;

static hmi_cache_t s_c;

/* 状态迁移计数器（2026-10-12 新增）。
 *
 * 为什么需要它：`断链` 是一个【转瞬即逝】的过渡态 ——
 *   断开时置 LINK_LOST，而重连成功后又立刻置 READY。
 *   测试想验证"断开确实置了断链"，但等它能读到（必须重连）时，
 *   状态已经变回 `就绪` 了 => 无法区分下面两种可能：
 *     · 断开时确实置了 `断链`（正确）
 *     · 断开时根本没置（缺陷）—— 反正重连后都是 `就绪`，看不出来
 *   => 这是一个【不可观测的中间行为】，判据无从下手。
 *
 * 修法：把"进入每个状态各多少次"记下来，事后从 0xABF4 读。
 *   这样"断开置断链"就有了【独立于读取时机】的判据。
 *   同族 C139（显示层掩盖内部真值）—— 把内部真值暴露成可读字段。
 *
 * 注意：定义必须放在 hmi_init 之前（它在初始化时就要计数）。
 */
static uint32_t s_enter_cnt[HMI_ST_COUNT];

/* ===========================================================================
 * ⭐⭐ 2026-10-01：屏 → ESP32 方向的【诊断计数】（⭐ 用户实测：屏有界面但数字不变）
 * ===========================================================================
 * 🔴 **为什么需要它**：⭐ 症状是"屏有界面（⭐ 说明屏有电、工程已下载），
 *    ⚠️ 但固件发的命令【不生效】" ⇒ 🔴 **无法区分**下面两种原因：
 *      · ⚠️ ESP32 **没发出去**（⭐ 或发错脚）
 *      · 🔴 **接线没通**（⭐ 最常见：`TX/RX` 没交叉）
 *    ⇒ ⭐ 所以必须有一个**独立于"发送"的判据**。
 *
 * ⭐ 本计数就是那个判据：⭐ **只要屏发过任何字节，这里就会涨**。
 *    · ⭐ **涨了** ⇒ 屏→ESP32 通路**通** ⇒ 🔴 问题在**反方向**（ESP32→屏）
 *    · 🔴 **一直 0** ⇒ 屏根本没送出来 ⇒ ⚠️ 查 `屏 TX → GPIO5` / 共地
 *
 * ⭐ 顺带**实装触摸事件**（⭐ `hmi.c:127` 的注释早就提到 `0x65`，⚠️ 但一直没有解析器）：
 *    TJC 触摸事件格式 = `0x65 <页> <控件> <事件> 0xFF 0xFF 0xFF`
 *    ⇒ ⭐ 数它有几个，⭐ 就能知道"屏上的按键按下去有没有到 ESP32"。
 */
static volatile uint32_t s_rx_bytes  = 0;   /* ⭐ 从屏收到的总字节 */
static volatile uint32_t s_rx_touch  = 0;   /* ⭐ 收到的触摸事件数（0x65） */
static volatile uint8_t  s_rx_last   = 0;   /* ⭐ 最后一个字节（⭐ 便于看是什么） */
static volatile uint32_t s_tx_cmds   = 0;   /* ⭐ 发给屏的命令条数（⭐ 发送侧的本地证据） */

void hmi_rx_stats(uint32_t *bytes, uint32_t *touch, uint8_t *last)
{
    if (bytes) { *bytes = s_rx_bytes; }
    if (touch) { *touch = s_rx_touch; }
    if (last)  { *last  = s_rx_last; }
}

uint32_t hmi_tx_cmds(void)
{
    return s_tx_cmds;
}

/* ⭐ 非阻塞收：⭐ 由 `hmi_task` 每轮调用（⛔ 不另开任务 —— ⚠️ 一个 UART 只能有一个读者） */
void hmi_poll_rx(void)
{
    if (!s_ready) {
        return;
    }
    /* ⚠️⚠️ 这个缓冲只有 32 B ⇒ ⭐ **一条长回复会被拆成多行日志**
     * -----------------------------------------------------------------
     * 🔴 实测踩过（2026-10-01）：⭐ 用 CMD `0x22` 设了个 60 字符的曲名，
     *    再 `get g0.txt` 读回 ⇒ ⚠️ 日志里只看到 **31** 个字符
     *    ⇒ 🔴 **我差点判定"固件把名字截断了"**（⭐ 固件其实没错）。
     * ⭐ 真因：⭐ `get` 的回复（⭐ `p` + 39 字符 + `FF FF FF`）**长于 32 B**
     *    ⇒ ⭐ 被拆成 2 段、⭐ 打成了**两行**日志。
     * ⭐ 判据（⭐ 读日志的人必须知道）：⭐ **回复以 `FF FF FF` 结束** ——
     *    ⚠️ 没看到结束符就说明**还没读完**，⭐ 要把后续行**拼起来**。
     * ⚠️ 当前固件**只把收到的字节计数+打日志，⛔ 不解析**
     *    ⇒ ⭐ 32 B 够用，⛔ **不是 bug**。
     * 🔴 **但这是个陷阱**：⭐ 将来若要让固件**解析**回复
     *    （⭐ 例如自己读回 `g0.txt` 做校验），⭐ 32 B 会**静默截断**
     *    ⇒ ⚠️ 那时必须**先把缓冲放大**，⛔ 不能直接用。
     * 📌 同族：`C139`（⭐ "显示没变"≠"值没设"）—— ⭐ 都是**测量层**的误判。 */
    uint8_t buf[32];
    int n = uart_read_bytes(BLE_HMI_UART_PORT, buf, sizeof(buf), 0);  /* ⚠️ 0 = 不等待 */
    if (n <= 0) {
        return;
    }
    for (int i = 0; i < n; i++) {
        s_rx_last = buf[i];
        if (buf[i] == 0x65) {          /* ⭐ TJC 触摸事件头 */
            s_rx_touch++;
        }
    }
    s_rx_bytes += (uint32_t)n;
    /* ⚠️ 只在收到东西时打日志 —— ⭐ 否则每秒刷屏，把有用的信息淹掉
     * ⭐⭐ 2026-10-01：**同时打 hex** —— 🔴 否则只能看到"收了多少字节"，
     *    ⚠️ 而 `get` 的答复内容正是排查"控件名对不对"的**唯一证据**
     *    （⭐ 实测：屏回了 32 B，⚠️ 但不 dump 就不知道回的是什么）。 */
    {
        char hex[3 * sizeof(buf) + 1];
        size_t o = 0;
        for (int i = 0; i < n && o + 3 < sizeof(hex); i++) {
            o += (size_t)snprintf(hex + o, sizeof(hex) - o, "%02X ", buf[i]);
        }
        ESP_LOGI(TAG, "screen -> ESP32: %d B (total=%lu touch=%lu) [%s]",
                 n, (unsigned long)s_rx_bytes, (unsigned long)s_rx_touch, hex);
    }
}

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
    /* ⭐⭐ 2026-10-01：**发出去的每条命令都记账 + 打日志**
     * -----------------------------------------------------------------------
     * 🔴 为什么必须加：⭐ 实测"屏有界面但数字不变"时，⚠️ **完全无法确认
     *    ESP32 到底发没发** —— ⭐ 发送路径原来**一个字节都不打日志**
     *    ⇒ 🔴 只能靠"屏上变没变"这一个**远端**证据，⚠️ 而它分不清
     *      "没发" / "发错脚" / "屏没收到" / "屏收到但控件名不对"。
     * ⭐ 现在：⭐ **发送侧有本地证据**（`hmi.tx` 计数 + 每条的原文）
     *    ⇒ ⭐ 与屏上的现象对照，**一眼定位是哪一段断了**。 */
    s_tx_cmds++;
    ESP_LOGI(TAG, "screen <- ESP32: \"%s\" (tx=%lu)", cmd,
             (unsigned long)s_tx_cmds);

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
    /* 开机进 IDLE 也要计数 —— 否则 `st.i` 恒 0，看起来像计数器坏了
     * （⚠️ 这里刻意【不】调 hmi_set_state：那会把 dirty 置 true 并触发
     *   一次多余的全量刷新，而本函数下面本来就会做初次同步）。 */
    s_enter_cnt[HMI_ST_IDLE]++;
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
    char clean[sizeof(s_c.song)];
    size_t k = 0;

    /* ⭐⭐ 净化（⭐ 必须在【源头】做，⛔ 不是在拼命令的地方）
     * -----------------------------------------------------------------
     * 🔴 为什么必须净化：⭐ 曲名最终会拼成 `g0.txt="<名字>"` ——
     *    ⚠️ 若名字里含【双引号】⇒ 🔴 **TJC 命令被截断/错位**
     *    （⭐ 例如名字 `a"b` ⇒ 发出 `g0.txt="a"b"` ⇒ ⭐ 屏收到的字符串是 `a`，
     *      ⚠️ 而多出来的 `b"` 会被当成**下一条命令的开头** ⇒ 🔴 后面全乱）。
     * ⚠️ 控制字符（⭐ < 0x20，⭐ 尤其 `FF`）同理 ——
     *    ⭐ TJC 用 `FF FF FF` 当**结束符** ⇒ 🔴 名字里混进 `FF` 会**提前结束**。
     * ⭐ 所以：⭐ **丢掉**双引号、反斜杠、`0x7F` 与控制字符；
     *    ⭐ 其余（⭐ 含 UTF-8 多字节，⭐ 其字节都 ≥ 0x80）原样保留。
     * 📌 放在这里 ⇒ ⭐ **任何调用方都自动受保护**（⭐ 不是每个调用点各写一遍）。 */
    for (const unsigned char *q = (const unsigned char *)p;
         *q && k + 1 < sizeof(clean); q++) {
        if (*q == '"' || *q == '\\' || *q == 0x7F || *q < 0x20) {
            continue;
        }
        clean[k++] = (char)*q;
    }
    clean[k] = '\0';
    if (k == 0) {
        snprintf(clean, sizeof(clean), "%s", "----");
    }

    if (strncmp(s_c.song, clean, sizeof(s_c.song)) != 0) {
        snprintf(s_c.song, sizeof(s_c.song), "%s", clean);
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

/* 播放位置（2026-10-13 新增）。
 *
 * 为什么单独一个 setter：`sent/total`（灌谱量）与"播放位置"是【两件事】——
 *   灌完之后前者恒为 100%，只有后者还会继续动。
 *   ⚠️ 而且它们的变化频率不同：前者很多次，后者每秒都在变
 *   => 分开设置 + 各自做变化检测，避免刷屏。
 *
 * `total` 是本曲总 tick（分母）；传 0 表示未知 => 显示层退回灌谱百分比。
 */
void hmi_set_play_pos(uint32_t play_tick, uint32_t t0_tick, uint32_t lead_ticks,
                      uint32_t total_ticks, bool valid)
{
    s_c.play_tick  = play_tick;
    s_c.play_t0    = t0_tick;
    s_c.play_lead  = lead_ticks;
    s_c.play_total = total_ticks;
    s_c.play_valid = valid;
    /* 注意：这里【不】置 dirty —— 播放进度是"连续变化量"，
     *   由刷新任务的周期性节拍驱动（见 hmi_task），
     *   ⛔ 不用 dirty 触发（否则每来一帧数据就刷一次屏）。 */
}

void hmi_set_state(hmi_state_t st)
{
    /* 计数必须【无条件】做（2026-10-12 修正）。
     * ---------------------------------------------------------------
     * 原来写在 `if (s_c.state != st)` 里面 => 记的是【变化次数】，
     *   而不是【进入次数】。后果（实测踩到）：
     *     · 开机时 hmi_init 直接赋 IDLE（不走本函数）=> `st.i` 恒 0
     *     · 断开时若 s_c.state 已经是 LINK_LOST（上次留下的）
     *       => 本次"断链"【不计数】=> `st.x` 恒 0
     *   => 🔴 判据 `st.x >= 1` 永远不成立，看起来像"固件没置断链"，
     *      而日志里明明发了 `t1.txt="断链"` —— 白查了半天。
     * ⭐ 教训：既然叫"进入次数"，就必须【每次调用都算】；
     *   想知道"有没有变化"是另一件事（那才是脏标记的职责）。
     *   ⛔ 不要把两个语义塞进同一个 if。
     */
    if ((unsigned)st < (unsigned)HMI_ST_COUNT) {
        s_enter_cnt[st]++;

    }
    if (s_c.state != st) {
        s_c.state = st;
        s_c.dirty = true;
    }
}

/* 读某状态的进入次数 —— 供 0xABF4 暴露 */
uint32_t hmi_state_enter_count(hmi_state_t st)
{
    return ((unsigned)st < (unsigned)HMI_ST_COUNT) ? s_enter_cnt[st] : 0;
}
/* ⭐ 读当前状态 —— ⭐ 供"只在某状态下才迁移"的判断用
 * ⚠️ 本文件**没有锁**（⭐ 全文件都是无锁风格，见 grep 无 Semaphore/Mutex）
 *    ⇒ ⭐ 这里也保持一致：⭐ 单个 enum 字段的读在 ESP32 上是【单字原子】的，
 *       ⚠️ 不引入锁（⛔ 只给一个 getter 加锁，反而与 setter 不对称）。
 * ⚠️ 语义提醒：⭐ 读到的值**可能立刻过期**（另一个任务下一秒就改）
 *    ⇒ ⭐ 只可用于"决定要不要迁移"，⛔ 不可用于任何需要精确同步的场合。 */
hmi_state_t hmi_get_state(void)
{
    return s_c.state;
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

        /* ⭐⭐ 2026-10-01：每轮先收屏的字节（⭐ 诊断 + 触摸事件）
         *    ⚠️ 放在 `dirty` 判断【之前】—— ⭐ 收数据与"要不要刷新"无关，
         *       ⚠️ 否则 dirty 为假时永远不收 ⇒ 🔴 诊断永远看不到东西 */
        hmi_poll_rx();

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
            /* 播放中：进度条改成显示【播放位置】，⛔ 不再是灌谱百分比。
             * 为什么这样切：灌完之后 sent/total 恒为 100%，进度条就"死"了；
             *   而用户真正想知道的是"放到哪了"。
             * 判据：拿到有效的播放位置（play_valid）就用它，否则退回灌谱百分比。
             * 语义区分靠 t2（灌谱计数）与 t1（播放中/播完）不变。 */
            if (s_c.play_valid && s_c.play_total > 0) {
                uint64_t heard = 0;
                if (s_c.play_tick > (s_c.play_t0 + s_c.play_lead)) {
                    heard = (uint64_t)s_c.play_tick - s_c.play_t0 - s_c.play_lead;
                }
                if (heard > s_c.play_total) {
                    heard = s_c.play_total;
                }
                pct = (uint32_t)(heard * 100ull / s_c.play_total);
                if (pct > 100) {
                    pct = 100;
                }
            }
            snprintf(cmd, sizeof(cmd), "j0.val=%u", (unsigned)pct);
            hmi_send_cmd(cmd);

            if (s_c.total > 0) {
                /* 屏自己算百分比（省一条我们这边的除法/格式化） */
                snprintf(cmd, sizeof(cmd), "n0.val=%u*100/%u",
                         (unsigned)s_c.sent, (unsigned)s_c.total);
            } else {
                snprintf(cmd, sizeof(cmd), "n0.val=0");
            }
            hmi_send_cmd(cmd);

            /* ③ 事件计数 -> t2.txt（⭐ 去掉 "事件：" 前缀，省屏宽）
             *    ⚠️ 与蓝牙【分属两个控件】—— 因为 t3.pco 改的是【整个控件】的颜色，
             *       合并的话数字会跟着一起变红/变绿
             * ⭐⭐ 2026-10-12：⭐ 显示层钳制（⚠️ 这是【兜底】，⛔ 不是修法）
             * ---------------------------------------------------------------
             * 🔴 实测症状：屏上显示 **`18704/200`** —— 分子远超分母，毫无意义。
             * ⭐ 根因已在上游修掉（`frame_parse_total()` 收到总数帧时把"已收"清零；
             *    ⛔ 原来只靠复位帧清 ⇒ 客户端不发复位帧就跨曲无限累加）。
             * ⚠️ 但显示层【仍然】不该输出"已收 > 应到"这种自相矛盾的数 ——
             *    ⭐ 兜底的意义：万一将来又冒出一条"不清零"的路径，
             *    用户看到的是"封顶的合理值"，⛔ 不是一串荒谬数字。
             * ⭐ 判据：`已收 > 应到` 时按【应到】显示。
             * ⚠️ 只影响【显示】，⛔ 不改任何真实计数（真实值仍从 `0xABF4` 可读）。 */
            {
                uint32_t shown = s_c.sent;
                if (s_c.total > 0 && shown > s_c.total) {
                    shown = s_c.total;
                }
                snprintf(cmd, sizeof(cmd), "t2.txt=\"%u/%u\"",
                         (unsigned)shown, (unsigned)s_c.total);
            }
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
