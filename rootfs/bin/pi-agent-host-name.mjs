#!/usr/bin/env node
/**
 * pi-agent-host-name -- the name this install's Omnigent host registers under.
 *
 *   pi-agent-host-name seed           give a never-named install a unique name
 *   pi-agent-host-name check [--json] report the name, whether it is safe, and the
 *                                     plugin's last refusal to start a host (if any)
 *   pi-agent-host-name set NAME       choose the name (any name, see below)
 *
 * WHY. The Omnigent server identifies a host by its host_id AND, per account, by
 * its name. When a daemon connects under a name that another host of the same
 * account holds, the server deletes the old registration row, creates a new one
 * and repoints every conversation bound to the old row at it. Two live daemons
 * with one name therefore take each other's row away on every tunnel reconnect,
 * and conversations follow whichever connected last. A scoped install and the
 * machine owner's own Omnigent both default to the machine's hostname, so on a
 * workstation that already runs Omnigent that is exactly what happened. See
 * docs/OPERATIONS-GOTCHAS.md section 13.
 *
 * SO the default is a name that is unique by construction: "<hostname>
 * (pi-agent)". `seed` writes it into this install's own host config -- and only
 * when no name is there. omnigent keeps a name it finds (host/identity.py,
 * load_or_create_host_identity: "a partial host section is completed rather than
 * discarded") and generates only the host_id, so the section `seed` writes is
 * deliberately partial.
 *
 *   * An existing name is NEVER replaced by `seed`, including one that equals
 *     the plain hostname: that host may be registered and in use, so it gets a
 *     warning and a way out, not a surprise rename.
 *   * `set` takes any name, on purpose. Replacing an existing host while keeping
 *     its conversations means taking over ITS name (docs/SESSION-HOME.md, "mode
 *     B"); that is `set "<the old host's exact name>"`, and the connect is then
 *     refused until PI_AGENT_TAKEOVER_HOST_ID names the host being replaced.
 *   * A running host keeps the name it started with (omnigent fixes it when the
 *     daemon is constructed); restart it after `set`.
 *
 * WHICH FILE. Only $PI_AGENT_HOME/home/.omnigent/config.yaml: the scoped home the
 * plugin and the host use (pi-agent-env.sh scopes HOME; the plugin resolves
 * $HOME/.omnigent). OMNIGENT_CONFIG_HOME and the real home are deliberately not
 * consulted -- on a workstation with its own Omnigent they point at somebody's
 * live host. The path is printed by every command.
 *
 * HOW. The scoped Node has no YAML library, and omnigent writes this file with
 * yaml.safe_dump (block style, ASCII-escaped). So the edit is textual and touches
 * the `name:` line of the top-level `host:` block (or adds one); every other
 * line is kept byte for byte. A shape it does not understand (flow style, a
 * block scalar, a duplicate key) is refused rather than guessed at, and the
 * result is read back and compared line by line before anything is written.
 * Writes are atomic, mode 0600, and the first change to an existing file keeps a
 * copy next to it (config.yaml.pre-host-name.bak).
 *
 * Exit status: 0 ok; 1 check found a name that can collide (or none yet);
 * 2 usage; 3 the config could not be read or safely edited.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const SUFFIX = ' (pi-agent)';
const MAX_NAME = 200;                       // the plugin shows at most 256 characters
const BACKUP = '.pre-host-name.bak';

export class EditError extends Error {}

// ------------------------------------------------------------------- names ---

// PI_AGENT_HOSTNAME exists for tests and for the odd machine whose hostname is
// not what omnigent will see; omnigent itself uses socket.gethostname().
export function plainHostname() {
  return (process.env.PI_AGENT_HOSTNAME || os.hostname() || '').trim() || 'localhost';
}
export function defaultName(host = plainHostname()) { return `${host}${SUFFIX}`; }

export function validateName(name) {
  if (typeof name !== 'string' || name === '') throw new EditError('the name is empty');
  if (name !== name.trim()) throw new EditError('the name has leading or trailing whitespace; the server matches names exactly, so this would silently be a different name');
  // C0/C1 controls, DEL and the Unicode line separators: none belong in a host name and
  // the last three are line breaks to some YAML readers.
  for (const ch of name) {
    const cp = ch.codePointAt(0);
    if (cp < 0x20 || (cp >= 0x7f && cp <= 0x9f) || cp === 0x2028 || cp === 0x2029) {
      throw new EditError('the name contains a control or line-break character');
    }
  }
  if ([...name].length > MAX_NAME) throw new EditError(`the name is longer than ${MAX_NAME} characters`);
  return name;
}

// ------------------------------------------------------------ YAML scalars ---

const DQ_SIMPLE = { 0: '\0', a: '\x07', b: '\b', t: '\t', '\t': '\t', n: '\n', v: '\v', f: '\f', r: '\r', e: '\x1b',
  ' ': ' ', '"': '"', '/': '/', '\\': '\\', N: '\u0085',
  _: String.fromCharCode(0xa0), L: String.fromCharCode(0x2028), P: String.fromCharCode(0x2029) };

function decodeDoubleQuoted(raw) {
  let out = '';
  for (let i = 0; i < raw.length; i++) {
    const c = raw[i];
    if (c !== '\\') { out += c; continue; }
    const n = raw[++i];
    if (n in DQ_SIMPLE) { out += DQ_SIMPLE[n]; continue; }
    const len = n === 'x' ? 2 : n === 'u' ? 4 : n === 'U' ? 8 : 0;
    if (!len) return null;
    const hex = raw.slice(i + 1, i + 1 + len);
    if (!new RegExp(`^[0-9a-fA-F]{${len}}$`).test(hex)) return null;
    const cp = parseInt(hex, 16);
    if (cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return null;
    out += String.fromCodePoint(cp);
    i += len;
  }
  return out;
}

// Parse the text after "key:" as one scalar. Understands what yaml.safe_dump
// writes for a string (plain, 'single', "double" with \u escapes) plus a trailing
// comment. Anything else (block scalar, anchor, tag, flow collection) -> null.
export function readScalar(text) {
  const s = text.replace(/^\s+/, '');
  if (s === '' || s[0] === '#') return { kind: 'empty', value: null, comment: s };
  if (s[0] === '"') {
    let i = 1;
    for (; i < s.length; i++) {
      if (s[i] === '\\') { i++; continue; }
      if (s[i] === '"') break;
    }
    if (i >= s.length) return null;
    const after = s.slice(i + 1);
    if (!/^\s*(#.*)?$/.test(after)) return null;
    const value = decodeDoubleQuoted(s.slice(1, i));
    return value === null ? null : { kind: 'double', value, comment: after.trim() };
  }
  if (s[0] === "'") {
    let out = '';
    let i = 1;
    for (; i < s.length; i++) {
      if (s[i] === "'") { if (s[i + 1] === "'") { out += "'"; i++; continue; } break; }
      out += s[i];
    }
    if (i >= s.length) return null;
    const after = s.slice(i + 1);
    return /^\s*(#.*)?$/.test(after) ? { kind: 'single', value: out, comment: after.trim() } : null;
  }
  if ('|>&*!%@`[{'.includes(s[0])) return null;
  const m = /^(.*?)(\s+#.*)?$/.exec(s);
  const plain = m[1].trimEnd();
  return { kind: 'plain', value: /^(~|null|Null|NULL)$/.test(plain) ? null : plain, comment: (m[2] || '').trim() };
}

// A double-quoted YAML scalar that every reader decodes the same way: printable
// ASCII as is, everything else as \uXXXX / \UXXXXXXXX -- which is also what
// yaml.safe_dump itself writes for non-ASCII text, so the file stays one style.
export function encodeScalar(value) {
  let out = '"';
  for (const ch of value) {
    const cp = ch.codePointAt(0);
    if (ch === '"') out += '\\"';
    else if (ch === '\\') out += '\\\\';
    else if (cp >= 0x20 && cp < 0x7f) out += ch;
    else if (cp <= 0xffff) out += `\\u${cp.toString(16).toUpperCase().padStart(4, '0')}`;
    else out += `\\U${cp.toString(16).toUpperCase().padStart(8, '0')}`;
  }
  return `${out}"`;
}

// ------------------------------------------------------------- config text ---

/**
 * Locate the top-level `host:` mapping and its `name` / `host_id` keys.
 *   state  'none'         no top-level host key
 *          'block'        `host:` with indented children (name may or may not be there)
 *          'flow'         `host: {…}` on one line -- name is read, never edited
 *          'unsupported'  something we will not touch (reason says what)
 */
