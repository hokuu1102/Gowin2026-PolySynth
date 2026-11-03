"""Production pool cleanup regression; host GCC, no serial/board access."""
import ast
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = pathlib.Path(r'D:\ChatGPT\Outputs\FPGA-20261028\stop-reset-probe')
OUT.mkdir(parents=True, exist_ok=True)
tree = ast.parse((ROOT / 'fix_evidence/pool_regression.py').read_text(encoding='utf-8-sig'))
stub = next(n.args[0].value for n in ast.walk(tree)
            if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
            and n.func.attr == 'write_text' and n.args
            and isinstance(n.args[0], ast.Constant) and 'typedef void *SemaphoreHandle_t' in str(n.args[0].value))
headers = ['freertos/FreeRTOS.h', 'freertos/task.h', 'freertos/semphr.h',
           'esp_log.h', 'esp_timer.h', 'esp_heap_caps.h', 'esp_err.h', 'driver/uart.h']
source = r'''
#include "common.h"
#include <stdio.h>
static unsigned count;
static unsigned failures;
static unsigned write_attempts,fail_on_attempt;
static unsigned char captures[1024][9];
PRODUCTION_INCLUDE
static void xSemaphoreGive(void*x){}
static int uart_write_bytes(int port,const char*buf,size_t n){
  ++write_attempts;
  if(fail_on_attempt && write_attempts==fail_on_attempt)return 0;
  if(n==9 && count<1024) memcpy(captures[count++],buf,9);return (int)n;
}
void hmi_set_play_pos(uint32_t a,uint32_t b,uint32_t c,uint32_t d,bool e){}
static void feed(unsigned tick,unsigned kind,unsigned axis,unsigned inc,unsigned n5,unsigned flags){
  uint64_t w=((uint64_t)tick<<44)|((uint64_t)inc<<23)|((uint64_t)axis<<19)|
    ((uint64_t)100<<11)|((uint64_t)kind<<9)|((flags&15)<<5)|n5;
  uint8_t f[9]={0xa5};for(int k=8;k>0;k--){f[k]=w&255;w>>=8;}pool_feed(f,9);
}
static uint64_t word_at(unsigned i){uint64_t w=0;if(i>=count)return 0;for(int k=1;k<9;k++)w=(w<<8)|captures[i][k];return w;}
static void check(const char*name,int ok){printf("%s %s\n",ok?"PASS":"FAIL",name);if(!ok)failures++;}
static int closes(unsigned i,unsigned axis,unsigned inc,unsigned n5,unsigned flags,unsigned tick){
 uint64_t w=word_at(i);return i<count && ev_kind(w)==1 && ev_tick(w)==tick && ev_inc(w)==inc &&
 ((w>>19)&15)==axis && (w&31)==n5 && ((w>>5)&15)==flags && ((w>>11)&255)==0;
}
static void show(const char*label,unsigned start){
 printf("%s: captures=%u running=%d frames=%u idx=%u\n",label,count-start,s_running,(unsigned)s_frames,(unsigned)s_play_idx);
 for(unsigned i=start;i<count;i++){uint64_t w=0;for(int k=1;k<9;k++)w=(w<<8)|captures[i][k];
 printf("  bytes=");for(int k=0;k<9;k++)printf("%02X",captures[i][k]);
 printf(" tick=%u kind=%u axis=%u inc=%u note5=%u\n",ev_tick(w),ev_kind(w),(unsigned)((w>>19)&15),ev_inc(w),(unsigned)(w&31));}
}
static void begin(void){fail_on_attempt=0;pool_reset();count=0;write_attempts=0;}
static void launch(void){pool_start();s_lead_ticks=0;s_lead_end=0;s_t0_us=999000;s_t0_tick=0;pool_pump();}
int main(void){
 begin();feed(0,0,0,37796,3,15);feed(100000,1,0,37796,3,15);launch();show("RESET before",0);
 unsigned before=count;pool_reset();show("RESET after",before);
 check("RESET closes committed ON with complete metadata before erasing pending OFF",before==1&&count==before+1&&closes(before,0,37796,3,15,0)&&s_frames==0&&!s_running);
 before=count;pool_reset();check("second RESET does not duplicate closes",count==before);
 begin();feed(0,0,0,37796,3,1);feed(0,0,1,42000,5,14);feed(0,1,0,37796,3,1);feed(100000,1,1,42000,5,14);
 launch();show("STOP swap before",0);before=count;pool_stop();show("STOP swap after",before);
 check("ON A ON B OFF A STOP retains B note5 and bits8:5",before==3&&count==before+1&&closes(before,1,42000,5,14,0));
 before=count;pool_stop();check("second STOP does not duplicate closes",count==before);
 pool_reset();check("RESET after successful STOP does not duplicate closes",count==before);
 begin();feed(0,0,0,37796,3,5);feed(0,0,0,37796,3,5);feed(0,1,0,37796,3,5);feed(100000,1,0,37796,3,5);
 launch();show("STOP repeat before",0);before=count;pool_stop();show("STOP repeat after",before);
 check("ON ON OFF STOP emits exactly one remaining OFF",before==3&&count==before+1&&closes(before,0,37796,3,5,0));
 begin();feed(0,0,0,37796,3,10);feed(0,0,0,37796,3,10);feed(100000,1,0,37796,3,10);
 launch();before=count;pool_stop();show("STOP two references",before);
 check("two open references produce two OFFs",before==2&&count==before+2&&closes(before,0,37796,3,10,0)&&closes(before+1,0,37796,3,10,0));
 begin();feed(0,0,0,37796,3,9);launch();before=count;
 check("EOF fixture is stopped with submitted ON",before==1&&!s_running);
 pool_stop();show("STOP after EOF",before);
 check("STOP after EOF still closes unmatched submitted ON",count==before+1&&closes(before,0,37796,3,9,0));
 begin();feed(0,0,0,37796,3,6);launch();before=count;pool_reset();
 check("RESET after EOF closes unmatched submitted ON",before==1&&count==before+1&&closes(before,0,37796,3,6,0));
 begin();
 for(unsigned i=0;i<64;i++){
   feed(0,0,i%16,37796+i,3+i/16,i%16);
   feed(0,0,i%16,37796+i,3+i/16,i%16);
 }
 feed(100000,1,0,37796,3,0);launch();before=count;pool_stop();
 int capacity_ok=before==128&&count==256;
 for(unsigned i=0;i<64;i++)for(unsigned ref=0;ref<2;ref++)
   capacity_ok=capacity_ok&&closes(before+2*i+ref,i%16,37796+i,3+i/16,i%16,0);
 check("64 identities each repeated twice close all 128 references with metadata",capacity_ok);
 before=count;pool_reset();check("64-slot cleanup remains idempotent through RESET",count==before);
 begin();feed(0,0,0,37796,3,15);feed(0,0,1,42000,5,14);feed(100000,1,1,42000,5,14);launch();
 before=count;fail_on_attempt=write_attempts+2;pool_stop();
 check("short write after first successful OFF leaves cleanup pending",count==before+1&&!s_cleanup_done&&!s_running);
 fail_on_attempt=0;pool_stop();show("STOP short-write retry",before);
 check("retry resumes pending OFF without repeating already submitted OFF",count==before+2&&closes(before,0,37796,3,15,0)&&closes(before+1,1,42000,5,14,0)&&s_cleanup_done);
 before=count;pool_stop();check("successful retry is idempotent",count==before);
 begin();feed(0,0,0,37796,3,5);feed(0,0,0,37796,3,5);feed(100000,1,0,37796,3,5);launch();
 before=count;fail_on_attempt=write_attempts+2;pool_reset();
 check("RESET short write retains score and cleanup progress",count==before+1&&s_frames==3&&!s_cleanup_done);
 fail_on_attempt=0;pool_reset();
 check("RESET retry sends only remaining repeated reference then clears score",count==before+2&&s_frames==0&&s_cleanup_done&&closes(before,0,37796,3,5,0)&&closes(before+1,0,37796,3,5,0));
 begin();feed(0,0,0,37796,3,2);feed(0,0,0,37796,3,0);feed(100000,1,0,37796,3,0);launch();
 before=count;pool_stop();show("STOP same note different routing flags",before);
 check("same identity guide-only and audible ON retain their separate OFF routing",before==2&&count==before+2&&closes(before,0,37796,3,2,0)&&closes(before+1,0,37796,3,0,0));
 begin();feed(0,0,0,37796,3,2);feed(0,1,0,37796,3,0);feed(100000,1,0,37796,3,0);launch();before=count;pool_stop();
 check("legacy unflagged OFF closes guide-only ON without duplicate cleanup",before==2&&count==before);
 begin();feed(0,0,0,37796,3,0);feed(0,1,0,37796,3,2);feed(100000,1,0,37796,3,0);launch();before=count;pool_stop();
 check("guide-only OFF cannot erase an audible cleanup obligation",before==2&&count==before+1&&closes(before,0,37796,3,0,0));
 begin();feed(0,0,0,37796,3,0);feed(0,1,0,37796,3,1);feed(100000,1,0,37796,3,0);launch();before=count;pool_stop();
 check("drum-routed OFF cannot erase a melodic cleanup obligation",before==2&&count==before+1&&closes(before,0,37796,3,0,0));
 begin();for(unsigned i=0;i<65;i++)feed(0,0,i%16,37796+i,3+i/16,i%16);
 feed(100000,1,0,37796,3,0);launch();before=count;pool_reset();
 check("65th simultaneous identity fails visibly without discarding unsafely unclosed score",before==65&&count==before&&s_frames==66&&!s_cleanup_done&&!s_running);
 printf("CLEANUP_REGRESSION failures=%u; no board accessed\n",failures);
 return failures?1:0;
}
'''.replace('PRODUCTION_INCLUDE', '#include "' + (ROOT / 'esp32/ble/main/pool.c').as_posix() + '"')
with tempfile.TemporaryDirectory(prefix='pool-lifecycle-', dir=OUT) as temp:
    work = pathlib.Path(temp)
    (work / 'common.h').write_text(stub, encoding='utf-8')
    for name in headers:
        target = work / name
        target.parent.mkdir(exist_ok=True)
        target.write_text('#include "common.h"\n', encoding='utf-8')
    (work / 'probe.c').write_text(source, encoding='utf-8')
    build = subprocess.run([r'D:/cyx/Dev-Cpp/MinGW64/bin/gcc.exe', '-std=c11', '-static',
                            '-I' + str(work), str(work / 'probe.c'), '-o', str(work / 'probe.exe')],
                           capture_output=True, text=True)
    if build.returncode:
        raise SystemExit(build.stdout + build.stderr)
    run = subprocess.run([str(work / 'probe.exe')], capture_output=True, text=True)
    (OUT / 'cleanup-regression.log').write_text(run.stdout + run.stderr, encoding='utf-8')
    print(run.stdout, end='')
    print('HOST_PROBE_EXIT', run.returncode)
    raise SystemExit(run.returncode)
