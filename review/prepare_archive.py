"""Select only new audit text, excluding dependencies and executable products."""
import argparse
import collections
import json
from pathlib import Path, PurePosixPath
import subprocess

root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--stage',action='store_true')
args=parser.parse_args()
raw=subprocess.check_output(['git','ls-files','--others','--exclude-standard','-z','--','review'],cwd=root)
suffixes={'.py','.ps1','.sv','.v','.js','.c','.h','.md','.json','.log','.csv','.html','.xml','.sdc','.timing_paths','.hex','.txt'}
selected=[]
for rel in raw.decode('utf-8').split('\0'):
    if not rel:
        continue
    parts=PurePosixPath(rel).parts
    if any(p in ('venv','__pycache__') or 'fixture' in p.lower() for p in parts):
        continue
    path=root/rel
    if path.is_file() and path.suffix.lower() in suffixes:
        selected.append(rel)
manifest='review/archive_selection.json'
if manifest not in selected:
    selected.append(manifest)
selected.sort()
result={'files':selected,'file_count':len(selected),
    'bytes_excluding_this_manifest':sum((root/p).stat().st_size for p in selected if p!=manifest),
    'extensions':dict(collections.Counter(PurePosixPath(p).suffix.lower() for p in selected))}
(root/manifest).write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
assert all(p.startswith('review/') for p in selected)
if args.stage:
    subprocess.run(['git','-c','core.autocrlf=false','add','--pathspec-from-file=-','--pathspec-file-nul'],
        cwd=root,input=('\0'.join(selected)+'\0').encode('utf-8'),check=True)
print(json.dumps({k:v for k,v in result.items() if k!='files'},indent=2))
