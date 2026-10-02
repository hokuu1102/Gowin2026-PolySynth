"""Extract actual reported setup paths; never infer missing paths from Top25."""
from pathlib import Path
import json, re, sys
from collect import rows

def extract(path):
    text = path.read_text(errors='replace')
    section = text.split('name="Setup_Analysis"')[1].split('name="Hold_Analysis"')[0]
    result = []
    for part in re.split(r'<h3>Path\d+</h3>', section)[1:]:
        tables = re.findall(r'<table\b.*?</table>', part, re.S)
        summary = dict(rows(tables[0]))
        rr = rows(tables[1])
        stages = [dict(zip(rr[0], r)) for r in rr[1:]]
        # Exclude launch clock insertion/routing; include clock-to-Q separately.
        start = next(i for i, r in enumerate(stages) if r['TYPE'] == 'tC2Q')
        data = stages[start:]
        summary['route_ns'] = round(sum(float(r['DELAY']) for r in data if r['TYPE'] == 'tNET'), 3)
        summary['cell_ns'] = round(sum(float(r['DELAY']) for r in data if r['TYPE'] not in ('tNET', 'tC2Q')), 3)
        summary['clock_to_q_ns'] = float(data[0]['DELAY'])
        summary['data_ns'] = round(sum(float(r['DELAY']) for r in data), 3)
        summary['source_fanout'] = data[0]['FANOUT']
        summary['stages'] = data
        result.append(summary)
    return result

if __name__ == '__main__':
    source = Path(sys.argv[1])
    dest = Path(sys.argv[2])
    data = extract(source)
    dest.with_suffix('.json').write_text(json.dumps(data, indent=2), encoding='utf-8')
    lines = []
    for i, p in enumerate(data, 1):
        lines += [f"Path {i}: {p['From']} -> {p['To']}",
                  f"slack={p['Slack']} route={p['route_ns']} cell={p['cell_ns']} tCO={p['clock_to_q_ns']} total={p['data_ns']} source_fanout={p['source_fanout']}",
                  'DELAY | TYPE | FANOUT | LOC | NODE']
        lines += [' | '.join(r[k] for k in ('DELAY','TYPE','FANOUT','LOC','NODE')) for r in p['stages']]
        lines += ['']
    dest.with_suffix('.txt').write_text('\n'.join(lines), encoding='utf-8')
    for i, p in enumerate(data, 1):
        print(i, p['Slack'], p['route_ns'], p['cell_ns'], p['source_fanout'], p['From'], '->', p['To'])
