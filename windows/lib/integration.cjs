'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

// Harness applies this patch after its bundled profile. Existing settings are
// preserved, and a backup is made before adding/updating our one plugin entry.
function installIntegration(source, home = os.homedir()) {
  const root = path.join(home,'.dsh'), target = path.join(root,'integrations','tokenlens-dsh-status.mjs');
  const patch = path.join(root,'profiles','desktop','cordis.patch.yml');
  const profile = path.dirname(patch);
  if (!fs.existsSync(profile)) throw new Error('请先安装并启动一次 DeepSeek Harness，再连接状态桥。');
  const old = fs.existsSync(patch) ? fs.readFileSync(patch,'utf8') : '';
  const entry = `- insert:\n    - id: tokenlens-dsh-status\n      name: ${JSON.stringify(target.replaceAll('\\','/'))}\n`;
  let next;
  if (/^\s*- id: tokenlens-dsh-status\s*$/m.test(old)) {
    next = old.replace(/(^\s*- id: tokenlens-dsh-status\s*\r?\n\s*name:)\s*[^\r\n]*/m,
      (_all,prefix) => `${prefix} ${JSON.stringify(target.replaceAll('\\','/'))}`);
    if (next === old && !old.includes(JSON.stringify(target.replaceAll('\\','/')))) {
      throw new Error('状态桥配置格式不同，请查看连接说明。');
    }
  } else next = old.trimEnd() + (old.trim() ? '\n' : '') + entry;
  fs.mkdirSync(path.dirname(target),{recursive:true});
  if (fs.existsSync(target)) fs.copyFileSync(target,target+'.tokenlens-backup');
  fs.copyFileSync(source,target);
  if (next !== old) {
    if (fs.existsSync(patch)) fs.copyFileSync(patch,patch+'.tokenlens-backup');
    fs.writeFileSync(patch+'.tokenlens-tmp',next,'utf8'); fs.renameSync(patch+'.tokenlens-tmp',patch);
  }
  return { target, patch };
}
module.exports = { installIntegration };
