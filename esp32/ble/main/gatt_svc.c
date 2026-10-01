/*
 * gatt_svc.c -- GATT 属性表定义（⭐ UUID 照抄 ESP-IDF 官方 ble_spp_server）
 * ============================================================================
 * 项目：FPGA2026 · ESP32-S3 BLE 版
 *
 * 【UUID 表 —— ⭐ 已拉官方源码核对，⛔ 不是凭印象】
 *   来源：esp-iot-solution/examples/bluetooth/ble_conn_mgr/ble_spp/spp_server/
 *         main/app_main.c
 *
 *     #define BLE_SVC_SPP_UUID16      0xABF0     // 服务（⭐ 16 位）
 *     #define BLE_SVC_SPP_CHR_UUID16  0xABF1     // 特征（⭐ 也是 16 位）
 *
 *   ⭐ 本工程按语义把特征拆成四个（官方示例只有一个 0xABF1）：
 *       0xABF0  服务
 *       0xABF1  接收  WRITE_NR  ← ⭐ 对端把事件帧写这里
 *       0xABF2  通知  NOTIFY    ← ⭐ 我们 notify 回对端
 *       0xABF3  命令  WRITE_NR
 *       0xABF4  状态  NOTIFY
 *   ⭐ 为什么拆：语义与 SPP 版一致（收/发/命令/状态），
 *     且手机端用支持自定义 UUID 的现成 BLE 终端 App 即可对接，⛔ 不必自研 App。
 *
 * 🔴 本文件【只提供属性表与句柄索引】——
 *    ⚠️ 事件回调统一在 ble_main.c。ESP-IDF 的 gatts 回调注册是【全局】的，
 *       注册两次会互相覆盖 ⇒ 症状是"回调只触发一半"，极难查。
 * ============================================================================
 */

#include <string.h>

#include "esp_log.h"
#include "esp_bt.h"
#include "esp_gatts_api.h"

#include "ble_config.h"
#include "gatt_svc.h"

static const char *TAG = "gatt";

/* ---------------------------------------------------------------------------
 * 属性表索引（⚠️ 顺序必须与数组一致）
 * --------------------------------------------------------------------------- */
enum {
    IDX_SVC = 0,
    IDX_CHAR_RECV_DECL, IDX_CHAR_RECV_VAL,
    IDX_CHAR_NOTI_DECL, IDX_CHAR_NOTI_VAL, IDX_CHAR_NOTI_CFG,
    IDX_CHAR_CMD_DECL,  IDX_CHAR_CMD_VAL,
    IDX_CHAR_STAT_DECL, IDX_CHAR_STAT_VAL, IDX_CHAR_STAT_CFG,
    IDX_NUM,
};

/* ---------------------------------------------------------------------------
 * UUID（⭐ 全部 16 位 —— 见文件头说明）
 * --------------------------------------------------------------------------- */
static const uint16_t s_uuid_pri_svc  = ESP_GATT_UUID_PRI_SERVICE;
static const uint16_t s_uuid_char_dec = ESP_GATT_UUID_CHAR_DECLARE;
static const uint16_t s_uuid_cccd     = ESP_GATT_UUID_CHAR_CLIENT_CONFIG;

static const uint16_t s_uuid_svc  = BLE_SVC_UUID16;
static const uint16_t s_uuid_recv = BLE_CHR_RECV_UUID16;
static const uint16_t s_uuid_noti = BLE_CHR_NOTI_UUID16;
static const uint16_t s_uuid_cmd  = BLE_CHR_CMD_UUID16;
static const uint16_t s_uuid_stat = BLE_CHR_STAT_UUID16;

/* ⭐ 供 ble_main.c 放进广播数据 */
const uint16_t gatt_service_uuid16 = BLE_SVC_UUID16;

/* 特征属性 */
static const uint8_t s_prop_recv = ESP_GATT_CHAR_PROP_BIT_READ |
                                   ESP_GATT_CHAR_PROP_BIT_WRITE_NR;
static const uint8_t s_prop_noti = ESP_GATT_CHAR_PROP_BIT_READ |
                                   ESP_GATT_CHAR_PROP_BIT_NOTIFY;

/* CCCD 初值：0 = 通知未开启（⭐ 客户端必须写 0x0001 才会收到 notify） */
static uint8_t s_cccd_noti[2] = { 0x00, 0x00 };
static uint8_t s_cccd_stat[2] = { 0x00, 0x00 };

/*
 * ⚠️ 每个"值属性"都要有自己的存储。
 *    ⭐ 容量 =【单次写】能进来的最大字节数，⛔ 不是总量。
 *    ⚠️ 整曲 104 KB 是靠【多次写】累加进来的 ——
 *       BLE 单包上限就是 MTU-3 ≈ 514 字节，一次写不了多少。
 *    ⭐ 512 对应协商 MTU 517，够用。
 */
