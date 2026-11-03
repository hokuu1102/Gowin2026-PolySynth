const fs=require('fs'),path=require('path');
const root=path.resolve(__dirname,'..');
let blobs=[];
const ctx=new Proxy({measureText(){return {width:20}},fillRect(){}},{get:(t,k)=>k in t?t[k]:(()=>{})});
const elements=new Map();
function el(id){if(!elements.has(id))elements.set(id,{
  style:{},classList:{add(){},remove(){}},getContext:()=>ctx,
  parentElement:{getBoundingClientRect:()=>({width:1000,height:500})},
  getBoundingClientRect:()=>({width:1000,height:500}),clientWidth:1000,clientHeight:500,
  querySelectorAll:()=>[],addEventListener(){},appendChild(){},insertAdjacentHTML(){},
  click(){},remove(){},textContent:'',innerHTML:'',value:'0'});return elements.get(id)}
const document={getElementById:el,querySelector:()=>el('q'),querySelectorAll:()=>[],createElement:()=>el('a'),body:el('body')};
function frame(type,seq,tick,b7,inc=38702840,vel=128){let b=[165,type,seq,tick>>>24&255,tick>>>16&255,tick>>>8&255,tick&255,b7,inc>>>24&255,inc>>>16&255,inc>>>8&255,inc&255,vel,0];b[13]=b.slice(0,13).reduce((a,b)=>a^b,0);return b}
function load(name,exports){
  const html=fs.readFileSync(path.join(root,'esp32/tools',name),'utf8');
  const script=[...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)][0][1];
  return new Function('document','window','navigator','performance','console','setTimeout','clearInterval','setInterval','requestAnimationFrame','location','localStorage','URLSearchParams','Blob','URL',script+'\nreturn {'+exports+'};')(
    document,{addEventListener(){},devicePixelRatio:1},{bluetooth:null},{now:()=>1000},console,()=>0,()=>{},()=>0,()=>0,
    {protocol:'http:',host:'x',search:''},{getItem:()=>null,setItem(){}},URLSearchParams,Blob,
    {createObjectURL(b){blobs.push(b);return 'blob:x'},revokeObjectURL(){}});
}
function assert(ok,msg){if(!ok)throw Error(msg);console.log('PASS '+msg)}
(async()=>{
  for(const [name,exports,state,reset,push,button] of [
    ['score_studio.html','U,uReset,uPushBytes,uResolveOffs,uMidiVelocity,uBuildMidi,parseMidi,midiToWords,unpackWord,__setDemoRepeat,__setGuide','U','uReset','uPushBytes','u_btnBin'],
    ['upstream_studio.html','S,reset,pushBytes,uResolveOffs,uMidiVelocity,buildMidi,draw','S','reset','pushBytes','btnBin']]){
    const api=load(name,exports);api[reset]();
    const input=Uint8Array.from([...frame(1,0,100,5),...frame(2,1,1060,5,0,0)]);
    // Fragment across both frame boundaries; mutate the caller's temporary buffer.
    for(const [a,b] of [[0,3],[3,19],[19,28]]){let chunk=input.slice(a,b);api[push](chunk);chunk.fill(0)}
    el(button).onclick();let raw=new Uint8Array(await blobs.at(-1).arrayBuffer());
    assert(Buffer.from(raw).equals(Buffer.from(input)),name+' raw export keeps every received byte across fragments');
    assert(api[state].buf.length===0,name+' parser consumed frames independently of archive');
    assert(api.uMidiVelocity(128)>0&&api.uMidiVelocity(255)===127&&api.uMidiVelocity(1)===1&&api.uMidiVelocity(0)===0,name+' MIDI velocity boundaries');
    const events=[{type:1,tick:0,axis:0,midi:69,timbre:0,drumType:null},
      {type:1,tick:1,axis:0,midi:72,timbre:0,drumType:null},
      {type:1,tick:2,axis:0,midi:36,timbre:null,drumType:0},
      {type:2,tick:3,axis:0,midi:69,timbre:0,drumType:null},
      {type:2,tick:4,axis:0,midi:72,timbre:0,drumType:null},
      {type:2,tick:5,axis:0,midi:0,timbre:null,drumType:0}];
    const resolved=api.uResolveOffs(events);
    assert(resolved.length===6&&new Set(resolved.slice(0,3).map(e=>e.voiceId)).size===3&&
      resolved.slice(3).every((e,i)=>e.voiceId===resolved[i].voiceId&&e.midi===resolved[i].midi),name+' chord and drums keep independent identities');
    if(api.draw){api[state].events=events;api.draw()}
    if(api.parseMidi){
      const bytes=fs.readFileSync(path.join(__dirname,'python-export.mid'));
      api.__setDemoRepeat(false);api.__setGuide(false);
      const parsed=api.parseMidi(bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength));
      const notes=api.midiToWords(parsed).words.map(api.unpackWord).filter(e=>e.kind===0);
      const melody=notes.filter(e=>!e.isDrum),drums=notes.filter(e=>e.isDrum);
      assert(melody.length===4&&new Set(melody.map(e=>e.timbre)).size===4&&
        drums.length===4&&new Set(drums.map(e=>e.timbre)).size===4,
        'Python export -> actual webpage score conversion preserves four timbres and four drums');
    }
    api[reset]();assert(api[state].raw.length===0&&api[state].bytes===0,name+' reset clears raw archive');
  }
})().catch(e=>{console.error(e);process.exitCode=1});
