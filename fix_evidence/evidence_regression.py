from pathlib import Path
import subprocess, tempfile, sys, json
ROOT=Path(__file__).resolve().parents[1]
cases=[
    ('indexed_fail',b'FAIL: indexed failure\n',b'PASS: disk\n',1),
    ('indexed_empty',b'',b'PASS: disk\n',1),
    ('indexed_utf16_fail','FAIL: utf16 log\n'.encode('utf-16'),b'PASS: disk\n',1),
    ('indexed_leak',b'GREEN(LEAK: mutated)\n',b'PASS: disk\n',1),
    ('disk_fail_only',b'PASS: indexed clean\n',b'FAIL: next run\n',0),
    ('disk_missing',b'PASS: indexed clean\n',None,0),
    ('indexed_bad_disk_missing',b'FAIL: indexed failure\n',None,1),
]
results=[]
for name,indexed,working,expected in cases:
    with tempfile.TemporaryDirectory(prefix='fpga_evidence_') as directory:
        case=Path(directory).resolve()
        assert case.parent==Path(tempfile.gettempdir()).resolve()
        subprocess.run(['git','init','--quiet',str(case)],check=True)
        log=case/'sim/evidence/probe.log';log.parent.mkdir(parents=True)
        log.write_bytes(indexed)
        subprocess.run(['git','add','sim/evidence/probe.log'],cwd=case,check=True)
        if working is None:log.unlink()
        else:log.write_bytes(working)
        r=subprocess.run([sys.executable,str(ROOT/'tools/check_evidence.py')],cwd=case,capture_output=True)
        assert r.returncode==expected,(name,r.returncode,r.stdout)
        results.append({'case':name,'expected':expected,'actual':r.returncode})
with tempfile.TemporaryDirectory(prefix='fpga_evidence_') as directory:
    case=Path(directory).resolve()
    assert case.parent==Path(tempfile.gettempdir()).resolve()
    subprocess.run(['git','init','--quiet',str(case)],check=True)
    for filename in ('probe.compile.log','probe.stderr.log','probe.err'):
        log=case/'sim/evidence'/filename;log.parent.mkdir(parents=True,exist_ok=True);log.touch()
        subprocess.run(['git','add','--',str(log)],cwd=case,check=True)
        r=subprocess.run([sys.executable,str(ROOT/'tools/check_evidence.py')],cwd=case,capture_output=True)
        assert r.returncode==0,r.stdout
        results.append({'case':'empty_'+filename,'expected':0,'actual':r.returncode})
with tempfile.TemporaryDirectory(prefix='fpga_evidence_') as directory:
    case=Path(directory).resolve()
    assert case.parent==Path(tempfile.gettempdir()).resolve()
    subprocess.run(['git','init','--quiet',str(case)],check=True)
    folder=case/'sim/evidence';folder.mkdir(parents=True)
    (folder/'pass name.log').write_bytes(b'PASS: first blob\n')
    other=folder/'other name.log'
    for payload,expected in [(b'FAIL: second blob\n',1),(b'PASS: second blob\n',0)]:
        other.write_bytes(payload)
        subprocess.run(['git','add','--','sim/evidence'],cwd=case,check=True)
        other.write_bytes(b'PASS: working copy\n')
        r=subprocess.run([sys.executable,str(ROOT/'tools/check_evidence.py')],cwd=case,capture_output=True)
        assert r.returncode==expected,r.stdout
        results.append({'case':'multiple_blobs_'+str(expected),'expected':expected,'actual':r.returncode})
(ROOT/'fix_evidence/evidence-guard-results.json').write_text(json.dumps(results,indent=2))
print('PASS index-only evidence guard: 12 cases, including UTF16, missing working files, stderr and batch blobs')
