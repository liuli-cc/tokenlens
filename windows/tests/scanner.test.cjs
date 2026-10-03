'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {CodexScanner,DeepSeekScanner,CompletionGate,digestDeepSeek,readDeepSeekStatus,decodeZstd,dataDirectory,recentCompletionEvents}=require('../lib/scanner.cjs');
const {installIntegration}=require('../lib/integration.cjs');
const {assistantForPath}=require('../lib/native.cjs');

function fixture(t){const root=fs.mkdtempSync(path.join(os.tmpdir(),'tokenlens-test-'));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));return root;}
const event=(type,payload,time=Date.now())=>JSON.stringify({timestamp:new Date(time).toISOString(),type,payload});
function tokens(total,used=74){return {type:'token_count',info:{total_token_usage:{input_tokens:total*.8,cached_input_tokens:total*.4,output_tokens:total*.2,total_tokens:total},last_token_usage:{input_tokens:80,cached_input_tokens:40,output_tokens:20,total_tokens:100},model_context_window:400000},rate_limits:{primary:{used_percent:used,window_minutes:10080,resets_at:2000000000}}};}
function rawZstd(text) {
  const data=Buffer.from(text),header=Buffer.alloc(12);
  header.set([0x28,0xb5,0x2f,0xfd,0xa0]);header.writeUInt32LE(data.length,5);
  header.writeUIntLE((data.length<<3)|1,9,3);
  return Buffer.concat([header,data]);
}

