'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {AdditionalAssistantReader,workBuddyRecord,claudeRecord,codeBuddyRecords,deduplicate,summarize,parseClaudeQuota}=require('../lib/assistant-telemetry.cjs');
const now=Date.parse('2026-09-30T12:00:00Z');
function work(id='call-a',input=100,output=20){return {timestamp:now-1000,sessionId:'synthetic-session',type:'message',content:'NEVER_EXPORT_TRANSCRIPT',providerData:{messageId:id,requestModelName:'test-model',usage:{inputTokens:input,outputTokens:output,totalTokens:input+output,requests:1},rawUsage:{prompt_cache_hit_tokens:40,prompt_cache_write_tokens:20,credit:800}}};}
test('WorkBuddy measures counters and deduplicates call snapshots without treating credits as funds',()=>{
  const first=workBuddyRecord(work()),second=workBuddyRecord(work('call-a',110,30));
  const result=summarize([first,second],'WorkBuddy',now,1);
  assert.equal(deduplicate([first,second]).length,1);assert.equal(result.todayTokens,140);
  assert.equal(result.cachePercent,40/110*100);assert.equal(result.recentRequestCount,1);
  assert.equal(result.remaining,null);assert.equal(result.balance,null);assert.equal(result.contextPercent,null);
  assert(!JSON.stringify(result).includes('NEVER_EXPORT_TRANSCRIPT'));
});
test('missing cache metadata is unknown and explicit measured zero is preserved',()=>{
  const absent=work();delete absent.providerData.rawUsage;
  assert.equal(summarize([workBuddyRecord(absent)],'WorkBuddy',now,1).cachePercent,null);
  const zero=work();zero.providerData.rawUsage.prompt_cache_hit_tokens=0;
  assert.equal(summarize([workBuddyRecord(zero)],'WorkBuddy',now,1).cachePercent,0);
  const bad=work();bad.providerData.usage.inputTokens=true;assert.equal(workBuddyRecord(bad),null);
  bad.providerData.usage.inputTokens=-10;assert.equal(workBuddyRecord(bad),null);
});
test('Anthropic inclusive input adds cache reads and writes; creation never counts as hit',()=>{
  const record=claudeRecord({type:'assistant',timestamp:new Date(now).toISOString(),sessionId:'synthetic',message:{id:'api-message',model:'claude-test',content:[{text:'PRIVATE'}],usage:{input_tokens:10,cache_read_input_tokens:70,cache_creation_input_tokens:20,output_tokens:5}}});
  assert.equal(record.input,100);assert.equal(record.total,105);assert.equal(record.cached,70);
  const result=summarize([record,{...record,output:6,total:106}],'Claude Desktop / Cowork',now,1);
  assert.equal(result.todayTokens,106);assert.equal(result.cachePercent,70);assert.equal(result.recentRequestCount,1);
  assert(!JSON.stringify(result).includes('PRIVATE'));
});
test('CodeBuddy cumulative user turns deduplicate; lastTokens and credit do not imply context/balance',()=>{
  const document={requests:[{id:'user-turn',startedAt:now-1000,state:'complete',messages:['SECRET_MESSAGE_ID'],usage:{inputTokens:1000,outputTokens:100,totalTokens:1100,cacheTokens:800,cachedWriteTokens:100,lastTokens:200,credit:8}}]};
  const records=codeBuddyRecords(document,'history-session');
  const result=summarize([...records,...records],'CodeBuddy',now,2,false);
  assert.equal(result.todayTokens,1100);assert.equal(result.cachePercent,80);
  assert.equal(result.recentRequestCount,null);assert.equal(result.contextPercent,null);assert.equal(result.balance,null);
  assert(!JSON.stringify(result).includes('SECRET_MESSAGE_ID'));
});
test('Claude quota uses newest fresh sampled windows and constraining window; no expired reset inference',()=>{
  const q=parseClaudeQuota({samples:[{t:now-1000,org:'DO_NOT_EXPORT_ORG',u:{five_hour:{utilization:20,resets_at:new Date(now+600000).toISOString()},seven_day:{utilization:75,resets_at:new Date(now+86400000).toISOString()}}}]},now);
  assert.equal(q.remaining,25);assert.equal(q.quota.used,20);assert.equal(q.secondaryQuota.used,75);
  assert(!JSON.stringify(q).includes('DO_NOT_EXPORT_ORG'));
  assert.equal(parseClaudeQuota({samples:[{t:now-901000,u:{five_hour:{utilization:0,resets_at:new Date(now+1000).toISOString()}}}]},now),null);
  assert.equal(parseClaudeQuota({samples:[{t:now-1000,u:{five_hour:{utilization:0,resets_at:new Date(now-1).toISOString()}}}]},now),null);
  assert.equal(parseClaudeQuota({samples:[{t:now-1000,u:{}}]},now),null);
  assert.equal(parseClaudeQuota({samples:[{t:now+6000,u:{five_hour:{utilization:1,resets_at:new Date(now+10000).toISOString()}}}]},now),null);
  const iso=parseClaudeQuota({samples:[{t:new Date(now-1000).toISOString(),u:{five_hour:{utilization:30,resets_at:new Date(now+10000).toISOString()}}}]},now);
  assert.equal(iso.remaining,70);assert.equal(iso.quotaAt,now-1000);
});
test('model breakdown matches seven calendar days; running needs actual WorkBuddy state, not completed-session update time',()=>{
  const current=workBuddyRecord(work());
  const older={...current,id:'old-call',model:'excluded-old-model',at:now-7*86400000};
  assert.deepEqual(summarize([current,older],'WorkBuddy',now,1).models.map(x=>x.model),['test-model']);
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tokenlens-assistant-lifecycle-'));
  let db;
  try{
    const {DatabaseSync}=require('node:sqlite');const folder=path.join(dir,'.workbuddy-ai');fs.mkdirSync(folder,{recursive:true});
    db=new DatabaseSync(path.join(folder,'workbuddy.db'));
    db.exec('CREATE TABLE sessions(id TEXT,status TEXT,is_background_automation INTEGER,deleted_at INTEGER,last_activity_at INTEGER);CREATE TABLE session_usage(session_id TEXT,used INTEGER,size INTEGER,updated_at INTEGER);');
    db.prepare('INSERT INTO sessions VALUES(?,?,?,?,?)').run('fixture-session','working',0,null,now-1000);
    db.prepare('INSERT INTO session_usage VALUES(?,?,?,?)').run('fixture-session',50,200,now-1000);
    let s=new AdditionalAssistantReader({home:dir,appData:path.join(dir,'AppData')}).scan(now).workbuddy;
    assert.equal(s.running,true);assert.equal(s.contextPercent,25);assert.equal(s.completion,null);
    db.prepare('UPDATE sessions SET status=?').run('completed');
    s=new AdditionalAssistantReader({home:dir,appData:path.join(dir,'AppData')}).scan(now).workbuddy;
    assert.equal(s.running,false);assert.equal(s.completion,null);
    db.prepare('UPDATE sessions SET status=?,is_background_automation=1').run('working');
    assert.equal(new AdditionalAssistantReader({home:dir,appData:path.join(dir,'AppData')}).scan(now).workbuddy.running,false);
  }finally{db?.close();fs.rmSync(dir,{recursive:true,force:true});}
});
test('Desktop Claude never borrows CLI records and ignores auth/config unrelated files',()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tokenlens-assistant-fixture-'));
  try {
    const cli=path.join(dir,'.claude','projects','project');fs.mkdirSync(cli,{recursive:true});
    fs.writeFileSync(path.join(cli,'session.jsonl'),JSON.stringify({type:'assistant',timestamp:new Date(now).toISOString(),sessionId:'cli-only',message:{id:'cli-call',model:'cli-test',usage:{input_tokens:100,cache_read_input_tokens:10,cache_creation_input_tokens:0,output_tokens:10}}}));
    fs.writeFileSync(path.join(dir,'.claude','.credentials.json'),'this file must never be read');
    const result=new AdditionalAssistantReader({home:dir,appData:path.join(dir,'AppData'),platform:'win32'}).scan(now);
    assert.equal(result.claude.tokenUsageKnown,false);assert.equal(result.claude.todayTokens,0);
    assert.equal(result.claude.model,'模型未返回');assert.equal(result.claude.remaining,null);
    assert.equal(result.workbuddy.cachePercent,null);assert.equal(result.codebuddy.contextPercent,null);
  }finally{fs.rmSync(dir,{recursive:true,force:true});}
});
