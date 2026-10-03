'use strict';
const {app,BrowserWindow,ipcMain,screen,Tray,Menu,nativeImage,dialog,shell}=require('electron');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {Worker}=require('node:worker_threads');
const {Spring,layout,contains}=require('./lib/geometry.cjs');
const {CompletionQueue}=require('./lib/completion-queue.cjs');
const {sample,DURATION}=require('./lib/island-motion.cjs');
const {NativeWindows}=require('./lib/native.cjs');
const {ASSISTANTS,ASSISTANT_IDS,emptyRunning,emptyStatus,chooseAssistant}=require('./lib/assistants.cjs');
const {installIntegration}=require('./lib/integration.cjs');

const smoke=process.argv.includes('--smoke-test');
if (smoke) app.setPath('userData',fs.mkdtempSync(path.join(os.tmpdir(),'tokenlens-smoke-')));
if (!smoke && !app.requestSingleInstanceLock()) { app.quit(); }
else {
  let island,details,tray,worker,native,frame,displayId,workerTimer,motionTimer,foregroundTimer;
  let active='gpt', pinned=false, visible=true, lastHover=0, hover=false, completionUntil=0;
  let preferences,preferencesPath,motionStarted=null,motionFrom=0,motionFromWidth=0,motionFromHeight=0,systemReduceMotion=false,glow=0,glowAssistant=null,lastCanvas=null,lastSentFrame=null,canvasChanges=0;
  const defaults={motionStyle:'jelly',glow:true,noticeDuration:6,followSystemMotion:true,expandedPinned:false};
  let status=emptyStatus();
  let completion=null, running=emptyRunning();
  const spring=new Spring(),glowSpring=new Spring(0,1,18),offsetWidth=new Spring(),offsetHeight=new Spring(),queue=new CompletionQueue();
  function readPreferences(){
    preferencesPath=path.join(app.getPath('userData'),'island-preferences.json');
    let stored={};try{stored=JSON.parse(fs.readFileSync(preferencesPath,'utf8'));}catch{}
    preferences={...defaults};
    for(const key of Object.keys(defaults))if(validPreference(key,stored[key]))preferences[key]=stored[key];
  }
  function validPreference(key,value){return key==='motionStyle'?['subtle','balanced','jelly'].includes(value):key==='noticeDuration'?[6,10,14].includes(value):['glow','followSystemMotion','expandedPinned'].includes(key)&&typeof value==='boolean';}
  function savePreference(key,value){
    if(!validPreference(key,value))return;preferences[key]=value;
    try{fs.mkdirSync(path.dirname(preferencesPath),{recursive:true});fs.writeFileSync(preferencesPath,JSON.stringify(preferences,null,2));}catch{}
    if(key==='expandedPinned'&&value)setVisible(true);
    if(key==='noticeDuration'&&completion)completionUntil=Date.now()+value*1000;
    send();buildMenu();
  }
  function reduced(){return !!(preferences?.followSystemMotion && systemReduceMotion);}
  function chosenDisplay() { return screen.getAllDisplays().find(d=>d.id===displayId) || screen.getPrimaryDisplay(); }
  function state() { return {active:completion?.assistant||active,selected:active,...status,completion,glowAssistant,recent:queue.recent,pendingCount:queue.pending.length,preferences,reduceMotion:reduced(),version:app.getVersion(),nativeAvailable:native?.available || false}; }
  function send() {
    for (const win of [island,details]) if (win && !win.isDestroyed()) win.webContents.send('state',state());
  }
  function markUnavailable(message) {
    status=Object.fromEntries(ASSISTANT_IDS.map(id=>[id,{
      ...emptyStatus()[id],model:status[id]?.model || ASSISTANTS[id].waiting,
      metricsSource:status[id]?.metricsSource || '本机记录',error:message,
      metricsDiagnostic:`${message}；等待重新读取，不沿用旧的额度、余额和计数。`
    }]));
    send();
  }
  function beginNotice(notice) {
    completion=notice;completionUntil=Date.now()+preferences.noticeDuration*1000;
    motionFrom=spring.value;motionFromWidth=frame?.widthOffset||0;motionFromHeight=frame?.heightOffset||0;
    glowAssistant=notice.assistant;motionStarted=performance.now();setVisible(true);send();
  }
  function showPending() { if(!completion){const next=queue.next();if(next)beginNotice(next);} }
  function finishNotice() {
    offsetWidth.value=frame?.widthOffset||0;offsetHeight.value=frame?.heightOffset||0;
    offsetWidth.velocity=offsetHeight.velocity=0;offsetWidth.target=offsetHeight.target=0;
    completion=null;motionStarted=null;send();showPending();
  }
  function requestPreview(){
    const notice={id:`preview-${Date.now()}`,assistant:active,at:Date.now(),title:'动效预览',preview:true};
    if(completion){queue.preview(notice);send();}else beginNotice(notice);
  }
  function position(accent={},force=false) {
    if (!island || island.isDestroyed()) return;
    frame=layout(chosenDisplay().workArea,spring.value,{...accent,glow,reveal:accent.reveal??1,reduceMotion:reduced()});
    const bounds={x:frame.x,y:frame.y,width:frame.width,height:frame.height};
    const key=JSON.stringify(bounds);
    if(key!==lastCanvas){island.setBounds(bounds,false);lastCanvas=key;canvasChanges++;}
    const payload=JSON.stringify(frame);
    if(force || payload!==lastSentFrame){island.webContents.send('frame',frame);lastSentFrame=payload;}
  }
  function setVisible(next) {
    if (visible===next) return;
    visible=next;
    if (next) { position(); island.showInactive(); }
    else { island.hide(); spring.target=0; hover=false; }
  }
  function buildMenu() {
    if (!tray) return;
    const displays=screen.getAllDisplays();
    tray.setContextMenu(Menu.buildFromTemplate([
      {label:'查看用量详情',click:openDetails},
      {label:'固定展开',type:'checkbox',checked:preferences.expandedPinned,click:item=>savePreference('expandedPinned',item.checked)},
      {label:'预览完成动效',click:requestPreview},
      {label:'提醒与动效设置',click:openDetails},
      ...ASSISTANT_IDS.map(id=>({label:`${ASSISTANTS[id].name} 灵动岛`,type:'radio',checked:active===id,click:()=>{active=id;pinned=true;showPending();setVisible(true);send();buildMenu();}})),
      {label:'跟随正在使用的助手',type:'checkbox',checked:!pinned,click:()=>{pinned=false;pollForeground();buildMenu();}},
      {label:'显示器',submenu:displays.map((d,i)=>({label:`${d.label || `显示器 ${i+1}`} (${d.size.width} × ${d.size.height})`,type:'radio',checked:d.id===chosenDisplay().id,click:()=>{displayId=d.id;position();buildMenu();}}))},
      {type:'separator'},
      {label:'连接 DeepSeek Harness 状态',click:connectDeepSeek},
      {label:'开机启动',type:'checkbox',checked:app.getLoginItemSettings().openAtLogin,click:item=>app.setLoginItemSettings({openAtLogin:item.checked})},
      {label:visible?'隐藏灵动岛':'显示灵动岛',click:()=>{pinned=true;setVisible(!visible);buildMenu();}},
      {label:`TokenLens ${app.getVersion()}`,enabled:false},
      {label:'退出',click:()=>app.quit()}
    ]));
  }
  function pollForeground() {
    if (smoke) return;
    try {
      const observation=native.poll(); running=observation.running;
      if (!pinned) {
        const next=chooseAssistant(active,observation);
        if (next!==active) { active=next;showPending();send();buildMenu(); }
        setVisible(!!completion || preferences.expandedPinned || Object.values(running).some(Boolean) || !native.available);
      }
    } catch { /* Keep the last known foreground state through transient failures. */ }
  }
  function openDetails() {
    if (details && !details.isDestroyed()) { details.show();details.focus();return; }
    details=new BrowserWindow({width:850,height:640,minWidth:700,minHeight:540,title:'TokenLens · 用量详情',
      backgroundColor:'#14101d',autoHideMenuBar:true,icon:path.join(__dirname,'assets','icon.png'),
      webPreferences:{preload:path.join(__dirname,'preload.cjs'),contextIsolation:true,sandbox:true,nodeIntegration:false}});
    secureWindow(details);details.loadFile(path.join(__dirname,'index.html'),{query:{details:'1'}});
    details.on('closed',()=>{details=null;});
  }
  function secureWindow(win) {
    win.webContents.setWindowOpenHandler(()=>({action:'deny'}));
    win.webContents.on('will-navigate',event=>event.preventDefault());
    win.webContents.on('will-attach-webview',event=>event.preventDefault());
  }
  async function connectDeepSeek() {
    if (smoke) return;
    const source=app.isPackaged?path.join(process.resourcesPath,'tokenlens-dsh-status.mjs'):path.join(__dirname,'..','Integration','tokenlens-dsh-status.mjs');
    try {
      if (native.poll().running.dsh) {
        await dialog.showMessageBox({type:'info',title:'连接 DeepSeek Harness',message:'请先完全退出 DeepSeek Harness，再点一次「连接状态」。',detail:'Harness 退出后写入插件配置，可以避免正在运行的设置覆盖连接信息。'});return;
      }
      installIntegration(source);
      await dialog.showMessageBox({type:'info',title:'连接完成',message:'状态桥已安装。重新打开 DeepSeek Harness 后会自动同步余额；发送下一条消息后更新当前模型。'});
    } catch (error) { await dialog.showMessageBox({type:'error',title:'连接未完成',message:error.message}); }
  }
  async function act(name,event,value) {
    if (![island,details].some(w=>w && !w.isDestroyed() && w.webContents===event.sender)) return;
    if (name==='details') openDetails();
    else if (name==='close-details') details?.close();
    else if (name==='open-assistant') {
      const source=completion?.assistant||active;
      if (!native.activate(source) && !smoke) dialog.showMessageBox({type:'info',message:`请先打开 ${ASSISTANTS[source].appName}。`});
      if(completion)finishNotice();
    } else if(name==='dismiss-notice')finishNotice();
    else if(name==='pin-expanded')savePreference('expandedPinned',!preferences.expandedPinned);
    else if(name==='set-preference' && value && typeof value==='object')savePreference(value.key,value.value);
    else if(name==='preview-notice')requestPreview();
    else if(name==='open-recent'){const notice=queue.recent.find(n=>n.id===value?.id&&n.assistant===value?.assistant);if(notice && !native.activate(notice.assistant) && !smoke)dialog.showMessageBox({type:'info',message:`请先打开 ${ASSISTANTS[notice.assistant].appName}。`});}
    else if (name==='connect-dsh') await connectDeepSeek();
    else if (name==='refresh') worker?.postMessage('scan');
    else if (name.startsWith('select-') && ASSISTANTS[name.slice(7)]) { active=name.slice(7);showPending();send();buildMenu(); }
    else if (name==='open-balance') {
      const source=completion?.assistant||active;
      const link=source==='dsh'?'https://platform.deepseek.com/top_up':source==='gpt'?status.gpt.external?.recharge:null;
      if (!link) { openDetails();return; }
      if (link) { try { if (new URL(link).protocol==='https:') await shell.openExternal(link); } catch {} }
    }
  }
  async function smokeTest() {
    const output=process.env.TOKENLENS_SMOKE_OUTPUT || path.join(os.tmpdir(),'tokenlens-smoke-output');
    fs.mkdirSync(output,{recursive:true});
    try {
      const assertion=(value,message)=>{if(!value)throw new Error(message);};
      clearInterval(motionTimer);preferences.followSystemMotion=false;
      // Exercise the shipped native DLL binding in the packaged executable.
      const nativeState=native.poll();
      assertion(process.platform!=='win32' || native.available,'Win32 foreground API did not load');
      assertion(ASSISTANT_IDS.every(id=>typeof nativeState.running[id]==='boolean'),'Win32 window enumeration failed');
      status={...emptyStatus(),gpt:{model:'gpt-6-luna',remaining:26,contextPercent:23.4,cachePercent:89,todayTokens:64600000,tokenUsageKnown:true,cacheUsageKnown:true,running:true,history:[],models:[]},
        dsh:{model:'DeepSeek-V41-Flash',balance:'¥25.80',bonus:'¥1.00',account:'已登录',balanceFresh:true,connected:true},
        workbuddy:{model:'reported-workbuddy-model',remaining:null,todayTokens:12000,tokenUsageKnown:true,cacheUsageKnown:true,cachePercent:50,contextPercent:null},
        claude:{model:'模型未返回',remaining:null,tokenUsageKnown:false,contextPercent:null,cachePercent:null},
        codebuddy:{model:'reported-codebuddy-model',remaining:null,todayTokens:36000,tokenUsageKnown:true,cacheUsageKnown:true,cachePercent:62.5,contextPercent:null}};
      active='gpt';spring.value=1;spring.target=1;position();send();
      await new Promise(resolve=>setTimeout(resolve,300));
      const gpt=await island.webContents.executeJavaScript('window.tokenLensView()');
      assertion(gpt.model==='gpt-6-luna' && gpt.metric==='26%','GPT model/quota did not render');
      assertion(gpt.symmetry && gpt.expanded,'Expanded island lost its centre axis');
      fs.writeFileSync(path.join(output,'windows-gpt.png'),(await island.webContents.capturePage()).toPNG());
      active='dsh';completion={id:'smoke-complete',assistant:'dsh',title:'DeepSeek 已完成本轮任务'};glowAssistant='dsh';glow=.38;position();send();
      await new Promise(resolve=>setTimeout(resolve,200));
      const dsh=await island.webContents.executeJavaScript('window.tokenLensView()');
      assertion(dsh.metric==='¥25.80' && dsh.complete,'DSH balance/completion did not render');
      fs.writeFileSync(path.join(output,'windows-dsh.png'),(await island.webContents.capturePage()).toPNG());
      const additional={};
      completion=null;
      for (const id of ['workbuddy','claude','codebuddy']) {
        active=id;send();await new Promise(resolve=>setTimeout(resolve,150));
        const view=await island.webContents.executeJavaScript('window.tokenLensView()');
        assertion(view.model===(id==='claude'?'Claude · 模型未提供':status[id].model) && view.assistant===id && view.metric==='--' && view.symmetry,`${id} model/theme/unknown quota did not render`);
        if (id==='claude') assertion(view.today==='--' && view.cache==='--','Claude missing metrics displayed as zero');
        additional[id]=view;
        fs.writeFileSync(path.join(output,`windows-${id}.png`),(await island.webContents.capturePage()).toPNG());
      }
      // The packaged renderer and native window traverse the full material
      // timeline, then retain a stable surface and a click-through halo.
      active='gpt';completion={id:'smoke-background',assistant:'dsh',at:Date.now(),title:'DeepSeek 已完成本轮任务'};glowAssistant='dsh';send();
      const nativeBounds=island.getBounds(),changesBefore=canvasChanges,motionViews=[];
      for(const elapsed of [0,.21,.42,.55,.70,.94,1.16,1.90,2.40]){
        const accent=sample(elapsed);spring.value=accent.openingProgress;glow=Math.max(accent.glow,.38);position(accent);
        await new Promise(resolve=>setTimeout(resolve,60));
        const view=await island.webContents.executeJavaScript('window.tokenLensView()');motionViews.push({elapsed,...view});
        assertion(JSON.stringify(island.getBounds())===JSON.stringify(nativeBounds),'Completion moved/resized its native canvas');
        assertion(view.textWidth===nativeBounds.width-48,'Completion reflowed its text');
        assertion(Math.abs(view.surface[0]-frame.surfaceWidth)<.001 && Math.abs(view.surface[1]-frame.surfaceHeight)<.001,'Renderer did not retain the sampled material geometry');
        if(elapsed===.70)fs.writeFileSync(path.join(output,'windows-completion-peak.png'),(await island.webContents.capturePage()).toPNG());
        assertion(!contains(frame,{x:frame.x+2,y:frame.y+frame.height-2}),'Transparent glow padding intercepted clicks');
      }
      const held=motionViews.at(-1),previous=motionViews.at(-2);
      assertion(held.assistant==='dsh' && active==='gpt','Background completion did not use its real assistant source');
      assertion(held.surface.every((v,i)=>v===previous.surface[i]),'Held completion geometry did not settle');
      assertion(held.glow>=.38 && held.rimOpacity>=.34 && held.haloOpacity>0,'Software coloured edge did not remain visible');
      assertion(canvasChanges===changesBefore,'Completion invoked a native canvas resize');
      fs.writeFileSync(path.join(output,'windows-completion-held.png'),(await island.webContents.capturePage()).toPNG());
      systemReduceMotion=true;preferences.followSystemMotion=true;const calm=sample(.70,{reduceMotion:reduced()});
      spring.value=calm.openingProgress;glow=.38;position(calm);send();await new Promise(resolve=>setTimeout(resolve,80));
      const reduceMotion=await island.webContents.executeJavaScript('window.tokenLensView()');
      assertion(reduceMotion.reduceMotion && calm.heightOffset===0 && calm.widthOffset===0 && reduceMotion.glow===.38,'Reduced motion lost its static completion edge');
      completion=null;preferences.followSystemMotion=false;glowAssistant='dsh';glow=.20;send();position();await new Promise(resolve=>setTimeout(resolve,60));
      const fading=await island.webContents.executeJavaScript('window.tokenLensView()');
      assertion(fading.assistant==='gpt' && fading.glowAssistant==='dsh','Dismissed glow switched to the foreground colour during fade');
      fs.writeFileSync(path.join(output,'smoke.json'),JSON.stringify({passed:true,version:app.getVersion(),platform:process.platform,arch:process.arch,native:native.available,gpt,dsh,...additional,
        completionMotion:{nativeBounds,canvasChanges:canvasChanges-changesBefore,samples:motionViews,held,reduceMotion,fading,haloAcceptsClicks:false}},null,2));
      app.exit(0);
    } catch(error) { fs.writeFileSync(path.join(output,'smoke.json'),JSON.stringify({passed:false,error:error.message}));app.exit(1); }
  }
  app.whenReady().then(()=>{
    app.setAppUserModelId('cn.liuli.tokenlens');readPreferences();
    try { native=new NativeWindows(); } catch { native={available:false,poll:()=>({frontmost:null,running:emptyRunning()}),activate:()=>false}; }
    frame=layout(chosenDisplay().workArea,0);
    island=new BrowserWindow({x:frame.x,y:frame.y,width:frame.width,height:frame.height,frame:false,transparent:true,
      backgroundColor:'#00000000',resizable:false,movable:false,focusable:false,skipTaskbar:true,show:false,hasShadow:false,
      roundedCorners:false,webPreferences:{preload:path.join(__dirname,'preload.cjs'),contextIsolation:true,sandbox:true,nodeIntegration:false,backgroundThrottling:false}});
    lastCanvas=JSON.stringify({x:frame.x,y:frame.y,width:frame.width,height:frame.height});
    secureWindow(island);island.setAlwaysOnTop(true,'screen-saver');island.setIgnoreMouseEvents(true,{forward:true});
    island.loadFile(path.join(__dirname,'index.html'));
    island.once('ready-to-show',()=>{
      island.showInactive();position();send();pollForeground();
      if (smoke) void smokeTest();
    });
    if (!smoke) {
      tray=new Tray(nativeImage.createFromPath(path.join(__dirname,'assets','tray.png')));
      tray.setToolTip('TokenLens · 五款助手灵动岛');tray.on('double-click',openDetails);buildMenu();
      worker=new Worker(path.join(__dirname,'scanner-worker.cjs'));
      worker.on('message',data=>{
        if (data.error) {markUnavailable(data.error);return;}
        status={...emptyStatus(),...data};
        queue.consumeBatch(Object.fromEntries(ASSISTANT_IDS.map(assistant=>{
          const current=status[assistant],events=current?.completionEvents;
          return [assistant,events?.length?events:current?.completion?[current.completion]:[]];
        })));
        showPending();
        send();
      });
      worker.on('error',()=>markUnavailable('读取进程已停止，请从托盘退出后重新启动'));
      worker.postMessage('scan');workerTimer=setInterval(()=>worker.postMessage('scan'),2000);
      foregroundTimer=setInterval(pollForeground,500);
    }
    let last=performance.now();
    motionTimer=setInterval(()=>{
      const now=performance.now(),dt=Math.min(.1,(now-last)/1000);last=now;
      if (!smoke) {
        const pointer=screen.getCursorScreenPoint(),inside=visible && contains(frame,pointer);
        island.setIgnoreMouseEvents(!inside,{forward:true});
        if (inside) { lastHover=Date.now();hover=true; } else if (Date.now()-lastHover>190) hover=false;
        if (completion && Date.now()>completionUntil)finishNotice();
        spring.target=hover || preferences.expandedPinned || completion ? 1:0;
      }
      let accent={};
      if(completion && motionStarted!==null){
        const elapsed=(now-motionStarted)/1000;accent=sample(elapsed,{style:preferences.motionStyle,reduceMotion:reduced()});
        spring.value=motionFrom+(1-motionFrom)*accent.openingProgress;spring.velocity=0;
        accent.widthOffset+=motionFromWidth*(1-accent.openingProgress);accent.heightOffset+=motionFromHeight*(1-accent.openingProgress);
        if(elapsed>=DURATION)motionStarted=null;
      }else if(reduced()){spring.value=spring.target;spring.velocity=0;}
      else spring.step(dt);
      if(!completion){accent.widthOffset=offsetWidth.step(dt);accent.heightOffset=offsetHeight.step(dt);}
      glowSpring.target=preferences.glow && completion?Math.max(accent.glow||0,.38):0;
      glow=glowSpring.step(dt);
      if(!completion && glow<.005 && glowAssistant){glowAssistant=null;send();}
      position(accent);
    },16);
    screen.on('display-metrics-changed',()=>{position();buildMenu();});
    screen.on('display-removed',()=>{position();buildMenu();});
    screen.on('display-added',buildMenu);
    ipcMain.on('ready',event=>{if([island,details].some(w=>w&&!w.isDestroyed()&&w.webContents===event.sender)){send();position({},true);}});
    ipcMain.on('action',(event,name,value)=>{if(typeof name==='string')void act(name,event,value);});
    ipcMain.on('system-motion',(event,value)=>{if(event.sender===island.webContents && typeof value==='boolean'){systemReduceMotion=value;send();}});
  });
  app.on('second-instance',()=>{pinned=true;setVisible(true);openDetails();buildMenu();});
  app.on('window-all-closed',()=>{});
  app.on('before-quit',()=>{clearInterval(workerTimer);clearInterval(motionTimer);clearInterval(foregroundTimer);worker?.terminate();tray?.destroy();});
}
