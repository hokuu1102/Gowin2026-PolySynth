from pathlib import Path
from html import unescape
import re

root = Path(__file__).resolve().parents[2]
out = Path(__file__).resolve().parent
lines = []
for mode, name in [('h4', 'hdmi_h4'), ('baseline_after', 'hdmi_640x480')]:
    lines.append(f'=== {mode}: timing report rendered cell text (unaltered values) ===')
    report = (out / mode / f'{name}_tr_content.html').read_text()
    summary = report.split('<h1><a name="Detail">')[0]
    for block in re.findall(r'<h[124]>.*?</h[124]>|<tr>.*?</tr>', summary, re.S):
        cells = re.findall(r'<t[dh][^>]*>(.*?)(?=</t[dh]>|<t[dh]|</tr>)', block, re.S)
        if cells:
            lines.append(' | '.join(unescape(re.sub('<[^>]*>', '', cell)).strip() for cell in cells))
        else:
            lines.append(unescape(re.sub('<[^>]*>', '', block)).strip())
    log = (out / mode / 'build.log').read_text()
    lines.append(f'PA1019 occurrences in build.log: {log.count("PA1019")}')
    lines.extend(line for line in log.splitlines() if 'WARN' in line or 'ERROR' in line)
    lines.append('PLL parameters from synthesized netlist:')
    vg = (out / mode / f'{name}.vg').read_text()
    lines.extend(line for line in vg.splitlines() if re.search(r'defparam .*\.(FCLKIN|IDIV_SEL|FBDIV_SEL|MDIV_SEL|MDIV_FRAC_SEL|ODIV[01]_SEL)=', line))
text = '\n'.join(lines) + '\n'
(out / 'evidence.txt').write_text(text, encoding='utf-8')
print(text)
