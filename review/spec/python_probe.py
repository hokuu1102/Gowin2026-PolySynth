import sys, pathlib, io
ROOT=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'esp32/tools/evt2midi'))
import evt2midi as em
import frame_format as ff
import mido
failures=0
def check(name, condition, actual):
    global failures
    print(('PASS ' if condition else 'FAIL ')+name+': '+repr(actual))
    failures+=not condition
inc=38702840
check('Python decodes full-width A4 phase_inc at sample rate', em.hz_to_note(em.inc_to_hz(inc))==69, (em.inc_to_hz(inc),em.hz_to_note(em.inc_to_hz(inc))))
for b7 in [0x00,0x11,0x22,0x33,0x40,0x50,0x60,0x70]:
    fr=bytearray(ff.build_frame(ff.T_NOTE_ON,0,100,0,inc,100));fr[7]=b7;fr[-1]=ff.frame_checksum(fr)
    s=em.ParseStats();evs,_=em.parse_stream(bytes(fr),s)
    check('byte7 %02x survives Event parse timbre/drum metadata'%b7,hasattr(evs[0],'timbre') and hasattr(evs[0],'drum_type'),repr(evs[0]))
print('FAILURES=%d'%failures)
sys.exit(bool(failures))
