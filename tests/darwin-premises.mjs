// Checks, on a real Mac, every OS-level premise the darwin plugin port rests on.
// Run it before trusting a port plan and again after any macOS release:
//     node tests/darwin-premises.mjs
// It found one wrong premise already -- see docs/MACOS.md "what the probe
// corrected" -- which is the whole reason it exists as a committed test rather
// than a one-off script.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync, spawn } from 'node:child_process';
const run = (f, a) => (spawnSync(f, a, { encoding: 'utf8', env: { ...process.env, LC_ALL: 'C' } }).stdout || '').trim();
const ok = (n, v, extra='') => console.log(`  ${v ? 'PASS' : 'FAIL'}  ${n}${extra ? '  -- ' + extra : ''}`);

console.log('== 1. ps -o lstart=,uid=,state=,comm= 的欄位版面 ==');
const line = run('/bin/ps', ['-o', 'lstart=,uid=,state=,comm=', '-p', String(process.pid)]);
console.log('  raw:', JSON.stringify(line));
const m = /^(\w{3}\s+\w{3}\s+\d+\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+(\d+)\s+(\S+)\s+(.*)$/.exec(line);
ok('正則解析得出', !!m);
if (m) {
  console.log(`    lstart=${m[1]} uid=${m[2]} state=${m[3]}`);
  console.log(`    comm=${m[4]}`);
  ok('comm 是完整執行檔路徑', m[4].startsWith('/'), m[4]);
  ok('lstart 可解析成時間', Number.isFinite(Date.parse(m[1] + ' UTC')));
}

console.log('== 2. boot id 來源 ==');
const bsu = run('/usr/sbin/sysctl', ['-n', 'kern.bootsessionuuid']);
ok('kern.bootsessionuuid 存在（最佳來源）', /^[0-9A-Fa-f-]{36}$/.test(bsu), bsu || '(空)');
const bt = run('/usr/sbin/sysctl', ['-n', 'kern.boottime']);
ok('kern.boottime 可解析（後備）', /sec\s*=\s*(\d+)/.test(bt), bt.slice(0, 60));

console.log('== 3. O_EXLOCK = 0x20，競爭時回 EAGAIN（APFS） ==');
const O_EXLOCK = 0x0020;
const f = path.join(os.tmpdir(), `pa-exlock-${process.pid}.guard`);
const flags = fs.constants.O_RDWR | fs.constants.O_CREAT | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK | O_EXLOCK;
let fd1;
try {
  fd1 = fs.openSync(f, flags, 0o600);
  ok('第一次取得獨占鎖', true);
  let code = null;
  try { const fd2 = fs.openSync(f, flags, 0o600); fs.closeSync(fd2); } catch (e) { code = e.code; }
  ok('第二次競爭回 EAGAIN/EWOULDBLOCK', code === 'EAGAIN' || code === 'EWOULDBLOCK', String(code));
  // death-releases-lock: a child holding it, then killed
  fs.closeSync(fd1); fd1 = undefined;
  const child = spawn(process.execPath, ['-e', `const fs=require('fs');fs.openSync(${JSON.stringify(f)},${flags},0o600);process.stdout.write('L');setInterval(()=>{},1e6);`], { stdio: ['ignore','pipe','ignore'] });
  await new Promise(r => child.stdout.once('data', r));
  let held = null; try { const fd3 = fs.openSync(f, flags, 0o600); fs.closeSync(fd3); } catch (e) { held = e.code; }
  ok('子程序持鎖時父取不到', held === 'EAGAIN' || held === 'EWOULDBLOCK', String(held));
  child.kill('SIGKILL');
  await new Promise(r => child.once('exit', r));
  await new Promise(r => setTimeout(r, 150));
  let after = 'got'; try { const fd4 = fs.openSync(f, flags, 0o600); fs.closeSync(fd4); } catch (e) { after = e.code; }
  ok('SIGKILL 後鎖自動釋放（關鍵保證）', after === 'got', after);
} finally { if (fd1 !== undefined) fs.closeSync(fd1); fs.rmSync(f, { force: true }); }

console.log('== 4. process title：ps -o args= 會不會顯示改過的標題 ==');
const t = spawn(process.execPath, ['-e', "process.title='Paseo Supervisor';process.stdout.write('R');setInterval(()=>{},1e6);"], { stdio: ['ignore','pipe','ignore'] });
await new Promise(r => t.stdout.once('data', r));
const args = run('/bin/ps', ['-o', 'args=', '-p', String(t.pid)]);
console.log('  ps args=:', JSON.stringify(args.slice(0, 80)));
// Observed on macOS 26.4 / M2: the title DOES take effect here, so an ownership
// check on argv[0] === 'Paseo Supervisor' stays valid on darwin and must NOT be
// dropped. A port plan written from the Linux source assumed the opposite.
ok('process.title 在 darwin 生效（argv[0] 判斷必須保留）', args.startsWith('Paseo Supervisor'),
   args.startsWith('Paseo Supervisor') ? '標題生效' : '標題未生效 → 重新評估歸屬驗證');
t.kill('SIGKILL');

console.log('== 5. 另一個程序的 environ 真的讀不到嗎 ==');
const e1 = run('/bin/ps', ['-Eww', '-o', 'command=', '-p', String(t.pid)]);
ok('ps -E 讀不到 env（所以歸屬驗證不能靠 environ）', !/PATH=/.test(e1),
   /PATH=/.test(e1) ? 'env 竟然讀得到 → 重新評估設計' : '確認讀不到');
