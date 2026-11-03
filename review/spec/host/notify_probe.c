#include "common.h"
#include <stdio.h>
#include "up_ring.h"
typedef int esp_err_t;
#define ESP_OK 0
#define BLE_TX_GAP_MS 2
#define BLE_DELAY_TICKS_AT_LEAST_1(x) 1
static int s_connected=1,s_handle_noti=1,s_noti_enabled=1,s_mtu=23,s_gatts_if=1,s_conn_id=1;
static uint32_t s_ble_tx_failed=0,s_ble_tx_bytes=0;
static int fail_send=0;
static int esp_ble_gatts_send_indicate(int a,int b,int c,size_t n,void*p,bool confirm){return fail_send?-1:0;}
static void vTaskDelay(int x){}
static void drain_once(void){
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
    }
}
int main(void){
 uint8_t bytes[28]={0};up_ring_stats_t st;
 up_ring_init();up_ring_push(bytes,28);drain_once();up_ring_stats(&st);
 printf("PASS positive send: tx=%u out=%u level=%u\n",s_ble_tx_bytes,st.out,st.level);
 if(s_ble_tx_bytes!=28 || st.level!=0)return 2;
 up_ring_reset();s_ble_tx_bytes=0;up_ring_push(bytes,28);fail_send=1;drain_once();up_ring_stats(&st);
 printf("%s failed notify retains unaccepted bytes: tx=%u out=%u level=%u failed=%u\n",st.level==28?"PASS":"FAIL",s_ble_tx_bytes,st.out,st.level,s_ble_tx_failed);
 return st.level==28?0:1;
}
