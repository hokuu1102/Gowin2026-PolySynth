"""Compile unchanged up_ring.c and verbatim production BLE drain block with host ESP stubs."""
import pathlib, subprocess, sys
ROOT=pathlib.Path(__file__).resolve().parents[2]
OUT=pathlib.Path(__file__).resolve().parent/'host'
OUT.mkdir(exist_ok=True);(OUT/'freertos').mkdir(exist_ok=True)
common='''#pragma once
#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
typedef int portMUX_TYPE;
#define portMUX_INITIALIZER_UNLOCKED 0
#define portENTER_CRITICAL(x) ((void)0)
#define portEXIT_CRITICAL(x) ((void)0)
#define ESP_LOGW(...) ((void)0)
#define ESP_LOGI(...) ((void)0)
#define ESP_LOGE(...) ((void)0)
#define MALLOC_CAP_SPIRAM 1
#define MALLOC_CAP_INTERNAL 2
#define MALLOC_CAP_8BIT 4
static inline size_t heap_caps_get_total_size(int x){return 1000000;}
static inline size_t heap_caps_get_largest_free_block(int x){return 1000000;}
static inline void *heap_caps_malloc(size_t n,int x){return malloc(n);}
'''
(OUT/'common.h').write_text(common)
for h in ['freertos/FreeRTOS.h','freertos/task.h','esp_log.h','esp_heap_caps.h']:(OUT/h).write_text('#include "common.h"\n')
prod=(ROOT/'esp32/ble/main/ble_main.c').read_text(encoding='utf-8-sig')
a=prod.index('        if (s_connected && s_handle_noti != 0 && s_noti_enabled) {',prod.index('static void task_uart_to_ble'))
b=prod.index('    }       /* if (s_connected && s_handle_noti != 0)',a)+5
block=prod[a:b]
(OUT/'drain-verbatim.txt').write_text(block,encoding='utf-8')
src='''#include "common.h"
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
'''+block+'''
}
int main(void){
 uint8_t bytes[28]={0};up_ring_stats_t st;
 up_ring_init();up_ring_push(bytes,28);drain_once();up_ring_stats(&st);
 printf("PASS positive send: tx=%u out=%u level=%u\\n",s_ble_tx_bytes,st.out,st.level);
 if(s_ble_tx_bytes!=28 || st.level!=0)return 2;
 up_ring_reset();s_ble_tx_bytes=0;up_ring_push(bytes,28);fail_send=1;drain_once();up_ring_stats(&st);
 printf("%s failed notify retains unaccepted bytes: tx=%u out=%u level=%u failed=%u\\n",st.level==28?"PASS":"FAIL",s_ble_tx_bytes,st.out,st.level,s_ble_tx_failed);
 return st.level==28?0:1;
}
'''
(OUT/'notify_probe.c').write_text(src,encoding='utf-8')
cmd=['D:/cyx/Dev-Cpp/MinGW64/bin/gcc.exe','-std=c11','-static','-I'+str(OUT),'-I'+str(ROOT/'esp32/ble/main'),str(OUT/'notify_probe.c'),str(ROOT/'esp32/ble/main/up_ring.c'),'-o',str(OUT/'notify_probe.exe')]
print('COMPILE',cmd,flush=True);r=subprocess.run(cmd);print('COMPILE_EXIT',r.returncode,flush=True)
if r.returncode:sys.exit(r.returncode)
r=subprocess.run([str(OUT/'notify_probe.exe')]);print('RUN_EXIT',r.returncode,flush=True);sys.exit(r.returncode)
