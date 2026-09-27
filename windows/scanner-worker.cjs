'use strict';
const {parentPort,workerData}=require('node:worker_threads');
const {CodexScanner,DeepSeekScanner}=require('./lib/scanner.cjs');
const {ProviderReader}=require('./lib/providers.cjs');
const gpt=new CodexScanner(workerData?.codexRoot),dsh=new DeepSeekScanner(workerData?.dshRoot,workerData?.statusFile);
const providers=new ProviderReader(workerData?.providerDB);
let busy=false;
parentPort.on('message',async message=>{
  if (message!=='scan' || busy) return;
  busy=true;
  try {
    const now=Date.now(),gptStatus=gpt.scan(now),dshStatus=dsh.scan(now);
    gptStatus.external=await providers.read(now);
    parentPort.postMessage({gpt:gptStatus,dsh:dshStatus});
  } catch { parentPort.postMessage({error:'本机记录暂不可读，稍后自动重试'}); }
  finally { busy=false; }
});
