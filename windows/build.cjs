'use strict';
const {spawnSync}=require('node:child_process');
const fs=require('node:fs');
const path=require('node:path');
const {prepareNative,machineOf}=require('./prepare-native.cjs');

async function build() {
  const flags=process.argv.slice(2),arch=flags.includes('--arm64')?'arm64':flags.includes('--x64')?'x64':process.arch;
  await prepareNative(arch);
  const cli=require.resolve('electron-builder/out/cli/cli.js');
  const result=spawnSync(process.execPath,[cli,'--win','nsis','zip',`--${arch}`],{stdio:'inherit',cwd:__dirname});
  if (result.error) throw result.error;
  if (result.status!==0) throw Error(`Windows packaging failed: ${result.status}`);
  const folder=path.join(__dirname,'dist',arch==='x64'?'win-unpacked':'win-arm64-unpacked');
  const wanted=arch==='x64'?0x8664:0xaa64;
  for (const relative of ['TokenLens.exe',`resources/koffi/build/win32_${arch}/koffi.node`]) {
    const file=path.join(folder,relative);
    if (machineOf(fs.readFileSync(file))!==wanted) throw Error(`Packaged architecture mismatch: ${relative}`);
  }
  console.log(`Verified packaged application and native DLL are both ${arch}`);
}
build().catch(error=>{console.error(error.message);process.exitCode=1;});
