'use strict';

// Only known assistant executables count; generic Electron processes never do.
const ASSISTANTS=Object.freeze({
  gpt:{name:'GPT',appName:'Codex / GPT',executables:['codex.exe','chatgpt.exe'],waiting:'等待 GPT'},
  dsh:{name:'DSH',appName:'DeepSeek Harness',executables:['deepseek harness.exe','deepseekharness.exe','deepseek-harness.exe','dsh.exe'],waiting:'等待 Harness'},
  workbuddy:{name:'WorkBuddy',appName:'WorkBuddy',executables:['workbuddy.exe','workbuddy ai.exe','workbuddy-ai.exe'],waiting:'等待 WorkBuddy'},
  claude:{name:'Claude',appName:'Claude',executables:['claude.exe'],waiting:'等待 Claude'},
  codebuddy:{name:'CodeBuddy',appName:'CodeBuddy',executables:['codebuddy.exe','codebuddy cn.exe','codebuddycn.exe'],waiting:'等待 CodeBuddy'}
});
const ASSISTANT_IDS=Object.freeze(Object.keys(ASSISTANTS));
const emptyRunning=()=>Object.fromEntries(ASSISTANT_IDS.map(id=>[id,false]));
const emptyStatus=()=>Object.fromEntries(ASSISTANT_IDS.map(id=>[id,{
  model:ASSISTANTS[id].waiting,remaining:null,balance:null,todayTokens:null,
  contextPercent:null,cachePercent:null,recentCalls:null,history:[],models:[],
  running:false,usageKnown:false,contextKnown:false,cacheKnown:false,
  source:'等待本机记录',limitations:['软件尚未提供可读取的用量记录。']
}]));

function chooseAssistant(current,observation) {
  if (ASSISTANTS[observation.frontmost]) return observation.frontmost;
  if (observation.running?.[current]) return current;
  return ASSISTANT_IDS.find(id=>observation.running?.[id]) || current;
}
module.exports={ASSISTANTS,ASSISTANT_IDS,emptyRunning,emptyStatus,chooseAssistant};
