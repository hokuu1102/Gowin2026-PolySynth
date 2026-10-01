/*
 * gatt_svc.h -- GATT 属性表（见 gatt_svc.c 说明）
 * ============================================================================
 * ⚠️ 事件回调统一在 ble_main.c —— 本模块⛔ 不再注册第二个 gatts 回调
 *    （ESP-IDF 的回调注册是全局的，注册两次会互相覆盖）。
 * ============================================================================
 */
#ifndef GATT_SVC_H
#define GATT_SVC_H

#include "esp_gatts_api.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 属性表本体（ble_main.c 拿它去 esp_ble_gatts_create_attr_tab） */
const esp_gatts_attr_db_t *gatt_get_db(void);

/* ⚠️ 属性表里的索引 —— ble_main.c 用它从 handles[] 取句柄 */
int gatt_idx_count(void);
int gatt_idx_recv(void);
int gatt_idx_noti(void);
int gatt_idx_cmd(void);
int gatt_idx_stat(void);

/* ⭐⭐ 2026-09-30 新增：0xABF2 的 **CCCD（通知使能）** 句柄索引。
 * 🔴 为什么需要它：⭐ 客户端**必须写 CCCD=0x0001** 才收得到 notify。
 *    ⚠️ 实测踩过的坑：固件原来把"**已连接**"当成"可以发了" ⇒
 *      🔴 **连接一建立就把环里的数据全推出去**，⚠️ 而那一刻客户端
 *      **还没订阅** ⇒ 数据**全丢**（⭐ 且 `fail=0`，看不出来）。
 *    ⭐ 正解：**用 CCCD 的写入作为"对端就绪"的判据**（⛔ 不是连接）。 */
int gatt_idx_noti_cccd(void);
int gatt_idx_stat_cccd(void);

/* ⭐⭐ 2026-09-30（B 子集）：把内容放进 0xABF4(STAT) 供客户端读取。
 * ⚠️ STAT 是【只读 + 自动响应】⇒ 固件**不能 notify**，只能**更新内容**，
 *    ⭐ 由客户端主动读。 */
void gatt_set_stat(const uint8_t *data, size_t n);

/* ⭐⭐ 2026-09-30：取 STAT 的内容指针 + 实际长度。
 * 🔴 STAT 是 `ESP_GATT_RSP_BY_APP` ⇒ ⭐ 读的时候要**自己填长度**，
 *    ⚠️ 所以 `ble_main.c` 的 READ_EVT 必须调这个函数。 */
size_t gatt_get_stat(const uint8_t **out);

/* 打印属性表布局（⭐ 上板第一眼要看的） */
void gatt_log_layout(int svc, int recv, int noti, int cmd, int stat);

/* ⭐ 服务 UUID（16 位 0xABF0）—— 广播里要用 */
extern const uint16_t gatt_service_uuid16;

#ifdef __cplusplus
}
#endif

#endif /* GATT_SVC_H */
