// Consume operator MIDI through the actual shipping web converter.
const fs=require('fs'),path=require('path'),assert=require('assert');
const tools=path.resolve(__dirname,'../../esp32/tools');
// Reuse the DOM stubs, but do not start the unrelated asynchronous UI boot.
const harness=fs.readFileSync(path.join(tools,'_midi_parse_check.js'),'utf8').split('let bad = 0;')[0]
  .replace('blocks[0] +','blocks[0].split("(async function boot() {")[0] +');
const API=new Function('require','__dirname','process',harness+'\nreturn API;')(require,tools,process);
const dir=path.join(__dirname,'测试素材');
const expected={F01:8,F02:12,F03:20,F04:2};
for(const name of fs.readdirSync(dir).filter(n=>n.endsWith('.mid'))){
  const b=fs.readFileSync(path.join(dir,name));
  const conv=API.midiToWords(API.parseMidi(b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength)));
  const kind=w=>Number((w>>9n)&3n);
  const ons=conv.words.filter(w=>kind(w)===0),offs=conv.words.filter(w=>kind(w)===1);
  assert.equal(ons.length,expected[name.slice(0,3)]);assert.equal(offs.length,ons.length);
  assert.equal(conv.axisClash,0);
  if(name.startsWith('F01'))assert.equal(new Set(ons.map(w=>Number((w>>7n)&3n))).size,4);
  if(name.startsWith('F02'))assert.equal(new Set(ons.map(w=>Number((w>>19n)&15n))).size,12);
  if(name.startsWith('F03')){
    assert(ons.every(w=>(w&32n)!==0n));
    assert.equal(new Set(ons.map(w=>Number((w>>7n)&3n))).size,4);
  }
  if(name.startsWith('F04'))assert.equal(conv.words.filter(w=>kind(w)===2).length,4);
  const hex=conv.words.map(w=>w.toString(16).padStart(16,'0')).join('\n')+'\n';
  fs.writeFileSync(path.join(dir,name.replace('.mid','.hex')),hex);
  console.log('PASS',name,'ON/OFF',ons.length,offs.length,'frames',conv.words.length,'axisClash',conv.axisClash);
}
