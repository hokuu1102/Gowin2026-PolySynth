"""Exercise the real link-checker against real tracked parent-relative links."""
import importlib.util
import json
from pathlib import Path
import posixpath
import subprocess

root=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('production_refcheck',root/'tools/check_doc_refs.py')
mod=importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
tracked=set(filter(None,subprocess.check_output(['git','ls-files','-z'],cwd=root).decode('utf-8').split('\0')))
base='bringup/hdmi_640x480'
cases=[]
for ref,want in [('rtl/hdmi/video_timing.v',True),('../../rtl/hdmi/video_timing.v',True),('../../rtl/hdmi/tmds_encoder.v',True),('../../rtl/hdmi/no_such_file.v',False)]:
    actual=mod.resolve(ref,base,tracked)
    canonical=posixpath.normpath(posixpath.join(base,ref)) if ref.startswith('..') else ref
    if want:
        assert canonical in tracked and (root/canonical).is_file()
    cases.append({'reference':ref,'document_directory':base,'canonical':canonical,'expected':want,'actual':actual})
hard,soft=[],[]
mod.check_file(base+'/README.md',root,tracked,hard,soft)
assert any(x[2]=='../../rtl/hdmi/video_timing.v' for x in hard)
tracked_report=json.loads((root/'review/tracked_doc_refs.json').read_text(encoding='utf-8'))
false_positives=[]
for path,line,ref in tracked_report['hard']:
    if '..' not in ref:
        continue
    rel=mod.normalize_ref(ref)
    options=[posixpath.normpath(rel),posixpath.normpath(posixpath.join(posixpath.dirname(path),rel)),posixpath.normpath('files/'+rel)]
    valid=next((v for v in options if v in tracked),None)
    if valid:
        false_positives.append({'document':path,'line':line,'reference':ref,'tracked_target':valid})
result={'cases':cases,'real_document_parent_reference_rejected':True,'tracked_valid_parent_links_wrongly_rejected':false_positives}
(root/'review/doc_ref_resolution.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'cases':cases,'confirmed_false_positive_count':len(false_positives)},ensure_ascii=False,indent=2))
raise SystemExit(any(c['expected']!=c['actual'] for c in cases))
