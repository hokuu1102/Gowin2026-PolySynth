import collections
import json
from pathlib import Path
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
project = ET.parse(root / 'Gowin2026.gprj')
items = []
for node in project.iter():
    if node.tag == 'File' and node.get('path'):
        rel = node.get('path').replace('\\', '/')
        path = root / rel
        items.append({'path': rel, 'exists': path.is_file(), 'type': node.get('type')})
counts = collections.Counter(x['path'] for x in items)
result = {'registered_entries': len(items), 'unique_paths': len(counts), 'duplicates': {k:v for k,v in counts.items() if v > 1}, 'missing': [x for x in items if not x['exists']], 'entries': items}
(root / 'review/project_inputs.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
print(json.dumps({k:v for k,v in result.items() if k != 'entries'}, indent=2))
raise SystemExit(bool(result['missing']))