export function analyze(text) {
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const lines = text.split(/\r?\n/);
  const out = { eol, lines, state: 'none', hostIdx: -1, childIndent: 2, nameIdx: -1, name: undefined, hostId: undefined };

  const hostIdxs = [];
  lines.forEach((l, i) => { if (/^host\s*:/.test(l)) hostIdxs.push(i); });
  if (hostIdxs.length === 0) return out;
  if (hostIdxs.length > 1) return { ...out, state: 'unsupported', reason: 'more than one top-level "host:" key' };
  const hostIdx = hostIdxs[0];
  out.hostIdx = hostIdx;

  const rest = lines[hostIdx].replace(/^host\s*:/, '');
  const trimmed = rest.replace(/\s+#.*$/, '').trim();
  if (trimmed.startsWith('{')) {
    // One-line flow mapping: enough to read a name someone typed from omnigent's own docstring.
    const m = /[{,]\s*["']?name["']?\s*:\s*("(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^,}]*)/.exec(trimmed);
    const scalar = m ? readScalar(m[1]) : null;
    return { ...out, state: 'flow', name: m ? (scalar ? scalar.value : undefined) : null,
      reason: 'the host section is written in flow style ({…}); edit it by hand' };
  }
  const head = readScalar(rest);
  if (!head || head.kind !== 'empty') return { ...out, state: 'unsupported', reason: 'the host section is not a block mapping' };

  const content = [];
  for (let j = hostIdx + 1; j < lines.length; j++) {
    const l = lines[j];
    if (l.trim() === '' || l.trimStart().startsWith('#')) continue;
    if (!/^\s/.test(l)) break;
    content.push(j);
  }
  if (content.length === 0) return { ...out, state: 'block' };
  const firstIndent = /^( *)/.exec(lines[content[0]])[1].length;
  if (/^\s*\t/.test(lines[content[0]])) return { ...out, state: 'unsupported', reason: 'the host section is indented with tabs' };
  out.childIndent = firstIndent;
  out.state = 'block';

  const key = (k) => new RegExp(`^ {${firstIndent}}${k}\\s*:(.*)$`);
  for (const j of content) {
    const nm = key('name').exec(lines[j]);
    if (nm) {
      if (out.nameIdx !== -1) return { ...out, state: 'unsupported', reason: 'more than one "name:" key in the host section' };
      out.nameIdx = j;
      const scalar = readScalar(nm[1]);
      const next = content.find((x) => x > j);
      const continued = next !== undefined && /^( *)/.exec(lines[next])[1].length > firstIndent;
      if (!scalar || continued) return { ...out, state: 'unsupported', reason: 'the "name:" value is not a simple scalar' };
      out.name = scalar.value;
      out.nameComment = scalar.comment;
    }
    const hid = key('host_id').exec(lines[j]);
    if (hid) { const s = readScalar(hid[1]); out.hostId = s ? s.value : undefined; }
  }
  return out;
}

function rebuild(a, edit) {
  const lines = a.lines.slice();
  edit(lines);
  return lines.join(a.eol);
}

/**
 * The config text with host.name = name. Returns { text, action } where action is
 * 'created' | 'added' | 'replaced' | 'unchanged'. Throws EditError when the
 * existing text is not safely editable or the result does not read back.
 */
export function withName(text, name) {
  validateName(name);
  const quoted = encodeScalar(name);
  const a = analyze(text);
  if (a.state === 'unsupported' || a.state === 'flow') throw new EditError(a.reason);

  let next, action;
  if (a.state === 'none') {
    const body = text === '' || text.endsWith('\n') ? text : text + a.eol;
    next = `${body}host:${a.eol}  name: ${quoted}${a.eol}`;
    action = text === '' ? 'created' : 'added';
  } else if (a.nameIdx === -1 || a.name === null) {
    // `host:` with no (or an empty) name: put the key first among its children.
    next = rebuild(a, (lines) => {
      if (a.nameIdx !== -1) lines.splice(a.nameIdx, 1);
      lines.splice(a.hostIdx + 1, 0, `${' '.repeat(a.childIndent)}name: ${quoted}`);
    });
    action = 'added';
  } else if (a.name === name) {
    return { text, action: 'unchanged' };
  } else {
    next = rebuild(a, (lines) => {
      lines[a.nameIdx] = `${' '.repeat(a.childIndent)}name: ${quoted}${a.nameComment ? `  ${a.nameComment}` : ''}`;
    });
    action = 'replaced';
  }

  // Read-back: the new name is what we meant, and only the lines we meant to touch changed.
  const b = analyze(next);
  if (b.state !== 'block' || b.name !== name) throw new EditError('the edited file did not read back with the new name; nothing was written');
  const before = new Set(a.lines);
  const foreign = b.lines.filter((l) => !before.has(l));
  const expected = new Set([`${' '.repeat(a.state === 'none' ? 2 : a.childIndent)}name: ${quoted}`, ...(a.state === 'none' ? ['host:', ''] : [])]);
  if (foreign.some((l) => !expected.has(l) && !(a.nameComment && l.startsWith(`${' '.repeat(a.childIndent)}name: ${quoted}`)))) {
    throw new EditError('the edit would have changed more than the name line; nothing was written');
  }
  return { text: next, action };
}

// ---------------------------------------------------------------- file I/O ---

export function configPath(home = process.env.PI_AGENT_HOME) {
  if (!home) throw new EditError('PI_AGENT_HOME is not set');
  return path.join(home, 'home', '.omnigent', 'config.yaml');
}

function readConfig(file) {
  try { return fs.readFileSync(file, 'utf8'); }
  catch (error) { if (error.code === 'ENOENT') return ''; throw new EditError(`cannot read ${file} (${error.code ?? error.message})`); }
}

function writeConfig(file, text, hadFile) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  if (hadFile) {
    const backup = file + BACKUP;
    if (!fs.existsSync(backup)) { fs.copyFileSync(file, backup); fs.chmodSync(backup, 0o600); }
  }
  const tmp = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.tmp`);
  try {
    fs.writeFileSync(tmp, text, { mode: 0o600 });
    fs.chmodSync(tmp, 0o600);
    fs.renameSync(tmp, file);
  } catch (error) {
    try { fs.unlinkSync(tmp); } catch { /* nothing to clean */ }
    throw new EditError(`cannot write ${file} (${error.code ?? error.message})`);
  }
  fs.chmodSync(file, 0o600);
}

// The plugin keeps the last failed operation in <data>/omnigent-plugin/state.json as
// { code, message }. The CLI's `connect` prints only the code and Settings shows a
// fixed hint, so this is where the full text of a HOST_NAME_* refusal -- the other
// host's name and id, and the exact commands with the id filled in -- can be read
// as it was written, newlines and all. A later successful operation clears it.
function lastRefusal(home = process.env.PI_AGENT_HOME) {
  const dataDir = process.env.PI_AGENT_DATA_DIR || path.join(home, 'data');
  try {
    const issue = JSON.parse(fs.readFileSync(path.join(dataDir, 'omnigent-plugin', 'state.json'), 'utf8'))?.issue;
    if (issue && /^HOST_NAME_[A-Z_]+$/.test(issue.code) && typeof issue.message === 'string' && issue.message) {
      return { code: issue.code, message: issue.message };
    }
  } catch { /* no state yet, or not readable: nothing to show */ }
  return null;
}

const same = (a, b) => typeof a === 'string' && typeof b === 'string' && a.trim().toLowerCase() === b.trim().toLowerCase();

// A cutover (docs/MACOS-CUTOVER.md) leaves CUTOVER=yes and the replaced host's name in
// $PI_AGENT_HOME/session-home.state: this install's host then carries that identity ON PURPOSE,
// and on a Mac that name is usually the plain hostname. It is not a collision -- the replaced
// host is gone and its server row is this host's -- and "renaming" it would rename the owner's
// own host on the server. Exact on purpose: only a cutover record naming this very name counts.
function adoptedByCutover(name, home = process.env.PI_AGENT_HOME) {
  if (!home) return false;
  let text;
  try { text = fs.readFileSync(path.join(home, 'session-home.state'), 'utf8'); } catch { return false; }
  const value = (key) => { const m = new RegExp(`^${key}=(.*)$`, 'm').exec(text); return m ? m[1] : null; };
  return value('CUTOVER') === 'yes' && same(value('OLD_HOST_NAME'), name);
}

function collisionWarning(name, host) {
  return [
    `WARN: this install's Omnigent host is named "${name}", the same as the machine itself ("${host}").`,
    'WARN: any other Omnigent host of the same account with that name (the machine owner\'s own Omnigent app, an older install) makes the server',
    'WARN: delete and re-create each other\'s registration on every reconnect and move conversations between them. It was NOT renamed: it may be registered.',
    `WARN: check: pi-agent-host-name check      rename: pi-agent-host-name set "${defaultName(host)}"  (then restart the host)`,
  ];
}

// ---------------------------------------------------------------- commands ---

function seed(file) {
  const host = plainHostname();
  const text = readConfig(file);
  const a = analyze(text);
  if (a.state === 'unsupported' || (a.state === 'flow' && a.name === null)) {
    return { code: 0, lines: [`WARN: not seeding a host name: ${a.reason} (${file}). Run: pi-agent-host-name set NAME after fixing it by hand.`] };
  }
  const hasName = (a.state === 'block' || a.state === 'flow') && typeof a.name === 'string' && a.name !== '';
  if (hasName) {
    if (same(a.name, host) && adoptedByCutover(a.name)) {
      return { code: 0, lines: [`KEPT host.name="${a.name}" (taken over from the replaced host by the cutover, on purpose; docs/MACOS-CUTOVER.md)`] };
    }
    const lines = [`KEPT host.name="${a.name}" (already set; seed never overwrites)`];
    if (same(a.name, host)) lines.push(...collisionWarning(a.name, host));
    return { code: 0, lines };
  }
  if (a.state === 'flow') return { code: 0, lines: [`WARN: not seeding a host name: ${a.reason} (${file}).`] };
  const name = defaultName(host);
  const r = withName(text, name);
  writeConfig(file, r.text, text !== '');
  return { code: 0, lines: [`SEEDED host.name="${name}" in ${file} (unique on this machine by construction; omnigent keeps it and generates only the host_id)`] };
}

function check(file, json) {
  const host = plainHostname();
  const text = readConfig(file);
  const a = analyze(text);
  const name = typeof a.name === 'string' && a.name !== '' ? a.name : null;
  const registered = typeof a.hostId === 'string' && a.hostId !== '' ? a.hostId : null;
  const bad = a.state === 'unsupported';
  const collides = name !== null && same(name, host);
  const adopted = collides && adoptedByCutover(name);
  const status = bad ? 'unreadable' : name === null ? 'unset' : adopted ? 'adopted' : collides ? 'plain-hostname' : 'ok';
  const refusal = lastRefusal();
  const code = bad ? 3 : (status === 'ok' || status === 'adopted') && !refusal ? 0 : 1;
  if (json) {
    return { code, lines: [JSON.stringify({ config: file, hostname: host, name, hostId: registered, status, lastRefusal: refusal })] };
  }
  const lines = [
    `config:    ${file}`,
    `hostname:  ${host}`,
    `host name: ${name ?? '(not set)'}`,
    `host id:   ${registered ? `${registered.replace(/-/g, '').slice(0, 8)}…` : '(not registered yet)'}`,
  ];
  if (bad) lines.push(`status:    unreadable — ${a.reason}`);
  else if (status === 'ok') lines.push('status:    ok — differs from the machine\'s own name; the server also checks it before every connect');
  else if (status === 'adopted') lines.push('status:    adopted — the replaced host\'s own name, taken over by the cutover on purpose; leave it (docs/MACOS-CUTOVER.md)');
  else if (status === 'unset') lines.push(`status:    not set — the host would register as "${host}". Run: pi-agent-host-name seed`);
  else lines.push('status:    COLLISION-PRONE — equals the machine\'s own name, the default of every other Omnigent host here', ...collisionWarning(name, host).slice(1).map((l) => l.replace(/^WARN: /, '  ')));
  if (refusal) lines.push('', `The plugin refused to start this host (${refusal.code}); its message:`, '', refusal.message);
  return { code, lines };
}

function setName(file, name) {
  const host = plainHostname();
  const text = readConfig(file);
  const before = analyze(text).name;
  const r = withName(text, name);
  if (r.action !== 'unchanged') writeConfig(file, r.text, text !== '');
  const lines = [r.action === 'unchanged'
    ? `UNCHANGED host.name="${name}" in ${file}`
    : `SET host.name="${name}"${typeof before === 'string' && before ? ` (was "${before}")` : ''} in ${file}`,
  'NOTE: a running host keeps its old name until it restarts: pi-agent restart'];
  if (same(name, host)) {
    lines.push(`WARN: "${name}" is the machine's own name. If another Omnigent host of this account already uses it, connecting is refused`,
      'WARN: unless PI_AGENT_TAKEOVER_HOST_ID=<first 8+ hex characters of that host\'s id> is set -- see docs/SESSION-HOME.md (replacing a host on purpose).');
  } else if (!same(name, defaultName(host))) {
    lines.push('NOTE: if another host of this account already has exactly this name, connecting is refused unless PI_AGENT_TAKEOVER_HOST_ID=<first 8+ hex characters of that host\'s id> is set (replacing it on purpose; the old host must be stopped first).');
  }
  return { code: 0, lines };
}

const USAGE = `usage: pi-agent-host-name seed | check [--json] | set NAME
  seed   write "<hostname> (pi-agent)" as host.name if the install has no name yet (never overwrites)
  check  show the name, whether it equals the machine's own, and -- if the plugin refused to start
         the host because the name is taken -- the refusal in full, with the exact commands
         (exit 1 for a plain-hostname or unset name, or a refusal)
  set    choose the name; any name, including an old host's exact name when replacing it on purpose`;

export function main(argv) {
  const [cmd, ...args] = argv;
  if (!cmd || cmd === '-h' || cmd === '--help' || cmd === 'help') { console.log(USAGE); return cmd ? 0 : 2; }
  let file;
  try { file = configPath(); } catch (error) { console.error(`pi-agent-host-name: ${error.message}`); return 3; }
  try {
    let r;
    if (cmd === 'seed' && args.length === 0) r = seed(file);
    else if (cmd === 'check' && (args.length === 0 || (args.length === 1 && args[0] === '--json'))) r = check(file, args[0] === '--json');
    else if (cmd === 'set' && args.length === 1) r = setName(file, args[0]);
    else { console.error(USAGE); return 2; }
    for (const line of r.lines) console.log(line);
    return r.code;
  } catch (error) {
    if (!(error instanceof EditError)) throw error;
    // `seed` runs inside the installer and must never fail it; `set` and `check` report.
    if (cmd === 'seed') { console.log(`WARN: not seeding a host name: ${error.message}`); return 0; }
    console.error(`pi-agent-host-name: ${error.message}`);
    return 3;
  }
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) process.exit(main(process.argv.slice(2)));
