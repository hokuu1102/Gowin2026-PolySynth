"""Independently retain each native path check; never add sys margin to other clocks."""
import argparse
from decimal import Decimal, InvalidOperation
import html
import json
from pathlib import Path
import re

def cell_text(s):
    return ' '.join(html.unescape(re.sub(r'<[^>]+>', ' ', s)).split())

def rows_for(raw, anchor):
    match = re.search(r'<a\b[^>]*\bname=[\"\x27]'+re.escape(anchor)+r'[\"\x27][^>]*>', raw, re.I)
    if not match:
        return []
    table = re.search(r'<table\b[^>]*>(.*?)</table>', raw[match.end():], re.S|re.I)
    if not table:
        return []
    return [[cell_text(c) for c in re.findall(r'<t[dh]\b[^>]*>(.*?)</t[dh]>', row, re.S|re.I)]
            for row in re.findall(r'<tr\b[^>]*>(.*?)</tr>', table.group(1), re.S|re.I)]

def analyze(path):
    raw = path.read_text(encoding='utf-8-sig', errors='replace')
    result = {'report': str(path), 'checks': {}}
    for label in ('Setup','Hold','Recovery','Removal'):
        rows = rows_for(raw,label+'_Slack_Table')
        header = rows[0] if rows else []
        paths=[]
        for row in rows[1:]:
            if len(row)<2:
                continue
            try:
                val = Decimal(row[1])
                if not val.is_finite():
                    continue
            except InvalidOperation:
                continue
            item = dict(zip(header,row))
            item['numeric_slack_ns']=float(val)
            item['negative_rounded_zero'] = val.is_zero() and val.is_signed()
            paths.append(item)
        worst = min(paths,key=lambda p:p['numeric_slack_ns']) if paths else None
        floor = .05 if label=='Hold' else 0
        accepted = bool(paths) and all(p['numeric_slack_ns']>=floor and not p['negative_rounded_zero'] for p in paths)
        result['checks'][label]={'reported_paths':len(paths),'worst':worst,'required_floor_ns':floor,'accepted':accepted,'paths':paths}
    result['clock_table']=rows_for(raw,'Clock_Report')
    result['fmax_table']=rows_for(raw,'Max_Frequency_Report')
    result['tns_table']=rows_for(raw,'Total_Negative_Slack_Report')
    native_counts=[]
    for row in result['tns_table'][1:]:
        if len(row)<4:
            continue
        try:
            val=Decimal(row[2])
            endpoints=int(row[3])
        except (InvalidOperation,ValueError):
            continue
        native_counts.append({'clock':row[0],'type':row[1],'tns':row[2],'endpoints':endpoints,
            'accepted':val.is_finite() and val>=0 and endpoints==0 and not (val.is_zero() and val.is_signed())})
    result['native_endpoint_checks']=native_counts
    result['all_native_checks_accepted']=bool(native_counts) and all(v['accepted'] for v in native_counts) and all(v['accepted'] for v in result['checks'].values())
    return result

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('report',type=Path)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    result=analyze(args.report)
    args.out.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({'all_native_checks_accepted':result['all_native_checks_accepted'], 'checks':{k:{'paths':v['reported_paths'],'worst':v['worst'],'accepted':v['accepted']} for k,v in result['checks'].items()}}, ensure_ascii=False,indent=2))
