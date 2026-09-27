'use strict';
const {test}=require('node:test');const assert=require('node:assert/strict');
const {Spring,layout,contains,modelLines,quotaLabel}=require('../lib/geometry.cjs');
test('top-aligned geometry remains centred, symmetric and within each display',()=>{
  for(const area of [{x:0,y:0,width:1920,height:1080},{x:-1600,y:48,width:1600,height:900},{x:200,y:40,width:320,height:600}]){
    for(const p of [0,.4,1,1.08]){const f=layout(area,p);assert.ok(Math.abs(f.x+f.width/2-(area.x+area.width/2))<1);assert.equal(f.y,area.y);assert.ok(f.x>=area.x);assert.ok(f.x+f.width<=area.x+area.width);assert.equal(contains(f,{x:f.x+f.width/2,y:f.y}),true);assert.equal(contains(f,{x:f.x-1,y:f.y}),false);}
  }
});
test('analytic spring overshoots gently, settles and matches 60/120 Hz',()=>{
  const trajectory=hz=>{const s=new Spring();s.target=1;let peak=0;for(let i=0;i<hz;i++){s.step(1/hz);peak=Math.max(peak,s.value);}return {s,peak};};
  const a=trajectory(60),b=trajectory(120);assert.ok(a.peak>1 && a.peak<1.1);assert.ok(Math.abs(a.s.value-1)<.001);assert.ok(Math.abs(a.s.value-b.s.value)<.0001);
  a.s.target=0;a.s.step(.01);const velocity=a.s.velocity;a.s.target=1;assert.equal(a.s.velocity,velocity,'Retarget must preserve velocity');
});
test('model names stay dynamic and absent quota is not shown as zero',()=>{
  assert.deepEqual(modelLines('gpt-6-luna'),['GPT-6','LUNA']);assert.deepEqual(modelLines('deepseek-v41-flash'),['DeepSeek','V41 FLASH']);
  assert.equal(quotaLabel(null),'--');assert.equal(quotaLabel(.3),'<1%');assert.equal(quotaLabel(26),'26%');
});
