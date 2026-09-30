'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {metric,stats,windows}=require('../lib/presentation.cjs');

test('missing metrics stay unknown, while explicit zero stays zero',()=>{
  assert.deepEqual(stats({todayTokens:0,tokenUsageKnown:false,cachePercent:0,cacheUsageKnown:false,contextPercent:null}).map(x=>x[0]),['--','--','--']);
  assert.deepEqual(stats({todayTokens:0,tokenUsageKnown:true,cachePercent:0,cacheUsageKnown:true,contextPercent:0}).map(x=>x[0]),['0','0%','0%']);
  assert.equal(metric({active:'claude',claude:{remaining:null}}),'--');
  assert.equal(metric({active:'gpt',gpt:{remaining:0}}),'0%');
});
test('expired balances and inferred context are visibly qualified',()=>{
  assert.equal(metric({active:'dsh',dsh:{balance:'¥25.80',balanceFresh:false}}),'--');
  assert.equal(metric({active:'gpt',gpt:{external:{balance:'¥1',balanceFresh:false}}}),'--');
  assert.equal(stats({contextPercent:12.5,contextIsEstimate:true})[1][0],'≈12.5%');
  assert.equal(metric({active:'workbuddy',workbuddy:{creditConsumed:32,remaining:null}}),'--');
});
test('both official quota windows are retained',()=>{
  assert.equal(windows({quota:{windowMinutes:300,remaining:70},secondaryQuota:{windowMinutes:10080,remaining:2}}).length,2);
});
test('clock expiry hides old values even if the reader stops responding',()=>{
  const now=Date.now(),stale=now-901000;
  const gpt={remaining:35,quotaAt:stale,quota:{windowMinutes:300,remaining:35,resetsAt:now+100000}};
  assert.equal(metric({active:'gpt',gpt},true,now),'--');
  assert.equal(windows(gpt,now)[0].value,'--');
  assert.equal(metric({active:'dsh',dsh:{balance:'¥100',balanceFresh:true,balanceUpdatedAt:now-181000}},true,now),'--');
});
