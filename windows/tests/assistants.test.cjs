'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {assistantForPath}=require('../lib/native.cjs');
const {ASSISTANT_IDS,emptyRunning,chooseAssistant}=require('../lib/assistants.cjs');

test('recognizes five assistant windows without matching unrelated Electron apps',()=>{
  for (const [exe,id] of [['ChatGPT.exe','gpt'],['DeepSeek Harness.exe','dsh'],['WorkBuddy AI.exe','workbuddy'],['Claude.exe','claude'],['CodeBuddy CN.exe','codebuddy']]) {
    assert.equal(assistantForPath(`C:\\Apps\\${exe}`),id);
  }
  for (const exe of ['electron.exe','claude-helper.exe','chrome.exe','not-codebuddy.exe']) assert.equal(assistantForPath(exe),null);
});
test('actual foreground wins; unrelated foreground preserves the last live assistant',()=>{
  const running=Object.fromEntries(ASSISTANT_IDS.map(id=>[id,true]));
  for (const id of ASSISTANT_IDS) assert.equal(chooseAssistant('gpt',{frontmost:id,running}),id);
  assert.equal(chooseAssistant('claude',{frontmost:null,running}),'claude');
  running.claude=false;
  assert.equal(chooseAssistant('claude',{frontmost:null,running}),'gpt');
  assert.equal(chooseAssistant('claude',{frontmost:null,running:emptyRunning()}),'claude');
});
