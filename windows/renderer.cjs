'use strict';
// A sandboxed renderer. All values from local logs are assigned as text, never HTML.
const $=id=>document.getElementById(id),details=new URLSearchParams(location.search).has('details');
if(details){document.body.classList.add('details');$('dashboard').hidden=false;}
let snapshot=null,geometry={width:280,height:36,neck:280,band:36,progress:0};
const {names,number,percent,metric,stats,windows}=window.tokenLensPresentation;
function time(at){return at && Number.isFinite(new Date(at).getTime())?new Date(at).toLocaleString(): '未提供';}
function lines(raw){const g=/^gpt-(\d+(?:\.\d+)?)(?:-(.+))?$/i.exec(raw);if(g)return[`GPT-${g[1]}`,(g[2]||'').replace(/-/g,' ').toUpperCase()];const d=/^deepseek[- ](.+)$/i.exec(raw);if(d)return['DeepSeek',d[1].replace(/-/g,' ').toUpperCase()];const w=raw.split(/[ -]+/);return[w[0],w.slice(1).join(' ')];}
function draw(frame){
  geometry=frame;const {width:w,height:h,neck:n}=frame,d=window.tokenLensGeometry.silhouette(frame);
  $('shape').setAttribute('viewBox',`0 0 ${w} ${h}`);
  for(const id of ['silhouette','clipSilhouette','neutralEdge','edgeHalo','edgeStroke'])$(id).setAttribute('d',d);
  $('crown').style.width=`${n}px`;$('body').style.width=`${w-48}px`;
  $('edgeStroke').setAttribute('opacity',String((frame.glow||0)*.92));
  $('edgeHalo').setAttribute('opacity',String((frame.glow||0)*.78));
  const reveal=snapshot?.completion?(frame.reveal??1):Math.max(0,Math.min(1,(frame.progress-.3)/.3));
  $('body').style.opacity=String(reveal);
  $('activity').style.transform=`translateY(${frame.iconLift||0}px) scale(${1+(frame.iconSquash||0)},${1-(frame.iconSquash||0)})`;
  document.body.classList.toggle('expanded',frame.progress>.45);
  document.body.classList.toggle('reduceMotion',!!frame.reduceMotion);
}
function element(tag,text,className){const node=document.createElement(tag);if(text!=null)node.textContent=text;if(className)node.className=className;return node;}
function update(s){
  snapshot=s;const id=s.active,dsh=id==='dsh',current=s[id]||{},value=metric(s),modelKnown=current.model&&!/模型未|未提供模型|等待/.test(current.model),[primary,secondary]=modelKnown?lines(current.model):[names[id],'模型未提供'];
  const colors={gpt:['#cd91ff','#eba5ec'],dsh:['#93baff','#c1a3ff'],workbuddy:['#83dcda','#a6e9f1'],claude:['#e6a48e','#f1c1aa'],codebuddy:['#b9a0ff','#99dce7']},edge=colors[s.glowAssistant||id]||colors.gpt;
  document.documentElement.style.setProperty('--glow-accent',edge[0]);document.documentElement.style.setProperty('--glow-end',edge[1]);
  for(const assistant of Object.keys(names))document.body.classList.toggle(assistant,assistant===id);
  document.body.classList.toggle('running',!!current.running&&!s.completion);document.body.classList.toggle('complete',!!s.completion);
  $('modelPrimary').textContent=primary;$('modelSecondary').textContent=secondary;$('compactMetric').textContent=value;
  $('expandedModel').textContent=modelKnown?current.model:`${names[id]} · 模型未提供`;$('bigMetric').textContent=metric(s,false);
  const label=dsh || current.external?.balance || current.balance && current.balance!=='--'?'可用余额':'剩余额度';$('metricLabel').textContent=label;
  const taskState=s.completion?(s.completion.preview?'动效预览':s.completion.title||'本轮任务已完成'):current.running?'正在处理任务':dsh&&!current.connected?'等待连接 Harness':current.error?'暂不可读':'随时待命';$('taskState').textContent=taskState;
  const summary=stats(current);
  for(const[i,name]of ['One','Two','Three'].entries()){$(`stat${name}`).textContent=summary[i][0];$(`label${name}`).textContent=summary[i][1];}
  $('returnButton').textContent=`↗ 返回 ${names[id]||id}`;
  $('dismissButton').hidden=!s.completion;$('pinButton').classList.toggle('selected',!!s.preferences?.expandedPinned);
  $('pinButton').textContent=s.preferences?.expandedPinned?'取消固定':'固定';
  document.body.classList.toggle('reduceMotion',!!s.reduceMotion);
  if(s.completion)$('crown').setAttribute('aria-label',`${names[id]} 任务完成，点击返回对应软件`);
  else $('crown').setAttribute('aria-label',`${names[id]} 用量`);
  if(!details)return;
  document.querySelectorAll('[data-assistant]').forEach(tab=>tab.setAttribute('aria-selected',String(tab.dataset.assistant===id)));
  $('version').textContent=`v${s.version}`;$('detailProvider').textContent=current.external?.provider||current.source||names[id];
  $('detailModel').textContent=current.model||'未提供模型';$('detailState').textContent=taskState;$('detailMetric').textContent=value;$('detailMetricLabel').textContent=label;
  const calls=current.recentRequestCount==null?'--':`${current.requestCountIsLowerBound?'≥':''}${number(current.recentRequestCount)}`;
  const detailed=[...summary,[calls,`${id==='gpt'||id==='dsh'?'近 7 天':'近 24 小时'}调用 · 已记录`]];
  $('detailStats').replaceChildren(...detailed.map(([value,label])=>{const node=element('div');node.append(element('strong',value),element('span',label));return node;}));
  $('quotaWindows').replaceChildren(...windows(current).map(q=>{
    const node=element('span');node.append(element('span',`${q.label} `),element('strong',q.value),element('span',` · 重置 ${time(q.resetsAt)}`));return node;
  }));
  const history=current.history||[],max=Math.max(1,...history.map(x=>x.tokens));
  $('historyCard').hidden=!history.length;
  $('history').replaceChildren(...history.map(x=>{const day=element('div',null,'day'),bar=element('div',null,'bar');bar.style.height=`${Math.max(2,x.tokens/max*87)}px`;day.append(element('span',number(x.tokens)),bar,element('span',x.day.slice(5)));return day;}));
  const models=current.models||[],top=Math.max(1,...models.map(x=>x.tokens));
  $('modelsCard').hidden=!models.length;
  $('models').replaceChildren(...models.slice(0,6).map(x=>{const row=element('div',null,'modelRow'),track=element('div',null,'track'),fill=element('div',null,'fill');fill.style.width=`${x.tokens/top*100}%`;track.append(fill);row.append(element('span',x.model),track,element('strong',number(x.tokens)));return row;}));
  $('dshCard').hidden=!dsh;
  if(dsh)$('dshHelp').textContent=current.connected?`已连接。余额更新时间：${time(current.balanceUpdatedAt)}。${current.balanceFresh===false?'余额已过期，等待状态桥刷新。':''}`:'先启动一次 Harness，再完全退出，从这里连接状态桥。重新启动后会自动读取余额。';
  const notes=[`来源：${current.metricsSource||current.source||'软件未提供可读记录'} · 用量记录：${time(current.metricsUpdatedAt||current.lastAt)}`];
  if(current.metricsDiagnostic)notes.push(current.metricsDiagnostic);
  if(current.limitations?.length)notes.push(...current.limitations);
  if(id==='gpt')notes.push(`订阅额度仅采用 Codex 官方记录 · 上次更新：${time(current.quotaAt)}。超过 15 分钟或重置后等待新记录，不沿用旧额度。`);
  if(current.quotaLimitName)notes.push(`账户额度类型：${current.quotaLimitName}`);
  if(current.external?.balance)notes.push(`配置账户 ${current.external.provider} 的官方余额 · 更新时间：${time(current.external.balanceUpdatedAt)}`);
  if(current.configuredBalance)notes.push(`配置账户 ${current.configuredBalance.provider} 余额：${current.configuredBalance.balance} · ${time(current.configuredBalance.balanceUpdatedAt)}；尚无法归因到当前会话，不作为顶部余额。`);
  if(current.contextUpdatedAt)notes.push(`软件报告的上下文时间：${time(current.contextUpdatedAt)}`);
  if(dsh)notes.push('余额来自 Harness 账号接口；超过 3 分钟未刷新显示 --。');
  $('dataNote').textContent=notes.join('\n');
  $('queuedCount').textContent=s.pendingCount?`${s.pendingCount} 条等待提醒`:'';
  $('notices').replaceChildren(...(s.recent||[]).map(notice=>{
    const button=element('button',null,'noticeRow');button.dataset.action='open-recent';button.dataset.noticeId=notice.id;button.dataset.noticeAssistant=notice.assistant;
    button.append(element('strong',names[notice.assistant]||notice.assistant),element('span',notice.title),element('time',time(notice.at)));return button;
  }));
  if(!s.recent?.length)$('notices').append(element('p','暂无新的完成提醒','muted'));
  const preferences=s.preferences||{};$('motionStyle').value=preferences.motionStyle||'jelly';$('noticeDuration').value=String(preferences.noticeDuration||6);
  $('glowPreference').checked=preferences.glow!==false;$('followSystemMotion').checked=preferences.followSystemMotion!==false;$('expandedPinned').checked=!!preferences.expandedPinned;
}
document.addEventListener('click',event=>{const button=event.target.closest('[data-action]');if(button)window.tokenLens.action(button.dataset.action,button.dataset.action==='open-recent'?{id:button.dataset.noticeId,assistant:button.dataset.noticeAssistant}:undefined);});
document.addEventListener('change',event=>{const input=event.target,key=input.dataset.preference;if(!key)return;const value=input.type==='checkbox'?input.checked:key==='noticeDuration'?Number(input.value):input.value;window.tokenLens.action('set-preference',{key,value});});
window.tokenLens.onState(update);window.tokenLens.onFrame(draw);
const media=matchMedia('(prefers-reduced-motion: reduce)');
if(!details){window.tokenLens.systemMotion(media.matches);media.addEventListener('change',event=>window.tokenLens.systemMotion(event.matches));}
// Expire sampled values even during a stalled/background reader.
setInterval(()=>{if(snapshot)update(snapshot);},5000);
// Used by the packaged CI smoke test; no IPC or filesystem access is exposed.
window.tokenLensView=()=>({assistant:snapshot?.active,today:$('statOne').textContent,cache:$('statThree').textContent,model:$('expandedModel').textContent,metric:$('compactMetric').textContent,expanded:document.body.classList.contains('expanded'),complete:document.body.classList.contains('complete'),symmetry:Math.abs((geometry.width-geometry.surfaceWidth)/2-geometry.surfaceX)<.001,canvas:[geometry.width,geometry.height],surface:[geometry.surfaceWidth,geometry.surfaceHeight],glow:geometry.glow||0,glowAssistant:snapshot?.glowAssistant,rimOpacity:Number($('edgeStroke').getAttribute('opacity')||0),haloOpacity:Number($('edgeHalo').getAttribute('opacity')||0),reduceMotion:document.body.classList.contains('reduceMotion'),textWidth:$('body').getBoundingClientRect().width});
