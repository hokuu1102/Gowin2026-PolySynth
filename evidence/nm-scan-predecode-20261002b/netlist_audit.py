from pathlib import Path
import re,json,sys,collections,bisect
E=Path(__file__).resolve().parent;R=E.parents[1]
path=Path(sys.argv[1]) if len(sys.argv)>1 else R/'impl/gwsynthesis/Gowin2026.vg'
text=path.read_text(errors='replace')
start=text.index('module note_manager (');end=text.index('endmodule',start)
s=text[start:end];base=text[:start].count('\n')
def norm(n):return re.sub(r'\s+','',n).lstrip('\\')
instances=[];drivers={};loads=collections.defaultdict(list)
newlines=[m.start() for m in re.finditer("\n",s)]
for m in re.finditer(r'^\s*(LUT\d+|DFF\w*|MUX\w*|ALU)\s+([^\n]+?)\s*\(\s*\n(.*?)^\s*\);',s,re.M|re.S):
    typ,name,body=m.groups();ports={p:norm(n) for p,n in re.findall(r'\.(\w+)\((.*?)\)',body)}
    inst={'type':typ,'name':name.strip(),'ports':ports,'line':base+bisect.bisect_left(newlines,m.start())+1,'text':m.group()}
    instances.append(inst)
    for p,n in ports.items():
        if p in ['F','Q','O','SUM','COUT']:drivers[n]=inst
        else:loads[n].append((name.strip(),p))
def ancestors(n,visited=None):
    if visited is None:visited=set()
    if n in visited:return set()
    visited.add(n)
    if n not in drivers or drivers[n]['type'].startswith('DFF'):return {n}
    return set().union(*(ancestors(v,visited) for p,v in drivers[n]['ports'].items() if p not in ['F','Q','O','SUM','COUT']))
regs=[x for x in instances if x['type'].startswith('DFF') and re.fullmatch(r'scan_sel\[\d+\]',x['ports'].get('Q',''))]
binary={f'scan_cnt[{i}]':len(loads[f'scan_cnt[{i}]']) for i in range(5)}
onehot={f'scan_sel[{i}]':len(loads[f'scan_sel[{i}]']) for i in range(32)}
selected=[];groups={}
for g in range(4):
    candidates=[n for n in drivers if re.fullmatch(rf'scan_group\[{g}\]\[\d+\]',n)]
    # Environment bit zero follows the 16-bit age field in the packed attributes.
    n=next((n for n in candidates if n.endswith('[16]')),None)
    assert n, (g,candidates[:4])
    a=ancestors(n);sel=sorted(n for n in a if n.startswith('scan_sel['));cnt=sorted(n for n in a if n.startswith('scan_cnt['))
    assert set(sel)=={f'scan_sel[{i}]' for i in range(g*8,g*8+8)},(g,sel)
    assert not cnt,(g,cnt)
    groups[str(g)]={'env0_output':n,'onehot_ancestors':sel,'binary_scan_ancestors':cnt}
    # Include every LUT in this small cone, with literal source lines.
    def walk(n,seen):
        if n in seen or n not in drivers:return
        seen.add(n);x=drivers[n];selected.append(x)
        if not x['type'].startswith('DFF'):
            for p,v in x['ports'].items():
                if p not in ['F','Q','O','SUM','COUT']:walk(v,seen)
    walk(n,set())
merge=[x for x in instances if len({re.fullmatch(r'scan_group\[(\d+)\]\[\d+\]',n).group(1) for p,n in x['ports'].items() if p.startswith('I') and re.fullmatch(r'scan_group\[(\d+)\]\[\d+\]',n)})==4]
assert merge,'No four-group combinational merge found'
assert len(regs)==32,len(regs)
out={'file':str(path),'onehot_registers':len(regs),'binary_load_pin_counts':binary,'onehot_load_pin_counts':onehot,'groups':groups,'four_group_merge_instances':len(merge)}
(E/'netlist-audit.json').write_text(json.dumps(out,indent=2))
selected=regs[:2]+selected+merge[:2]
lines=text.splitlines();seen=set(); excerpts=[]
for x in selected:
    if x['name'] in seen:continue
    seen.add(x['name']);i=x['line']-1
    # Regex may start with preceding whitespace; retain one following defparam too.
    endline=i+len(x['text'].splitlines())+1
    excerpts+=['\n'+x['name']]+[f'{j+1}: {lines[j]}' for j in range(i,min(endline,len(lines)))]
(E/'netlist-excerpts.txt').write_text('\n'.join(excerpts),encoding='utf-8')
print(json.dumps(out,indent=2))
