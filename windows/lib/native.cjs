'use strict';
const path = require('node:path');

function assistantForPath(executable) {
  const name = path.win32.basename(executable).toLowerCase();
  if (['codex.exe','chatgpt.exe'].includes(name)) return 'gpt';
  if (['deepseek harness.exe','deepseekharness.exe','deepseek-harness.exe','dsh.exe'].includes(name)) return 'dsh';
  return null;
}

class NativeWindows {
  constructor() {
    this.available=false; this.windows={gpt:[],dsh:[]}; this.cache=new Map();
    if (process.platform!=='win32') return;
    const koffi=require('koffi'), user=koffi.load('user32.dll'), kernel=koffi.load('kernel32.dll');
    this.foreground=user.func('void * __stdcall GetForegroundWindow()');
    this.pidOf=user.func('uint32_t __stdcall GetWindowThreadProcessId(void * hwnd, _Out_ uint32_t * pid)');
    this.visible=user.func('int32_t __stdcall IsWindowVisible(void * hwnd)');
    this.open=kernel.func('void * __stdcall OpenProcess(uint32_t access, int32_t inherit, uint32_t pid)');
    this.close=kernel.func('int32_t __stdcall CloseHandle(void * handle)');
    this.image=kernel.func('int32_t __stdcall QueryFullProcessImageNameW(void * process, uint32_t flags, _Out_ uint16_t * name, _Inout_ uint32_t * size)');
    const callback=koffi.proto('int32_t __stdcall TokenLensEnumProc(void * hwnd, intptr_t param)');
    this.enumWindows=user.func('int32_t __stdcall EnumWindows(TokenLensEnumProc * callback, intptr_t param)');
    this.restore=user.func('int32_t __stdcall ShowWindowAsync(void * hwnd, int32_t command)');
    this.raise=user.func('int32_t __stdcall SetForegroundWindow(void * hwnd)');
    this.available=true;
  }
  processOf(hwnd) {
    if (!hwnd) return null;
    const pid=[0]; this.pidOf(hwnd,pid); if (!pid[0]) return null;
    const old=this.cache.get(pid[0]); if (old && Date.now()-old.at<5000) return old.path;
    const process=this.open(0x1000,0,pid[0]); if (!process) return null;
    let executable=null;
    try {
      const length=[32768], buffer=Buffer.alloc(32768*2);
      if (this.image(process,0,buffer,length)) executable=buffer.subarray(0,length[0]*2).toString('utf16le');
    } finally { this.close(process); }
    this.cache.set(pid[0],{path:executable,at:Date.now()});
    if (this.cache.size>512) this.cache.clear();
    return executable;
  }
  poll() {
    if (!this.available) return {frontmost:null,running:{gpt:false,dsh:false}};
    const windows={gpt:[],dsh:[]};
    this.enumWindows(hwnd=>{
      if (!this.visible(hwnd)) return 1;
      const exe=this.processOf(hwnd), assistant=exe && assistantForPath(exe);
      if (assistant) windows[assistant].push(hwnd);
      return 1;
    },0);
    this.windows=windows;
    const exe=this.processOf(this.foreground());
    return {frontmost:exe ? assistantForPath(exe):null,running:{gpt:!!windows.gpt.length,dsh:!!windows.dsh.length}};
  }
  activate(assistant) {
    const hwnd=this.windows[assistant]?.[0]; if (!hwnd) return false;
    this.restore(hwnd,9); return !!this.raise(hwnd);
  }
}
module.exports={NativeWindows,assistantForPath};
