"""Archive compact reports and compare synthesis metrics (not physical CLS)."""
from pathlib import Path
import hashlib
import json
import shutil
import xml.etree.ElementTree as ET

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[2]
summary = {}
for name in ['synth-before', 'synth-after', 'synth-age-local', 'synth-diag-before', 'synth-diag-after']:
    src = OUT / name
    if not (src / 'exit.json').exists():
        continue
    result = json.loads((src / 'exit.json').read_text())
    assert result['exit'] == 0, (name,result)
    assert not (src/'impl/pnr').exists()
    dst = OUT / ('reports-' + name)
    dst.mkdir(exist_ok=True)
    for f in ['exit.json','source-manifest.json','synthesis_only.tcl','console.log']:
        shutil.copy2(src/f, dst/f)
    for f in ['Gowin2026_syn.rsc.xml','Gowin2026_syn_rsc.xml','Gowin2026_syn.rpt.html','Gowin2026.log']:
        file = src/'impl/gwsynthesis'/f
        if file.exists(): shutil.copy2(file,dst/f)
    vg = src/'impl/gwsynthesis/Gowin2026.vg'
    (dst/'netlist-sha256.txt').write_text(hashlib.sha256(vg.read_bytes()).hexdigest()+'  Gowin2026.vg\n',encoding='ascii')
    tree = ET.parse(src/'impl/gwsynthesis/Gowin2026_syn_rsc.xml').getroot()
    def metrics(el):
        d = {k:int(el.get('T_'+k,'0').split('(')[0]) for k in ['Register','Alu','Lut','Bsram']}
        d['Logic']=d['Alu']+d['Lut']
        d['CLS']=None
        return d
    summary[name] = {'top':metrics(tree), 'note_manager':metrics(next(e for e in tree if e.get('name')=='g_sound.u_note_manager'))}
    print(name,summary[name])
(OUT/'synthesis-summary.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
# Record unchanged protected files and final candidate source against Git HEAD.
import subprocess
protected = ['constr/top.sdc','constr/top.cst','build_cli.tcl','rtl/top.v','rtl/w3b/oscillator_bank.v','Gowin2026.gprj']
hashes = {}
for name in protected:
    raw=(ROOT/name).read_bytes()
    committed=subprocess.check_output(['git','show','HEAD:'+name],cwd=ROOT)
    assert raw.replace(b'\r\n',b'\n') == committed.replace(b'\r\n',b'\n'), name
    hashes[name]=hashlib.sha256(raw).hexdigest()
hashes['rtl/w3b/note_manager.v']=hashlib.sha256((ROOT/'rtl/w3b/note_manager.v').read_bytes()).hexdigest()
(OUT/'protected-and-candidate-sha256.json').write_text(json.dumps(hashes,indent=2),encoding='utf-8')
