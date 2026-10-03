'use strict';
const {contextBridge,ipcRenderer}=require('electron');
const allowed=new Set(['details','open-assistant','connect-dsh','refresh','open-balance','close-details','select-gpt','select-dsh','select-workbuddy','select-claude','select-codebuddy','dismiss-notice','pin-expanded','set-preference','preview-notice','open-recent']);
contextBridge.exposeInMainWorld('tokenLens',{
  onState(callback) { ipcRenderer.on('state',(_event,data)=>callback(data)); ipcRenderer.send('ready'); },
  onFrame(callback) { ipcRenderer.on('frame',(_event,data)=>callback(data)); },
  action(name,value) { if (allowed.has(name)) ipcRenderer.send('action',name,value); },
  systemMotion(value) { if(typeof value==='boolean')ipcRenderer.send('system-motion',value); }
});
