// Real registry consumer: no moon.work and no development-tree dependency.
import {mkdtempSync,writeFileSync,existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {resolve} from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import net from 'node:net';
import assert from 'node:assert/strict';
const dir=mkdtempSync(resolve(tmpdir(),'moonfcgi-registry-'));
const version='0.2.0';
const moon=process.platform==='win32'?'moon.exe':'moon';
function run(args){const p=spawnSync(moon,args,{cwd:dir,stdio:'inherit',windowsHide:true});if(p.error)throw p.error;assert.equal(p.status,0,`moon ${args.join(' ')}`);}
writeFileSync(resolve(dir,'moon.mod'),`name = "validation/registry"\nversion = "0.0.0"\npreferred_target = "native"\nimport { "Ryan-1125/moonfcgi@${version}", "moonbitlang/async@0.20.0" }\n`);
writeFileSync(resolve(dir,'moon.pkg'),'import { "Ryan-1125/moonfcgi" @fcgi, "Ryan-1125/moonfcgi/server" @server, "moonbitlang/core/env", "moonbitlang/async" }\nsupported_targets = "+native"\npkgtype(kind: "executable")\n');
writeFileSync(resolve(dir,'main.mbt'),`///|
async fn main {
  let endpoint = @env.args()[1]
  let decoder = @fcgi.Decoder::new()
  assert_eq(decoder.feed(b"\\x01\\x05\\x00\\x01\\x00\\x00\\x00\\x00").length(), 1)
  decoder.finish()
  let handler : @server.StreamHandler = (request, response) => {
    response.start(status=201, headers=[("Content-Type", "application/octet-stream"), ("Set-Cookie", "a=1"), ("Set-Cookie", "b=2")])
    while request.body.read() is Some(chunk) { response.write(chunk) }
  }
  @server.serve_stream(endpoint, handler)
}
`);
assert(!existsSync(resolve(dir,'moon.work')));
run(['update']);run(['check','--target','native','--deny-warn']);run(['build','--target','native']);
const probe=net.createServer();await new Promise(r=>probe.listen(0,'127.0.0.1',r));const port=probe.address().port;await new Promise(r=>probe.close(r));
const base=resolve(dir,'_build/native/debug/build/registry');
const child=spawn(process.platform==='win32'?base+'.exe':base,[`127.0.0.1:${port}`],{cwd:dir,windowsHide:true,stdio:['ignore','pipe','pipe']});
let log='';child.stdout.on('data',b=>log+=b);child.stderr.on('data',b=>log+=b);
let spawnError;child.on('error',e=>{spawnError=e;});
const ended=new Promise(r=>child.once('close',r));
const frame=(type,body=Buffer.alloc(0))=>{const h=Buffer.alloc(8);h[0]=1;h[1]=type;h.writeUInt16BE(1,2);h.writeUInt16BE(body.length,4);return Buffer.concat([h,body]);};
try{
 let socket;
 for(let i=0;i<150;i++){
  if(spawnError)throw spawnError;
  try{socket=await new Promise((res,rej)=>{const s=net.connect(port,'127.0.0.1');s.once('error',rej);s.once('connect',()=>{s.off('error',rej);res(s);});});break;}catch{await new Promise(r=>setTimeout(r,20));}
 }
 assert(socket,'service failed to start: '+log);
 try{
  let buffer=Buffer.alloc(0),outputs=[],completed=0;
  const done=new Promise((res,rej)=>{
   socket.setTimeout(10000,()=>rej(Error('response timeout')));socket.on('error',rej);socket.on('close',()=>{if(completed!==2)rej(Error('truncated response'));});
   socket.on('data',b=>{try{buffer=Buffer.concat([buffer,b]);while(buffer.length>=8){const n=buffer.readUInt16BE(4),size=8+n+buffer[6];if(buffer.length<size)break;assert.equal(buffer[0],1);assert.equal(buffer.readUInt16BE(2),1);const type=buffer[1],content=buffer.subarray(8,8+n);if(type===6)outputs.push(content);if(type===3){assert.deepEqual(content,Buffer.alloc(8));completed++;if(completed===2)res();else send();}buffer=buffer.subarray(size);}}catch(e){rej(e);}});
  });
  const body=Buffer.from(Array.from({length:10001},(_,i)=>i%256));
  function send(){socket.write(Buffer.concat([frame(1,Buffer.from([0,1,1,0,0,0,0,0])),frame(4),frame(5,body.subarray(0,37)),frame(5,body.subarray(37)),frame(5)]));}
  send();await done;
  const wire=Buffer.concat(outputs),header=Buffer.from('Status: 201 Created\r\nContent-Type: application/octet-stream\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\n');
  assert.deepEqual(wire,Buffer.concat([header,body,header,body]));
 }finally{socket.destroy();}
 console.log(`PASS registry ${version}: core API, streaming binary TCP, status, duplicate headers and same-connection ID reuse; ${dir}`);
}finally{child.kill();await ended;}
