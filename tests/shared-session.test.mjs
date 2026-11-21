import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
const bundle=process.env.SHARED_RUNTIME_TEST_BUNDLE;
assert.ok(bundle,'SHARED_RUNTIME_TEST_BUNDLE is required');
const helper=path.resolve('rootfs/bin/pi-agent-shared-session.mjs');
const write=(file,v)=>{fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,JSON.stringify(v));};
const read=file=>JSON.parse(fs.readFileSync(file,'utf8'));
function fixture(t){
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'native-shared-session-'));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
 const home=path.join(root,'real-home'),canonical=path.join(root,'install-data'),actual=path.join(home,'.pi/agent');
 fs.mkdirSync(actual,{recursive:true});fs.mkdirSync(canonical);
 for(const data of [actual,canonical]){write(path.join(data,'settings.json'),{packages:[],theme:'keep'});write(path.join(data,'mcp.json'),{mcpServers:{}});}
 write(path.join(actual,'auth.json'),{fixture:'private-unmodified'});write(path.join(actual,'models.json'),{providers:{fixture:{baseUrl:'https://fixture.invalid'}}});
 write(path.join(actual,'mcp.json'),{mcpServers:{custom:{command:'keep'}}});
 const auth=fs.readFileSync(path.join(actual,'auth.json'),'utf8'),models=fs.readFileSync(path.join(actual,'models.json'),'utf8');
 const env={...process.env,HOME:home,PI_SHARED_HOME:home,PI_SHARED_DATA_DIR:canonical,PI_CODING_AGENT_DIR:actual,PI_SHARED_RUNTIME_BUNDLE_DIR:bundle};
 const run=()=>{const r=spawnSync(process.execPath,[helper],{env,cwd:home,encoding:'utf8',timeout:30000});assert.equal(r.status,0,r.stderr);assert.equal(fs.readFileSync(path.join(actual,'auth.json'),'utf8'),auth);assert.equal(fs.readFileSync(path.join(actual,'models.json'),'utf8'),models);assert.equal(read(path.join(actual,'mcp.json')).mcpServers.custom.command,'keep');};
 return {home,canonical,actual,run,root};
}
function choice(data,value){
 if(value==='disabled')write(path.join(data,'settings.json'),{packages:[{source:bundle,extensions:[]}]});
 else if(value==='removed')write(path.join(data,'shared-runtime/distribution-seed.json'),{schema:1});
 else if(value==='external')write(path.join(data,'settings.json'),{packages:['npm:@woowtech/pi-agent-shared-runtime@0.1.4']});
}
test('alternate Pi uses canonical memory and bridge while retaining its settings and credentials',t=>{
 const f=fixture(t);f.run();
 assert.ok(read(path.join(f.actual,'settings.json')).packages.includes(bundle));
 assert.equal(read(path.join(f.actual,'settings.json')).theme,'keep');
 const entry=read(path.join(f.actual,'mcp.json')).mcpServers.pi_shared_runtime;
 assert.equal(entry.env.PI_SHARED_DATA_DIR,f.canonical);assert.equal(entry.env.PI_SHARED_HOME,f.home);
 assert.equal(read(path.join(f.canonical,'mcp.json')).mcpServers.pi_shared_memory.env.PI_SHARED_DATA_DIR,f.canonical);
 assert.equal(fs.existsSync(path.join(f.actual,'shared-runtime/memory')),false);
 f.run();assert.deepEqual(read(path.join(f.actual,'mcp.json')).mcpServers.pi_shared_runtime,entry);
});
for(const side of ['canonical','actual'])for(const value of ['disabled','removed','external'])test(`${side} ${value} selection is preserved`,t=>{
 const f=fixture(t);choice(f[side],value);const original=fs.readFileSync(path.join(f[side],'settings.json'),'utf8');f.run();
 assert.equal(fs.readFileSync(path.join(f[side],'settings.json'),'utf8'),original);
 assert.equal(read(path.join(f.actual,'mcp.json')).mcpServers.pi_shared_runtime,undefined);
 if(side==='canonical')assert.deepEqual(read(path.join(f.actual,'settings.json')).packages,[]);
});
for(const side of ['canonical','actual'])test(`turning off ${side} retires only the managed alternate bridge`,t=>{
 const f=fixture(t);f.run();choice(f[side],'disabled');f.run();assert.equal(read(path.join(f.actual,'mcp.json')).mcpServers.pi_shared_runtime,undefined);
});
test('a user-owned alternate bridge collision survives enable and disable',t=>{
 const f=fixture(t),custom={command:'my-own-bridge'};write(path.join(f.actual,'mcp.json'),{mcpServers:{custom:{command:'keep'},pi_shared_runtime:custom}});
 f.run();assert.deepEqual(read(path.join(f.actual,'mcp.json')).mcpServers.pi_shared_runtime,custom);
 choice(f.actual,'disabled');f.run();assert.deepEqual(read(path.join(f.actual,'mcp.json')).mcpServers.pi_shared_runtime,custom);
});

