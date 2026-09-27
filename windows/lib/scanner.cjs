'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { Decompress } = require('fzstd');

const DAY = 86400000;
function dayKey(time) { const d = new Date(time); return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`; }
function usage(raw = {}) {
  return { input: +raw.input_tokens || 0, cached: +raw.cached_input_tokens || 0,
    output: +raw.output_tokens || 0, total: +raw.total_tokens || 0 };
}
function emptyDigest() {
  return { id: '', user: true, model: '', provider: 'openai', total: usage(), last: usage(),
    days: {}, models: {}, quota: null, context: 0, at: 0, quotaAt: 0, running: false, completion: null };
}
function consumeCodex(d, event) {
  const p = event.payload || {}, at = Date.parse(event.timestamp) || 0;
  if (event.type === 'session_meta') {
    d.id = p.id || d.id; d.provider = p.model_provider || d.provider;
    d.user = (!p.thread_source || p.thread_source === 'user') && !(p.source && typeof p.source === 'object');
  } else if (event.type === 'turn_context') {
    if (typeof p.model === 'string') d.model = p.model;
    d.at = Math.max(d.at, at);
  } else if (event.type === 'event_msg') {
    if (p.type === 'task_started') {
      d.running = true; d.turn = p.turn_id || ''; d.context = +p.model_context_window || d.context;
      d.startedAt = p.started_at ? +p.started_at * 1000 : at; d.at = Math.max(d.at, at);
    } else if (p.type === 'turn_aborted') {
      d.running = false; d.turn = null; d.at = Math.max(d.at, at);
    } else if (p.type === 'task_complete') {
      const turn = p.turn_id || d.turn;
      if (d.user && d.id && turn) d.completion = {
        id: `${d.id}|${turn}`, at: p.completed_at ? +p.completed_at * 1000 : at, model: d.model,
        title: 'GPT 已完成本轮任务' };
      d.running = false; d.turn = null; d.at = Math.max(d.at, at);
    } else if (p.type === 'token_count' && p.info) {
      const total = usage(p.info.total_token_usage), delta = Math.max(0, total.total - d.total.total);
      if (at && delta) {
        const day = dayKey(at); d.days[day] = (d.days[day] || 0) + delta;
        const model = d.model || '未知模型'; d.models[model] = (d.models[model] || 0) + delta;
      }
      d.total = total; d.last = usage(p.info.last_token_usage); d.context = +p.info.model_context_window || d.context;
      const primary = p.rate_limits?.primary;
      if (primary && primary.used_percent != null && Number.isFinite(+primary.used_percent)) {
        d.quota = { used: Math.max(0, Math.min(100, +primary.used_percent)),
          resetsAt: +primary.resets_at * 1000 || null, windowMinutes: +primary.window_minutes || 0 };
        d.quotaAt = at;
      }
      d.at = Math.max(d.at, at);
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
    const quotaDigest = user.filter(d => d.quota).toSorted((a,b) => b.quotaAt - a.quotaAt)[0];
    const totals = {}, models = {};
    for (const d of all) {
      for (const [day,tokens] of Object.entries(d.days)) totals[day] = (totals[day] || 0) + tokens;
      for (const [model,tokens] of Object.entries(d.models)) models[model] = (models[model] || 0) + tokens;
    }
    const history = Array.from({length:7}, (_,i) => {
      const day = dayKey(now-(6-i)*DAY); return {day,tokens:totals[day] || 0};
    });
    return { model: active.model || '等待 GPT', provider: active.provider, remaining: quotaDigest ? 100-quotaDigest.quota.used : null,
      quota: quotaDigest?.quota || null, quotaAt: quotaDigest?.quotaAt || null,
      contextPercent: active.context ? active.last.total / active.context * 100 : null,
      cachePercent: active.last.input ? active.last.cached / active.last.input * 100 : null,
      todayTokens: totals[dayKey(now)] || 0, history, models: Object.entries(models).map(([model,tokens]) => ({model,tokens})).sort((a,b)=>b.tokens-a.tokens),
      running: user.some(d => d.running && now-d.at < 600000),
      completion: user.map(d=>d.completion).filter(Boolean).sort((a,b)=>b.at-a.at)[0] || null,
      files: files.length, updatedAt: active.at || null, error: files.length ? null : '等待本机 Codex 会话记录' };
  }
}

function digestDeepSeek(lines) {
  const d = { user: false, id: '', running: false, completion: null };
  for (const line of lines.split('\n')) {
    if (!/"(?:session|turn\/start|turn\/end)"/.test(line)) continue;
    let e; try { e = JSON.parse(line); } catch { continue; }
    if (e.type === 'session') { d.user = e.version === 4 && e.delegationDepth === 0; d.id = e.id; }
    else if (d.user && e.data?.turn != null) {
      if (e.type === 'turn/start') { d.running = true; d.turn = e.data.turn; }
      else if (e.type === 'turn/end') {
        if (e.data.reason?.kind === 'completed' && d.id && Number.isFinite(e.time)) {
          d.completion = {id: `dsh|${d.id}|${e.data.turn}`, at:e.time,title:'DeepSeek 已完成本轮任务'};
        }
        if (d.turn === e.data.turn) d.running = false;
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
  const symbol = {CNY:'¥',USD:'$',EUR:'€',GBP:'£'}[wallet.currency] || `${wallet.currency} `;
  return symbol + amount.toFixed(amount !== 0 && Math.abs(amount) < .01 ? 4 : 2);
}
function readDeepSeekStatus(file) {
  let p; try { p = JSON.parse(fs.readFileSync(file,'utf8')); } catch { return {model:'等待 Harness',balance:'--',account:'等待账号数据',bonus:'--',connected:false}; }
  const signedIn = p.accountStatus === 'credential-stored';
  const pick = wallets => wallets?.find(w=>w.currency==='CNY') || wallets?.[0];
  return { model: p.modelLabel || p.model || '等待模型', effort:p.reasoningEffort || null,
    balance: !signedIn ? '未登录' : p.balanceStatus === 'ready' ? walletLabel(pick(p.balance)) : '暂不可读',
    bonus: signedIn ? walletLabel(pick(p.bonusWallets),'暂无') : '--', account:signedIn?'已登录':'未登录',
    connected:true, balanceUpdatedAt:p.balanceUpdatedAt || null,
    workspace: p.workspacePath ? path.basename(p.workspacePath) : '默认工作区' };
}
class DeepSeekScanner {
  constructor(root = path.join(os.homedir(),'.dsh','sessions'), status = path.join(dataDirectory(),'deepseek-status.json')) {
    this.root=root; this.status=status; this.cache = new Map();
  }
  scan(now=Date.now()) {
    const files = walk(this.root,n=>n==='session.v4.jsonl.zstd',now-DAY,32), seen = new Set(files.map(x=>x.file));
    let decoded = 0;
    for (const {file,stat} of files) {
      const old = this.cache.get(file); if (old?.mtime===stat.mtimeMs && old?.size===stat.size) continue;
      if (decoded++>=4 || stat.size>64*1024*1024) continue;
      try { this.cache.set(file,{mtime:stat.mtimeMs,size:stat.size,digest:digestDeepSeek(decodeZstd(fs.readFileSync(file)))}); } catch {}
    }
    for (const key of this.cache.keys()) if (!seen.has(key)) this.cache.delete(key);
    const entries=[...this.cache.values()];
    return {...readDeepSeekStatus(this.status), running: entries.some(x=>x.digest.running && now-x.mtime<600000),
      completion: entries.map(x=>x.digest.completion).filter(Boolean).sort((a,b)=>b.at-a.at)[0] || null};
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
module.exports = { CodexScanner, DeepSeekScanner, CompletionGate, consumeCodex, emptyDigest, digestDeepSeek, decodeZstd, dataDirectory, readDeepSeekStatus, walletLabel };
