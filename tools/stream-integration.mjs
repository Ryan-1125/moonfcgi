// Independent wire driver: never imports a MoonFCGI encoder/decoder.
import net from 'node:net';
import http from 'node:http';
import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';
import {existsSync, mkdirSync, writeFileSync, statSync} from 'node:fs';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const win=process.platform==='win32', base=resolve(root,'_build/native/debug/build/cmd/stream/stream');
const exe=process.env.MOONFCGI_STREAM_BIN||(existsSync(base+'.exe')?base+'.exe':base);
const work=resolve(root,process.env.MOONFCGI_WORK_DIR||'.local/work');mkdirSync(work,{recursive:true});
const children=[], log=[];let passed=0;
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
function start(bin,args){const p=spawn(bin,args,{cwd:root,windowsHide:true,stdio:['ignore','pipe','pipe']});children.push(p);p.on('error',e=>log.push(String(e)));for(const s of [p.stdout,p.stderr])s.on('data',b=>log.push(b.toString()));return p;}
function frame(t,id=1,b=Buffer.alloc(0)){const h=Buffer.alloc(8);h[0]=1;h[1]=t;h.writeUInt16BE(id,2);h.writeUInt16BE(b.length,4);return Buffer.concat([h,b]);}
function params(pairs){return Buffer.concat(pairs.map(([k,v])=>{k=Buffer.from(k);v=Buffer.from(v);assert(k.length<128&&v.length<128);return Buffer.concat([Buffer.from([k.length,v.length]),k,v]);}));}
function begin(role=1,id=1,pairs=[]){const b=Buffer.from([0,role,1,0,0,0,0,0]);const p=params(pairs);return Buffer.concat([frame(1,id,b),...(p.length?[frame(4,id,p)]:[]),frame(4,id)]);}
class Client{
 constructor(socket){this.socket=socket;this.buf=Buffer.alloc(0);this.queue=[];this.waiters=[];this.closed=false;socket.on('error',()=>{});socket.on('data',bytes=>{this.buf=Buffer.concat([this.buf,bytes]);while(this.buf.length>=8){const n=this.buf.readUInt16BE(4),size=8+n+this.buf[6];if(this.buf.length<size)break;const r={t:this.buf[1],id:this.buf.readUInt16BE(2),b:Buffer.from(this.buf.subarray(8,8+n))};this.buf=this.buf.subarray(size);const w=this.waiters.shift();if(w)w(r);else this.queue.push(r);}});socket.on('close',()=>{this.closed=true;for(const w of this.waiters.splice(0))w(null);});}
 static open(endpoint){return new Promise((res,rej)=>{const s=net.connect(typeof endpoint==='string'?endpoint:{host:'127.0.0.1',port:endpoint});s.once('error',rej);s.once('connect',()=>{s.off('error',rej);res(new Client(s));});});}
 next(){if(this.queue.length)return Promise.resolve(this.queue.shift());if(this.closed)return Promise.resolve(null);return new Promise((res,rej)=>{const timer=setTimeout(()=>rej(Error('wire timeout')),5000);this.waiters.push(r=>{clearTimeout(timer);res(r);});});}
 async response(){const records=[];while(true){const r=await this.next();assert(r,'unexpected EOF');records.push(r);if(r.t===3)break;}const stdout=Buffer.concat(records.filter(r=>r.t===6).map(r=>r.b));const pos=stdout.indexOf('\r\n\r\n');assert(pos>=0);return{records,headers:stdout.subarray(0,pos).toString(),body:stdout.subarray(pos+4)};}
 close(){this.socket.destroy();}
}
async function ready(endpoint){for(let i=0;i<100;i++){try{const c=await Client.open(endpoint);c.close();return;}catch{await sleep(50);}}throw Error('listener unavailable: '+log.join(''));}
async function test(name,f){await f();passed++;console.log('PASS '+name);}
async function exchange(endpoint,role,pairs=[],stdin=Buffer.alloc(0),data=null){const c=await Client.open(endpoint);try{c.socket.write(begin(role,1,pairs));if(role!==2){for(let i=0;i<stdin.length;i+=60000)c.socket.write(frame(5,1,stdin.subarray(i,i+60000)));c.socket.write(frame(5));}if(data!==null){for(let i=0;i<data.length;i+=60000)c.socket.write(frame(8,1,data.subarray(i,i+60000)));c.socket.write(frame(8));}return await c.response();}finally{c.close();}}
let nginxProcess;let nginxPrefix;let upstream='127.0.0.1:19100';
try{
 start(exe,['127.0.0.1:19100','test']);await ready(19100);
 await test('response headers and echoed bytes arrive before STDIN terminator',async()=>{
  const c=await Client.open(19100);try{c.socket.write(begin());let r=await c.next();assert.equal(r.t,6);assert(r.b.includes(Buffer.from('\r\n\r\n')));assert(!r.b.includes(Buffer.from('Content-Length:')));
   c.socket.write(frame(5,1,Buffer.from([0,255,1])));r=await c.next();assert.equal(r.t,6);assert.deepEqual(r.b,Buffer.from([0,255,1]));c.socket.write(frame(5));const end=[];while((r=await c.next())&&r.t!==3)end.push(r);assert(r);assert(end.some(r=>r.t===6&&r.b.length===0));assert(end.some(r=>r.t===7&&r.b.length===0));
  }finally{c.close();}
 });
 await test('9 MiB binary upload streams beyond the buffered default and reuses connection',async()=>{
  const body=Buffer.alloc(9*1024*1024);for(let i=0;i<body.length;i++)body[i]=i%256;
  const r=await exchange(19100,1,[['CONTENT_LENGTH',String(body.length)]],body);assert.deepEqual(r.body,body);
 });
 await test('stream ABORT cancels handler and same-ID reuse is isolated',async()=>{
  const c=await Client.open(19100);try{c.socket.write(begin());assert.equal((await c.next()).t,6);c.socket.write(frame(2));assert.equal((await c.next()).t,3);c.socket.write(Buffer.concat([begin(),frame(5,1,Buffer.from('next')),frame(5)]));assert.equal((await c.response()).body.toString(),'next');}finally{c.close();}
 });
 await test('early response drains remaining input before sequential request reuse',async()=>{
  const c=await Client.open(19100);try{c.socket.write(begin(1,1,[['DOCUMENT_URI','/early']]));assert.equal((await c.response()).body.toString(),'accepted');c.socket.write(Buffer.concat([frame(5,1,Buffer.from('discard')),frame(5),begin(),frame(5,1,Buffer.from('after')),frame(5)]));assert.equal((await c.response()).body.toString(),'after');}finally{c.close();}
 });
 await test('Authorizer allows with Variable header or denies without STDIN',async()=>{
  let r=await exchange(19100,2,[['HTTP_AUTHORIZATION','Bearer demo-token']]);assert(r.headers.includes('Status: 200'));assert(r.headers.includes('Variable-REMOTE_USER: demo'));
  r=await exchange(19100,2);assert(r.headers.includes('Status: 403'));assert.equal(r.body.toString(),'Forbidden');
 });
 await test('Filter consumes STDIN then separately streams binary DATA',async()=>{
  const bytes=Buffer.from([0,255,17,3]);const r=await exchange(19100,3,[['CONTENT_LENGTH','5'],['FCGI_DATA_LENGTH','4']],Buffer.from('input'),bytes);assert.deepEqual(r.body,bytes);
 });
 await test('handler failures before and after header commit have defined completion status',async()=>{
  let r=await exchange(19100,1,[['DOCUMENT_URI','/failure']]);assert(r.headers.includes('Status: 500'));assert.equal(r.records.at(-1).b.readUInt32BE(0),1);
  r=await exchange(19100,1,[['DOCUMENT_URI','/partial-failure']]);assert.equal(r.body.toString(),'partial');assert.equal(r.records.at(-1).b.readUInt32BE(0),1);
 });
 await test('stream rejects invalid CONTENT_LENGTH and Filter DATA ordering',async()=>{
  for(const wire of [begin(1,1,[['CONTENT_LENGTH','x']]),Buffer.concat([begin(3),frame(8,1,Buffer.from('bad'))])]){
   const c=await Client.open(19100);try{c.socket.write(wire);while(await c.next()){}assert(c.closed);}finally{c.close();}
  }
 });
 await test('slow consumer cycle timeout releases input backpressure',async()=>{
  const c=await Client.open(19100);try{c.socket.write(begin(1,1,[['DOCUMENT_URI','/slow']]));for(let i=0;i<20;i++)c.socket.write(frame(5,1,Buffer.alloc(60000)));while(await c.next()){}assert(c.closed);}finally{c.close();}
 });
 if(!win){
  const path=resolve(work,'stream.sock');start(exe,['unix:'+path,'test']);await ready(path);
  upstream='unix:'+path;
  await test('real Unix socket binary exchange and restrictive permissions',async()=>{assert.equal(statSync(path).mode&0o777,0o600);assert.deepEqual((await exchange(path,1,[],Buffer.from([0,255]))).body,Buffer.from([0,255]));});
  start(process.env.PYTHON_BIN||'python3',[resolve(root,'tools/inherited-launch.py'),exe,'19101']);await ready(19101);
  await test('real fd0 inherited TCP listener',async()=>{assert.equal((await exchange(19101,1,[],Buffer.from('fd0'))).body.toString(),'fd0');});
  const reference=process.env.LIBFCGI_REFERENCE_BIN;
  if(!reference)throw Error('Linux suite requires LIBFCGI_REFERENCE_BIN for real libfcgi comparison');
  start(reference,[':19102']);await ready(19102);
  await test('libfcgi common-scenario differential Responder/Authorizer/Filter',async()=>{
   const body=Buffer.from([0,255,1,2,9]);
   for(const [role,pairs,stdin,data] of [
    [1,[['CONTENT_LENGTH','5']],body,null],
    [2,[['HTTP_AUTHORIZATION','Bearer demo-token']],Buffer.alloc(0),null],
    [2,[],Buffer.alloc(0),null],
    [3,[['CONTENT_LENGTH','5'],['FCGI_DATA_LENGTH','5']],body,body]
   ]){
    const actual=await exchange(19100,role,pairs,stdin,data), expected=await exchange(19102,role,pairs,stdin,data);
    assert.deepEqual(actual.body,expected.body);assert.equal(actual.headers.match(/Status: (\d+)/)[1],expected.headers.match(/Status: (\d+)/)[1]);
    if(role===2&&expected.headers.includes('Variable-REMOTE_USER'))assert(actual.headers.includes('Variable-REMOTE_USER: demo'));
   }
  });
 } else { console.log('POSIX transport tests require Linux; Windows TCP tests remain real.'); }
 const nginx=process.env.NGINX_BIN;
 if(nginx){
  const prefix=resolve(work,'stream-nginx').replaceAll('\\','/')+'/';mkdirSync(prefix+'logs',{recursive:true});mkdirSync(prefix+'temp',{recursive:true});
  nginxPrefix=prefix;
  writeFileSync(prefix+'nginx.conf',`pid logs/nginx.pid; error_log logs/error.log; events {worker_connections 128;} http {access_log logs/access.log; client_max_body_size 64m; client_body_temp_path temp; fastcgi_temp_path temp; upstream moon {server ${upstream}; keepalive 4;} server {listen 127.0.0.1:18100; location / {fastcgi_pass moon; fastcgi_keep_conn on; fastcgi_request_buffering off; fastcgi_buffering off; fastcgi_param REQUEST_METHOD $request_method; fastcgi_param CONTENT_LENGTH $content_length; fastcgi_param DOCUMENT_URI $uri;}}}`);
  nginxProcess=start(nginx,['-p',prefix,'-c','nginx.conf']);await ready(18100);
  await test('real Nginx unbuffered binary POST and streaming download',async()=>{
   const request=(path,body=Buffer.alloc(0))=>new Promise((res,rej)=>{const q=http.request({host:'127.0.0.1',port:18100,path,method:body.length?'POST':'GET',headers:{'Content-Length':body.length}},r=>{const chunks=[];r.on('data',b=>chunks.push(b));r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(chunks)}));r.on('error',rej);});q.on('error',rej);q.end(body);});
   const body=Buffer.alloc(100000,0xff);assert.deepEqual((await request('/echo',body)).body,body);const r=await request('/download');assert.equal(r.status,200);assert.equal(r.body.length,4194304);
  });
  await test('real Nginx returns first echoed chunk while HTTP upload is still open',async()=>{
   await new Promise((res,rej)=>{
    const timer=setTimeout(()=>{q.destroy();rej(Error('Nginx buffered the upload or response'));},1800);
    let received=0,sentRest=false;
    const q=http.request({host:'127.0.0.1',port:18100,path:'/echo',method:'POST',headers:{'Content-Length':16384}},r=>{
     r.on('error',rej);r.on('data',b=>{received+=b.length;if(!sentRest){sentRest=true;q.end(Buffer.alloc(8192,0x62));}});
     r.on('end',()=>{clearTimeout(timer);try{assert(sentRest);assert.equal(received,16384);res();}catch(e){rej(e);}});
    });q.on('error',e=>{clearTimeout(timer);rej(e);});q.write(Buffer.alloc(8192,0x61));
   });
  });
 } else {throw Error('NGINX_BIN must point to real nginx for this suite');}
 console.log(`TOTAL ${passed} streaming integration groups passed`);
}finally{
 if(nginxProcess&&nginxPrefix)spawnSync(process.env.NGINX_BIN,['-p',nginxPrefix,'-c','nginx.conf','-s','quit'],{cwd:root,windowsHide:true,stdio:'ignore'});
 await sleep(200);
 for(const child of children.reverse())child.kill();
 await sleep(150);
 if(log.length)writeFileSync(resolve(work,'stream-integration.log'),log.join(''));
}
