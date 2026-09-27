'use strict';
// A sandboxed renderer. All values from local logs are assigned as text, never HTML.
const $=id=>document.getElementById(id),details=new URLSearchParams(location.search).has('details');
if(details){document.body.classList.add('details');$('dashboard').hidden=false;}
let snapshot=null,geometry={width:280,height:36,neck:280,band:36,progress:0};
function number(n){if(!Number.isFinite(n))return '--';for(const [v,s]of [[1e9,'B'],[1e6,'M'],[1e3,'K']])if(Math.abs(n)>=v)return(n/v).toFixed(1).replace(/\.0$/,'')+s;return String(Math.round(n));}
function percent(n,digits=1){return Number.isFinite(n)?`${n.toFixed(digits).replace(/\.0$/,'')}%`:'--';}
function metric(s){const n=s.gpt.remaining;return s.active==='dsh'?s.dsh.balance:s.gpt.external?.balance||(Number.isFinite(n)&&n>0&&n<1?'<1%':percent(n,0));}
function lines(raw){const g=/^gpt-(\d+(?:\.\d+)?)(?:-(.+))?$/i.exec(raw);if(g)return[`GPT-${g[1]}`,(g[2]||'').replace(/-/g,' ').toUpperCase()];const d=/^deepseek[- ](.+)$/i.exec(raw);if(d)return['DeepSeek',d[1].replace(/-/g,' ').toUpperCase()];const w=raw.split(/[ -]+/);return[w[0],w.slice(1).join(' ')];}
function draw(frame){
  geometry=frame;const {width:w,height:h,neck:n,band:b}=frame, left=(w-n)/2,right=(w+n)/2;
  const body=Math.max(0,h-b),shoulder=Math.min(15,body/2),radius=Math.min(28,body/2),r=Math.min(13,b/2);
  let d;
  if(body<1)d=`M ${left} 0 H ${right} V ${b-r} Q ${right} ${b} ${right-r} ${b} H ${left+r} Q ${left} ${b} ${left} ${b-r} Z`;
  else d=`M ${left} 0 H ${right} V ${b-4} Q ${right} ${b} ${right+6} ${b} C ${right+15} ${b+shoulder/2} ${w} ${b} ${w} ${b+shoulder} V ${h-radius} Q ${w} ${h} ${w-radius} ${h} H ${radius} Q 0 ${h} 0 ${h-radius} V ${b+shoulder} C 0 ${b} ${left-15} ${b+shoulder/2} ${left-6} ${b} Q ${left} ${b} ${left} ${b-4} Z`;
  $('shape').setAttribute('viewBox',`0 0 ${w} ${h}`);$('silhouette').setAttribute('d',d);
  $('crown').style.width=`${n}px`;document.body.classList.toggle('expanded',frame.progress>.45);
}
function element(tag,text,className){const node=document.createElement(tag);if(text!=null)node.textContent=text;if(className)node.className=className;return node;}
function update(s){
  snapshot=s;const dsh=s.active==='dsh',current=dsh?s.dsh:s.gpt,value=metric(s),[primary,secondary]=lines(current.model||'等待模型');
  document.body.classList.toggle('dsh',dsh);document.body.classList.toggle('running',!!current.running&&!s.completion);document.body.classList.toggle('complete',!!s.completion);
  $('modelPrimary').textContent=primary;$('modelSecondary').textContent=secondary;$('compactMetric').textContent=value;
  $('expandedModel').textContent=current.model;$('bigMetric').textContent=dsh?value:s.gpt.external?.balance||percent(current.remaining);
  const label=dsh||s.gpt.external?'可用余额':'剩余额度';$('metricLabel').textContent=label;
  const taskState=s.completion?'本轮任务已完成':current.running?'正在处理任务':dsh&&!current.connected?'等待连接 Harness':'随时待命';$('taskState').textContent=taskState;
  const stats=dsh?[[current.account,'账号'],[current.bonus,'赠送额度'],[current.effort||'--','推理强度']]:[[number(current.todayTokens),'今日 Token'],[percent(current.contextPercent),'上下文'],[percent(current.cachePercent),'缓存命中']];
  for(const[i,name]of ['One','Two','Three'].entries()){$(`stat${name}`).textContent=stats[i][0];$(`label${name}`).textContent=stats[i][1];}
  $('returnButton').textContent=`↗ 返回 ${dsh?'DSH':'GPT'}`;
  if(!details)return;
  $('version').textContent=`v${s.version}`;$('detailProvider').textContent=dsh?'DEEPSEEK HARNESS':current.external?.provider||'CODEX / GPT';
  $('detailModel').textContent=current.model;$('detailState').textContent=taskState;$('detailMetric').textContent=value;$('detailMetricLabel').textContent=label;
  $('detailStats').replaceChildren(...stats.map(([value,label])=>{const node=element('div');node.append(element('strong',value),element('span',label));return node;}));
  $('historyCard').hidden=dsh;$('modelsCard').hidden=dsh;$('dshCard').hidden=!dsh;
  if(dsh){$('dshHelp').textContent=current.connected?`已连接 · ${current.workspace||'默认工作区'}。余额更新时间：${current.balanceUpdatedAt?new Date(current.balanceUpdatedAt).toLocaleTimeString():'等待同步'}。`:'先启动一次 Harness，再完全退出，从这里连接状态桥。重新启动后会自动读取余额。';}
  else{
    const history=current.history||[],max=Math.max(1,...history.map(x=>x.tokens));
    $('history').replaceChildren(...history.map(x=>{const day=element('div',null,'day'),bar=element('div',null,'bar');bar.style.height=`${Math.max(2,x.tokens/max*87)}px`;day.append(element('span',number(x.tokens)),bar,element('span',x.day.slice(5)));return day;}));
    const models=current.models||[],top=Math.max(1,...models.map(x=>x.tokens));
    $('models').replaceChildren(...models.slice(0,6).map(x=>{const row=element('div',null,'modelRow'),track=element('div',null,'track'),fill=element('div',null,'fill');fill.style.width=`${x.tokens/top*100}%`;track.append(fill);row.append(element('span',x.model),track,element('strong',number(x.tokens)));return row;}));
    if(!models.length)$('models').append(element('p','发送一条消息后，这里会显示本机记录中的模型用量。','muted'));
  }
  $('dataNote').textContent=dsh?'状态桥只同步模型、余额和工作区名称。登录凭据保留在 Harness 中。':`额度来自本机 Codex 日志，随消息更新${current.quotaAt?` · 上次更新 ${new Date(current.quotaAt).toLocaleTimeString()}`:''}。普通 ChatGPT 网页或独立聊天客户端未提供这些本机记录时显示「--」。`;
}
document.addEventListener('click',event=>{const button=event.target.closest('[data-action]');if(button)window.tokenLens.action(button.dataset.action);});
window.tokenLens.onState(update);window.tokenLens.onFrame(draw);
// Used by the packaged CI smoke test; no IPC or filesystem access is exposed.
window.tokenLensView=()=>({model:$('expandedModel').textContent,metric:$('compactMetric').textContent,expanded:document.body.classList.contains('expanded'),complete:document.body.classList.contains('complete'),symmetry:Math.abs((geometry.width-geometry.neck)/2-(geometry.width-(geometry.width+geometry.neck)/2))<.001});
