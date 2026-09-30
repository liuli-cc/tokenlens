'use strict';
// Only recognized numeric usage metadata is retained. Content, account IDs,
// cookies, credentials and transcript text are neither returned nor persisted.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const DAY = 86400000;
const number = x => typeof x === 'number' && Number.isSafeInteger(x) && x >= 0 ? x : null;
const timestamp = x => typeof x === 'number' && Number.isFinite(x) && x > 1e12 ? x : typeof x === 'string' ? Date.parse(x) || null : null;
const dayKey = t => { const d = new Date(t); return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`; };
const safeModel = x => typeof x === 'string' && /^[\p{L}\p{N} ._:/()+-]{1,96}$/u.test(x) ? x : null;
function empty(source, diagnostic) {
  return {model:'模型未返回',provider:source,source,remaining:null,quota:null,secondaryQuota:null,
    balance:null,contextPercent:null,contextIsEstimate:false,cachePercent:null,todayTokens:0,
    tokenUsageKnown:false,cacheUsageKnown:false,recentRequestCount:null,history:[],models:[],
    running:false,completion:null,files:0,updatedAt:null,metricsUpdatedAt:null,quotaAt:null,
    metricsSource:source,metricsDiagnostic:diagnostic,error:null};
}
function workBuddyRecord(e) {
  const p=e?.providerData, u=p?.usage, raw=p?.rawUsage;
  if (!p || !u || typeof p.messageId!=='string' || !p.messageId) return null;
  const input=number(u.inputTokens), output=number(u.outputTokens), total=number(u.totalTokens), at=timestamp(e.timestamp);
  if (input==null || output==null || total==null || at==null || total!==input+output) return null;
  const cached=number(raw?.prompt_cache_hit_tokens) ?? number(raw?.cached_tokens) ?? number(raw?.cache_read_input_tokens);
  const write=number(raw?.prompt_cache_write_tokens) ?? number(raw?.cache_creation_input_tokens);
  return {id:p.messageId,session:typeof e.sessionId==='string'?e.sessionId:'',at,input,output,total,
    cached:cached!=null&&cached<=input?cached:null,write:write!=null&&write<=input?write:null,
    model:safeModel(p.requestModelName)||safeModel(p.requestModelId)||safeModel(p.model),
    requests:number(u.requests),primary:p.isSubAgent!==true};
}
function claudeRecord(e) {
  const m=e?.message, u=m?.usage;
  if (e?.type!=='assistant' || !u || typeof m.id!=='string' || !m.id) return null;
  const uncached=number(u.input_tokens), read=number(u.cache_read_input_tokens), write=number(u.cache_creation_input_tokens), output=number(u.output_tokens),at=timestamp(e.timestamp);
  if (uncached==null || output==null || at==null) return null;
  // Anthropic input_tokens excludes cache reads and writes. Missing cache fields
  // are not known zero: older schemas without them cannot produce a hit rate.
  const cacheKnown=read!=null&&write!=null;
  const input=uncached+(read??0)+(write??0);
  return {id:m.id,session:typeof e.sessionId==='string'?e.sessionId:'',at,input,output,total:input+output,
    cached:cacheKnown?read:null,write:cacheKnown?write:null,model:safeModel(m.model),requests:1,primary:e.isSidechain!==true};
}
function codeBuddyRecords(doc, session) {
  if (!doc || !Array.isArray(doc.requests)) return [];
  return doc.requests.flatMap(r=>{
    const u=r?.usage, at=timestamp(r?.startedAt),input=number(u?.inputTokens),output=number(u?.outputTokens),total=number(u?.totalTokens);
    if(typeof r?.id!=='string'||!r.id||at==null||input==null||output==null||total==null||total!==input+output)return [];
    const cache=number(u.cacheTokens),write=number(u.cachedWriteTokens);
    // credit is consumed credit. lastTokens has no verified capacity/semantic
    // contract; neither is converted to a balance or context percentage.
    return [{id:r.id,session,at,input,output,total,cached:cache!=null&&cache<=input?cache:null,
      write:write!=null&&write<=input?write:null,model:null,requests:null,primary:true,running:r.state==='running'}];
  });
}
function deduplicate(records) {
  const unique=new Map();
  for (const r of records) {
    const old=unique.get(r.id);
    // Streaming assistant blocks/saved snapshots reuse request IDs. Keep the
    // greatest completed cumulative usage instead of charging every block.
    if (!old || r.total>old.total || r.total===old.total&&r.at>=old.at) unique.set(r.id,r);
  }
  return [...unique.values()];
}
function summarize(records,source,now,files,requestCounts=true) {
  const unique=deduplicate(records).filter(r=>r.at<=now+300000 && r.at>=now-8*DAY);
  const result=empty(source,'本机未返回可识别的用量；额度与余额不可读取');result.files=files;
  if(!unique.length)return result;
  unique.sort((a,b)=>b.at-a.at);const latest=unique.find(r=>r.primary!==false)||unique[0],session=unique.filter(r=>r.session===latest.session);
  const input=session.reduce((s,r)=>s+r.input,0),cacheKnown=session.every(r=>r.cached!=null);
  result.model=latest.model||'模型未返回';result.tokenUsageKnown=true;result.cacheUsageKnown=cacheKnown;
  result.cachePercent=cacheKnown&&input>0?session.reduce((s,r)=>s+r.cached,0)/input*100:null;
  result.todayTokens=unique.filter(r=>dayKey(r.at)===dayKey(now)).reduce((s,r)=>s+r.total,0);
  result.history=Array.from({length:7},(_,i)=>{const day=dayKey(now-(6-i)*DAY);return {day,tokens:unique.filter(r=>dayKey(r.at)===day).reduce((s,r)=>s+r.total,0)};});
  result.updatedAt=latest.at;result.metricsUpdatedAt=latest.at;
  result.recentRequestCount=requestCounts&&unique.filter(r=>r.at>=now-DAY).every(r=>r.requests!=null)?unique.filter(r=>r.at>=now-DAY).reduce((s,r)=>s+r.requests,0):null;
  result.running=unique.some(r=>r.running&&now-r.at<600000);
  const modelStart=new Date(now);modelStart.setHours(0,0,0,0);modelStart.setDate(modelStart.getDate()-6);
  const models=new Map();for(const r of unique.filter(r=>r.at>=modelStart.getTime())){const name=r.model||'模型未返回';models.set(name,(models.get(name)||0)+r.total)}
  result.models=[...models].map(([model,tokens])=>({model,tokens})).sort((a,b)=>b.tokens-a.tokens);
  result.metricsDiagnostic=source==='CodeBuddy'?'本机历史按用户请求去重；API 调用次数、上下文容量、剩余额度与余额未返回':'本机响应 usage；只覆盖留存在本机的记录，额度与余额未返回';
  result.sessionID=latest.session; // Internal only, root need not display this.
  return result;
}
function parseClaudeQuota(doc,now) {
  if(!Array.isArray(doc?.samples))return null;
  const samples=doc.samples.map(s=>({sample:s,at:timestamp(s.t)})).filter(s=>s.at!=null&&s.at<=now+5000&&s.at>=now-15*60000).sort((a,b)=>b.at-a.at);
  for(const {sample:s,at} of samples){
    const parse=(v,minutes)=>{
      if(!v||typeof v.utilization!=='number'||!Number.isFinite(v.utilization)||v.utilization<0||v.utilization>100)return null;
      const resetsAt=timestamp(v.resets_at);if(resetsAt==null||resetsAt<=now)return null;
      return {used:v.utilization,remaining:100-v.utilization,resetsAt,windowMinutes:minutes};
    };
    const primary=parse(s.u?.five_hour,300),secondary=parse(s.u?.seven_day,10080);
    if(primary||secondary){const selected=[primary,secondary].filter(Boolean).sort((a,b)=>b.used-a.used)[0];return {quota:primary||secondary,secondaryQuota:primary?secondary:null,remaining:selected.remaining,quotaAt:at};}
  }
  return null;
}
function walk(root,match,after,limit=1000) {
  const result=[],stack=[root];let visited=0;
  while(stack.length&&visited++<5000){const dir=stack.pop();let entries;try{entries=fs.readdirSync(dir,{withFileTypes:true});}catch{continue;}
    for(const e of entries){if(e.isSymbolicLink()||e.name.startsWith('.')||['node_modules','plugins','memory','vm.bundle','blobs'].includes(e.name))continue;
      const file=path.join(dir,e.name);if(e.isDirectory())stack.push(file);else if(e.isFile()&&match(file)){try{const s=fs.statSync(file);if(s.mtimeMs>=after&&s.size<=64*1024*1024)result.push({file,mtime:s.mtimeMs,size:s.size});}catch{}}}
  }
  return result.sort((a,b)=>b.mtime-a.mtime).slice(0,limit);
}
class AdditionalAssistantReader {
  constructor({home=os.homedir(),appData,platform=process.platform}={}) {
    this.home=home;this.platform=platform;this.appData=appData||(platform==='win32'?(process.env.APPDATA||path.join(home,'AppData','Roaming')):path.join(home,'Library','Application Support'));this.cache=new Map();
  }
  records(files,kind){return files.flatMap(f=>{
    const key=kind+'|'+f.file,old=this.cache.get(key);if(old?.mtime===f.mtime&&old?.size===f.size)return old.records;
    let records=[];try{const text=fs.readFileSync(f.file,'utf8');
      if(kind==='codebuddy'){records=codeBuddyRecords(JSON.parse(text),path.dirname(f.file));}
      else {for(const line of text.split('\n')){if(line.length>2*1024*1024)continue;try{const record=kind==='workbuddy'?workBuddyRecord(JSON.parse(line)):claudeRecord(JSON.parse(line));if(record)records.push(record);}catch{}}}
    }catch{}this.cache.set(key,{mtime:f.mtime,size:f.size,records});return records;
  });}
  workBuddyContext(result,now){
    const file=path.join(this.home,'.workbuddy-ai','workbuddy.db');if(!fs.existsSync(file))return;
    let db;try{const {DatabaseSync}=require('node:sqlite');db=new DatabaseSync(file,{readOnly:true});
      const active=db.prepare("SELECT COUNT(*) AS active FROM sessions WHERE status IN ('working','planning') AND COALESCE(is_background_automation,0)=0 AND (deleted_at IS NULL OR deleted_at<0) AND last_activity_at BETWEEN ? AND ?").get(now-600000,now+5000);
      result.running=active.active>0;result.metricsDiagnostic+='；运行状态取自本机会话，未提供任务结束时间';
      const row=result.sessionID?db.prepare('SELECT used,size,updated_at FROM session_usage WHERE session_id=? ORDER BY updated_at DESC LIMIT 1').get(result.sessionID):db.prepare('SELECT used,size,updated_at FROM session_usage ORDER BY updated_at DESC LIMIT 1').get();
      const used=number(row?.used),size=number(row?.size),at=timestamp(row?.updated_at);
      if(used!=null&&size!=null&&size>0&&used<=size&&at!=null&&at<=now+300000){result.contextPercent=used/size*100;result.contextIsEstimate=false;result.contextUpdatedAt=at;result.metricsDiagnostic+='；上下文取自 session_usage.used/size';}
    }catch{result.metricsDiagnostic+='；本机 SQLite 上下文暂不可读取';}finally{db?.close();}
  }
  scan(now=Date.now()){
    const work=walk(path.join(this.home,'.workbuddy-ai','projects'),f=>f.endsWith('.jsonl'),now-8*DAY);
    const code=walk(path.join(this.appData,'CodeBuddyExtension','Data'),f=>f.endsWith('.json')&&f.split(path.sep).includes('history'),now-8*DAY);
    const claudeFiles=['local-agent-mode-sessions','claude-code-sessions'].flatMap(root=>walk(path.join(this.appData,'Claude',root),f=>f.endsWith('.jsonl'),now-8*DAY));
    const workbuddy=summarize(this.records(work,'workbuddy'),'WorkBuddy',now,work.length);this.workBuddyContext(workbuddy,now);
    const codebuddy=summarize(this.records(code,'codebuddy'),'CodeBuddy',now,code.length,false);
    const claude=summarize(this.records(claudeFiles,'claude'),'Claude Desktop / Cowork',now,claudeFiles.length);
    if(!claude.tokenUsageKnown)claude.metricsDiagnostic='Claude 桌面聊天/Cowork 未返回令牌指标；Claude Code 记录独立，不计入此岛';
    try{const q=parseClaudeQuota(JSON.parse(fs.readFileSync(path.join(this.appData,'Claude','plan-usage-history.json'),'utf8')),now);if(q){Object.assign(claude,q);claude.metricsDiagnostic=claude.tokenUsageKnown?'本机 Desktop/Cowork 响应用量；额度为 Claude 本机服务端采样，余额未返回':'Claude Desktop/Cowork 令牌未返回；额度为 Claude 本机服务端采样；独立 Code 记录未计入';}}catch{}
    for(const s of [workbuddy,claude,codebuddy])delete s.sessionID;
    const live=new Set([...work,...code,...claudeFiles].map(f=>f.file));
    for(const key of this.cache.keys())if(!live.has(key.slice(key.indexOf('|')+1)))this.cache.delete(key);
    return {workbuddy,claude,codebuddy};
  }
}
module.exports={AdditionalAssistantReader,workBuddyRecord,claudeRecord,codeBuddyRecords,deduplicate,summarize,parseClaudeQuota};
