'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {walletLabel} = require('./scanner.cjs');

class ProviderReader {
  constructor(database = path.join(os.homedir(),'.cc-switch','cc-switch.db')) {
    this.database=database; this.cache=null; this.cachedAt=0; this.identity='';
  }
  async read(now=Date.now()) {
    if (!fs.existsSync(this.database)) return null;
    let db, row;
    try {
      const {DatabaseSync} = require('node:sqlite');
      db=new DatabaseSync(this.database,{readOnly:true});
      row=db.prepare(`SELECT p.name, COALESCE(e.url,'') AS endpoint,
        COALESCE(json_extract(p.settings_config,'$.auth.OPENAI_API_KEY'),'') AS apiKey,
        COALESCE(p.website_url,'') AS website
        FROM providers p LEFT JOIN provider_endpoints e ON e.provider_id=p.id AND e.app_type=p.app_type
        WHERE p.app_type='codex' AND p.is_current=1 LIMIT 1`).get();
    } catch { return null; } finally { db?.close(); }
    if (!row || /^(default|openai|official)$/i.test(row.name)) return null;
    const identity=`${row.name}|${row.endpoint}|${row.apiKey}`;
    if (identity===this.identity && now-this.cachedAt<60000) return this.cache;
    this.identity=identity; this.cachedAt=now;
    let endpoint=null, recharge=null, kind=null;
    try {
      const url=new URL(row.endpoint), host=url.hostname.toLowerCase();
      // Send credentials only to the matching official HTTPS balance endpoint.
      if (url.protocol==='https:' && host==='api.deepseek.com') {
        endpoint='https://api.deepseek.com/user/balance'; recharge='https://platform.deepseek.com/top_up';kind='deepseek';
      } else if (url.protocol==='https:' && ['api.moonshot.cn','api.moonshot.ai'].includes(host)) {
        endpoint=`https://${host}/v1/users/me/balance`;recharge='https://platform.kimi.com/console/pay';kind='kimi';
      }
    } catch {}
    if (!recharge) {
      try { const url=new URL(row.website); if (url.protocol==='https:') recharge=url.href; } catch {}
    }
    this.cache={provider:row.name,balance:'暂不可读',balanceKnown:false,balanceUpdatedAt:null,recharge};
    if (!endpoint || !row.apiKey) return this.cache;
    try {
      const response=await fetch(endpoint,{headers:{Authorization:`Bearer ${row.apiKey}`},signal:AbortSignal.timeout(5000),redirect:'error'});
      if (!response.ok) return this.cache;
      const data=await response.json(); let wallet;
      if (kind==='deepseek' && data.is_available) wallet=data.balance_infos?.find(w=>w.currency==='CNY') || data.balance_infos?.[0];
      if (kind==='kimi' && data.data?.available_balance!=null) wallet={currency:'CNY',total_balance:data.data.available_balance};
      if (wallet && Number.isFinite(Number(wallet.total_balance))) {
        this.cache.balance=walletLabel({currency:wallet.currency,balance:wallet.total_balance});
        this.cache.balanceKnown=true;this.cache.balanceUpdatedAt=Date.now();
      }
    } catch {}
    return this.cache;
  }
}
module.exports={ProviderReader};
