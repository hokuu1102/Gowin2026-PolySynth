"""Assert recovery closure on this run's real, fresh vendor timing reports."""
from datetime import datetime
from decimal import Decimal
from html.parser import HTMLParser
import hashlib
import json
from pathlib import Path
import subprocess
from read_sta import analyze

root=Path(__file__).resolve().parents[1]
meta=json.loads((root/'review/physical_exit.json').read_text(encoding='utf-8-sig'))
assert meta['source']=='cd63b0773480e43b19d47f7b541d202a0a66df4d'
subprocess.run(['git','diff','--exit-code',meta['source'],'--','rtl','constr','Gowin2026.gprj','sim/gowin_build.ps1'],cwd=root,check=True,capture_output=True)
report=root/'impl/pnr/Gowin2026_tr_content.html'
started=datetime.fromisoformat(meta['started_utc'].replace('Z','+00:00')).timestamp()
assert report.stat().st_mtime>=started
sta=analyze(report)
recovery=sta['checks']['Recovery']['paths']
bad=[p for p in recovery if p['numeric_slack_ns']<0]
raw=(root/'impl/pnr/Gowin2026.timing_paths').read_text(encoding='utf-8-sig').splitlines()
class RecoveryTable(HTMLParser):
    def __init__(self):
        super().__init__()
        self.armed=False
        self.active=False
        self.rows=[]
        self.row=[]
        self.cell=None
    def handle_starttag(self,tag,attrs):
        if tag=='a' and dict(attrs).get('name')=='Recovery_Slack_Table':
            self.armed=True
        if tag=='table' and self.armed:
            self.active=True
            self.armed=False
        if self.active and tag=='tr':
            self.row=[]
        if self.active and tag in ('td','th'):
            self.cell=[]
    def handle_data(self,data):
        if self.active and self.cell is not None:
            self.cell.append(data)
    def handle_endtag(self,tag):
        if self.active and tag in ('td','th') and self.cell is not None:
            self.row.append(' '.join(''.join(self.cell).split()))
            self.cell=None
        if self.active and tag=='tr' and self.row:
            self.rows.append(self.row)
        if self.active and tag=='table':
            self.active=False
independent=RecoveryTable()
independent.feed(report.read_text(encoding='utf-8-sig'))
native_slacks=[Decimal(row[1]) for row in independent.rows[1:]]
assert len(native_slacks)==len(recovery)
for p in bad:
    assert Decimal(p['Path Slack']) in native_slacks
assert any(row[1]=='serial_clk' and row[3]=='8.000' for row in sta['clock_table'][1:])
assert sta['checks']['Hold']['accepted'] and sta['checks']['Removal']['accepted']
result={'source':meta['source'],'physical_wrapper_exit':meta['actual_exit_code'],
        'fresh_report':str(report),'report_sha256':hashlib.sha256(report.read_bytes()).hexdigest(),
        'real_serial_period_ns':8,'native_recovery_negative_count':len(bad),
        'negative_paths':bad,'cross_checked_with_independent_HTMLParser':True,
        'flat_timing_paths_contains_recovery':any(line.strip()=='RECOVERY' for line in raw),
        'expected_all_recovery_nonnegative':True,'actual_all_recovery_nonnegative':not bad,
        'hold_and_removal_positive_controls':True,
        'limitation':'Vendor STA violation on the original constraints; no physical display failure claimed.'}
(root/'review/fresh_hdmi_timing.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print(json.dumps(result,indent=2))
raise SystemExit(bool(bad))
