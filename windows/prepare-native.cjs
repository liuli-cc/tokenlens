'use strict';
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const zlib=require('node:zlib');

function machineOf(buffer) {
  if (buffer.toString('ascii',0,2)!=='MZ') throw Error('Native component is not a PE executable');
  const offset=buffer.readUInt32LE(0x3c);
  if (buffer.toString('ascii',offset,offset+4)!=='PE\0\0') throw Error('Invalid PE header');
  return buffer.readUInt16LE(offset+4);
}
async function prepareNative(arch) {
  if (!['x64','arm64'].includes(arch)) throw Error('Unsupported Windows architecture');
  const lock=require('./package-lock.json'),key=`node_modules/@koromix/koffi-win32-${arch}`;
  const pinned=lock.packages[key];
  if (!pinned?.resolved || !pinned.integrity?.startsWith('sha512-')) throw Error('Native module is not pinned in the lockfile');
  // The user's npm mirror may differ; acquire this pinned binary from npm's
  // official registry and verify the lockfile's original integrity digest.
  const url=new URL(`https://registry.npmjs.org/@koromix/koffi-win32-${arch}/-/koffi-win32-${arch}-${pinned.version}.tgz`);
  if (url.protocol!=='https:' || url.hostname!=='registry.npmjs.org') throw Error('Unexpected native module registry');
  const response=await fetch(url,{signal:AbortSignal.timeout(60000)});
  if (!response.ok) throw Error(`Native module download failed: ${response.status}`);
  const compressed=Buffer.from(await response.arrayBuffer());
  const integrity='sha512-'+crypto.createHash('sha512').update(compressed).digest('base64');
  if (integrity!==pinned.integrity) throw Error('Native module integrity check failed');
  const tar=zlib.gunzipSync(compressed),expected=`package/win32_${arch}/koffi.node`;
  let binary=null;
  for (let offset=0;offset+512<=tar.length;) {
    const header=tar.subarray(offset,offset+512),name=header.subarray(0,100).toString().replace(/\0.*$/s,'');
    if (!name) break;
    const size=parseInt(header.subarray(124,136).toString().replace(/\0.*$/s,'').trim(),8)||0;
    if (name===expected) binary=tar.subarray(offset+512,offset+512+size);
    offset+=512+Math.ceil(size/512)*512;
  }
  if (!binary) throw Error(`Native module missing from official package: ${expected}`);
  const machine=machineOf(binary),wanted=arch==='x64'?0x8664:0xaa64;
  if (machine!==wanted) throw Error(`Native module architecture mismatch: ${machine.toString(16)}`);
  const folder=path.join(__dirname,'.build','native','koffi','build',`win32_${arch}`);
  fs.mkdirSync(folder,{recursive:true});fs.writeFileSync(path.join(folder,'koffi.node'),binary);
  console.log(`Prepared official Koffi ${pinned.version} for Windows ${arch}; npm integrity and PE architecture verified`);
}
if (require.main===module) prepareNative(process.argv[2]||process.arch).catch(error=>{console.error(error.message);process.exitCode=1;});
module.exports={prepareNative,machineOf};
