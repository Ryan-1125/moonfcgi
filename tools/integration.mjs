// External byte-level driver. No MoonFCGI encoder/decoder is used here.
import net from 'node:net';
import http from 'node:http';
import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';
import {mkdirSync,writeFileSync,existsSync} from 'node:fs';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const work=resolve(root,process.env.MOONFCGI_WORK_DIR||(existsSync(resolve(root,'.local/work'))?'.local/work':'../work'));
const win=process.platform==='win32';
const nativeBase=resolve(root,'_build/native/debug/build/cmd/main/main');
const exe=process.env.MOONFCGI_BIN||(existsSync(nativeBase+'.exe')?nativeBase+'.exe':nativeBase);
const go=process.env.GO_REFERENCE_BIN||resolve(work,`go-ref${win?'.exe':''}`);
const nginx=process.env.NGINX_BIN||resolve(work,'nginx-1.28.0/nginx.exe');
const children=[]; const logs=[];
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
function start(bin,args){const p=spawn(bin,args,{windowsHide:true,cwd:root,stdio:['ignore','pipe','pipe']});children.push(p);p.on('error',e=>logs.push(String(e)));p.stdout.on('data',b=>logs.push(b.toString()));p.stderr.on('data',b=>logs.push(b.toString()));return p;}
async function ready(port){for(let i=0;i<100;i++){try{const c=await connect(port);c.destroy();return;}catch{await sleep(50);}}throw Error(`port ${port} not ready: ${logs.join('')}`);}
function connect(port){return new Promise((res,rej)=>{const s=net.connect(port,'127.0.0.1');s.once('error',rej);s.once('connect',()=>{s.off('error',rej);res(s);});});}
function rec(t,id,b=Buffer.alloc(0),pad=0){const h=Buffer.alloc(8);h[0]=1;h[1]=t;h.writeUInt16BE(id,2);h.writeUInt16BE(b.length,4);h[6]=pad;return Buffer.concat([h,b,Buffer.alloc(pad,0xa5)]);}
function begin(id=1,keep=true,role=1){const b=Buffer.alloc(8);b.writeUInt16BE(role);b[2]=+keep;return rec(1,id,b);}
function len(n){if(n<128)return Buffer.from([n]);const b=Buffer.alloc(4);b.writeUInt32BE((n+0x80000000)>>>0);return b;}
function params(p){return Buffer.concat(p.map(([k,v])=>{k=Buffer.from(k);v=Buffer.from(v);return Buffer.concat([len(k.length),len(v.length),k,v]);}));}
function request(path,body=Buffer.alloc(0),id=1,keep=true,extra=[]){const p=params([['REQUEST_METHOD',body.length?'POST':'GET'],['DOCUMENT_URI',path],['PATH_INFO',path],['REQUEST_URI',path+'?a=1'],['SERVER_PROTOCOL','HTTP/1.1'],['QUERY_STRING','a=1'],['CONTENT_LENGTH',String(body.length)],...extra]);const frames=[begin(id,keep)];for(let i=0;i<p.length;i+=3)frames.push(rec(4,id,p.subarray(i,i+3),i%5));frames.push(rec(4,id));for(let i=0;i<body.length;i+=60000)frames.push(rec(5,id,body.subarray(i,i+60000)));frames.push(rec(5,id));return Buffer.concat(frames);}
class Client{
 constructor(s){this.s=s;this.buf=Buffer.alloc(0);this.queue=[];this.waiters=[];this.closed=false;s.on('data',b=>{this.buf=Buffer.concat([this.buf,b]);while(this.buf.length>=8){const n=this.buf.readUInt16BE(4),size=8+n+this.buf[6];if(this.buf.length<size)break;const r={t:this.buf[1],id:this.buf.readUInt16BE(2),b:Buffer.from(this.buf.subarray(8,8+n))};this.buf=this.buf.subarray(size);const w=this.waiters.shift();if(w)w(r);else this.queue.push(r);}});s.on('error',()=>{});s.on('close',()=>{this.closed=true;for(const w of this.waiters.splice(0))w(null);});}
 static async open(port){return new Client(await connect(port));}
 next(){if(this.queue.length)return Promise.resolve(this.queue.shift());if(this.closed)return Promise.resolve(null);return new Promise((res,rej)=>{const timer=setTimeout(()=>rej(Error('record timeout')),5000);this.waiters.push(r=>{clearTimeout(timer);res(r);});});}
 async response(id=1){let stdout=[],stderr=[],records=[];while(true){const r=await this.next();assert(r,'unexpected EOF');records.push(r);assert.equal(r.id,id);if(r.t===6)stdout.push(r.b);if(r.t===7)stderr.push(r.b);if(r.t===3){assert.equal(r.b.length,8);assert.equal(r.b[4],0);break;}}const bytes=Buffer.concat(stdout);const split=bytes.indexOf('\r\n\r\n');assert(split>=0);const headers=bytes.subarray(0,split).toString();return{body:bytes.subarray(split+4),headers,status:Number(headers.match(/^Status: (\d+)/m)?.[1]||200),records};}
 close(){this.s.destroy();}
}
let passed=0;async function test(name,f){await f();passed++;console.log(`PASS ${name}`);}
function httpRequest(path,body=Buffer.alloc(0)){return new Promise((res,rej)=>{const q=http.request({host:'127.0.0.1',port:18080,path,method:body.length?'POST':'GET',headers:{'Content-Length':body.length}},r=>{const chunks=[];r.on('data',b=>chunks.push(b));r.on('end',()=>res({status:r.statusCode,headers:r.headers,body:Buffer.concat(chunks)}));});q.on('error',rej);q.end(body);});}
let proxy;let nginxStarted=false;const prefix=resolve(work,'nginx-test').replaceAll('\\','/')+'/';
try{
 start(exe,['127.0.0.1:19000','test']); await ready(19000);
 const binary=Buffer.alloc(180001);for(let i=0;i<binary.length;i++)binary[i]=i%256;
 await test('TCP fragmented PARAMS, padding, binary body and same-ID sequential reuse',async()=>{const c=await Client.open(19000);try{c.s.write(request('/api/echo',binary));assert.deepEqual((await c.response()).body,binary);c.s.write(request('/missing'));assert.equal((await c.response()).status,404);c.s.write(request('/api/cookies',Buffer.alloc(0),1,false));assert.equal((await c.response()).headers.match(/Set-Cookie:/g).length,2);await sleep(50);assert(c.closed);}finally{c.close();}});
 await test('management capabilities, unknown management type and unsupported role',async()=>{const c=await Client.open(19000);try{c.s.write(rec(9,0,params([['FCGI_MPXS_CONNS',''],['FCGI_MAX_REQS',''],['UNKNOWN','']])));const v=await c.next();assert.equal(v.t,10);assert(v.b.includes(Buffer.from('FCGI_MPXS_CONNS0')));assert(!v.b.includes(Buffer.from('UNKNOWN')));c.s.write(rec(99,0));assert.deepEqual((await c.next()).b,Buffer.from([99,0,0,0,0,0,0,0]));c.s.write(begin(3,true,2));assert.equal((await c.next()).b[4],3);}finally{c.close();}});
 await test('multiplex rejection, ABORT cancellation and unpolluted ID reuse',async()=>{const c=await Client.open(19000);try{c.s.write(request('/api/slow'));c.s.write(begin(2));let r=await c.next();assert.equal(r.id,2);assert.equal(r.b[4],1);c.s.write(rec(2,1));r=await c.next();assert.equal(r.t,3);c.s.write(request('/api/echo',Buffer.from([0,255,1])));assert.deepEqual((await c.response()).body,Buffer.from([0,255,1]));await sleep(650);c.s.write(request('/api/hello'));assert.equal((await c.response()).status,200);}finally{c.close();}});
 await test('handler error/timeout, concurrent connections and isolation',async()=>{const a=await Client.open(19000),b=await Client.open(19000);try{a.s.write(request('/api/slow'));b.s.write(request('/api/echo',Buffer.from('independent')));assert.equal((await b.response()).body.toString(),'independent');assert.equal((await a.response()).status,500);b.s.write(request('/api/error'));assert.equal((await b.response()).status,500);}finally{a.close();b.close();}});
 await test('malformed version, EOF truncation, request limit and idle timeout close sockets',async()=>{for(const bytes of [Buffer.from([2,1,0,1,0,0,0,0]),Buffer.concat([begin(),rec(4,1),rec(5,1,Buffer.alloc(65535))])]){const c=await Client.open(19000);c.s.write(bytes);if(bytes[0]===1){for(let i=0;i<16;i++)c.s.write(rec(5,1,Buffer.alloc(65535)));}await sleep(150);assert(c.closed);c.close();}const c=await Client.open(19000);c.s.end(Buffer.from([1,1,0]));await sleep(100);assert(c.closed);const idle=await Client.open(19000);await sleep(1700);assert(idle.closed);idle.close();});
 await test('real TCP backpressure triggers write deadline and frees connection',async()=>{const s=await connect(19000);s.on('error',()=>{});s.pause();s.write(request('/api/huge'));await sleep(1000);const c=new Client(s);s.resume();let ended=false;while(true){const r=await c.next();if(!r)break;if(r.t===3)ended=true;}assert.equal(ended,false,'response must be interrupted by write timeout');c.close();const next=await Client.open(19000);try{next.s.write(request('/api/hello'));assert.equal((await next.response()).status,200);}finally{next.close();}});
 await test('connection capacity queues excess work and releases timed-out slots',async()=>{const idle=[];let c;try{for(let i=0;i<8;i++)idle.push(await Client.open(19000));c=await Client.open(19000);let early=false;c.s.on('data',()=>{early=true;});c.s.write(request('/api/hello'));await sleep(200);assert.equal(early,false);assert.equal((await c.response()).status,200);}finally{for(const x of idle)x.close();c?.close();}});
 await test('wire STDOUT/STDERR termination, HEAD, and oversized-response recovery',async()=>{
  const c=await Client.open(19000);
  try {
   c.s.write(request('/api/stderr'));
   let r=await c.response();
   assert.deepEqual(Buffer.concat(r.records.filter(x=>x.t===7).map(x=>x.b)),Buffer.from([0,255,...Buffer.from('diagnostic')]));
   assert.equal(r.body.toString(),'ok');
   for(const type of [6,7]) { const stream=r.records.filter(x=>x.t===type);assert.equal(stream.at(-1).b.length,0);assert.equal(stream.filter(x=>x.b.length===0).length,1); }
   assert.equal(r.records.filter(x=>x.t===3).length,1);
   c.s.write(request('/api/echo',Buffer.from([0,255,1]),1,true,[['REQUEST_METHOD','HEAD']]));
   r=await c.response();assert.equal(r.body.length,0);assert.match(r.headers,/Content-Length: 3/);
   c.s.write(request('/api/oversized'));r=await c.response();assert.equal(r.status,500);assert.equal(r.body.length,0);
   c.s.write(request('/api/echo',Buffer.from('after output failure')));assert.equal((await c.response()).body.toString(),'after output failure');
   for(const [path,status] of [['/api/no-content',204],['/api/not-modified',304]]){c.s.write(request(path));r=await c.response();assert.equal(r.status,status);assert.equal(r.body.length,0);assert(!/Content-Length:/i.test(r.headers));}
  } finally { c.close(); }
 });
 if(process.env.SKIP_GO!=='1'){
  start(go,['127.0.0.1:19001']);await ready(19001);
  await test('Go 1.23.2 net/http/fcgi common-scenario differential interoperability',async()=>{for(const [path,body] of [['/api/echo',binary],['/api/hello',Buffer.alloc(0)],['/api/cookies',Buffer.alloc(0)],['/api/large',Buffer.alloc(0)],['/missing',Buffer.alloc(0)]]){const results=[];for(const port of [19000,19001]){const c=await Client.open(port);try{c.s.write(request(path,body));results.push(await c.response());}finally{c.close();}}assert.equal(results[0].status,results[1].status);if(path==='/api/hello')assert.deepEqual(JSON.parse(results[0].body),JSON.parse(results[1].body));else assert.deepEqual(results[0].body,results[1].body);}});
 }
 if(process.env.SKIP_NGINX!=='1'){
  // A transparent TCP relay counts actual backend connections; it never synthesizes replies.
  let accepted=0;const sockets=new Set();proxy=net.createServer(s=>{accepted++;sockets.add(s);const upstream=net.connect(19000,'127.0.0.1');s.pipe(upstream).pipe(s);s.on('error',()=>upstream.destroy());upstream.on('error',()=>s.destroy());s.on('close',()=>{sockets.delete(s);upstream.destroy();});});await new Promise(r=>proxy.listen(19002,'127.0.0.1',r));proxy.cleanup=()=>{for(const s of sockets)s.destroy();proxy.close();};
  mkdirSync(prefix+'logs',{recursive:true});mkdirSync(prefix+'temp',{recursive:true});
  const conf=`worker_processes 1;\nerror_log logs/error.log info;\npid logs/nginx.pid;\nevents { worker_connections 64; }\nhttp { access_log logs/access.log; client_body_temp_path temp; fastcgi_temp_path temp; upstream moon { server 127.0.0.1:19002; keepalive 4; } server { listen 127.0.0.1:18080; client_max_body_size 2m; location / { fastcgi_pass moon; fastcgi_keep_conn on; fastcgi_param REQUEST_METHOD $request_method; fastcgi_param DOCUMENT_URI $document_uri; fastcgi_param QUERY_STRING $query_string; fastcgi_param CONTENT_LENGTH $content_length; fastcgi_param SERVER_PROTOCOL $server_protocol; fastcgi_param REQUEST_URI $request_uri; } } }\n`;
  writeFileSync(prefix+'nginx.conf',conf);const check=spawnSync(nginx,['-p',prefix,'-c','nginx.conf','-t'],{windowsHide:true,encoding:'utf8'});assert.equal(check.status,0,check.stderr);start(nginx,['-p',prefix,'-c','nginx.conf']);nginxStarted=true;await ready(18080);
  await test('real Nginx GET JSON and upstream persistent connection reuse',async()=>{const before=accepted;for(let i=0;i<2;i++){const r=await httpRequest('/api/hello?a=1');assert.equal(r.status,200);assert.deepEqual(JSON.parse(r.body),{message:'hello',query:'a=1'});}assert.equal(accepted-before,1);console.log('  two HTTP requests used exactly one real FastCGI TCP connection');});
  await test('real Nginx binary POST, duplicate headers, 404 and handler 500',async()=>{assert.deepEqual((await httpRequest('/api/echo',binary)).body,binary);assert.deepEqual((await httpRequest('/api/cookies')).headers['set-cookie'],['a=1','b=2']);assert.equal((await httpRequest('/missing')).status,404);assert.equal((await httpRequest('/api/error')).status,500);});
  await test('real Nginx suppresses 204/304 bodies and keeps connection after response limit failure',async()=>{for(const [path,status] of [['/api/no-content',204],['/api/not-modified',304],['/api/oversized',500]]){const r=await httpRequest(path);assert.equal(r.status,status);assert.equal(r.body.length,0);}assert.equal((await httpRequest('/api/hello')).status,200);});
 }
 console.log(`TOTAL ${passed} integration groups passed`);
}finally{
 if(nginxStarted)spawnSync(nginx,['-p',prefix,'-c','nginx.conf','-s','quit'],{windowsHide:true});
 if(proxy)proxy.cleanup();
 for(const p of children)if(p.pid)p.kill();
 writeFileSync(resolve(work,'integration-process.log'),logs.join(''));
}

