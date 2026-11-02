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

console.log('== 6. the flock(1) the plugin will find honours its -n -E 75 contract ==');
// The plugin's locked() shells out to flock(1). macOS ships none, and /usr/bin
// is SIP-protected, so the darwin patch teaches it to look on PATH. That keeps
// locked() a KERNEL lock instead of an advisory file, but only while whatever
// it finds honours the two flags the plugin passes: -n (fail instead of
// waiting) and -E 75 (exit 75 on conflict). Anything that broke either would
// silently break `pi-omnigent connect`, so the contract is asserted here
// rather than assumed.
//
// Since the wire stage now installs rootfs/bin/flock -- a /usr/bin/perl
// stand-in -- into $PI_AGENT_HOME/bin, and pi-agent-env.sh puts that directory
// FIRST on PATH, the shim is what the plugin runs, with or without Homebrew.
// Resolve flock the way the plugin will: its two hard-coded paths, then PATH as
// pi-agent-env.sh builds it ($PI_AGENT_HOME/bin first, the Homebrew prefixes
// appended last). Looking only at this process's PATH would test a flock the
// plugin never runs.
const executableFile = c => { try { fs.accessSync(c, fs.constants.X_OK); return true; } catch { return false; } };
const agentBin = process.env.PI_AGENT_HOME ? path.join(process.env.PI_AGENT_HOME, 'bin') : null;
const pluginPath = [agentBin, ...(process.env.PATH || '').split(path.delimiter), '/opt/homebrew/bin', '/usr/local/bin'];
const flockBin = ['/usr/bin/flock', '/bin/flock'].find(executableFile)
  ?? pluginPath.filter(Boolean).map(d => path.join(d, 'flock')).find(executableFile);
console.log('  flock the plugin will run:', flockBin ?? '(none)');
if (agentBin) {
  ok('plugin 用的是本安裝的 flock（不依賴 Homebrew）', flockBin === path.join(agentBin, 'flock'),
     flockBin ?? '沒找到');
}
if (!flockBin) {
  ok('flock(1) 可用（Omnigent connect 需要）', false,
     `沒找到 → 執行 ./install.sh wire（會裝 ${agentBin ?? '$PI_AGENT_HOME/bin'}/flock）`);
} else {
  const guard = path.join(os.tmpdir(), `pa-flock-${process.pid}.guard`);
  fs.closeSync(fs.openSync(guard, 'a', 0o600));
  try {
    // Holder: prints LOCKED and keeps the lock until its stdin closes, exactly
    // as locked() drives it.
    const holder = spawn(flockBin, ['-n', '-E', '75', guard, process.execPath, '-e',
      "process.stdout.write('LOCKED\\n'); process.stdin.resume();"], { stdio: ['pipe', 'pipe', 'ignore'] });
    const first = await new Promise(r => { holder.stdout.once('data', c => r(String(c))); });
    ok('持鎖者印出 LOCKED', first.startsWith('LOCKED'), JSON.stringify(first.trim()));
    // Contender: must be refused with the conflict code, not block and not run.
    const clash = spawnSync(flockBin, ['-n', '-E', '75', guard, process.execPath, '-e',
      "process.stdout.write('RAN')"], { encoding: 'utf8' });
    ok('競爭者以 75 退出且沒執行（-n -E 合約）', clash.status === 75 && !/RAN/.test(clash.stdout || ''),
       `exit=${clash.status} stdout=${JSON.stringify((clash.stdout || '').trim())}`);
    holder.stdin.end();
    await new Promise(r => holder.once('close', r));
    // Released on exit: the next acquirer must succeed.
    const after = spawnSync(flockBin, ['-n', '-E', '75', guard, process.execPath, '-e',
      "process.stdout.write('FREE')"], { encoding: 'utf8' });
    ok('持鎖者結束後鎖被釋放', after.status === 0 && /FREE/.test(after.stdout || ''),
       `exit=${after.status}`);
  } finally { fs.rmSync(guard, { force: true }); }
}

console.log('== 7. the scoped HOME can resolve the login Keychain ==');
// macOS resolves the login Keychain from $HOME/Library/Keychains, and
// pi-agent-env.sh scopes HOME. Without a link every keychain call from this
// install returns errSecNoDefaultKeychain (-25307): Claude Code then reports
// "Not logged in" although the user IS logged in, and `claude auth login`
// fails with "Couldn't save your login. If your Mac's keychain is locked,
// unlock it and log in again." That message is a red herring -- the keychain
// is neither locked nor inaccessible, it is simply not found -- and it cost a
// long detour through ACL and launchd-session theories, all of which were
// wrong. The wire stage links the real directory in; assert it here so the
// regression announces itself instead of impersonating a login problem.
const scopedHome = process.env.PI_AGENT_HOME
  ? path.join(process.env.PI_AGENT_HOME, 'home')
  : null;
if (!scopedHome) {
  ok('scoped HOME 能解析 login Keychain', false, 'PI_AGENT_HOME 未設,無法檢查');
} else {
  const link = path.join(scopedHome, 'Library', 'Keychains');
  let linked = false;
  try { linked = fs.statSync(link).isDirectory(); } catch { linked = false; }
  ok('scoped home 有 Library/Keychains', linked, linked ? link : `缺少 ${link}`);
  // The real check: ask the Security framework itself, under the scoped HOME.
  const probe = spawnSync('/usr/bin/security', ['default-keychain'], {
    encoding: 'utf8',
    env: { ...process.env, HOME: scopedHome, LC_ALL: 'C' },
  });
  const out = `${probe.stdout || ''}${probe.stderr || ''}`.trim();
  const resolved = /login\.keychain/.test(out);
  ok('scoped HOME 下 security 找得到預設 keychain', resolved,
     resolved ? out.replace(/\s+/g, ' ').slice(0, 70)
              : `${out.slice(0, 80)} → Claude Code 會誤報 Not logged in`);
}
