from pathlib import Path
import importlib.util, subprocess, json, tempfile, sys
ROOT=Path(__file__).resolve().parents[1]

def load(path):
    spec=importlib.util.spec_from_file_location('checker',path)
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod);return mod

def doc_refs():
    mod=load(ROOT/'tools/check_doc_refs.py')
    tracked={'rtl/hdmi/video_timing.v','.github/workflows/check.yml','files/test.md'}
    for ref,base,want in [('../../rtl/hdmi/video_timing.v','bringup/hdmi_640x480',True),
                          ('../../rtl/hdmi/no_file.v','bringup/hdmi_640x480',False),
                          ('../../../rtl/hdmi/video_timing.v','bringup/hdmi_640x480',False),
                          ('./.github/workflows/check.yml','',True),
                          ('test.md','',True)]:
        actual=mod.resolve(ref,base,tracked)
        assert actual==want,(ref,actual,want)
    print('PASS document parent resolution, dot directories and escape/missing controls')

def timing_gate():
    source=(ROOT/'sim/gowin_build.ps1').read_text(encoding='utf-8-sig')
    gate=source[source.index('$p030Tr = $trPath'):]
    results=[]
    for name,clock,slack,recovery,removal,expected in [
        ('sys_budget','clk_sys','-0.500','0.500','0.500',0),
        ('serial_failure','serial_clk','-0.500','0.500','0.500',12),
        ('pixel_failure','pixel_clk','-0.500','0.500','0.500',12),
        ('sys_real_failure','clk_sys','-4.000','0.500','0.500',12),
        ('recovery_failure','clk_sys','-0.500','-0.001','0.500',12),
        ('removal_failure','clk_sys','-0.500','0.500','-0.001',12),
        ('recovery_missing','clk_sys','-0.500',None,'0.500',12),
        ('rounded_negative_zero','clk_sys','-0.500','-0.000','0.500',12),
        ('short_sys_exception','clk_sys','-0.500','0.500','0.500',12),
    ]:
        with tempfile.TemporaryDirectory(prefix='fpga_gate_') as directory:
            case=Path(directory);(case/'impl/pnr').mkdir(parents=True);(case/'constr').mkdir()
            (case/'constr/top.sdc').write_bytes((ROOT/'constr/top.sdc').read_bytes())
            html=f'<html>Total Negative Slack Summary<table><tr><td>Clock Name</td><td>Analysis Type</td><td>TNS</td><td>Endpoints</td></tr><tr><td>{clock}</td><td>Setup</td><td>{slack}</td><td>1</td></tr></table>Path Slacks Table'
            relation='10.000' if name=='short_sys_exception' else '16.400'
            html+=f'<a name="Setup_Slack_Table"></a><table><tr><td>Path Number</td><td>Path Slack</td></tr><tr><td>1</td><td>{slack}</td><td>source</td><td>dest</td><td>{clock}:[R]</td><td>{clock}:[R]</td><td>{relation}</td></tr></table>'
            for kind,value in [('Hold','0.183'),('Recovery',recovery),('Removal',removal)]:
                if value is not None:
                    html+=f'<a name="{kind}_Slack_Table"></a><table><tr><td>Path Number</td><td>Path Slack</td></tr><tr><td>1</td><td>{value}</td></tr></table>'
            (case/'impl/pnr/report.html').write_text(html+'</html>')
            (case/'impl/pnr/Gowin2026.timing_paths').write_text(f'SETUP\n{slack}\n{clock}\n')
            script=case/'run.ps1'
            script.write_text("$root=$PSScriptRoot\n$trPath=Join-Path $root 'impl/pnr/report.html'\n"+gate,encoding='utf-8-sig')
            r=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(script)],capture_output=True)
            results.append({'name':name,'expected':expected,'actual':r.returncode})
            assert r.returncode==expected,(name,r.returncode,r.stdout.decode(errors='replace'))
    (ROOT/'fix_evidence/timing-gate-results.json').write_text(json.dumps(results,indent=2))
    print('PASS exact production timing gate: 9 positive/negative fixtures, including shorter CDC budget')

def process_guard():
    source=(ROOT/'sim/gowin_build.ps1').read_text(encoding='utf-8-sig')
    a=source.index('$pcPath =')
    b=source.index('# ----',a)
    results=[]
    for mapping,place,route,expected in [('0','0','0',0),('1','0','0',0),
                                        ('2','0','0',3),('1','2','0',3),
                                        ('1','0','2',3),('','0','0',3)]:
        with tempfile.TemporaryDirectory(prefix='fpga_config_') as directory:
            case=Path(directory);(case/'impl').mkdir()
            (case/'impl/Gowin2026_process_config.json').write_text(json.dumps({
                'Map_Option':mapping,'Place_Option':place,'Route_Option':route}))
            script=case/'run.ps1'
            script.write_text('$root=$PSScriptRoot\n'+source[a:b]+'\nexit 0',encoding='utf-8-sig')
            r=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(script)],capture_output=True)
            assert r.returncode==expected,(mapping,place,route,r.returncode,r.stdout)
            results.append({'Map':mapping,'Place':place,'Route':route,'expected':expected,'actual':r.returncode})
    (ROOT/'fix_evidence/process-guard-results.json').write_text(json.dumps(results,indent=2))
    print('PASS production process guard accepts measured vendor default and rejects unsupported modes')

if __name__=='__main__':
    doc_refs();timing_gate();process_guard()
