'use strict';
const {parentPort,workerData}=require('node:worker_threads');
const {CodexScanner,DeepSeekScanner}=require('./lib/scanner.cjs');
const {ProviderReader}=require('./lib/providers.cjs');
const {AdditionalAssistantReader}=require('./lib/assistant-telemetry.cjs');
const gpt=new CodexScanner(workerData?.codexRoot),dsh=new DeepSeekScanner(workerData?.dshRoot,workerData?.statusFile);
const providers=new ProviderReader(workerData?.providerDB);
const additional=new AdditionalAssistantReader(workerData?.additional);
let busy=false;
parentPort.on('message',async message=>{
  if (message!=='scan' || busy) return;
  busy=true;
  try {
    const now=Date.now(),gptStatus=gpt.scan(now),dshStatus=dsh.scan(now);
    // A currently configured account can differ from the active session. Never
    // place another account's balance next to an official Codex model/usage.
    const provider=(gptStatus.provider||'').toLowerCase();
    const usesExternal=provider && !['openai','default','official'].includes(provider);
    const external=usesExternal?await providers.read(now):null;
    gptStatus.external=external && usesExternal && provider===external.provider.toLowerCase() ? external:null;
    gptStatus.configuredBalance=external && usesExternal && !gptStatus.external ? external:null;
    if(usesExternal){gptStatus.remaining=null;gptStatus.quota=null;gptStatus.secondaryQuota=null;}
    parentPort.postMessage({gpt:gptStatus,dsh:dshStatus,...additional.scan(now)});
  } catch { parentPort.postMessage({error:'本机记录暂不可读，稍后自动重试'}); }
  finally { busy=false; }
});
