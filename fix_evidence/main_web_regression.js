const fs = require('fs'), path = require('path');
const root = path.resolve(__dirname, '..');
let draws = [], blobs = [];
const ctx = new Proxy({fillRect(...a) { draws.push({a, color:this.fillStyle}); }, measureText(){return {width:20};}}, {get:(t,k)=>k in t?t[k]:(()=>{})});
const els = new Map();
function element(id) { if (!els.has(id)) els.set(id, {style:{},classList:{add(){},remove(){}},getContext:()=>ctx,
  parentElement:{getBoundingClientRect:()=>({width:1000,height:500})}, getBoundingClientRect:()=>({width:1000,height:500}),
  clientWidth:1000, clientHeight:500, querySelectorAll:()=>[],addEventListener(){},appendChild(){},
  insertAdjacentHTML(){},click(){},remove(){},textContent:'',innerHTML:'', value:'0'}); return els.get(id); }
const doc={getElementById:element,querySelector:()=>element('q'),querySelectorAll:()=>[],createElement:()=>element('a'),body:element('body')};
const html=fs.readFileSync(path.join(root,'esp32/tools/score_studio.html'),'utf8');
const script=[...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)][0][1];
const api=new Function('document','window','navigator','performance','console','setTimeout','clearInterval','setInterval','requestAnimationFrame','location','localStorage','URLSearchParams','Blob','URL',script+'\nreturn {U,uReset,uPushBytes,uBuildMidi,uDraw,uIncToHz,uHzToMidi,parseMidi,midiToWords,__setGuide,__setDemoRepeat,unpackWord,tickToSec,secToTick};')(
  doc,{addEventListener(){},devicePixelRatio:1},{bluetooth:null},{now:()=>1000},console,()=>0,()=>{},()=>0,()=>0,
  {protocol:'http:',host:'x',search:''},{getItem:()=>null,setItem(){}},URLSearchParams,Blob,{createObjectURL(b){blobs.push(b);return 'blob:x';},revokeObjectURL(){}});
