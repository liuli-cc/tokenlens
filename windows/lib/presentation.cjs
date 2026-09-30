'use strict';
(function(root){
  const names={gpt:'GPT',dsh:'DSH',workbuddy:'WorkBuddy',claude:'Claude',codebuddy:'CodeBuddy'};
  function number(n){if(!Number.isFinite(n))return '--';for(const [v,s] of [[1e9,'B'],[1e6,'M'],[1e3,'K']])if(Math.abs(n)>=v)return(n/v).toFixed(1).replace(/\.0$/,'')+s;return String(Math.round(n));}
  function percent(n,digits=1){return Number.isFinite(n)?`${n.toFixed(digits).replace(/\.0$/,'')}%`:'--';}
  function fresh(at,age,now){const timestamp=typeof at==='number'?at:Date.parse(at);return Number.isFinite(timestamp) && timestamp>0 && now-timestamp<=age && timestamp-now<=5000;}
  function metric(state,compact=true,now=Date.now()){
    const current=state[state.active]||{};
    if(state.active==='dsh')return current.balanceFresh===false || current.balanceUpdatedAt && !fresh(current.balanceUpdatedAt,180000,now)?'--':current.balance||'--';
    if(state.active==='gpt' && current.external?.balance) return current.external.balanceFresh===false || current.external.balanceUpdatedAt && !fresh(current.external.balanceUpdatedAt,180000,now)?'--':current.external.balance;
    if(current.balance && current.balance!=='--' && current.balanceFresh!==false)return current.balance;
    if(current.quotaAt && !fresh(current.quotaAt,900000,now))return '--';
    if(current.effectiveQuota?.resetsAt && current.effectiveQuota.resetsAt<=now)return '--';
    const remaining=current.remaining;
    return compact && Number.isFinite(remaining) && remaining>0 && remaining<1?'<1%':percent(remaining,compact?0:1);
  }
  function stats(current){
    const context=percent(current.contextPercent);
    return [[current.tokenUsageKnown===false?'--':number(current.todayTokens),'今日 Token'],
      [Number.isFinite(current.contextPercent) && current.contextIsEstimate?`≈${context}`:context,'上下文'],
      [current.cacheUsageKnown===false?'--':percent(current.cachePercent),'缓存命中']];
  }
  function windows(current,now=Date.now()){
    return [current.quota,current.secondaryQuota].filter(Boolean).map(q=>({
      label:q.windowMinutes>=1440?`${number(q.windowMinutes/1440)} 天额度`:q.windowMinutes?`${number(q.windowMinutes/60)} 小时额度`:'额度窗口',
      value:current.quotaAt && !fresh(current.quotaAt,900000,now) || q.resetsAt && q.resetsAt<=now?'--':percent(q.remaining),resetsAt:q.resetsAt
    }));
  }
  const api={names,number,percent,metric,stats,windows};
  if(typeof module==='object' && module.exports)module.exports=api;else root.tokenLensPresentation=api;
})(typeof globalThis!=='undefined'?globalThis:this);
