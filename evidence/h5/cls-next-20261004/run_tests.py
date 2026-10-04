"""Bounded simulations with exit/status/log accounting; timeout is failure."""
from pathlib import Path
import argparse
import json
import re
import subprocess
import time
import threading
from concurrent.futures import ThreadPoolExecutor

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[2]
p = argparse.ArgumentParser()
p.add_argument('suite', choices=['diff', 'regression'])
p.add_argument('--only', help='Run one named existing bench')
p.add_argument('--label', help='Separate evidence directory for a rerun')
p.add_argument('--jobs', type=int, default=1)
p.add_argument('--rtl-file', help='Explicit archived note_manager candidate, relative to repo root')
args = p.parse_args()
logs = OUT / ('tests-' + (args.label or args.suite))
logs.mkdir(exist_ok=True)
sources = sorted(f for folder in ['rtl', 'tb/models', 'tb/checkers'] for f in (ROOT/folder).rglob('*')
                 if f.suffix in ['.sv', '.v'] and not f.name.startswith('tb_'))
results = []
result_lock = threading.Lock()
snapshot = logs / 'note_manager_under_test.v'
snapshot.write_bytes((ROOT / (args.rtl_file or 'rtl/w3b/note_manager.v')).read_bytes())
sources.remove(ROOT / 'rtl/w3b/note_manager.v')
sources.append(snapshot)

def run(name, tb, extra=(), mutant=None, red=False, timeout=120):
    files = sources.copy()
    if mutant:
        files.remove(snapshot)
        files.append(mutant)
    for match in re.findall(r'\$dumpfile\s*\(\s*"([^"]+)"', tb.read_text(encoding='utf-8-sig')):
        target = (ROOT / match).resolve()
        assert target.is_relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
    filelist = logs / (name + '.f')
    filelist.write_text('\n'.join(f.relative_to(ROOT).as_posix() for f in files+[tb])+'\n', encoding='utf-8')
    vvp = logs / (name + '.vvp')
    cmd = ['iverilog', '-g2012', '-DWAVETABLE_BEHAVIORAL', '-s', tb.stem, '-o', str(vvp), *extra, '-f', str(filelist)]
    t = time.time()
    with (logs / (name+'.compile.log')).open('wb') as log:
        c = subprocess.run(cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    status, rc = 'COMPILE_FAIL', None
    if c.returncode == 0:
        with (logs / (name+'.log')).open('wb') as log:
            try:
                r = subprocess.run(['vvp', str(vvp)], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
                rc = r.returncode
            except subprocess.TimeoutExpired:
                status = 'TIMEOUT'
        txt = (logs / (name+'.log')).read_text(encoding='utf-8', errors='replace')
        if status != 'TIMEOUT':
            if red:
                status = 'RED_DETECTED' if rc != 0 and 'DIFF ' in txt else 'RED_MISSED'
            else:
                status = 'PASS' if rc == 0 and re.search(r'PASS', txt) and not re.search(r'(?:^|\n)\s*(?:FAIL|FATAL)', txt) else 'FAIL'
    row = dict(name=name, status=status, compile_exit=c.returncode, run_exit=rc, seconds=round(time.time()-t,2))
    with result_lock:
        results.append(row)
        (logs/'results.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
        print(row, flush=True)

if args.suite == 'diff':
    tb = ROOT/'tb/w3b/tb_note_manager_write_share.sv'
    for n, params in [('p32', []), ('p4', ['POLY_TARGET=4','RESERVED_N=0']), ('p7', ['POLY_TARGET=7','RESERVED_N=2']),
                      ('t3', ['POLY_TARGET=4','RESERVED_N=0','T3_EN=1'])]:
        run(n, tb, ['-Ptb_note_manager_write_share.'+s for s in params])
    src = snapshot.read_text(encoding='utf-8')
    mutations = {
        'wrong_alloc_phase': ('event_write_retrig ? cur_inc : cmt_inc_r', 'event_write_retrig ? cur_inc : (cmt_inc_r ^ 1)'),
        'wrong_retrig_velocity': ('event_write_retrig ? new_vel : cmt_vel_r', 'event_write_retrig ? (new_vel ^ 1) : cmt_vel_r'),
        'lost_priority': ('phase_r[i]  <= event_write_phase;', 'phase_r[i]  <= pitch_upd_valid_i ? pitch_upd_value_i : event_write_phase;'),
    }
    for n, (old,new) in mutations.items():
        assert src.count(old)==1
        file = logs/(n+'.v')
        file.write_text(src.replace(old,new), encoding='utf-8')
        run(n, tb, mutant=file, red=True)
else:
    names = ['tb_note_manager','tb_note_manager_vel_ramp','tb_envelope_bank','tb_adsr','tb_tdm_render_mixer',
             'tb_oscillator_bank','tb_top_sound','tb_polyphony_onset_step','tb_timbre_adsr','tb_timbre_event_path',
             'tb_nm_no_leak','tb_nm_off_in_hold','tb_nm_reuse_tail','tb_pool_by_src','tb_retrig_reset_span',
             'tb_velocity_lane_isolation','tb_vel_pos_follow','tb_transpose','tb_base_semi','tb_e2e_key_to_sound']
    def regression(n):
        if args.only and n != args.only:
            return
        matches = list((ROOT/'tb').rglob(n+'.sv'))
        assert len(matches)==1, (n,matches)
        # Match the effective budgets at the end of sim/tb_all.ps1, not its
        # historical 300-second comment. Top/e2e already have 900 seconds.
        budget = 900 if n in ['tb_top_sound','tb_e2e_key_to_sound'] else 300 if n in ['tb_transpose','tb_note_manager','tb_nm_no_leak'] else 120
        run(n, matches[0], timeout=budget)
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        list(pool.map(regression, names))
bad = [r for r in results if r['status'] not in ['PASS','RED_DETECTED']]
print('PASS', sum(r['status']=='PASS' for r in results), 'RED_DETECTED',sum(r['status']=='RED_DETECTED' for r in results),'FAIL',len(bad), flush=True)
raise SystemExit(bool(bad))