static uint8_t s_val_recv[512];
static uint8_t s_val_noti[512];
static uint8_t s_val_cmd[64];
static uint8_t s_val_stat[64];
/* ⭐ 已写入 STAT 的字节数（⚠️ 属性表的 max_length 是 64） */
static size_t  s_stat_len = 0;


/* ---------------------------------------------------------------------------
 * 属性表
 * --------------------------------------------------------------------------- */
static const esp_gatts_attr_db_t s_db[IDX_NUM] = {
    /* ---- 服务声明 ---- */
    [IDX_SVC] = {
        { ESP_GATT_AUTO_RSP },
        { ESP_UUID_LEN_16, (uint8_t *)&s_uuid_pri_svc,
          ESP_GATT_PERM_READ, sizeof(uint16_t), sizeof(uint16_t),
          (uint8_t *)&s_uuid_svc }
    },

    /* ---- ① 0xABF1 接收：对端写数据进来 ---- */
    [IDX_CHAR_RECV_DECL] = {
        { ESP_GATT_AUTO_RSP },
        { ESP_UUID_LEN_16, (uint8_t *)&s_uuid_char_dec,
          ESP_GATT_PERM_READ, sizeof(uint8_t), sizeof(uint8_t),
          (uint8_t *)&s_prop_recv }
    },
    [IDX_CHAR_RECV_VAL] = {
        { ESP_GATT_RSP_BY_APP },              /* ⭐ 回调里自己回响应 */
        { ESP_UUID_LEN_16, (uint8_t *)&s_uuid_recv,
          ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE,
          sizeof(s_val_recv), 0, s_val_recv }
    },

    /* ---- ② 0xABF2 通知：我们发出去 ---- */
    [IDX_CHAR_NOTI_DECL] = {
        { ESP_GATT_AUTO_RSP },
        { ESP_UUID_LEN_16, (uint8_t *)&s_uuid_char_dec,
          ESP_GATT_PERM_READ, sizeof(uint8_t), sizeof(uint8_t),
          (uint8_t *)&s_prop_noti }
    },
    [IDX_CHAR_NOTI_VAL] = {
        { ESP_GATT_AUTO_RSP },
        { ESP_UUID_LEN_16, (uint8_t *)&s_uuid_noti,
          ESP_GATT_PERM_READ, sizeof(s_val_noti), 0, s_val_noti }
    },
    /* ⭐ CCCD —— 🔴 客户端**必须**写 0x0001 才收得到 notify。
     *    ⚠️ 漏了它的典型症状：**连上了、写数据也成功，但一路收不到任何东西**。 */
    [IDX_CHAR_NOTI_CFG] = {
        { ESP_GATT_AUTO_RSP },
        { ESP_UUID_LEN_16, (uint8_t *)&s_uuid_cccd,
          ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE,
          sizeof(uint16_t), sizeof(s_cccd_noti), s_cccd_noti }
    },

    /* ---- ③ 0xABF3 命令 ---- */
    [IDX_CHAR_CMD_DECL] = {
        { ESP_GATT_AUTO_RSP },
        { ESP_UUID_LEN_16, (uint8_t *)&s_uuid_char_dec,
          ESP_GATT_PERM_READ, sizeof(uint8_t), sizeof(uint8_t),
          (uint8_t *)&s_prop_recv }
    },
    [IDX_CHAR_CMD_VAL] = {
        { ESP_GATT_RSP_BY_APP },
        { ESP_UUID_LEN_16, (uint8_t *)&s_uuid_cmd,
          ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE,
          sizeof(s_val_cmd), 0, s_val_cmd }
    },

    /* ---- ④ 0xABF4 状态 ---- */
    [IDX_CHAR_STAT_DECL] = {
        { ESP_GATT_AUTO_RSP },
        { ESP_UUID_LEN_16, (uint8_t *)&s_uuid_char_dec,
          ESP_GATT_PERM_READ, sizeof(uint8_t), sizeof(uint8_t),
          (uint8_t *)&s_prop_noti }
    },
    [IDX_CHAR_STAT_VAL] = {
        /* 🔴🔴 2026-09-30 修复：原来用 `ESP_GATT_AUTO_RSP` + **`length = 0`**
         *    ⇒ ⚠️ 自动响应回的是【声明长度】= **0** ⇒ 🔴 **读回来永远是空串**
         *      （⭐ 实测：`read_gatt_char(0xABF4)` 得到 `b''`，⚠️ 而固件
         *        明明已经 `STAT updated: pool=...` 写进去了 —— ⚠️ 两头都对不上）。
         * ⭐ 正解：改成 **`ESP_GATT_RSP_BY_APP`** ⇒ ⭐ 由【我们】在 READ_EVT 里
         *    决定长度（⭐ 即 `s_stat_len` 那个"实际写入了多少"）。
         *    ⚠️ 代价：READ_EVT 里必须**自己回响应**（⭐ 否则对端等超时）。 */
        { ESP_GATT_RSP_BY_APP },
        { ESP_UUID_LEN_16, (uint8_t *)&s_uuid_stat,
          ESP_GATT_PERM_READ, sizeof(s_val_stat), 0, s_val_stat }
    },
    [IDX_CHAR_STAT_CFG] = {
        { ESP_GATT_AUTO_RSP },
        { ESP_UUID_LEN_16, (uint8_t *)&s_uuid_cccd,
          ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE,
          sizeof(uint16_t), sizeof(s_cccd_stat), s_cccd_stat }
    },
};