test('incremental Codex logs retain partial UTF-8 lines, sum deltas once and update actual models',t=>{
  const root=fixture(t),file=path.join(root,'rollout.jsonl'),now=Date.now();
  fs.writeFileSync(file,[event('session_meta',{id:'root',thread_source:'user',source:'vscode'},now-3000),event('turn_context',{model:'gpt-6-luna'},now-2000),event('event_msg',tokens(100),now-1000)].join('\n')+'\n');
  const scanner=new CodexScanner(root),first=scanner.scan(now);
  assert.equal(first.model,'gpt-6-luna');assert.equal(first.remaining,26);assert.equal(first.todayTokens,100);assert.equal(first.cachePercent,50);
  const update=Buffer.from(event('event_msg',tokens(250,78),now)+'\n');
  fs.appendFileSync(file,update.subarray(0,update.length-3));
  assert.equal(scanner.scan(now).todayTokens,100,'Incomplete records must wait for a newline');
  fs.appendFileSync(file,update.subarray(update.length-3));
  assert.equal(scanner.scan(now).todayTokens,250);assert.equal(scanner.scan(now).todayTokens,250,'Re-reading unchanged logs must not add tokens');
  assert.equal(scanner.scan(now).remaining,22);
  fs.writeFileSync(file,event('turn_context',{model:'未知的新模型'},now)+'\n');
  const replaced=scanner.scan(now);assert.equal(replaced.model,'未知的新模型');assert.equal(replaced.todayTokens,0);
});
test('only root completions produce notices; cancellation and stale tasks do not',t=>{
  const root=fixture(t),file=path.join(root,'root.jsonl'),now=Date.now();
  fs.writeFileSync(file,[event('session_meta',{id:'root',thread_source:'user'},now-1000),event('turn_context',{model:'gpt-6-astra'},now-900),event('event_msg',{type:'task_started',turn_id:'a'},now-800)].join('\n')+'\n');
  const scanner=new CodexScanner(root);assert.equal(scanner.scan(now).running,true);assert.equal(scanner.scan(now+900000).running,false);
  fs.appendFileSync(file,event('event_msg',{type:'turn_aborted',turn_id:'a'},now)+'\n');
  assert.equal(scanner.scan(now).running,false);assert.equal(scanner.scan(now).completion,null);
  fs.writeFileSync(path.join(root,'child.jsonl'),[event('session_meta',{id:'child',source:{subagent:{}}},now),event('turn_context',{model:'must-not-replace'},now+500),event('event_msg',{type:'task_complete',turn_id:'child'},now+600)].join('\n')+'\n');
  assert.equal(scanner.scan(now+600).model,'gpt-6-astra');assert.equal(scanner.scan(now+600).completion,null);
  fs.appendFileSync(file,event('event_msg',{type:'task_complete',turn_id:'b'},now+700)+'\n');
  assert.equal(scanner.scan(now+700).completion.id,'root|b');
});
test('completion feedback is primed, de-duplicated and expires instead of replaying history',()=>{
  const gate=new CompletionGate(),now=Date.now(),old={id:'old',at:now-1000};
  assert.equal(gate.accept('gpt',old,now),false);assert.equal(gate.accept('gpt',old,now),false);
  assert.equal(gate.accept('gpt',{id:'new',at:now},now),true);assert.equal(gate.accept('gpt',{id:'new',at:now},now),false);
  assert.equal(gate.accept('gpt',{id:'expired',at:now-91000},now),false);
  assert.equal(gate.accept('dsh',null,now),false);assert.equal(gate.accept('dsh',{id:'dsh',at:now},now),true);
});
test('Codex retains every root completion between polls, de-duplicates repeats and keeps legacy latest',t=>{
  const root=fixture(t),file=path.join(root,'root.jsonl'),now=Date.now();
  const rows=[event('session_meta',{id:'root',thread_source:'user'},now-4000),event('turn_context',{model:'gpt-current'},now-3500)];
  fs.writeFileSync(file,rows.join('\n')+'\n');const scanner=new CodexScanner(root);
  assert.deepEqual(scanner.scan(now).completionEvents,[]);
  fs.appendFileSync(file,[
    event('event_msg',{type:'task_complete',turn_id:'a'},now-2000),
    event('event_msg',{type:'task_complete',turn_id:'b'},now-1000),
    event('event_msg',{type:'task_complete',turn_id:'a'},now),
    event('event_msg',{type:'task_started',turn_id:'cancelled'},now),
    event('event_msg',{type:'turn_aborted',turn_id:'cancelled'},now),
    event('event_msg',{type:'error',turn_id:'error'},now)
  ].join('\n')+'\n');
  fs.writeFileSync(path.join(root,'child.jsonl'),[
    event('session_meta',{id:'child',source:{subagent:{}}},now-500),...rows,
    event('event_msg',{type:'task_complete',turn_id:'child'},now)
  ].join('\n')+'\n');
  const result=scanner.scan(now);
  assert.deepEqual(result.completionEvents.map(x=>x.id),['root|a','root|b']);
  assert.equal(result.completionEvents[0].at,now-2000,'Duplicate events must not make old completion look newer');
  assert.equal(result.completionEvents[0].model,'gpt-current');assert.equal(result.completion.id,'root|b');
  assert.deepEqual(scanner.scan(now).completionEvents,result.completionEvents,'Unchanged scans preserve the batch for the queue to deduplicate');
  assert.deepEqual(scanner.scan(now+90001).completionEvents,[]);assert.equal(scanner.scan(now+90001).completion.id,'root|b');
});
test('completion batches bound time and memory while merging duplicate session files',t=>{
  const now=Date.now();
  assert.deepEqual(recentCompletionEvents([
    {id:'expired',at:now-90001},{id:'boundary',at:now-90000},
    {id:'current',at:now},{id:'current',at:now+1},
    {id:'future',at:now+5000},{id:'too-future',at:now+5001},
    {id:'invalid',at:NaN},{id:'invalid-text',at:String(now)},{id:'',at:now}
  ],now).map(x=>x.id),['boundary','current','future']);
  const root=fixture(t),file=path.join(root,'a.jsonl');
  const rows=[event('session_meta',{id:'root',thread_source:'user'},now-1000)];
  for(let i=0;i<140;i++)rows.push(event('event_msg',{type:'task_complete',turn_id:String(i)},now-1000+i));
  fs.writeFileSync(file,rows.join('\n')+'\n');fs.copyFileSync(file,path.join(root,'copy.jsonl'));
  const scanner=new CodexScanner(root),result=scanner.scan(now);
  assert.equal(result.completionEvents.length,128);assert.equal(result.completionEvents[0].id,'root|12');
  assert.equal(result.completionEvents.at(-1).id,'root|139');
  assert.equal(scanner.cache.values().next().value.digest.completionEvents.length,128);
});
test('DSH scanner returns completed root turn batches without duplicates, errors or delegated work',t=>{
  const root=fixture(t),now=Date.now(),sessionDir=path.join(root,'one');fs.mkdirSync(sessionDir);
  const file=path.join(sessionDir,'session.v4.jsonl.zstd');
  const rows=[{type:'session',version:4,delegationDepth:0,id:'one'},
    {type:'turn/start',time:now-4000,data:{turn:1}},
    {type:'turn/end',time:now-3500,data:{turn:1,reason:{kind:'completed'}}},
    {type:'turn/start',time:now-3000,data:{turn:2}},
    {type:'turn/end',time:now-2500,data:{turn:2,reason:{kind:'completed'}}},
    {type:'turn/end',time:now-2000,data:{turn:1,reason:{kind:'completed'}}},
    {type:'turn/end',time:now-1500,data:{turn:3,reason:{kind:'error'}}},
    {type:'turn/end',time:now-1000,data:{turn:4,reason:{kind:'cancelled'}}}];
  fs.writeFileSync(file,rawZstd(rows.map(x=>JSON.stringify(x)).join('\n')));
  const childDir=path.join(root,'child');fs.mkdirSync(childDir);
  fs.writeFileSync(path.join(childDir,'session.v4.jsonl.zstd'),rawZstd([
    {type:'session',version:4,delegationDepth:1,id:'child'},
    {type:'turn/end',time:now,data:{turn:1,reason:{kind:'completed'}}}
  ].map(x=>JSON.stringify(x)).join('\n')));
  const scanner=new DeepSeekScanner(root,path.join(root,'missing-status.json')),result=scanner.scan(now);
  assert.deepEqual(result.completionEvents.map(x=>x.id),['dsh|one|1','dsh|one|2']);
  assert.equal(result.completionEvents[0].at,now-3500);assert.equal(result.completion.id,'dsh|one|2');
  assert.deepEqual(scanner.scan(now+90001).completionEvents,[]);
  const later={type:'turn/end',time:now+1000,data:{turn:5,reason:{kind:'completed'}}};
  fs.writeFileSync(file,rawZstd([...rows,later].map(x=>JSON.stringify(x)).join('\n')));
  assert.deepEqual(scanner.scan(now+1000).completionEvents.map(x=>x.id),['dsh|one|1','dsh|one|2','dsh|one|5']);
});
test('missing quota and invalid balances stay unavailable',t=>{
  const root=fixture(t),file=path.join(root,'empty.jsonl');
  const payload=tokens(10);payload.rate_limits.primary.used_percent=null;
  fs.writeFileSync(file,event('event_msg',payload)+'\n');assert.equal(new CodexScanner(root).scan().remaining,null);
  const {walletLabel}=require('../lib/scanner.cjs');assert.equal(walletLabel({currency:'CNY',balance:''}),'--');
});
test('DSH root v4 lifecycle rejects delegation, cancellation and errors',()=>{
  const lines=(depth,reason)=>[JSON.stringify({type:'session',version:4,delegationDepth:depth,id:'session'}),JSON.stringify({type:'turn/start',time:1,data:{turn:4}}),JSON.stringify({type:'turn/end',time:2,data:{turn:4,reason:{kind:reason}}})].join('\n');
  assert.equal(digestDeepSeek(lines(0,'completed')).completion.id,'dsh|session|4');
  for(const reason of ['error','cancelled','blocked','max-tokens'])assert.equal(digestDeepSeek(lines(0,reason)).completion,null);
  assert.equal(digestDeepSeek(lines(1,'completed')).completion,null);assert.equal(digestDeepSeek(lines(0,'error')).running,false);
  // Minimal zstd frame with a raw (uncompressed) block containing "hello".
  assert.equal(decodeZstd(Buffer.from([0x28,0xb5,0x2f,0xfd,0x20,5,0x29,0,0,...Buffer.from('hello')])),'hello');
});
test('DSH reports unreadable and signed-out states without invented balances',t=>{
  const file=path.join(fixture(t),'status.json');assert.equal(readDeepSeekStatus(file).balance,'--');
  fs.writeFileSync(file,JSON.stringify({accountStatus:'signed-out',balanceStatus:'ready',balance:[{currency:'CNY',balance:'999'}]}));
  assert.equal(readDeepSeekStatus(file).balance,'未登录');
  fs.writeFileSync(file,JSON.stringify({accountStatus:'credential-stored',balanceStatus:'failed',balance:[{currency:'CNY',balance:'999'}]}));
  assert.equal(readDeepSeekStatus(file).balance,'暂不可读');
  fs.writeFileSync(file,JSON.stringify({accountStatus:'credential-stored',balanceStatus:'ready',balanceUpdatedAt:new Date().toISOString(),modelLabel:'DeepSeek-R1',balance:[{currency:'CNY',balance:'0.0012'}]}));
  assert.equal(readDeepSeekStatus(file).balance,'¥0.0012');assert.equal(readDeepSeekStatus(file).model,'DeepSeek-R1');
  assert.equal(dataDirectory('win32',{APPDATA:'roaming'},'user'),path.join('roaming','TokenLens'));
});
test('integration installer preserves settings and adds exactly one backed-up plugin',t=>{
  const home=fixture(t),profile=path.join(home,'.dsh','profiles','desktop');fs.mkdirSync(profile,{recursive:true});
  const patch=path.join(profile,'cordis.patch.yml'),old='- id: ui-theme\n  config:\n    preference: system\n';fs.writeFileSync(patch,old);
  const source=path.join(home,'plugin.mjs');fs.writeFileSync(source,'export const name="tokenlens-dsh-status";');
  installIntegration(source,home);installIntegration(source,home);
  const result=fs.readFileSync(patch,'utf8');assert.ok(result.startsWith(old));assert.equal(result.match(/id: tokenlens-dsh-status/g).length,1);
  assert.equal(fs.readFileSync(patch+'.tokenlens-backup','utf8'),old);
  assert.equal(assistantForPath('C:\\Program Files\\Codex\\Codex.exe'),'gpt');
  assert.equal(assistantForPath('C:\\Apps\\DeepSeek Harness.exe'),'dsh');assert.equal(assistantForPath('C:\\Apps\\Code.exe'),null);
});

