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

/* 打印属性表布局（⭐ 上板第一眼要看的） */
void gatt_log_layout(int svc, int recv, int noti, int cmd, int stat);

/* ⭐ 服务 UUID（16 位 0xABF0）—— 广播里要用 */
extern const uint16_t gatt_service_uuid16;

#ifdef __cplusplus
}
#endif

#endif /* GATT_SVC_H */
