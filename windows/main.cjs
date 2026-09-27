'use strict';
const {app,BrowserWindow,ipcMain,screen,Tray,Menu,nativeImage,dialog,shell}=require('electron');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {Worker}=require('node:worker_threads');
const {Spring,layout,contains}=require('./lib/geometry.cjs');
const {CompletionGate}=require('./lib/scanner.cjs');
const {NativeWindows}=require('./lib/native.cjs');
const {installIntegration}=require('./lib/integration.cjs');

const smoke=process.argv.includes('--smoke-test');
if (smoke) app.setPath('userData',fs.mkdtempSync(path.join(os.tmpdir(),'tokenlens-smoke-')));
if (!smoke && !app.requestSingleInstanceLock()) { app.quit(); }
else {
  let island,details,tray,worker,native,frame,displayId,workerTimer,motionTimer,foregroundTimer;
  let active='gpt', pinned=false, visible=true, lastHover=0, hover=false, completionUntil=0;
  let status={gpt:{model:'等待 GPT',remaining:null,history:[],models:[],running:false},dsh:{model:'等待 Harness',balance:'--',bonus:'--',account:'等待账号数据',connected:false}};
  let completion=null, running={gpt:false,dsh:false};
  const pendingCompletions=new Map();
  const spring=new Spring(),gate=new CompletionGate();
  function chosenDisplay() { return screen.getAllDisplays().find(d=>d.id===displayId) || screen.getPrimaryDisplay(); }
  function state() { return {active,...status,completion,version:app.getVersion(),nativeAvailable:native?.available || false}; }
  function send() {
    for (const win of [island,details]) if (win && !win.isDestroyed()) win.webContents.send('state',state());
  }
  function showPending() {
    const pending=pendingCompletions.get(active);
    if (pending && Date.now()-pending.at<90000) {
      completion={...pending,assistant:active};completionUntil=Date.now()+4000;
      pendingCompletions.delete(active);
    } else if (completion?.assistant && completion.assistant!==active) completion=null;
  }
  function position() {
    if (!island || island.isDestroyed()) return;
    frame=layout(chosenDisplay().workArea,spring.value);
    const bounds={x:frame.x,y:frame.y,width:frame.width,height:frame.height};
    const old=island.getBounds();
    if (Object.keys(bounds).some(k=>bounds[k]!==old[k])) island.setBounds(bounds,false);
    island.webContents.send('frame',{width:frame.width,height:frame.height,neck:frame.neck,band:frame.band,progress:frame.progress});
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
      {label:'GPT 灵动岛',type:'radio',checked:active==='gpt',click:()=>{active='gpt';pinned=true;showPending();setVisible(true);send();buildMenu();}},
      {label:'DSH 灵动岛',type:'radio',checked:active==='dsh',click:()=>{active='dsh';pinned=true;showPending();setVisible(true);send();buildMenu();}},
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
        const next=observation.frontmost || (running.dsh && !running.gpt?'dsh':running.gpt && !running.dsh?'gpt':active);
        if (next!==active) { active=next;showPending();send();buildMenu(); }
        setVisible(running.gpt || running.dsh || !native.available);
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
  async function act(name,event) {
    if (![island,details].some(w=>w && !w.isDestroyed() && w.webContents===event.sender)) return;
    if (name==='details') openDetails();
    else if (name==='close-details') details?.close();
    else if (name==='open-assistant') {
      if (!native.activate(active) && !smoke) dialog.showMessageBox({type:'info',message:`请先打开 ${active==='gpt'?'Codex / GPT 桌面端':'DeepSeek Harness'}。`});
    } else if (name==='connect-dsh') await connectDeepSeek();
    else if (name==='refresh') worker?.postMessage('scan');
    else if (name==='select-gpt' || name==='select-dsh') { active=name.slice(7);showPending();send();buildMenu(); }
    else if (name==='open-balance') {
      const link=active==='dsh'?'https://platform.deepseek.com/top_up':status.gpt.external?.recharge;
      if (link) { try { if (new URL(link).protocol==='https:') await shell.openExternal(link); } catch {} }
    }
  }
  async function smokeTest() {
    const output=process.env.TOKENLENS_SMOKE_OUTPUT || path.join(os.tmpdir(),'tokenlens-smoke-output');
    fs.mkdirSync(output,{recursive:true});
    try {
      const assertion=(value,message)=>{if(!value)throw new Error(message);};
      // Exercise the shipped native DLL binding in the packaged executable.
      const nativeState=native.poll();
      assertion(process.platform!=='win32' || native.available,'Win32 foreground API did not load');
      assertion(typeof nativeState.running.gpt==='boolean','Win32 window enumeration failed');
      status={gpt:{model:'gpt-6-luna',remaining:26,contextPercent:23.4,cachePercent:89,todayTokens:64600000,running:true,history:[],models:[]},
        dsh:{model:'DeepSeek-V41-Flash',balance:'¥25.80',bonus:'¥1.00',account:'已登录',connected:true}};
      active='gpt';spring.value=1;spring.target=1;position();send();
      await new Promise(resolve=>setTimeout(resolve,300));
      const gpt=await island.webContents.executeJavaScript('window.tokenLensView()');
      assertion(gpt.model==='gpt-6-luna' && gpt.metric==='26%','GPT model/quota did not render');
      assertion(gpt.symmetry && gpt.expanded,'Expanded island lost its centre axis');
      fs.writeFileSync(path.join(output,'windows-gpt.png'),(await island.webContents.capturePage()).toPNG());
      active='dsh';completion={id:'smoke-complete',title:'DeepSeek 已完成本轮任务'};send();
      await new Promise(resolve=>setTimeout(resolve,200));
      const dsh=await island.webContents.executeJavaScript('window.tokenLensView()');
      assertion(dsh.metric==='¥25.80' && dsh.complete,'DSH balance/completion did not render');
      fs.writeFileSync(path.join(output,'windows-dsh.png'),(await island.webContents.capturePage()).toPNG());
      fs.writeFileSync(path.join(output,'smoke.json'),JSON.stringify({passed:true,version:app.getVersion(),platform:process.platform,arch:process.arch,native:native.available,gpt,dsh},null,2));
      app.exit(0);
    } catch(error) { fs.writeFileSync(path.join(output,'smoke.json'),JSON.stringify({passed:false,error:error.message}));app.exit(1); }
  }
  app.whenReady().then(()=>{
    app.setAppUserModelId('cn.liuli.tokenlens');
    try { native=new NativeWindows(); } catch { native={available:false,poll:()=>({frontmost:null,running:{gpt:false,dsh:false}}),activate:()=>false}; }
    frame=layout(chosenDisplay().workArea,0);
    island=new BrowserWindow({x:frame.x,y:frame.y,width:frame.width,height:frame.height,frame:false,transparent:true,
      backgroundColor:'#00000000',resizable:false,movable:false,focusable:false,skipTaskbar:true,show:false,hasShadow:false,
      roundedCorners:false,webPreferences:{preload:path.join(__dirname,'preload.cjs'),contextIsolation:true,sandbox:true,nodeIntegration:false,backgroundThrottling:false}});
    secureWindow(island);island.setAlwaysOnTop(true,'screen-saver');island.setIgnoreMouseEvents(true,{forward:true});
    island.loadFile(path.join(__dirname,'index.html'));
    island.once('ready-to-show',()=>{
      island.showInactive();position();send();pollForeground();
      if (smoke) void smokeTest();
    });
    if (!smoke) {
      tray=new Tray(nativeImage.createFromPath(path.join(__dirname,'assets','tray.png')));
      tray.setToolTip('TokenLens · GPT / DSH 灵动岛');tray.on('double-click',openDetails);buildMenu();
      worker=new Worker(path.join(__dirname,'scanner-worker.cjs'));
      worker.on('message',data=>{
        if (data.error) return;
        status=data;
        for (const assistant of ['gpt','dsh']) {
          if (gate.accept(assistant,status[assistant].completion)) {
            // Completion from a background assistant does not displace the
            // foreground island; retain it briefly until that assistant is used.
            pendingCompletions.set(assistant,status[assistant].completion);
          }
        }
        showPending();
        send();
      });
      worker.on('error',()=>{status.gpt.error='读取进程已停止，请从托盘退出后重新启动';send();});
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
        if (completion && Date.now()>completionUntil) {completion=null;send();}
        spring.target=hover || (completion && visible) ? 1:0;
      }
      if (spring.value!==spring.target || spring.velocity!==0) {spring.step(dt);position();}
    },16);
    screen.on('display-metrics-changed',()=>{position();buildMenu();});
    screen.on('display-removed',()=>{position();buildMenu();});
    screen.on('display-added',buildMenu);
    ipcMain.on('ready',event=>{send();position();});
    ipcMain.on('action',(event,name)=>{void act(name,event);});
  });
  app.on('second-instance',()=>{pinned=true;setVisible(true);openDetails();buildMenu();});
  app.on('window-all-closed',()=>{});
  app.on('before-quit',()=>{clearInterval(workerTimer);clearInterval(motionTimer);clearInterval(foregroundTimer);worker?.terminate();tray?.destroy();});
}
