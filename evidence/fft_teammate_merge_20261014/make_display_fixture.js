// Generated acceptance input, not a change to the browser or synthesis source.
const fs = require('fs');
const path = require('path');
const track = bytes => Buffer.from([77,84,114,107,0,0,0,bytes.length,...bytes]);
const melodic = track([0,0xc0,0,0,0x90,60,100,0x83,0x60,0x80,60,0,0,0xff,0x2f,0]);
const drum = track([0,0x99,36,100,0,0x99,38,100,0,0x99,42,100,0,0x99,45,100,
 0x83,0x60,0x89,36,0,0,0x89,38,0,0,0x89,42,0,0,0x89,45,0,0,0xff,0x2f,0]);
const header=Buffer.from([77,84,104,100,0,0,0,6,0,1,0,2,1,224]);
fs.writeFileSync(path.join(__dirname,'display_fixture.mid'),Buffer.concat([header,melodic,drum]));
