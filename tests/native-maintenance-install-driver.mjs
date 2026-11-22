// Real packaged installer + explicit fake SDK transport. No command is spawned here.
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';
const [root, stateDir, mode, scenario, ambient = 'hardlink'] = process.argv.slice(2);
const { installDependencies } = await import(pathToFileURL(path.join(root, 'src/installer.mjs')));
const tool = path.join(stateDir, 'uv/tools/omnigent'), python = path.join(tool, 'bin/python');
let present = mode !== 'fresh';
const events = [], installs = [], installLinkModes = [];
const discover = async () => { events.push('discover'); return {
  omnigent: present ? {available:true,path:path.join(stateDir,'bin/omnigent'),python,version:'0.16.0'} : {available:false},
  uv:{available:true,path:'/fixture/uv'}, python:{available:true,path:'/fixture/python',version:'3.12.14'}
}; };
const run = async (command,args,options) => {
  if(command==='/fixture/uv') { events.push('uv'); installs.push(args); installLinkModes.push(options.env.UV_LINK_MODE); present=true; return {code:0}; }
  if(command===python && args[0].endsWith('omnigent-model-options-patch.py')) {
    events.push('model'); if(scenario==='model-throws')throw Error('fixture model failure');return {code:scenario==='model-fails'?1:0};
  }
  if(command===python && args[0]==='-I' && args[1]==='-B' && args[2].endsWith('maintenance_preservation.py')) {
    events.push('maintenance');
    if(scenario==='guard-throws')throw Error('fixture guard failure');
    if(scenario==='guard-fails')return {code:1,stdout:'fixture refusal'};
    return {code:0,stdout:JSON.stringify({schema:'plugin-native-maintenance-preservation/v2',ok:true,state:'verified',
      sourceSha256:'68f4c2a3c0a3aa75436a15828e325bd279995435d83931d93b12516cca303962',sdkImported:false,
      purelib:path.join(tool,'lib/python3.12/site-packages'),distribution:'omnigent',coreVersion:'0.16.0',
      consoleEntryPoint:'omnigent.cli:main',consoleScriptValidated:true,pythonExecutable:python,
      consoleScript:path.join(tool,'bin/omnigent'),consoleScriptSha256:'a'.repeat(64)})};
  }
  throw Error('Unexpected command at synthetic SDK seam');
};
const env={PATH:'/fixture/bin',HOME:stateDir,PI_AGENT_HOME:stateDir,PI_OMNIGENT_UV_CONSTRAINTS:'/fixture/reviewed-constraints',
  ...(ambient === 'unset' ? {} : {UV_LINK_MODE:ambient})};
const originalEnv = {...env};
const result=await installDependencies({home:stateDir,stateDir,env,run,discover,platform:'darwin',arch:'x64',update:mode==='force'});
// Assert outside the installer's catch blocks so a copy regression cannot hide
// behind the expected failure of a separate guard/model fixture.
assert.deepEqual(installLinkModes,['copy']);
assert.deepEqual(env,originalEnv);
console.log(JSON.stringify({events,installs,installLinkModes,ambientLinkMode:env.UV_LINK_MODE ?? null,
  callerEnvUnchanged:true,ok:result.ok,maintenance:result.maintenancePreservation,issues:result.issues}));
