"""Index completed runs and make readable copies without changing raw outputs."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

root=Path(__file__).resolve().parents[1]
out=root/'review'
source='cd63b0773480e43b19d47f7b541d202a0a66df4d'
subprocess.run(['git','diff','--quiet',source,'--','.',':(exclude)review/**',':(exclude)sim/evidence/**',':(exclude)evidence/**'],cwd=root,check=True)
def read_json(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))
reg=read_json(out/'regression_summary.json')
physical=read_json(out/'physical_exit.json')
sta=read_json(out/'sta_actual.json')
retries=[read_json(p) for p in sorted((out/'retries').glob('*.result.json'))]
assert reg['metadata']['source']==physical['source']==source
timeouts={c['test'] for c in reg['cases'] if c['status']=='TIMEOUT_INCOMPLETE'}
passed={r['test'] for r in retries if r['status']=='PASS' and r['actual_native_exit']==0}
manifest=[]
def make_readable(original,destination):
    raw=original.read_bytes()
    codec='utf-16' if raw.startswith((b'\xff\xfe',b'\xfe\xff')) else 'utf-8-sig'
    text=raw.decode(codec)  # Fail instead of silently replacing unknown bytes.
    encoded=text.encode('utf-8')
    destination.write_bytes(encoded)
    manifest.append({'original':str(original.relative_to(root)),
        'readable_copy':str(destination.relative_to(root)),
        'original_encoding':codec,'original_sha256':hashlib.sha256(raw).hexdigest(),
        'readable_sha256':hashlib.sha256(encoded).hexdigest()})
for name in ('regression','physical'):
    make_readable(out/f'{name}.log',out/f'{name}_readable.log')
for destination in sorted((out/'regression_evidence').glob('*.log')):
    original=root/'sim/evidence'/destination.name
    make_readable(original,destination)
(out/'evidence_encoding_manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
result={'source':source,'generated_utc':datetime.now(timezone.utc).isoformat(),
    'confirmed_primary_findings':{'Standards':8,'Spec':5,'P1':6,'P2':7,'total':13},
    'tracked_production_inputs_unchanged':True,
    'regression':{k:v for k,v in reg.items() if k!='cases'},
    'isolated_native_replays':retries,
    'original_timeouts_without_a_passing_isolated_replay':sorted(timeouts-passed),
    'physical_wrapper':physical,
    'native_STA_worst_slack_ns':{k:v['worst']['numeric_slack_ns'] for k,v in sta['checks'].items()},
    'native_STA_all_checks_pass':sta['all_native_checks_accepted'],
    'esp_idf_full_build_verified':False,'esp_idf_limit':'SDK was unavailable; see esp_idf_build.log',
    'board_tests_executed':False,
    'C_runtime_probes':'Real production C with host SDK/RTOS stubs; not hardware BLE or dual-core stress.'}
(out/'verification_summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'primary_findings':13,'regression_status_counts':reg['observed_status_counts'],
    'native_replay_count':len(retries),'unresolved_timeout_names':sorted(timeouts-passed),
    'native_STA_all_checks_pass':sta['all_native_checks_accepted'],'readable_evidence_files':len(manifest)},indent=2))
