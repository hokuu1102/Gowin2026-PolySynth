from pathlib import Path
import subprocess, shutil, hashlib, json, time, sys
E=Path(__file__).resolve().parent
R=E.parents[1]
label=sys.argv[1]
D=E/label
assert not D.exists(), 'Never repeat a same-label build'
check=subprocess.run(['powershell','-NoProfile','-Command','Get-Process gw_sh -ErrorAction SilentlyContinue | Select-Object Id,StartTime | ConvertTo-Json'],capture_output=True)
assert not check.stdout.strip(), 'Another gw_sh is running: '+check.stdout.decode(errors='replace')
previous=list(E.glob('build-*/started.json'))
assert len(previous)<3,'Three-build budget exhausted'
D.mkdir()
(D/'process-check.txt').write_bytes(b'Get-Process gw_sh: no running process\n'+check.stdout+check.stderr)
for directory in ['rtl','constr','ip']:
    shutil.copytree(R/directory,D/'source'/directory)
for name in ['Gowin2026.gprj','Gowin2026.gprj.user','build_cli.tcl','impl/Gowin2026_process_config.json']:
    p=D/'source'/name;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(R/name,p)
hashes={str(p.relative_to(D/'source')):hashlib.sha256(p.read_bytes()).hexdigest() for p in (D/'source').rglob('*') if p.is_file()}
(D/'source-hashes.json').write_text(json.dumps(hashes,indent=2))
start=time.time()
(D/'started.json').write_text(json.dumps({'unix_time':start,'command':'gw_sh.exe build_cli.tcl','cwd':str(R)},indent=2))
with (D/'build.log').open('wb') as out,(D/'build.stderr.log').open('wb') as err:
    p=subprocess.Popen(['D:/Gowin/Software/Gowin_V1.9.12.03_x64/IDE/bin/gw_sh.exe','build_cli.tcl'],cwd=R,stdout=out,stderr=err,creationflags=subprocess.CREATE_NO_WINDOW)
    (D/'pid.txt').write_text(str(p.pid));print('Build started',label,p.pid,flush=True)
    rc=p.wait()
shutil.copytree(R/'impl',D/'impl')
(D/'exit.json').write_text(json.dumps({'exit':rc,'elapsed_seconds':time.time()-start},indent=2))
assert (D/'impl/pnr/Gowin2026_tr_content.html').stat().st_mtime>=start,'Stale timing'
assert (D/'impl/pnr/Gowin2026.fs').stat().st_mtime>=start,'Stale bitstream'
print('Build complete',label,'exit',rc,flush=True)
sys.exit(rc)
