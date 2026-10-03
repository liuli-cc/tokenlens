'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { Decompress } = require('fzstd');

const DAY = 86400000;
const COMPLETION_FRESHNESS = 90000;
const MAX_COMPLETION_EVENTS = 128;
function recentCompletionEvents(events, now = Date.now()) {
  const seen = new Set();
  return events.filter(event => {
    if (!event || typeof event.id !== 'string' || !event.id || !Number.isFinite(event.at)
      || event.at <= 0 || event.at > now + 5000 || now - event.at > COMPLETION_FRESHNESS
      || seen.has(event.id)) return false;
    seen.add(event.id); return true;
  }).sort((a,b) => a.at-b.at || a.id.localeCompare(b.id)).slice(-MAX_COMPLETION_EVENTS);
}
function recordCompletion(digest, notice) {
  if (!Number.isFinite(notice.at) || notice.at <= 0) return;
  if (digest.completion?.id === notice.id || digest.completionEvents.some(event => event.id === notice.id)) return;
  digest.completion = notice;
  digest.completionEvents.push(notice);
  const newest = Math.max(...digest.completionEvents.map(event => event.at));
  digest.completionEvents = recentCompletionEvents(digest.completionEvents, newest);
}
function dayKey(time) { const d = new Date(time); return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`; }
function validCount(value) { return value!=null && String(value).trim()!=='' && Number.isSafeInteger(Number(value)) && Number(value)>=0; }
function count(value) { const n = Number(value); return value != null && Number.isFinite(n) && n >= 0 ? n : 0; }
function usage(raw = {}) {
  const input=count(raw.input_tokens), output=count(raw.output_tokens);
  return { input, cached:count(raw.cached_input_tokens), output,
    total:raw.total_tokens != null ? count(raw.total_tokens) : input+output, cacheWrite:count(raw.cache_write_input_tokens) };
}
function deltaUsage(a,b) { return Object.fromEntries(Object.keys(a).map(key=>[key,Math.max(0,a[key]-(b[key]||0))])); }
function addUsage(a,b) { return Object.fromEntries(Object.keys(a).map(key=>[key,a[key]+(b[key]||0)])); }
function limitWindow(raw) {
  if (raw?.used_percent==null || !Number.isFinite(Number(raw.used_percent)) || raw.used_percent<0 || raw.used_percent>100) return null;
  return {used:Number(raw.used_percent),remaining:100-Number(raw.used_percent),
    resetsAt:count(raw.resets_at)*1000 || null,windowMinutes:count(raw.window_minutes)};
}
function effectiveQuota(primary,secondary,at,now) {
  if (!at || now-at > 900000 || at-now > 5000) return null;
  return [primary,secondary].filter(q=>q && q.resetsAt>now).sort((a,b)=>b.used-a.used)[0] || null;
}
function emptyDigest() {
  return { id: '', user: true, model: '', provider: 'openai', total: usage(), last: usage(),
    accumulated:usage(), tokenUsageKnown:false, cacheUsageKnown:false, samples:[],
    days: {}, models: {}, quota: null, secondaryQuota:null, context: 0, at: 0, tokenAt:0, quotaAt: 0, running: false, completion: null, completionEvents: [] };
}
function consumeCodex(d, event) {
  const p = event.payload || {}, at = Date.parse(event.timestamp) || 0;
  if (event.type === 'session_meta') {
    if(d.identityRead)return;d.identityRead=true;
    d.id = p.id || d.id; d.provider = p.model_provider || d.provider;
    d.user = (!p.thread_source || p.thread_source === 'user') && !(p.source && typeof p.source === 'object');
  } else if (event.type === 'turn_context') {
    if (typeof p.model === 'string') {if(d.model!==p.model){d.context=0;d.contextUsedTokens=null;}d.model=p.model;}
    d.at = Math.max(d.at, at);
  } else if (event.type === 'event_msg') {
    if (p.type === 'task_started') {
      d.running = true; d.turn = p.turn_id || ''; d.context = +p.model_context_window || d.context;
      d.startedAt = p.started_at ? +p.started_at * 1000 : at; d.at = Math.max(d.at, at);
    } else if (p.type === 'turn_aborted') {
      d.running = false; d.turn = null; d.at = Math.max(d.at, at);
    } else if (p.type === 'task_complete') {
      const turn = p.turn_id || d.turn;
      if (d.user && d.id && turn) recordCompletion(d, {
        id: `${d.id}|${turn}`, at: p.completed_at ? +p.completed_at * 1000 : at, model: d.model,
        title: 'GPT 已完成本轮任务' });
      d.running = false; d.turn = null; d.at = Math.max(d.at, at);
    } else if (p.type === 'token_count') {
      if(p.rate_limits && typeof p.rate_limits==='object') {
        d.quota=limitWindow(p.rate_limits.primary);d.secondaryQuota=limitWindow(p.rate_limits.secondary);d.quotaAt=at;d.quotaLimitID=p.rate_limits.limit_id || null;d.quotaLimitName=p.rate_limits.limit_name || null;
      }
      const info=p.info;
      if(info?.total_token_usage && validCount(info.total_token_usage.input_tokens) && validCount(info.total_token_usage.output_tokens) && (info.total_token_usage.total_tokens==null || validCount(info.total_token_usage.total_tokens)) && (count(info.total_token_usage.input_tokens)>0 || count(info.total_token_usage.output_tokens)>0 || count(info.total_token_usage.total_tokens)===0)) {
        const total=usage(info.total_token_usage);
        const delta=total.total<d.total.total ? total : deltaUsage(total,d.total);
        if(at && delta.total>0) {
          const day=dayKey(at),model=d.model || '未知模型';
          const id=[at,d.provider,total.input,total.cached,total.output,total.total].join('|');
          d.samples.push({id,day,model,tokens:delta.total});
          d.days[day]=(d.days[day]||0)+delta.total;d.models[model]=(d.models[model]||0)+delta.total;
        }
        d.total=total;d.accumulated=addUsage(d.accumulated,delta);
        d.tokenUsageKnown=info.total_token_usage.input_tokens!=null && info.total_token_usage.output_tokens!=null;
        d.cacheUsageKnown = info.total_token_usage.cached_input_tokens!=null;
      }
      if(info?.last_token_usage){d.last=usage(info.last_token_usage);d.contextUsedTokens=info.last_token_usage.total_tokens ?? null;}
      if(info?.model_context_window>0)d.context=Number(info.model_context_window);
      if(info)d.tokenAt=at;
      d.at=Math.max(d.at,at);

    }
  }
}

function walk(root, match, after, limit = Infinity) {
  const found = [], stack = [root];
  while (stack.length) {
    let entries; try { entries = fs.readdirSync(stack.pop(), { withFileTypes: true }); } catch { continue; }
    for (const e of entries) {
      if (e.name.startsWith('.')) continue;
      const file = path.join(e.parentPath || e.path, e.name);
      if (e.isDirectory()) stack.push(file);
      else if (e.isFile() && match(e.name)) {
        try { const stat = fs.statSync(file); if (stat.mtimeMs >= after) found.push({file,stat}); } catch {}
      }
    }
  }
  return found.sort((a,b) => b.stat.mtimeMs - a.stat.mtimeMs).slice(0,limit);
}

class CodexScanner {
  constructor(root = path.join(process.env.CODEX_HOME || path.join(os.homedir(), '.codex'), 'sessions')) {
    this.root = root; this.cache = new Map();
  }
  scan(now = Date.now()) {
    const files = walk(this.root, n => n.endsWith('.jsonl'), now - 8 * DAY);
    const seen = new Set(files.map(x => x.file));
    for (const {file,stat} of files) {
      let entry = this.cache.get(file);
      if (entry && entry.mtime === stat.mtimeMs && entry.size === stat.size) continue;
      // A truncation or same-sized rewrite resets the cumulative counters.
      if (!entry || stat.size <= entry.size || entry.ino !== stat.ino) entry = { size: 0, pending: '', digest: emptyDigest(), ino: stat.ino };
      const fd = fs.openSync(file, 'r');
      try {
        const chunk = Buffer.alloc(65536); let offset = entry.size, read;
        while ((read = fs.readSync(fd, chunk, 0, Math.min(chunk.length, stat.size-offset), offset)) > 0) {
          offset += read;
          // StringDecoder retains UTF-8 sequences split across read chunks.
          entry.decoder ||= new (require('node:string_decoder').StringDecoder)('utf8');
          entry.pending += entry.decoder.write(chunk.subarray(0,read));
          let end;
          while ((end = entry.pending.indexOf('\n')) !== -1) {
            const line = entry.pending.slice(0,end); entry.pending = entry.pending.slice(end+1);
            if (!/"(?:session_meta|turn_context|token_count|task_started|task_complete|turn_aborted)"/.test(line)) continue;
            try { consumeCodex(entry.digest, JSON.parse(line)); } catch {}
          }
          // Tool outputs are never surfaced; a malformed gigantic line is discarded.
          if (entry.pending.length > 16 * 1024 * 1024) entry.pending = '';
        }
      } finally { fs.closeSync(fd); }
      entry.size = stat.size; entry.mtime = stat.mtimeMs; this.cache.set(file,entry);
    }
    for (const key of this.cache.keys()) if (!seen.has(key)) this.cache.delete(key);
    const all = [...this.cache.values()].map(x => x.digest);
    const user = all.filter(d => d.user), active = user.toSorted((a,b) => b.at - a.at)[0] || emptyDigest();
    const quotaDigest = user.filter(d => d.quota || d.secondaryQuota).toSorted((a,b) => b.quotaAt - a.quotaAt)[0];
    const totals = {}, models = {}, requests={},seenSamples=new Set();let recentRequestCount=0;
    const historyStart=new Date(now);historyStart.setHours(0,0,0,0);historyStart.setDate(historyStart.getDate()-6);
    for (const d of all) {
      for (const sample of d.samples) {
        if(sample.day<dayKey(historyStart) || sample.day>dayKey(now) || seenSamples.has(sample.id))continue;
        seenSamples.add(sample.id);totals[sample.day]=(totals[sample.day]||0)+sample.tokens;
        models[sample.model]=(models[sample.model]||0)+sample.tokens;requests[sample.model]=(requests[sample.model]||0)+1;recentRequestCount++;
      }
    }
    const reportedQuota=effectiveQuota(quotaDigest?.quota,quotaDigest?.secondaryQuota,quotaDigest?.quotaAt,now);
    const history = Array.from({length:7}, (_,i) => {
      const date = new Date(historyStart); date.setDate(date.getDate()+i); const day=dayKey(date); return {day,tokens:totals[day] || 0};
    });
    return { model: active.model || '等待 GPT', provider: active.provider, remaining: reportedQuota?.remaining ?? null,
      quota:quotaDigest?.quota ? {...quotaDigest.quota,remaining:effectiveQuota(quotaDigest.quota,null,quotaDigest.quotaAt,now)?.remaining ?? null}:null,
      secondaryQuota:quotaDigest?.secondaryQuota ? {...quotaDigest.secondaryQuota,remaining:effectiveQuota(null,quotaDigest.secondaryQuota,quotaDigest.quotaAt,now)?.remaining ?? null}:null,
      effectiveQuota:reportedQuota,quotaAt:quotaDigest?.quotaAt || null,quotaLimitID:quotaDigest?.quotaLimitID || null,quotaLimitName:quotaDigest?.quotaLimitName || null,
      contextPercent: active.contextUsedTokens!=null && active.context ? Math.min(100,active.contextUsedTokens / active.context * 100) : null,
      cachePercent: active.cacheUsageKnown && active.accumulated.input ? Math.min(100,active.accumulated.cached / active.accumulated.input * 100) : null,
      tokenUsageKnown:all.some(d=>d.tokenUsageKnown),cacheUsageKnown:active.cacheUsageKnown,contextIsEstimate:true,
      recentRequestCount:all.some(d=>d.tokenUsageKnown)?recentRequestCount:null,requestCountIsLowerBound:true,
      metricsSource:'Codex token_count · 本机日志',metricsUpdatedAt:active.tokenAt || null,
      metricsDiagnostic:'近期 Token 包含本机子任务；调用为已记录的用量事件，不包含未返回用量的失败请求。上下文按最近响应总量估算，后续工具消息和压缩变化可能未反映；配额是账号共享的采样值。',
      todayTokens: totals[dayKey(now)] || 0, history, models: Object.entries(models).map(([model,tokens]) => ({model,tokens,requests:requests[model],requestsKnown:true})).sort((a,b)=>b.tokens-a.tokens),
      running: user.some(d => d.running && now-d.at < 600000),
      completion: user.map(d=>d.completion).filter(Boolean).sort((a,b)=>b.at-a.at)[0] || null,
      completionEvents: recentCompletionEvents(user.flatMap(d=>d.completionEvents), now),
      files: files.length, updatedAt: active.at || null, error: files.length ? null : '等待本机 Codex 会话记录' };
  }
}

function digestDeepSeek(lines) {
  const d={user:false,id:'',running:false,completion:null,completionEvents:[],model:'等待 Harness',provider:'DeepSeek',context:0,
    usage:usage(),last:usage(),tokenUsageKnown:false,cacheUsageKnown:false,cacheComplete:true,samples:[],at:0,eventAt:0};
  const seen=new Set();let seedEnded=false;
  for(const line of lines.split('\n')) {
    if(!/"(?:session|session\/end-seed|model\/selection|request\/header|request\/context|assistant\/message|assistant\/attempt|turn\/start|turn\/end)"/.test(line))continue;
    let e;try{e=JSON.parse(line);}catch{continue;}const data=e.data || {};
    if(e.type==='session'){d.user=e.version===4 && e.delegationDepth===0;d.id=e.id;continue;}
    if(!d.user)continue;
    d.eventAt=e.time || d.eventAt;
    const select=raw=>{if(typeof raw?.model==='string'){if(d.model!==raw.model)d.context=0;d.model=raw.model;}if(typeof raw?.provider==='string')d.provider=raw.provider;};
    if(e.type==='session/end-seed')seedEnded=true;
    else if(e.type==='model/selection')select(data);
    else if(e.type==='request/header')select(data.header?.config);
    else if(e.type==='request/context'){select(data);if(data.contextWindow>0)d.context=Number(data.contextWindow);}
    else if(seedEnded && ['assistant/message','assistant/attempt'].includes(e.type)){
      const raw=data.usage || (Array.isArray(data.stream)?data.stream.findLast(x=>x.type==='usage')?.usage:null);
      if(validCount(raw?.inputTokens) && validCount(raw?.outputTokens)){
        if(['cacheReadTokens','cacheWriteTokens','reasoningTokens','totalTokens'].some(key=>raw[key]!=null && !validCount(raw[key])))continue;
        const input=count(raw.inputTokens),read=count(raw.cacheReadTokens),write=count(raw.cacheWriteTokens),output=count(raw.outputTokens);
        const knownTotal=input+read+write+output;
        let total;
        if(raw.totalTokens!=null){total=count(raw.totalTokens);if(total<knownTotal || (raw.cacheReadTokens!=null && raw.cacheWriteTokens!=null && total!==knownTotal))continue;}
        else{if(raw.cacheReadTokens==null || raw.cacheWriteTokens==null)continue;total=knownTotal;}
        if(raw.reasoningTokens!=null && count(raw.reasoningTokens)>output)continue;
        const current={input:total-output,cached:read,cacheWrite:write,output,total};
        const id=[d.id,e.seq ?? e.time].join('|');
        if(!seen.has(id)){
          seen.add(id);select(data.message?.source);d.usage=addUsage(d.usage,current);d.last=current;
          d.tokenUsageKnown=true;d.cacheComplete &&=raw.cacheReadTokens!=null;d.cacheUsageKnown=d.cacheComplete;d.at=e.time || d.at;
          d.samples.push({id,at:e.time,day:dayKey(e.time),tokens:current.total,model:d.model});
        }
      }
    }
    if(data.turn!=null){
      if(e.type==='turn/start'){d.running=true;d.turn=data.turn;}
      else if(e.type==='turn/end'){
        if(data.reason?.kind==='completed' && d.id && Number.isFinite(e.time))recordCompletion(d,{id:`dsh|${d.id}|${data.turn}`,at:e.time,title:'DeepSeek 已完成本轮任务'});
        if(d.turn===data.turn)d.running=false;
      }
    }
  }
  return d;
}

function decodeZstd(buffer) {
  let total = 0; const chunks = [];
  const stream = new Decompress(data => {
    total += data.length;
    if (total > 128 * 1024 * 1024) throw new Error('DSH log exceeds size limit');
    chunks.push(Buffer.from(data));
  });
  stream.push(buffer,true); return Buffer.concat(chunks).toString('utf8');
}
function dataDirectory(platform = process.platform, env = process.env, home = os.homedir()) {
  if (env.TOKENLENS_DATA_DIR) return env.TOKENLENS_DATA_DIR;
  return platform === 'win32' ? path.join(env.APPDATA || path.join(home,'AppData','Roaming'),'TokenLens')
    : path.join(home,'Library','Application Support','TokenLens');
}
function walletLabel(wallet, empty = '--') {
  if (!wallet) return empty;
  if (wallet.balance == null || String(wallet.balance).trim()==='') return '--';
  const amount = Number(wallet.balance); if (!Number.isFinite(amount)) return '--';
  const currency=String(wallet.currency || '').toUpperCase();
  const symbol={CNY:'¥',USD:'$',EUR:'€',GBP:'£'}[currency] || `${currency} `;
  const magnitude=Math.abs(amount);
  if(magnitude>0 && magnitude<.00000001)return symbol+(amount<0?'>-0.00000001':'<0.00000001');
  const digits=magnitude>0 && magnitude<.01?Math.min(8,Math.max(4,Math.ceil(-Math.log10(magnitude))+1)):2;
  return symbol+amount.toFixed(digits);
}
function readDeepSeekStatus(file,now=Date.now()) {
  let p; try { p = JSON.parse(fs.readFileSync(file,'utf8')); } catch { return {model:'等待 Harness',balance:'--',account:'等待账号数据',bonus:'--',connected:false,balanceFresh:false}; }
  const signedIn=p.accountStatus==='credential-stored',signedOut=p.accountStatus==='signed-out';
  const balanceAt=Date.parse(p.balanceFetchedAt || p.balanceUpdatedAt) || 0;
  const fresh=balanceAt>0 && now-balanceAt<=180000 && balanceAt-now<=5000;
  const ready=signedIn && p.balanceStatus==='ready' && fresh;
  const allWallets=(wallets,empty='--')=>{const values=(wallets || []).map(w=>walletLabel(w)).filter(x=>x!=='--');return values.join(' / ') || empty;};
  return {model:p.modelLabel || p.model || '等待模型',effort:p.reasoningEffort || null,
    provider:p.provider || 'DeepSeek Harness',balance:signedOut?'未登录':!signedIn?'--':ready?allWallets(p.balance):'暂不可读',
    bonus:ready?allWallets(p.bonusWallets,'暂无'):'--',account:signedIn?'已登录':signedOut?'未登录':'等待账号数据',
    connected:true,balanceStatus:p.balanceStatus || 'unavailable',balanceFresh:fresh,
    balanceUpdatedAt:p.balanceFetchedAt || p.balanceUpdatedAt || null,
    balanceDiagnostic:ready?'Harness 官方余额 · 60秒轮询':'官方余额未更新或读取失败',
    workspace:p.workspacePath?path.basename(p.workspacePath):'默认工作区'};
}

class DeepSeekScanner {
  constructor(root = path.join(os.homedir(),'.dsh','sessions'), status = path.join(dataDirectory(),'deepseek-status.json')) {
    this.root=root; this.status=status; this.cache = new Map();
  }
  scan(now=Date.now()) {
    const files = walk(this.root,n=>n==='session.v4.jsonl.zstd',now-8*DAY,64), seen = new Set(files.map(x=>x.file));
    let decoded = 0;
    for (const {file,stat} of files) {
      const old = this.cache.get(file); if (old?.mtime===stat.mtimeMs && old?.size===stat.size) continue;
      if (decoded++>=4 || stat.size>64*1024*1024) continue;
      try { this.cache.set(file,{mtime:stat.mtimeMs,size:stat.size,digest:digestDeepSeek(decodeZstd(fs.readFileSync(file)))}); } catch {}
    }
    for (const key of this.cache.keys()) if (!seen.has(key)) this.cache.delete(key);
    const entries=[...this.cache.values()],digests=entries.map(x=>x.digest).filter(d=>d.user);
    const active=digests.toSorted((a,b)=>b.eventAt-a.eventAt)[0];
    const historyStart=new Date(now);historyStart.setHours(0,0,0,0);historyStart.setDate(historyStart.getDate()-6);
    const totals={},models={},usageSeen=new Set();
    for(const sample of digests.flatMap(d=>d.samples)){
      if(sample.at<historyStart.getTime() || sample.at>now || usageSeen.has(sample.id))continue;
      usageSeen.add(sample.id);totals[sample.day]=(totals[sample.day]||0)+sample.tokens;
      models[sample.model] ??={model:sample.model,tokens:0,requests:0,requestsKnown:true};models[sample.model].tokens+=sample.tokens;models[sample.model].requests++;
    }
    const status=readDeepSeekStatus(this.status,now);
    return {...status,model:status.model.startsWith('等待') && active?active.model:status.model,
      tokenUsageKnown:active?.tokenUsageKnown || false,cacheUsageKnown:active?.cacheUsageKnown || false,
      contextPercent:active?.tokenUsageKnown && active.context?Math.min(100,active.last.total/active.context*100):null,
      cachePercent:active?.cacheUsageKnown && active.usage.input?Math.min(100,active.usage.cached/active.usage.input*100):null,
      contextIsEstimate:true,todayTokens:totals[dayKey(now)]||0,
      recentRequestCount:active?.tokenUsageKnown?usageSeen.size:null,requestCountIsLowerBound:true,
      metricsSource:'Harness v4 · 适配器返回的 usage',metricsUpdatedAt:active?.at || null,
      metricsDiagnostic:'最近7天本机根会话；未返回 usage 的尝试无法计入 Token。缓存命中分母含缓存创建；推理 Token 已包含在输出。上下文按最近响应总量估算，后续工具消息和压缩变化可能未反映。',
      history:Array.from({length:7},(_,i)=>{const date=new Date(historyStart);date.setDate(date.getDate()+i);const day=dayKey(date);return{day,tokens:totals[day]||0};}),models:Object.values(models).sort((a,b)=>b.tokens-a.tokens),
      remaining:null,quota:null,secondaryQuota:null,
      running:entries.some(x=>x.digest.running && now-x.mtime<600000),
      completion:entries.map(x=>x.digest.completion).filter(Boolean).sort((a,b)=>b.at-a.at)[0]||null,
      completionEvents:recentCompletionEvents(digests.flatMap(d=>d.completionEvents),now)};

  }
}
class CompletionGate {
  constructor() { this.primed = new Set(); this.seen = new Set(); }
  accept(assistant, notice, now=Date.now()) {
    if (!this.primed.has(assistant)) {
      this.primed.add(assistant); if (notice) this.seen.add(notice.id); return false;
    }
    if (!notice || this.seen.has(notice.id)) return false;
    this.seen.add(notice.id);
    if (this.seen.size>512) this.seen.delete(this.seen.values().next().value);
    return notice.at <= now+5000 && now-notice.at<=90000;
  }
}
module.exports = { CodexScanner, DeepSeekScanner, CompletionGate, consumeCodex, emptyDigest, digestDeepSeek, decodeZstd, dataDirectory, readDeepSeekStatus, walletLabel, effectiveQuota, recentCompletionEvents };
