#include "common.h"
#include <stdio.h>
static int intervene=0, tx=0;
#include "C:/Users/cyx/Documents/ChatGPT/FPGA/audit-latest-20261020-cd63b07/esp32/ble/main/pool.c"

static void xSemaphoreGive(void*x){if(intervene){int mode=intervene;intervene=0;if(mode==1)pool_reset();else pool_stop();}}
static int uart_write_bytes(int port,const char*buf,size_t n){tx++;return n;}
void hmi_set_play_pos(uint32_t a,uint32_t b,uint32_t c,uint32_t d,bool e){}
static void setup(void){pool_reset();uint8_t fr[9]={0xa5};uint64_t w=((uint64_t)37796<<23)|((uint64_t)100<<11);for(int k=8;k>0;k--){fr[k]=w&255;w>>=8;}pool_feed(fr,9);s_running=true;s_lead_ticks=0;s_lead_end=0;s_t0_us=0;s_t0_tick=0;tx=0;}
int main(void){
 setup();pool_pump();printf("PASS positive tx=%d\n",tx);if(tx!=1)return 2;
 setup();intervene=1;pool_pump();
 printf("%s RESET between unlock and UART prevents stale send: tx=%d frames=%u idx=%u running=%d\n",tx==0?"PASS":"FAIL",tx,(unsigned)s_frames,(unsigned)s_play_idx,s_running);
 int reset_bad=tx!=0;
 setup();intervene=2;pool_pump();
 printf("%s STOP between unlock and UART prevents stale note_on: tx=%d idx=%u running=%d\n",tx==0?"PASS":"FAIL",tx,(unsigned)s_play_idx,s_running);
 return reset_bad || tx!=0;
}