test('Codex repeat/reset/fork metadata and two quota windows retain honest metrics',t=>{
  const root=fixture(t),now=Date.now(),file=path.join(root,'root.jsonl');
  const headers=[event('session_meta',{id:'root',model_provider:'openai'},now-6000),event('turn_context',{model:'gpt-current'},now-5500)];
  const calls=[event('event_msg',tokens(100),now-5000),event('event_msg',tokens(100),now-4500),event('event_msg',tokens(20),now-4000),event('event_msg',tokens(70),now-3500)];
  const quota=event('event_msg',{type:'token_count',info:null,rate_limits:{primary:{used_percent:50,window_minutes:300,resets_at:Math.floor(now/1000)+3600},secondary:{used_percent:80,window_minutes:10080,resets_at:Math.floor(now/1000)+7200}}},now-1000);
  fs.writeFileSync(file,[...headers,...calls,quota].join('\n')+'\n');
  fs.writeFileSync(path.join(root,'child.jsonl'),[event('session_meta',{id:'child',source:{subagent:{}}},now-7000),...headers,...calls,event('turn_context',{model:'child-model'},now)].join('\n')+'\n');
  const scanner=new CodexScanner(root),result=scanner.scan(now);
  assert.equal(result.model,'gpt-current','Copied ancestor session_meta must not replace child identity');
  assert.equal(result.todayTokens,170,'Cumulative repeats and copied history must count once; resets create a new epoch');
  assert.equal(result.recentRequestCount,3);assert.equal(result.contextPercent,100/400000*100,'Context estimate must use the latest response, not lifetime cumulative usage');
  assert.equal(result.cachePercent,50);assert.equal(result.remaining,20,'The most restrictive valid account window controls remaining');
  assert.equal(result.secondaryQuota.remaining,20);
  const stale=scanner.scan(now+901000);assert.equal(stale.remaining,null);assert.equal(stale.quota.remaining,null);assert.equal(stale.secondaryQuota.remaining,null);
});
test('DSH per-response usage includes read/write input, ignores inherited seed and avoids reasoning double count',()=>{
  const usage={inputTokens:100,cacheReadTokens:200,cacheWriteTokens:50,outputTokens:40,totalTokens:390,reasoningTokens:20};
  const lines=[{type:'session',version:4,delegationDepth:0,id:'one'},
    {type:'assistant/message',seq:1,time:100,data:{usage}},
    {type:'session/end-seed',seq:2,time:200,data:{}},
    {type:'request/context',seq:3,time:300,data:{model:'dsh-current',provider:'deepseek',contextWindow:1000}},
    {type:'assistant/message',seq:4,time:400,data:{usage,message:{source:{model:'dsh-current',provider:'deepseek'}}}},
    {type:'assistant/message',seq:4,time:400,data:{usage}}].map(x=>JSON.stringify(x)).join('\n');
  const d=digestDeepSeek(lines);assert.equal(d.usage.total,390);assert.equal(d.usage.input,350);assert.equal(d.usage.cached,200);assert.equal(d.samples.length,1);assert.equal(d.context,1000);
});
test('DSH stale or failed balances hide both money and stale bonus',t=>{
  const file=path.join(fixture(t),'status.json'),now=Date.now();
  fs.writeFileSync(file,JSON.stringify({accountStatus:'credential-stored',balanceStatus:'ready',balanceUpdatedAt:new Date(now-181000).toISOString(),balance:[{currency:'CNY',balance:'9'}],bonusWallets:[{currency:'CNY',balance:'100'}]}));
  assert.equal(readDeepSeekStatus(file,now).balance,'暂不可读');assert.equal(readDeepSeekStatus(file,now).bonus,'--');
});

test('synthetic Codex full-context notifications never inflate billed usage',t=>{
  const root=fixture(t),file=path.join(root,'root.jsonl'),now=Date.now();
  fs.writeFileSync(file,[event('event_msg',tokens(100),now-2000),event('event_msg',{type:'token_count',info:{total_token_usage:{input_tokens:0,output_tokens:0,total_tokens:400000},last_token_usage:{input_tokens:0,output_tokens:0,total_tokens:400000},model_context_window:400000}},now-1000)].join('\n')+'\n');
  const result=new CodexScanner(root).scan(now);assert.equal(result.todayTokens,100);assert.equal(result.contextPercent,100);assert.equal(result.recentRequestCount,1);
});
