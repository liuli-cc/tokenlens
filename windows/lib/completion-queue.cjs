'use strict';

// First observation establishes each source's startup cutoff. Foreground and
// metric changes never manufacture success. Accepted notices have a separate
// retention window so a later scan cannot erase an in-flight notification.
class CompletionQueue {
  constructor({pendingLimit=128,historyLimit=20,retention=600000}={}){
    this.baselines=new Map();this.seen=new Set();this.pending=[];this.recent=[];
    this.pendingLimit=Math.max(1,pendingLimit);this.historyLimit=Math.max(1,historyLimit);this.retention=retention;
  }
  eligible(assistant,events,now) {
    if(!['gpt','dsh'].includes(assistant))return [];
    const batch=(Array.isArray(events)?events:[]).filter(e=>e&&typeof e.id==='string'&&e.id&&Number.isFinite(e.at));
    if(!this.baselines.has(assistant)){
      for(const e of batch)this.remember(`${assistant}|${e.id}`);
      this.baselines.set(assistant,Math.floor(now/1000)*1000);return [];
    }
    return batch.filter(e=>{
      const key=`${assistant}|${e.id}`;
      if(this.seen.has(key)||this.pending.some(n=>n.id===e.id&&n.assistant===assistant)||this.recent.some(n=>n.id===e.id&&n.assistant===assistant))return false;
      if(e.at<this.baselines.get(assistant)||now-e.at>90000||e.at-now>5000)return false;
      this.remember(key);return true;
    }).map(e=>({...e,assistant,title:typeof e.title==='string'?e.title:'本轮任务已完成',observedAt:now}));
  }
  consume(assistant,events,now=Date.now()){return this.append(this.eligible(assistant,events,now),now);}
  consumeBatch(eventsByAssistant,now=Date.now()){
    return this.append(Object.entries(eventsByAssistant).flatMap(([assistant,events])=>this.eligible(assistant,events,now)),now);
  }
  append(events,now){
    this.pending=this.pending.filter(n=>now-(n.observedAt||now)<=this.retention);
    const accepted=events.sort((a,b)=>a.at-b.at||a.assistant.localeCompare(b.assistant)||a.id.localeCompare(b.id));
    this.pending.push(...accepted);if(this.pending.length>this.pendingLimit)this.pending.splice(0,this.pending.length-this.pendingLimit);
    this.recent=[...accepted,...this.recent].sort((a,b)=>b.at-a.at).slice(0,this.historyLimit);
    return accepted;
  }
  preview(notice){this.pending.push({...notice,observedAt:Date.now()});if(this.pending.length>this.pendingLimit)this.pending.shift();}
  remember(key){this.seen.add(key);if(this.seen.size>4096)this.seen.delete(this.seen.values().next().value);}
  next(now=Date.now()){this.pending=this.pending.filter(n=>now-(n.observedAt||now)<=this.retention);return this.pending.shift()||null;}
}
module.exports={CompletionQueue};
