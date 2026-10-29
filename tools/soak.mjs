// Invoked by lifecycle-integration.mjs; uses its real TCP fixture and cleanup.
import assert from 'node:assert/strict';
import {readFileSync,readdirSync,writeFileSync,mkdirSync} from 'node:fs';
import {resolve} from 'node:path';
export async function runSoak({server,Client,frame,begin,stop,sleep,metric,root}) {
 const seconds=Number(process.env.MOONFCGI_SOAK_SECONDS);
 assert(Number.isFinite(seconds)&&seconds>=10&&seconds<=86400,'duration must be 10..86400 seconds');
 const start=Date.now(),samples=[];let cycles=0,requests=0;
 while(Date.now()-start<seconds*1000){
  const s=await server(),until=Math.min(start+seconds*1000,Date.now()+300000);
  let operations=0;const persistent=await Client.open(s.port);
  try{
   while(Date.now()<until){
    persistent.request();assert.equal((await persistent.response()).body.toString(),'ok');requests++;
    const c=await Client.open(s.port);
    try{
     switch(operations%3){
      case 0:c.s.write(begin('/hang'));c.s.write(frame(9,Buffer.alloc(0),0));assert.equal((await c.next()).t,10);c.s.write(frame(2));while((await c.next()).t!==3){}break;
      case 1:c.s.write(begin('/echo'));c.s.write(frame(5,Buffer.alloc(8192,173)));break;
      case 2:c.request('/backpressure');await c.next();break;
     }
    }finally{c.close();}
    operations++;await sleep(5);
   }
  }finally{persistent.close();}
  await sleep(100);
  let resources=null;
  if(process.platform==='linux'){
   const status=readFileSync(`/proc/${s.child.pid}/status`,'utf8');
   resources={rss_kib:Number(status.match(/VmRSS:\s+(\d+)/)?.[1]||0),fds:readdirSync(`/proc/${s.child.pid}/fd`).length};
  }
  await stop(s);assert.equal(s.child.exitCode,0);
  samples.push({cycle:++cycles,operations,resources,active_connections:metric(s,'active_connections'),active_requests:metric(s,'active_requests')});
 }
 const result={duration_ms:Date.now()-start,cycles,successful_requests:requests,platform:process.platform,samples};
 const dir=resolve(root,process.env.MOONFCGI_WORK_DIR||'.local/work');mkdirSync(dir,{recursive:true});
 writeFileSync(resolve(dir,'soak-result.json'),JSON.stringify(result,null,2));
 console.log('PASS real TCP soak '+JSON.stringify(result));
}
