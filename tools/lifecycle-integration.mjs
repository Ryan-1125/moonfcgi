// Real TCP regression driver for lifecycle, telemetry and staged limits.
import net from 'node:net';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {existsSync,mkdirSync,writeFileSync,unlinkSync} from 'node:fs';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const base=resolve(root,'_build/native/debug/build/cmd/lifecycle/lifecycle');
const exe=process.env.MOONFCGI_LIFECYCLE_BIN||(existsSync(base+'.exe')?base+'.exe':base);
const sleep=ms=>new Promise(r=>setTimeout(r,ms));const children=[];const logs=[];let passed=0;
function frame(t,b=Buffer.alloc(0),id=1){const h=Buffer.alloc(8);h[0]=1;h[1]=t;h.writeUInt16BE(id,2);h.writeUInt16BE(b.length,4);return Buffer.concat([h,b]);}
function begin(path='/'){const k=Buffer.from('DOCUMENT_URI'),v=Buffer.from(path);return Buffer.concat([frame(1,Buffer.from([0,1,1,0,0,0,0,0])),frame(4,Buffer.concat([Buffer.from([k.length,v.length]),k,v])),frame(4)]);}
class Client{
 constructor(s){this.s=s;this.buffer=Buffer.alloc(0);this.queue=[];this.waiters=[];this.closed=false;s.on('error',()=>{});s.on('data',b=>{this.buffer=Buffer.concat([this.buffer,b]);while(this.buffer.length>=8){const n=this.buffer.readUInt16BE(4),size=8+n+this.buffer[6];if(this.buffer.length<size)break;const r={t:this.buffer[1],b:Buffer.from(this.buffer.subarray(8,8+n))};this.buffer=this.buffer.subarray(size);const w=this.waiters.shift();if(w)w(r);else this.queue.push(r);}});s.on('close',()=>{this.closed=true;for(const w of this.waiters.splice(0))w(null);});}
 static open(port){return new Promise((res,rej)=>{const s=typeof port==='string'?net.connect(port):net.connect(port,'127.0.0.1');s.once('error',rej);s.once('connect',()=>{s.off('error',rej);res(new Client(s));});});}
 next(){if(this.queue.length)return Promise.resolve(this.queue.shift());if(this.closed)return Promise.resolve(null);return new Promise((res,rej)=>{const timer=setTimeout(()=>rej(Error('TCP record timeout')),3500);this.waiters.push(r=>{clearTimeout(timer);res(r);});});}
 request(path='/'){this.s.write(Buffer.concat([begin(path),frame(5)]));}
 async response(){const out=[];while(true){const r=await this.next();assert(r,'response truncated');if(r.t===6)out.push(r.b);if(r.t===3)break;}const bytes=Buffer.concat(out),split=bytes.indexOf('\r\n\r\n');assert(split>=0);return{headers:bytes.subarray(0,split).toString(),body:bytes.subarray(split+4)};}
 async closedAfterRecords(){while(await this.next()){}assert(this.closed);}
 close(){this.s.destroy();}
}
async function waitFor(test,ms=3000){const end=Date.now()+ms;while(!test()){if(Date.now()>end)throw Error('fixture wait timeout');await sleep(10);}}
async function vacantPort(){
 const probe=net.createServer();await new Promise((res,rej)=>{probe.once('error',rej);probe.listen(0,'127.0.0.1',res);});
 const port=probe.address().port;await new Promise((res,rej)=>probe.close(e=>e?rej(e):res()));return port;
}
async function server(mode='stream',endpoint=undefined,inherited=false){
 if(endpoint===undefined)endpoint=await vacantPort();
 const port=typeof endpoint==='string'?endpoint.slice(5):endpoint;
 const args=inherited?[resolve(root,'tools/inherited-launch.py'),exe,String(endpoint)]:[typeof endpoint==='string'?endpoint:`127.0.0.1:${port}`,mode];
 const child=spawn(inherited?(process.env.PYTHON_BIN||'python3'):exe,args,{cwd:root,windowsHide:true,stdio:['ignore','pipe','pipe']});children.push(child);
 let log='';for(const stream of [child.stdout,child.stderr])stream.on('data',b=>{log+=b.toString();});
 const ended=new Promise((res,rej)=>{child.once('error',rej);child.once('close',code=>{logs.push(log);res(code);});});
 for(let i=0;i<100;i++){try{const c=await Client.open(port);c.close();return{child,port,ended,get log(){return log;}};}catch{await sleep(30);}}
 throw Error('cannot start lifecycle fixture: '+log);
}
function metric(s,name){const line=s.log.includes('STATS ')?s.log.slice(s.log.indexOf('STATS ')):null;assert(line,'missing final counters: '+s.log);const match=line.match(new RegExp(`\\b${name}: (\\d+)`));assert(match,'missing metric '+name);return Number(match[1]);}
async function stop(s){const c=await Client.open(s.port);try{c.request('/shutdown');assert.equal((await c.response()).body.toString(),'ok');}finally{c.close();}assert.equal(await s.ended,0);assert.equal(metric(s,'active_connections'),0);assert.equal(metric(s,'active_requests'),0);}
async function test(name,f){await f();passed++;console.log('PASS '+name);}
try{
 for(const mode of ['stream','buffered']){
  await test(`${mode}: graceful shutdown drains active response and rejects new connections`,async()=>{
   const s=await server(mode),active=await Client.open(s.port);
   try{active.request('/slow');active.s.write(frame(9,Buffer.alloc(0),0));assert.equal((await active.next()).t,10);
    const trigger=await Client.open(s.port);try{trigger.request('/shutdown');assert.equal((await trigger.response()).body.toString(),'ok');}finally{trigger.close();}
    assert.equal((await active.response()).body.toString(),'done');assert.equal(await s.ended,0);
    assert.equal(metric(s,'completed'),2);assert.equal(metric(s,'active_connections'),0);assert.equal(metric(s,'active_requests'),0);
    await assert.rejects(Client.open(s.port));
   }finally{active.close();}
  });
  await test(`${mode}: shutdown deadline cancels stuck handler and balances counters`,async()=>{
   const s=await server(mode),active=await Client.open(s.port);
   try{active.request('/hang');active.s.write(frame(9,Buffer.alloc(0),0));assert.equal((await active.next()).t,10);await stop(s);await active.closedAfterRecords();assert(s.log.includes('Deadline(Shutdown)'));assert.equal(metric(s,'failed'),1);}finally{active.close();}
  });
  await test(`${mode}: idle, input, handler and protocol errors are distinguishable`,async()=>{
   const s=await server(mode);
   let c=await Client.open(s.port);await c.closedAfterRecords();c.close();
   c=await Client.open(s.port);c.s.write(Buffer.from([1]));const drip=setInterval(()=>c.s.write(Buffer.from([0])),40);
   try{await c.closedAfterRecords();}finally{clearInterval(drip);c.close();}
   c=await Client.open(s.port);try{c.request('/hang');assert((await c.response()).headers.includes('Status: 500'));}finally{c.close();}
   c=await Client.open(s.port);try{c.s.write(Buffer.from([2,1,0,1,0,0,0,0]));await c.closedAfterRecords();}finally{c.close();}
   c=await Client.open(s.port);try{c.request('/fail');assert((await c.response()).headers.includes('Status: 500'));}finally{c.close();}
   await stop(s);for(const stage of ['Idle','Input','Handler'])assert(s.log.includes(`Deadline(${stage})`),s.log);
   assert(s.log.includes('Protocol('));assert(s.log.includes('Handler('));assert(metric(s,'timeouts')>=3);assert(metric(s,'protocol_errors')>=1);assert.equal(metric(s,'handler_errors'),1);
  });
 }
 await test('observer exceptions are isolated and wire counters remain usable',async()=>{
  const s=await server('observer'),c=await Client.open(s.port);try{c.request();assert.equal((await c.response()).body.toString(),'ok');}finally{c.close();}
  await stop(s);assert.equal(metric(s,'completed'),2);assert(metric(s,'observer_errors')>=6);assert(metric(s,'bytes_read')>0);assert(metric(s,'bytes_written')>0);assert(s.log.includes('elapsed_ms:'));assert(s.log.includes('input_content_bytes:'));
 });
 await test('capacity-one input queue enforces backpressure and input deadline',async()=>{
  const s=await server(),c=await Client.open(s.port);try{c.s.write(begin('/hang'));for(let i=0;i<20;i++)c.s.write(frame(5,Buffer.alloc(60000)));await c.closedAfterRecords();}finally{c.close();}
  await stop(s);assert(s.log.includes('Deadline(Input)'));assert(metric(s,'failed')>=1);
 });
 await test('slow output reader triggers structured Write deadline',async()=>{
  const s=await server(),c=await Client.open(s.port);try{c.s.pause();c.request('/backpressure');await sleep(550);c.s.resume();await c.closedAfterRecords();}finally{c.close();}
  await stop(s);assert(s.log.includes('Deadline(Write)'),s.log);
 });
 await test('total cycle deadline remains independent of stage deadlines',async()=>{
  const s=await server('cycle'),c=await Client.open(s.port);try{c.request('/hang');await c.closedAfterRecords();}finally{c.close();}
  await stop(s);assert(s.log.includes('Deadline(Cycle)'),s.log);
 });
 if(process.platform!=='win32'){
  const work=resolve(root,process.env.MOONFCGI_WORK_DIR||(existsSync(resolve(root,'.local/work'))?'.local/work':'../work'));mkdirSync(work,{recursive:true});
  await test('POSIX Unix listener drains before shutdown and removes its socket path',async()=>{
   const path=resolve(work,'lifecycle.sock'),s=await server('stream','unix:'+path),c=await Client.open(path);
   try{c.request('/slow');c.s.write(frame(9,Buffer.alloc(0),0));assert.equal((await c.next()).t,10);await stop(s);assert.equal((await c.response()).body.toString(),'done');assert(!existsSync(path));}finally{c.close();}
  });
  await test('POSIX inherited TCP and Unix listeners drain on explicit shutdown',async()=>{
   const path=resolve(work,'lifecycle-inherited.sock');
   for(const endpoint of [undefined,'unix:'+path]){
    const s=await server('stream',endpoint,true),c=await Client.open(s.port);
    try{c.request('/slow');c.s.write(frame(9,Buffer.alloc(0),0));assert.equal((await c.next()).t,10);await stop(s);assert.equal((await c.response()).body.toString(),'done');}finally{c.close();}
   }
   assert(existsSync(path),'inherited Unix path must remain caller-owned');unlinkSync(path);
  });
 }
 console.log(`TOTAL ${passed} lifecycle integration groups passed`);
}finally{
 for(const child of children)if(child.exitCode===null)child.kill();
 const work=resolve(root,process.env.MOONFCGI_WORK_DIR||(existsSync(resolve(root,'.local/work'))?'.local/work':'../work'));mkdirSync(work,{recursive:true});writeFileSync(resolve(work,'lifecycle-integration.log'),logs.join('\n'));
}
