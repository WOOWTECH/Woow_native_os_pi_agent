#!/usr/bin/env node
// Share the install's resources with an adopted Pi data directory without
// moving that directory's credentials, model selection or native conversations.
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const bundle = process.env.PI_SHARED_RUNTIME_BUNDLE_DIR;
const canonical = process.env.PI_SHARED_DATA_DIR;
const actual = process.env.PI_CODING_AGENT_DIR;
const home = process.env.HOME;
if (!bundle || !canonical || !actual || !home || path.resolve(actual) === path.resolve(canonical)) process.exit(0);
// An adopted path may already be a symlink to canonical data. Registering a
// bridge inside its own source MCP file would recursively expose itself.
const identity = value => { try { return fs.realpathSync(value); } catch (error) { if (error.code === 'ENOENT') return path.resolve(value); throw error; } };
if (identity(actual) === identity(canonical)) process.exit(0);
if (!fs.existsSync(path.join(bundle, 'src/distribution.mjs'))) process.exit(0);
// Resource synchronization must not initialize the shared extension or execute
// user extensions. This child-only mode retains SDK package/skill authority.
process.env.PI_SHARED_BRIDGE = '1';
const { seedDistribution, synchronizeDistribution } = await import(pathToFileURL(path.join(bundle, 'src/distribution.mjs')).href);
const { digest, readJSON, saveJSON, locked } = await import(pathToFileURL(path.join(bundle, 'src/common.mjs')).href);
const canonicalLoc = { home, data: canonical, state: path.join(canonical, 'shared-runtime') };
const actualLoc = { home, data: actual, state: path.join(actual, 'shared-runtime') };
const central = await seedDistribution(canonicalLoc);
if (central.busy) process.exit(0);
const local = central.status === 'enabled' ? await seedDistribution(actualLoc) : null;
if (local?.busy) process.exit(0);
// A disabled choice must retire its bridge even if another provider is syncing.
// An enabled concurrent initializer may finish canonical resources independently.
if (central.status === 'enabled' && local?.status === 'enabled') await synchronizeDistribution({ loc: canonicalLoc });
await locked(path.join(actualLoc.state, 'distribution-bridge.lock'), () => {
  const file = path.join(actual, 'mcp.json');
  const marker = path.join(actualLoc.state, 'distribution-bridge.json');
  const before = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null;
  const config = before === null ? {} : JSON.parse(before);
  if (config.mcpServers !== undefined && (!config.mcpServers || Array.isArray(config.mcpServers) || typeof config.mcpServers !== 'object')) throw new Error('Invalid Pi MCP settings');
  const previous = readJSON(marker), existing = config.mcpServers?.pi_shared_runtime;
  const entry = { command: process.execPath, args: [path.join(bundle, 'bin/bridge.mjs')],
    env: { PI_SHARED_HOME: home, PI_SHARED_DATA_DIR: canonical, PI_SHARED_BRIDGE: '1' } };
  const owned = existing && previous.hash === digest(existing);
  if (central.status !== 'enabled' || local?.status !== 'enabled') {
    if (!owned) return;
    delete config.mcpServers.pi_shared_runtime;
  } else {
    if (existing && !owned) return; // A user or another package owns this name.
    config.mcpServers ||= {};
    config.mcpServers.pi_shared_runtime = entry;
  }
  const current = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null;
  if (current !== before) throw new Error('Pi MCP settings changed during shared registration');
  saveJSON(file, config);
  saveJSON(marker, { schema: 1, hash: central.status === 'enabled' && local?.status === 'enabled' ? digest(entry) : null });
});
