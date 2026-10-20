import pathlib,ast,csv,subprocess,json
ROOT=pathlib.Path(__file__).resolve().parents[2];OUT=pathlib.Path(__file__).resolve().parent
rows=[];bad=[]
for base in ['esp32','tools']:
 for p in sorted((ROOT/base).rglob('*')):
  if p.suffix.lower() not in {'.py','.js','.html','.c','.h'} or not p.is_file():continue
  rel=p.relative_to(ROOT).as_posix();text=p.read_text(encoding='utf-8-sig',errors='replace')
  mode='inventory/static only; hardware/SDK behavior not executed'
  if p.suffix=='.py':
   try:ast.parse(text);mode='Python AST syntax PASS; runtime only if named in selftest-complete.log'
   except Exception as e:mode='Python AST FAIL '+str(e);bad.append(rel)
  if p.suffix=='.html':mode='HTML inventory; 3 live pages script syntax in html-syntax.log'
  if p.name=='pool.c':mode='unchanged actual C compiled/run; STOP/RESET interleave host probe'
  if p.name=='up_ring.c':mode='unchanged actual C compiled/run; notify host probe'
  if p.name=='ble_main.c':mode='actual notify drain block compiled/run; other paths static only'
  if p.name=='score_studio.html':mode='real inline JS Node execution; web_probe.js plus existing suite'
  if p.name=='evt2midi.py':mode='runtime selftests and true full-width upstream phase probe'
  rows.append([rel,len(text.splitlines()),mode])
with (OUT/'coverage.csv').open('w',encoding='utf-8-sig',newline='') as f:
 w=csv.writer(f);w.writerow(['file','lines','coverage']);w.writerows(rows)
print(json.dumps({'files':len(rows),'python_ast_failures':bad},ensure_ascii=False));raise SystemExit(bool(bad))