/* ---------------------------------------------------------------------------
 * 对外接口
 * --------------------------------------------------------------------------- */
const esp_gatts_attr_db_t *gatt_get_db(void) { return s_db; }

int gatt_idx_count(void) { return IDX_NUM; }
int gatt_idx_recv(void)  { return IDX_CHAR_RECV_VAL; }
int gatt_idx_noti(void)  { return IDX_CHAR_NOTI_VAL; }
int gatt_idx_cmd(void)   { return IDX_CHAR_CMD_VAL;  }
int gatt_idx_stat(void)  { return IDX_CHAR_STAT_VAL; }

/* ⭐⭐ 2026-09-30：CCCD（通知使能）句柄索引 —— ⭐ ble_main.c 用它判断
 * "对端到底订阅了没有"（🔴 那是能否发 notify 的**真正前提**，⛔ 不是"已连接"）。 */
int gatt_idx_noti_cccd(void) { return IDX_CHAR_NOTI_CFG; }
int gatt_idx_stat_cccd(void) { return IDX_CHAR_STAT_CFG; }

/* ⭐⭐ 2026-09-30（B 子集）：往 0xABF4(STAT) 里放内容
 * ---------------------------------------------------------------------------
 * ⚠️ 注意 STAT 是 **只读 + 自动响应**（`ESP_GATT_PERM_READ` + `ESP_GATT_AUTO_RSP`，
 *    见 `s_db[IDX_CHAR_STAT_VAL]`）⇒ ⭐ **固件【不能 notify】它，
 *    客户端只能【主动读】**。
 * ⇒ ⭐ 所以"上报状态"= **先把内容写进 `s_val_stat`，等客户端来读**。
 *    ⚠️ 若客户端不读，那这次调用只更新了内容（⭐ 不是"发失败了"）。 */
void gatt_set_stat(const uint8_t *data, size_t n)
{
    if (data == NULL || n == 0) {
        return;
    }
    if (n > sizeof(s_val_stat)) {
        n = sizeof(s_val_stat);          /* ⚠️ 截断到属性表声明的长度 */
    }
    size_t cur = s_stat_len;
    if (cur > sizeof(s_val_stat)) {
        cur = sizeof(s_val_stat);
    }
    /* ⭐ 追加（⭐ 让多次上报能累积；⚠️ 满了就从头覆盖） */
    if (cur + n > sizeof(s_val_stat)) {
        cur = 0;
    }
    memcpy(s_val_stat + cur, data, n);
    s_stat_len = cur + n;
}

/* ⭐⭐ 2026-09-30：把 STAT 的**内容指针 + 实际长度**交出去
 * ---------------------------------------------------------------------------
 * 🔴 为什么需要它：STAT 改成了 `ESP_GATT_RSP_BY_APP` ⇒ ⭐ 长度必须由
 *    `ble_main.c` 的 READ_EVT **自己填**。⚠️ 而 `s_val_stat`/`s_stat_len`
 *    是本文件的 static ⇒ ⭐ 必须通过函数暴露，⛔ 不能让调用方猜格式。
 * ⭐ 返回：实际长度；`*out` 指向内容（⚠️ 只读，⛔ 不要改）。 */
size_t gatt_get_stat(const uint8_t **out)
{
    if (out != NULL) {
        *out = s_val_stat;
    }
    /* ⚠️ 夹一下：防止越界（⭐ 属性表声明的 max_length 就是 sizeof(s_val_stat)） */
    return (s_stat_len <= sizeof(s_val_stat)) ? s_stat_len : sizeof(s_val_stat);
}

void gatt_log_layout(int svc, int recv, int noti, int cmd, int stat)
{
    ESP_LOGI(TAG, "attr table created OK");
    ESP_LOGI(TAG, "  svc  0x%04X  handle=%d", BLE_SVC_UUID16, svc);
    ESP_LOGI(TAG, "  0x%04X RECV handle=%d  <- peer WRITES here",
             BLE_CHR_RECV_UUID16, recv);
    ESP_LOGI(TAG, "  0x%04X NOTI handle=%d  <- we notify here",
             BLE_CHR_NOTI_UUID16, noti);
    ESP_LOGI(TAG, "  0x%04X CMD  handle=%d", BLE_CHR_CMD_UUID16, cmd);
    ESP_LOGI(TAG, "  0x%04X STAT handle=%d", BLE_CHR_STAT_UUID16, stat);
    ESP_LOGI(TAG, "  REMINDER: peer MUST write CCCD=0x0001 to get notifications");
}