test('an alternate directory symlink to canonical data does not create a recursive bridge',t=>{
 const f=fixture(t),alias=path.join(f.root,'canonical-alias');fs.symlinkSync(f.canonical,alias,'dir');
 const before=fs.readFileSync(path.join(f.canonical,'mcp.json'),'utf8');
 const r=spawnSync(process.execPath,[helper],{env:{...process.env,HOME:f.home,PI_SHARED_DATA_DIR:f.canonical,PI_CODING_AGENT_DIR:alias,PI_SHARED_RUNTIME_BUNDLE_DIR:bundle},encoding:'utf8'});
 assert.equal(r.status,0,r.stderr);assert.equal(fs.readFileSync(path.join(f.canonical,'mcp.json'),'utf8'),before);
 assert.equal(fs.existsSync(path.join(f.canonical,'shared-runtime/distribution-bridge.json')),false);
});
for (const probe of [false,true]) test(`shipped Pi wrapper ${probe?'skips pure discovery':'registers alternate resources'} while preserving HOME and credentials`,t=>{
 const f=fixture(t),install=path.join(f.root,'install'),bin=path.join(install,'bin');
 fs.mkdirSync(bin,{recursive:true});fs.mkdirSync(path.join(install,'node/bin'),{recursive:true});
 fs.symlinkSync(process.execPath,path.join(install,'node/bin/node'));fs.symlinkSync(bundle,path.join(install,'shared-runtime'),'dir');
 for(const name of ['pi','pi-agent-env.sh','pi-agent-shared-session.mjs'])fs.copyFileSync(path.resolve('rootfs/bin',name),path.join(bin,name));
 fs.writeFileSync(path.join(install,'session-home.state'),'test');
 const cli=path.join(install,'piweb/lib/node_modules/@agegr/pi-web/node_modules/@earendil-works/pi-coding-agent/dist/cli.js');
 fs.mkdirSync(path.dirname(cli),{recursive:true});fs.writeFileSync(cli,'console.log(JSON.stringify({home:process.env.HOME,agentDir:process.env.PI_CODING_AGENT_DIR,shared:process.env.PI_SHARED_DATA_DIR,args:process.argv.slice(2)}))');
 // The wrapper pins SDK lookup to its own installation, just as the actual
 // installer does. A CLI-only fixture accidentally passed on machines with a
 // global Pi Web SDK while failing on a clean runner.
 const sdkCandidates=[path.join(bundle,'node_modules/@earendil-works/pi-coding-agent'),process.env.PI_SHARED_SDK_ROOT&&path.join(process.env.PI_SHARED_SDK_ROOT,'node_modules/@earendil-works/pi-coding-agent')].filter(Boolean);
 const sourceSdk=sdkCandidates.find(dir=>fs.existsSync(path.join(dir,'package.json')));
 assert.ok(sourceSdk,'fixture requires the verified distribution SDK');
 const manifest=read(path.join(sourceSdk,'package.json'));
 const entry=manifest.exports?.['.']?.import||manifest.module||manifest.main;
 const fixtureSdk=path.dirname(path.dirname(cli));
 write(path.join(fixtureSdk,'package.json'),{name:'@earendil-works/pi-coding-agent',type:'module',main:'index.mjs'});
 fs.symlinkSync(fs.realpathSync(path.join(sourceSdk,entry)),path.join(fixtureSdk,'index.mjs'));
 const r=spawnSync('bash',[path.join(bin,'pi'),...(probe?['--version']:['--print','fixture'])],{env:{...process.env,HOME:f.home,PI_AGENT_HOME:install,PI_AGENT_DATA_DIR:f.canonical,PI_CODING_AGENT_DIR:f.actual},encoding:'utf8',timeout:30000});
 assert.equal(r.status,0,r.stderr);assert.doesNotMatch(r.stderr,/shared session sync failed/);const result=JSON.parse(r.stdout);
 assert.equal(result.home,f.home);assert.equal(result.agentDir,f.actual);assert.equal(result.shared,f.canonical);
 assert.equal(read(path.join(f.actual,'auth.json')).fixture,'private-unmodified');
 assert.equal(Boolean(read(path.join(f.actual,'mcp.json')).mcpServers.pi_shared_runtime),!probe);
});
