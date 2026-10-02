from pathlib import Path
import re, html, json, sys, hashlib
E=Path(__file__).resolve().parent
def rows(s):
    return [[' '.join(html.unescape(re.sub('<[^>]+>',' ',c)).split()) for c in re.findall(r'<t[dh]\b[^>]*>(.*?)</t[dh]>',r,re.I|re.S)] for r in re.findall(r'<tr\b[^>]*>.*?</tr>',s,re.I|re.S)]
def collect(d,report,log):
    s=report.read_text(errors='replace');r=rows(s)
    out={'part':next(x[1] for x in r if x[0]=='Part Number'),'tool':next(x[1] for x in r if x[0]=='Tool Version')}
    for kind in ['Setup','Hold']:
        out[kind.lower()+'_violations']=int(next(x[1] for x in r if x[0]==f'Numbers of {kind} Violated Endpoints'))
    out['fmax']={x[1]:float(x[3].replace('(MHz)','')) for x in r if len(x)==6 and '(MHz)' in x[3]}
    out['tns']=[x for x in r if len(x)==4 and x[0] in ['clk_sys','pixel_clk','serial_clk']]
    for kind in ['Setup','Hold','Recovery','Removal']:
        sec=s.split(f'name="{kind}_Slack_Table"')[1].split('</table>')[0]
        rr=rows(sec);out[kind.lower()+'_paths']=[dict(zip(rr[0],row)) for row in rr[1:]]
    out['pa1019']=len(re.findall(r'\bPA1019\b',log.read_text(errors='replace')))
    out['qualified']=out['setup_violations']==0 and out['hold_violations']==0 and out['pa1019']==0 and out['fmax']['clk_sys']>=51.5
    (d/'timing-summary.json').write_text(json.dumps(out,indent=2),encoding='utf-8')
    (d/'timing-rows.txt').write_text('\n'.join(' | '.join(x) for x in r),encoding='utf-8')
    print(d.name,json.dumps({k:v for k,v in out.items() if not k.endswith('_paths')},indent=2))
    for kind in ['setup','hold','recovery','removal']: print(kind,'worst:',out[kind+'_paths'][0])
    return out
if __name__=='__main__':
    if len(sys.argv)>1:
        d=E/sys.argv[1];collect(d,d/'impl/pnr/Gowin2026_tr_content.html',d/'build.log')
        files=[p for p in (d/'impl').rglob('*') if p.is_file()]
        (d/'artifact-hashes.json').write_text(json.dumps({str(p.relative_to(d)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},indent=2))
    else:
        d=E/'reference-50p040';collect(d,d/'tr_content.html',d/'build.log')
