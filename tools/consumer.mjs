// Consume the actual moon package archive, never the development tree.
import {readFileSync,writeFileSync,mkdirSync,mkdtempSync} from 'node:fs';
import {resolve,dirname,sep} from 'node:path';
import {tmpdir} from 'node:os';
import {inflateRawSync} from 'node:zlib';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const moon=process.platform==='win32'?'moon.exe':'moon';
function run(args,cwd){const r=spawnSync(moon,args,{cwd,stdio:'inherit',windowsHide:true});if(r.error)throw r.error;if(r.status!==0)throw Error(`moon ${args.join(' ')} failed: ${r.status}`);}
run(['package'],root);
const archive=resolve(root,'_build/publish/Ryan-1125-moonfcgi-0.1.0.zip');
const zip=readFileSync(archive);let eocd=zip.length-22;
while(eocd>=0&&zip.readUInt32LE(eocd)!==0x06054b50)eocd--;
if(eocd<0)throw Error('missing ZIP directory');
const temp=mkdtempSync(resolve(tmpdir(),'moonfcgi-consumer-'));
const library=resolve(temp,'package');mkdirSync(library);
let pos=zip.readUInt32LE(eocd+16);const count=zip.readUInt16LE(eocd+10);
for(let i=0;i<count;i++){
 if(zip.readUInt32LE(pos)!==0x02014b50)throw Error('invalid ZIP directory');
 const method=zip.readUInt16LE(pos+10),size=zip.readUInt32LE(pos+20),nl=zip.readUInt16LE(pos+28),el=zip.readUInt16LE(pos+30),cl=zip.readUInt16LE(pos+32),offset=zip.readUInt32LE(pos+42);
 const name=zip.subarray(pos+46,pos+46+nl).toString().replaceAll('\\','/');pos+=46+nl+el+cl;
 const target=resolve(library,name);if(!target.startsWith(library+sep))throw Error('unsafe ZIP path');
 if(name.endsWith('/')){mkdirSync(target,{recursive:true});continue;}
 const start=offset+30+zip.readUInt16LE(offset+26)+zip.readUInt16LE(offset+28);
 const data=zip.subarray(start,start+size);mkdirSync(dirname(target),{recursive:true});
 writeFileSync(target,method===0?data:method===8?inflateRawSync(data):(()=>{throw Error('unsupported ZIP compression');})());
}
const consumer=resolve(temp,'consumer');mkdirSync(consumer);
writeFileSync(resolve(temp,'moon.work'),'members = ["package", "consumer"]\n');
writeFileSync(resolve(consumer,'moon.mod'),'name = "validation/consumer"\nversion = "0.0.0"\npreferred_target = "native"\nimport { "Ryan-1125/moonfcgi@0.1.0" }\n');
writeFileSync(resolve(consumer,'moon.pkg'),'import { "Ryan-1125/moonfcgi" @fcgi, "Ryan-1125/moonfcgi/server" @server }\nsupported_targets = "+native"\n');
writeFileSync(resolve(consumer,'consumer.mbt'),`///|
pub fn verify() -> Unit raise {
  let decoder = @fcgi.Decoder::new()
  ignore(decoder.feed(b"\\x01\\x05\\x00"))
  let records = decoder.feed(b"\\x01\\x00\\x00\\x00\\x00")
  assert_eq(records.length(), 1)
  assert_eq(records[0].id, 1)
  decoder.finish()
  let params = @fcgi.ParamsDecoder::new()
  params.feed(b"\\x01\\x02k\\x00\\xff")
  assert_eq(params.finish(), [(b"k", b"\\x00\\xff")])
  let session = @fcgi.Session::new()
  assert_eq(session.accept({kind: 9, id: 0, content: b""}).length(), 1)
  session.finish()
  assert_eq(@fcgi.Response::new(b"ok", status=201).status, 201)
  let handler : @server.Handler = request => @fcgi.Response::new(request.body)
  ignore(handler)
  ignore(@server.Config::new())
}
`);
writeFileSync(resolve(consumer,'consumer_test.mbt'), '///|\ntest "installed archive core and server API" { @consumer.verify() }\n');
run(['check','--target','native'],consumer);
run(['build','--target','native'],consumer);
run(['test','--target','native','-p','validation/consumer'],consumer);
console.log(`PASS independent consumer of ${archive}\nIsolated workspace retained for inspection: ${temp}`);

