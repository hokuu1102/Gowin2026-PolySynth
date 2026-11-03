from pathlib import Path
import sys, io
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'esp32/tools/evt2midi'))
import evt2midi as em
import frame_format as ff
import mido

def frame(kind,seq,tick,b7,inc=38702840,vel=128):
    b=bytearray(ff.build_frame(kind,seq,tick,b7&15,inc,vel))
    b[7]=b7;b[-1]=ff.frame_checksum(b);return b

stream=bytearray()
seq=0
for b7 in (0x00,0x11,0x22,0x33,0x40,0x50,0x60,0x70):
    stream+=frame(ff.T_NOTE_ON,seq,seq*1000+100,b7,0 if b7&64 else 38702840)
    stream+=frame(ff.T_NOTE_OFF,seq+1,seq*1000+1060,b7,0,0)
    seq+=2
events,stats=em.parse_stream(bytes(stream))
assert len(events)==16 and stats.rejected==0
for i,b7 in enumerate((0,0x11,0x22,0x33,0x40,0x50,0x60,0x70)):
    e=events[i*2]
    assert e.drum_type==((b7>>4)&3 if b7&64 else None)
    assert e.timbre==(None if b7&64 else (b7>>4)&3)
data,skipped,count=em.build_midi(events,stats)
mid=mido.MidiFile(file=io.BytesIO(data))
assert [tr.name for tr in mid.tracks if tr.name]==['BASS','GUITAR','PIANO','PAD','Drums']
(ROOT/'fix_evidence/python-export.mid').write_bytes(data)
notes=[m for tr in mid.tracks for m in tr if m.type in ('note_on','note_off')]
on=[m for m in notes if m.type=='note_on']
off=[m for m in notes if m.type=='note_off']
assert len(on)==len(off)==8 and count==16 and skipped==0
assert sorted(m.channel for m in on)==[0,1,2,3,9,9,9,9]
assert sorted(m.note for m in on if m.channel!=9)==[69]*4
assert sorted(m.note for m in on if m.channel==9)==[36,38,42,45]
assert all(m.velocity>0 for m in on)
assert sorted((m.channel,m.note) for m in on)==sorted((m.channel,m.note) for m in off)
programs={m.channel:m.program for tr in mid.tracks for m in tr if m.type=='program_change'}
assert programs=={0:32,1:24,2:0,3:89}
print('PASS actual Python parser/export: A4, four timbres/programs, four GM drums, zero-inc OFF pairing')
stream=(frame(ff.T_NOTE_ON,0,100,0x40,0) +
        frame(ff.T_NOTE_ON,1,200,0x50,0) +
        frame(ff.T_NOTE_OFF,2,300,0x40,0,0))
events,stats=em.parse_stream(stream)
data,_,_=em.build_midi(events,stats)
mid=mido.MidiFile(file=io.BytesIO(data))
notes=[m for tr in mid.tracks for m in tr if m.type in ('note_on','note_off')]
assert stats.notes_open_at_end==1
assert [(m.type,m.channel,m.note) for m in notes]==[
    ('note_on',9,36),('note_on',9,38),('note_off',9,36),('note_off',9,38)]
print('PASS overlapping drums retain independent open state and truncated-tail cleanup')
stream=(frame(ff.T_NOTE_ON,0,100,0) +
        frame(ff.T_NOTE_ON,1,200,0,46044927) +
        frame(ff.T_NOTE_OFF,2,300,0,46044927,0))
events,stats=em.parse_stream(stream)
data,_,_=em.build_midi(events,stats)
mid=mido.MidiFile(file=io.BytesIO(data))
notes=[m for tr in mid.tracks for m in tr if m.type in ('note_on','note_off')]
assert [(m.type,m.note) for m in notes]==[
    ('note_on',69),('note_on',72),('note_off',72),('note_off',69)]
assert stats.notes_open_at_end==1
assert [tr.name for tr in mid.tracks if tr.name]==['BASS']
print('PASS legacy collapsed-axis chord matches OFF pitch and preserves named tracks')
