'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {sample,DURATION}=require('../lib/island-motion.cjs');
const {layout}=require('../lib/geometry.cjs');
const {CompletionQueue}=require('../lib/completion-queue.cjs');

test('completion opens before one bounded compression/rebound and finishes at rest',()=>{
  let previous=0;const directions=[];let lastHeight=0;
  const area={x:0,y:40,width:1920,height:1040},canvas=layout(area,0);
  for(let i=0;i<=300;i++){
    const t=i/100,s=sample(t),f=layout(area,s.openingProgress,s);
    assert.ok(s.openingProgress>=previous);previous=s.openingProgress;
    assert.deepEqual([f.x,f.y,f.width,f.height],[canvas.x,canvas.y,canvas.width,canvas.height]);
    assert.ok(s.heightOffset>=-3.5 && s.heightOffset<=1.2250001);
    assert.ok(Math.abs(s.widthOffset/4+s.heightOffset/3.5)<1e-9);
    if(t<.55 || t>=1.16)assert.equal(s.heightOffset,0);
    const direction=Math.sign(s.heightOffset-lastHeight);if(direction && direction!==directions.at(-1))directions.push(direction);lastHeight=s.heightOffset;
    if(t>=DURATION)assert.deepEqual([s.heightOffset,s.widthOffset,s.iconLift,s.iconSquash],[0,0,0,0]);
  }
  assert.deepEqual(directions,[-1,1,-1]);
  for(const t of [.55,.70,.94,1.16]){
    const e=.000001,velocityLeft=(sample(t).heightOffset-sample(t-e).heightOffset)/e,velocityRight=(sample(t+e).heightOffset-sample(t).heightOffset)/e;
    assert.ok(Math.abs(velocityLeft-velocityRight)<.01,'A material join changed velocity abruptly');
  }
  assert.equal(sample(.70).glow,1);assert.equal(sample(1.10).glow,1);
  assert.ok(sample(.70,{style:'subtle'}).heightOffset>sample(.70,{style:'balanced'}).heightOffset);
});
test('reduced motion leaves a steady expanded notification without deformation',()=>{
  for(const t of [0,.42,.70,.94,1.90]){
    const s=sample(t,{reduceMotion:true});assert.deepEqual([s.openingProgress,s.heightOffset,s.widthOffset,s.iconLift,s.reveal],[1,0,0,0,1]);
  }
});
test('completion baseline suppresses startup history and later-discovered old sessions',()=>{
  const q=new CompletionQueue();
  assert.deepEqual(q.consume('gpt',[{id:'known',at:9500}],10000),[]);
  assert.deepEqual(q.consume('gpt',[{id:'known',at:9500},{id:'old-file',at:9700}],11000),[]);
  assert.equal(q.consume('gpt',[{id:'new',at:10500}],11000).length,1);
  assert.equal(q.consume('gpt',[{id:'new',at:10500}],11001).length,0);
  assert.equal(q.consume('claude',[{id:'false-success',at:11000}],11001).length,0);
});
test('background completion batches keep true source and global FIFO order',()=>{
  const q=new CompletionQueue();q.consumeBatch({gpt:[],dsh:[]},10000);
  q.consumeBatch({gpt:[{id:'same',at:11000},{id:'gpt-later',at:13000}],dsh:[{id:'same',at:12000}]},14000);
  assert.deepEqual(q.pending.map(n=>[n.assistant,n.id]),[['gpt','same'],['dsh','same'],['gpt','gpt-later']]);
  assert.deepEqual(q.recent.map(n=>n.at),[13000,12000,11000]);
  assert.equal(q.next(110000).assistant,'gpt','Accepted notices expired at source freshness rather than their separate retention');
  assert.equal(q.next(110000).assistant,'dsh');
});
test('pending/recent queues are bounded while a real active notice is preserved externally',()=>{
  const q=new CompletionQueue();q.consumeBatch({gpt:[],dsh:[]},10000);
  q.consume('gpt',Array.from({length:150},(_,i)=>({id:`task-${i}`,at:11000+i})),12000);
  assert.equal(q.pending.length,128);assert.equal(q.recent.length,20);
  assert.equal(q.pending[0].id,'task-22');assert.equal(q.pending.at(-1).id,'task-149');
  assert.equal(q.next(700000),null,'Expired waiting notices replayed after a long backlog');
});
