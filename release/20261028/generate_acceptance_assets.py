"""Deterministic operator fixtures, not physical PASS evidence."""
from pathlib import Path
import csv
import mido

OUT=Path(__file__).resolve().parent/'测试素材'
OUT.mkdir(exist_ok=True)

def save(name, tracks, tempos=None):
    mid=mido.MidiFile(ticks_per_beat=480)
    tempo=mido.MidiTrack();mid.tracks.append(tempo)
    events=tempos or [(0,500000)]
    last=0
    for tick,us in events:
        tempo.append(mido.MetaMessage('set_tempo',tempo=us,time=tick-last));last=tick
    for label,ch,program,notes in tracks:
        track=mido.MidiTrack();mid.tracks.append(track)
        track.append(mido.MetaMessage('track_name',name=label,time=0))
        if ch!=9:track.append(mido.Message('program_change',channel=ch,program=program,time=0))
        ev=[]
        for tick,duration,note,vel in notes:
            ev.extend([(tick,1,note,vel),(tick+duration,0,note,0)])
        last=0
        for tick,kind,note,vel in sorted(ev):
            track.append(mido.Message('note_on' if kind else 'note_off',channel=ch,note=note,velocity=vel,time=tick-last));last=tick
    mid.save(OUT/name)
    reread=mido.MidiFile(OUT/name)
    ons=sum(msg.type=='note_on' and msg.velocity>0 for t in reread.tracks for msg in t)
    offs=sum(msg.type=='note_off' or (msg.type=='note_on' and msg.velocity==0) for t in reread.tracks for msg in t)
    assert ons==offs and ons>0,(name,ons,offs)
    return dict(file=name,notes=ons,tracks=len(mid.tracks),seconds=round(reread.length,3))

manifest=[]
parts=[]
for i,(name,program,note) in enumerate([('BASS',32,48),('GUITAR',24,52),('PIANO',0,55),('PAD',89,60)]):
    parts.append((name,i,program,[(i*960,720,note,40+40*(i%3)),(4800,1920,note,100)]))
manifest.append(save('F01_四音色.mid',parts))
channels=list(range(9))+[10,11,12]
manifest.append(save('F02_十二路交叠.mid',[(f'PIANO{i+1}',ch,0,[(0,1920+i*120,48+i,80)]) for i,ch in enumerate(channels)]))
manifest.append(save('F03_四件鼓.mid',[('DRUMS',9,0,[(i*960,120,n,100) for i,n in enumerate([36,38,42,45])]+[(4800+i*240,120,n,90) for i,n in enumerate([36,38,42,45]*4)])]))
manifest.append(save('F04_变速长音休止.mid',[('PIANO',0,0,[(0,5760,55,90),(9600,1920,60,100)])],[(0,500000),(1920,750000),(3840,250000),(9600,500000)]))
with (OUT/'素材清单.csv').open('w',encoding='utf-8-sig',newline='') as f:
    writer=csv.DictWriter(f,fieldnames=['file','notes','tracks','seconds']);writer.writeheader();writer.writerows(manifest)
with (OUT.parent/'逐项验收记录.csv').open('w',encoding='utf-8-sig',newline='') as f:
    w=csv.writer(f);w.writerow(['用例','日期','操作者','FPGA_SHA256','ESP_SHA256','结果','证据绝对路径','问题及复测'])
    for prefix,count in [('A',11),('B',8),('C',11),('D',8),('E',10),('F',5),('G',5)]:
        for i in range(1,count+1):w.writerow([f'{prefix}{i:02d}','','','','','待上板','',''])
print(manifest)
