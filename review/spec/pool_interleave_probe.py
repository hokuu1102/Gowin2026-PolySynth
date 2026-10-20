import pathlib,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parents[2];OUT=pathlib.Path(__file__).resolve().parent/'pool-host';OUT.mkdir(exist_ok=True)
for d in ['freertos','driver']:(OUT/d).mkdir(exist_ok=True)
(OUT/'common.h').write_text('''#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stddef.h>
typedef void *SemaphoreHandle_t;
typedef int esp_err_t;
#define portMAX_DELAY 0
#define pdMS_TO_TICKS(x) (x)
#define UART_NUM_0 0
#define UART_NUM_1 1
#define UART_NUM_2 2
#define ESP_LOGI(...) ((void)0)
#define ESP_LOGW(...) ((void)0)
#define ESP_LOGE(...) ((void)0)
#define ESP_LOGD(...) ((void)0)
#define MALLOC_CAP_SPIRAM 1
#define MALLOC_CAP_INTERNAL 2
#define MALLOC_CAP_8BIT 4
static inline size_t heap_caps_get_total_size(int x){return 1000000;}
static inline size_t heap_caps_get_largest_free_block(int x){return 1000000;}
static inline void *heap_caps_malloc(size_t n,int x){return malloc(n);}
static void *xSemaphoreCreateMutex(void){return (void*)1;}
static void xSemaphoreTake(void*x,int n){}
static void xSemaphoreGive(void*x);
static int64_t esp_timer_get_time(void){return 1000000;}
static void vTaskDelay(int x){}
static int uart_write_bytes(int port,const char *buf,size_t n);
''')
for p in ['freertos/FreeRTOS.h','freertos/task.h','freertos/semphr.h','esp_log.h','esp_timer.h','esp_heap_caps.h','esp_err.h','driver/uart.h']:(OUT/p).write_text('#include "common.h"\n')
prod=(ROOT/'esp32/ble/main/pool.c').as_posix()
src='''#include "common.h"
#include <stdio.h>
static int intervene=0, tx=0;
'''+f'#include "{prod}"\n'+'''
static void xSemaphoreGive(void*x){if(intervene){int mode=intervene;intervene=0;if(mode==1)pool_reset();else pool_stop();}}
static int uart_write_bytes(int port,const char*buf,size_t n){tx++;return n;}
void hmi_set_play_pos(uint32_t a,uint32_t b,uint32_t c,uint32_t d,bool e){}
static void setup(void){pool_reset();uint8_t fr[9]={0xa5};uint64_t w=((uint64_t)37796<<23)|((uint64_t)100<<11);for(int k=8;k>0;k--){fr[k]=w&255;w>>=8;}pool_feed(fr,9);s_running=true;s_lead_ticks=0;s_lead_end=0;s_t0_us=0;s_t0_tick=0;tx=0;}
int main(void){
 setup();pool_pump();printf("PASS positive tx=%d\\n",tx);if(tx!=1)return 2;
 setup();intervene=1;pool_pump();
 printf("%s RESET between unlock and UART prevents stale send: tx=%d frames=%u idx=%u running=%d\\n",tx==0?"PASS":"FAIL",tx,(unsigned)s_frames,(unsigned)s_play_idx,s_running);
 int reset_bad=tx!=0;
 setup();intervene=2;pool_pump();
 printf("%s STOP between unlock and UART prevents stale note_on: tx=%d idx=%u running=%d\\n",tx==0?"PASS":"FAIL",tx,(unsigned)s_play_idx,s_running);
 return reset_bad || tx!=0;
}
'''
(OUT/'pool_probe.c').write_text(src,encoding='utf-8')
cmd=['D:/cyx/Dev-Cpp/MinGW64/bin/gcc.exe','-std=c11','-static','-I'+str(OUT),str(OUT/'pool_probe.c'),'-o',str(OUT/'pool_probe.exe')]
r=subprocess.run(cmd);print('COMPILE_EXIT',r.returncode,flush=True)
if r.returncode:sys.exit(r.returncode)
r=subprocess.run([str(OUT/'pool_probe.exe')]);print('RUN_EXIT',r.returncode,flush=True);sys.exit(r.returncode)
