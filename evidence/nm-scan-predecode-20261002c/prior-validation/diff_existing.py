"""Run the unchanged original note-manager TB with a cycle-comparison observer.
The observer is added only to an evidence copy, never production RTL.
"""
from pathlib import Path
import re,subprocess
E=Path(__file__).resolve().parent; R=E.parents[1]
s=(R/'rtl/w3b/note_manager.v').read_text(encoding='utf-8')
params=re.findall(r'parameter integer\s+(\w+)\s*=',s.split(') (')[0])
ports=re.findall(r'^\s*(input|output)\s+wire\s*(\[[^\]]+\])?\s*(\w+)',s,re.M)
observer='\nnote_manager_ref #(\n'+',\n'.join(f'.{p}({p})' for p in params)+'\n) reference_observer (\n'+',\n'.join(f'.{n}({n})' if d=='input' else f'.{n}()' for d,w,n in ports)+'\n);\n'
observer+='integer diff_cycles=0;\nalways @(posedge clk_i) begin\n #1; diff_cycles=diff_cycles+1;\n'
for n in [n for d,w,n in ports if d=='output']+['state','scan_cnt','best_valid','best_idx','best_cls','best_env','best_age','cand_ok','cand_better']:
    observer+=f' if ({n} !== reference_observer.{n}) $fatal(1,"FAIL existing TB diff %m {n} cycle=%0d",diff_cycles);\n'
observer+='end\nfinal $display("PASS differential observer %m cycles=%0d differences=0 POLY=%0d",diff_cycles,POLY_TARGET);\n'
s=s.replace('\nendmodule',observer+'\nendmodule')
(E/'note_manager_observed.sv').write_text(s,encoding='utf-8')
sources=[p for p in (R/'rtl').rglob('*') if p.suffix in ['.v','.sv'] and p.name!='note_manager.v']
sources += [p for d in ['tb/models','tb/checkers'] for p in (R/d).rglob('*') if p.suffix in ['.v','.sv']]
sources += [E/'note_manager_observed.sv',E/'note_manager_ref.v',R/'tb/w3b/tb_note_manager.sv']
p=subprocess.run(['iverilog','-g2012','-s','tb_note_manager','-o',str(E/'existing-diff.vvp')]+[str(p) for p in sources],capture_output=True)
(E/'existing-diff.compile.log').write_bytes(p.stdout+p.stderr)
assert p.returncode==0,p.stderr.decode(errors='replace')
p=subprocess.run(['vvp',str(E/'existing-diff.vvp')],cwd=R,capture_output=True,timeout=120)
(E/'existing-diff.log').write_bytes(p.stdout+p.stderr)
print(p.stdout.decode(errors='replace')[-2200:]);assert p.returncode==0
assert not re.search(rb'(?m)^\s*FAIL',p.stdout)