function frame(type,seq,tick,b7,inc=38702840,vel=100) { let b=[165,type,seq,tick>>>24&255,tick>>>16&255,tick>>>8&255,tick&255,b7,inc>>>24&255,inc>>>16&255,inc>>>8&255,inc&255,vel,0];b[13]=b.slice(0,13).reduce((a,b)=>a^b,0);return b; }
function feed(...f){api.uPushBytes(new Uint8Array(f.flat()));}
let failures=0; function check(name,ok,actual){console.log(`${ok?'PASS':'FAIL'} ${name}: ${JSON.stringify(actual)}`);if(!ok)failures++;}
function midiEvents(buf) { let p=14, result=[], names=[];while(p<buf.length){p+=4;let size=buf.readUInt32BE(p);p+=4;let end=p+size,t=0;function vl(){let n=0,x;do{x=buf[p++];n=n*128+(x&127);}while(x&128);return n;}while(p<end){t+=vl();let s=buf[p++];if(s===255){let type=buf[p++],len=vl();if(type===3)names.push(buf.subarray(p,p+len).toString());p+=len;}else result.push({tick:t,status:s,note:buf[p++],vel:buf[p++]});}}return {names,events:result};}
(async()=>{
  api.uReset();feed(frame(1,1,100,0,38702840,128),frame(2,2,1060,0));
  let mid=midiEvents(Buffer.from(await api.uBuildMidi().arrayBuffer()));check('velocity128 remains audible',mid.events[0].vel>0,mid);
  api.uReset();feed(frame(1,1,100,0),frame(2,2,1060,0,0,0));
  mid=midiEvents(Buffer.from(await api.uBuildMidi().arrayBuffer()));check('zero-inc note_off closes same pitch',mid.events[0].note===mid.events[1].note,mid);
  api.uReset();feed(frame(1,1,100,0),frame(2,2,1060,0));
  element('u_btnBin').onclick();let raw=Buffer.from(await blobs.at(-1).arrayBuffer());check('download bin preserves received 28 bytes',raw.length===28,{downloaded:raw.length,received:api.U.bytes,remaining:api.U.buf.length});
  api.uReset();feed(frame(1,1,100,0),frame(1,2,110,0x40,10000000),frame(1,3,120,0x50,20000000),frame(2,4,500,0),frame(2,5,510,0x40),frame(2,6,520,0x50));
  draws=[];api.uDraw();let blocks=draws.filter(d=>d.a[0]>=76&&d.a[3]<=12&&d.a[3]>0&&d.a[1]<478);check('roll draws melody and two drums independently',blocks.length===3,{blocks});
  for (const axes of [[0,1],[0,0]]) {
    api.uReset();feed(frame(1,1,100,axes[0]),frame(1,2,110,axes[1],46000000),frame(2,3,500,axes[0]),frame(2,4,510,axes[1],46000000));
    draws=[];api.uDraw();blocks=draws.filter(d=>d.a[0]>=76&&d.a[3]<=12&&d.a[3]>0&&d.a[1]<478);
    check('roll draws two concurrent melodies axes '+axes,blocks.length===2,blocks);
  }
  const fixture=path.join(root,'sim/evidence/top-identity-frames.hex');
  if(fs.existsSync(fixture)) {
    const data=fs.readFileSync(fixture,'utf8').split(/\r?\n/).map(s=>s.replace(/\/\/.*$/,'').trim()).filter(s=>/^[0-9a-f]{2}$/i.test(s)).map(s=>parseInt(s,16));
    api.uReset();api.uPushBytes(new Uint8Array(data));draws=[];api.uDraw();
    blocks=draws.filter(d=>d.a[0]>=76&&d.a[3]<=12&&d.a[3]>0&&d.a[1]<478);
    check('REAL TOP UART fixture preserves two chord notes on roll',api.U.events.length===4&&blocks.length===2,{inputBytes:data.length,events:api.U.events,blocks});
  }
  api.uReset();for(let tb=0;tb<4;tb++)feed(frame(1,tb*2,100,tb*16+tb),frame(2,tb*2+1,1060,tb*16+tb));
  mid=midiEvents(Buffer.from(await api.uBuildMidi().arrayBuffer()));check('four timbres export four named tracks',mid.names.length===4,mid.names);
  check('sample-clock A4 decodes MIDI69',api.uHzToMidi(api.uIncToHz(38702840))===69,api.uHzToMidi(api.uIncToHz(38702840)));
  const parsed={format:1,division:960,allTempos:[{tick:0,usPerQuarter:750000},{tick:960,usPerQuarter:500000}],tracks:[{name:'PIANO',chan:new Set([0]),tempos:[],notes:[{tick:0,midi:69,vel:100,on:true},{tick:960,midi:69,vel:0,on:false}]}]};
  api.__setDemoRepeat(false);api.__setGuide(true,0,false,'quarter','all','both',2);
  let conv=api.midiToWords(parsed), ev=conv.words.map(api.unpackWord);
  check('two-bar silent preparation shifts first note to7680',Math.min(...ev.filter(e=>e.kind===0).map(e=>e.tick))===7680,ev);
  check('preparation retains tempo at0 and shifts later tempo to8640',ev.some(e=>e.kind===2&&e.tick===0)&&ev.some(e=>e.kind===2&&e.tick===8640),ev.filter(e=>e.kind===2));
  let ts=ev.filter(e=>e.kind===2).map(e=>({tick:e.tick,hz:e.inc*50000000/4294967296}));
  check('preparation clock starts zero and 7680ticks lasts6sec',api.secToTick(0,ts)===0&&Math.abs(api.tickToSec(7680,ts)-6)<0.001,{tick0:api.secToTick(0,ts),sec7680:api.tickToSec(7680,ts)});
  api.uReset();for(let b=0;b<64;b++){feed(frame(1,b,100,b));check(`byte7 compatibility ${b}`,api.U.events.at(-1).drumType===null&&api.U.events.at(-1).axis===(b&15)&&api.U.events.at(-1).timbre===(b>>4),api.U.events.at(-1).axis);}
  console.log(`FAILURES=${failures}`);process.exitCode=failures?1:0;
})().catch(e=>{console.error(e);process.exitCode=2;});
