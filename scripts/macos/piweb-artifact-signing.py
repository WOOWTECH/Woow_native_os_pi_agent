#!/usr/bin/env python3
"""Safely stage, sign every Mach-O, verify, and publish a NEW pinned archive."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import pwd
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile

MAGIC = {bytes.fromhex(x) for x in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
                                  'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
NAME = re.compile(r'piweb-[A-Za-z0-9._+-]+-macos-(arm64|x64)\.tar\.gz\Z')


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def run(args, env=None):
    r = subprocess.run(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode:
        raise RuntimeError(f'{args[0]} failed (exit {r.returncode}): {r.stdout.strip()}')
    return r.stdout


def member_name(name):
    p = PurePosixPath(name)
    if p.is_absolute() or '..' in p.parts or '\\' in name or '\0' in name:
        raise ValueError(f'unsafe archive path: {name!r}')
    return str(p)


def unpack(archive, root):
    """No extractall: validate the complete graph, write files, then links.

    Never write through archive symlinks; discard AppleDouble bookkeeping and
    ignore pax xattrs/owners. Source files, including .git refs, keep their bytes.
    """
    with tarfile.open(archive, 'r:gz') as tf:
        entries = {}
        root_metadata = None
        for m in tf.getmembers():
            name = member_name(m.name)
            if any(p.startswith('._') or p == '__MACOSX' for p in PurePosixPath(name).parts):
                continue
            if name == '.' and m.isdir():
                root_metadata = (m.mode & 0o777, m.mtime)
                continue
            if name in entries:
                raise ValueError(f'duplicate archive entry: {name!r}')
            if not (m.isdir() or m.isfile() or m.issym() or m.islnk()) or m.mode & 0o7000:
                raise ValueError(f'unsupported archive entry/type/mode: {name!r}')
            entries[name] = m
        for name, m in entries.items():
            for parent in PurePosixPath(name).parents:
                if str(parent) in entries and not entries[str(parent)].isdir():
                    raise ValueError(f'archive writes through a non-directory: {name!r}')
            if m.issym():
                target = posixpath.normpath(posixpath.join(posixpath.dirname(name), m.linkname))
                member_name(target)
                if posixpath.isabs(m.linkname):
                    raise ValueError(f'absolute symlink: {name!r}')
            elif m.islnk():
                target = member_name(m.linkname)
                if target not in entries or not entries[target].isfile():
                    raise ValueError(f'hardlink must target a regular member: {name!r}')
        for name, m in entries.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            if m.isdir():
                path.mkdir(exist_ok=True)
            elif m.isfile():
                with tf.extractfile(m) as src, open(path, 'xb') as dst:
                    shutil.copyfileobj(src, dst)
                os.chmod(path, m.mode & 0o777)
                os.utime(path, (m.mtime, m.mtime))
        for name, m in entries.items():
            path = root / name
            if m.islnk():
                # Materialize as a separate file so codesign cannot mutate an alias.
                shutil.copy2(root / member_name(m.linkname), path)
            elif m.issym():
                path.symlink_to(m.linkname)
        for name, m in entries.items():
            path = root / name
            if m.issym() and not path.resolve().is_relative_to(root.resolve()):
                raise ValueError(f'symlink chain escapes archive: {name!r}')
        # Directories stay owner-writable during signing/repacking. Their original
        # permissions and mtimes are restored just before packaging.
        directories = {name: (m.mode & 0o777, m.mtime) for name, m in entries.items() if m.isdir()}
        if root_metadata is not None:
            directories['.'] = root_metadata
        return directories


def inventory(root):
    regular, links = {}, {}
    for parent, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            p = Path(parent) / name
            rel = p.relative_to(root).as_posix()
            if p.is_symlink():
                links[rel] = os.readlink(p)
            elif p.is_file():
                regular[rel] = (stat.S_IMODE(p.stat().st_mode), digest(p))
    return regular, links


def native_files(root, regular):
    result = []
    for rel in sorted(regular):
        p = root / rel
        with open(p, 'rb') as f:
            candidate = f.read(4) in MAGIC
        # Magic filters cheaply; file distinguishes Java class CAFEBABE from fat Mach-O.
        if candidate and 'Mach-O' in run(['file', '-b', str(p)]):
            result.append(rel)
    if not result:
        raise ValueError('archive contains no Mach-O files; refusing an empty native verification')
    return result


def verify(path, identity, env):
    run(['codesign', '--verify', '--strict', '--all-architectures', '--verbose=2', str(path)], env)
    arches = run(['lipo', '-archs', str(path)], env).split()
    if not arches:
        raise ValueError(f'no Mach-O slices found: {path}')
    for arch in arches:
        detail = run(['codesign', '--display', '--verbose=4', '--architecture', arch, str(path)], env)
        authority = next((x.removeprefix('Authority=') for x in detail.splitlines()
                          if x.startswith('Authority=Developer ID Application: ')), None)
        if not authority or (identity and authority != identity):
            raise ValueError(f'{path} [{arch}]: missing or unexpected Developer ID Application authority')
        if not re.search(r'\bflags=[^\n]*\bruntime\b', detail, re.M):
            raise ValueError(f'{path} [{arch}]: hardened runtime flag missing')
        timestamp = re.search(r'^Timestamp=(.+)$', detail, re.M)
        if not timestamp or timestamp[1].strip().lower() in ('none', 'not set', 'unavailable'):
            raise ValueError(f'{path} [{arch}]: secure Timestamp missing')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--artifact-file', required=True, type=Path)
    ap.add_argument('--artifact-sha256', required=True)
    ap.add_argument('--out', type=Path, help='NEW filename ending in -macos-<same arch>.tar.gz')
    ap.add_argument('--sign-app', help='existing Developer ID Application identity; expected authority in verify-only mode')
    ap.add_argument('--keychain', type=Path)
    ap.add_argument('--verify-only', action='store_true', help='read-only: verify every native signature, no signing/repacking')
    args = ap.parse_args()
    if sys.version_info < (3, 9):
        ap.error('Python 3.9 or newer required on the build host')
    source = args.artifact_file.resolve()
    match = NAME.fullmatch(source.name)
    if not match or not source.is_file():
        ap.error('input must be an existing piweb-<version>-macos-<arm64|x64>.tar.gz')
    if not re.fullmatch('[0-9a-f]{64}', args.artifact_sha256):
        ap.error('explicit SHA256 must be 64 lowercase hex characters')
    if args.sign_app and not args.sign_app.startswith('Developer ID Application: '):
        ap.error('--sign-app must be a Developer ID Application identity')
    if args.verify_only:
        if args.out or args.keychain:
            ap.error('--verify-only does not accept --out or --keychain')
    elif not args.out or not args.sign_app:
        ap.error('signing needs --out and --sign-app')
    if args.out and args.out.is_symlink():
        ap.error('output must not be a symlink')
    output = args.out.resolve() if args.out else None
    if output:
        outmatch = NAME.fullmatch(output.name)
        if not outmatch or outmatch[1] != match[1] or output == source:
            ap.error('--out must be a NEW piweb filename with the same architecture suffix')
        for p in (output, Path(str(output) + '.sha256'), Path(str(output) + '.signing.json')):
            if p.exists() or p.is_symlink():
                ap.error(f'refusing to overwrite output: {p}')
    if run(['uname', '-s']).strip() != 'Darwin':
        ap.error('macOS build host required')
    env = dict(os.environ, HOME=pwd.getpwuid(os.getuid()).pw_dir)
    if args.keychain and not args.keychain.is_file():
        ap.error('keychain path does not exist')
    with tempfile.TemporaryDirectory(prefix='piweb-sign-') as tmp:
        work = Path(tmp)
        snapshot = work / 'input.tar.gz'
        shutil.copyfile(source, snapshot)
        if digest(snapshot) != args.artifact_sha256:
            raise ValueError('input artifact SHA256 mismatch; nothing unpacked or signed')
        root = work / 'tree'
        root.mkdir()
        directory_metadata = unpack(snapshot, root)
        before, links = inventory(root)
        natives = native_files(root, before)
        print(f'Found {len(natives)} Mach-O files (all extensions and executable modes)', flush=True)
        original_keychains = None
        try:
            if args.keychain:
                original_keychains = shlex.split(run(['security', 'list-keychains', '-d', 'user'], env))
                run(['security', 'list-keychains', '-d', 'user', '-s', str(args.keychain.resolve()), *original_keychains], env)
            for rel in natives:
                path = root / rel
                print(('verify ' if args.verify_only else 'sign + verify ') + repr(rel), flush=True)
                if not args.verify_only:
                    mode = stat.S_IMODE(path.stat().st_mode)
                    os.chmod(path, mode | stat.S_IWUSR)
                    try:
                        cmd = ['codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', args.sign_app]
                        if args.keychain:
                            cmd += ['--keychain', str(args.keychain.resolve())]
                        run(cmd + [str(path)], env)
                    finally:
                        os.chmod(path, mode)
                verify(path, args.sign_app, env)
        finally:
            if original_keychains is not None:
                run(['security', 'list-keychains', '-d', 'user', '-s', *original_keychains], env)
        after, after_links = inventory(root)
        if before.keys() != after.keys() or links != after_links:
            raise ValueError('signing changed archive entries or symlinks')
        for rel in before:
            if rel not in natives and before[rel] != after[rel]:
                raise ValueError(f'signing changed non-native source metadata/content: {rel!r}')
        if args.verify_only:
            print(f'PASS: {len(natives)} native files; strict signatures, all-slice Developer ID/runtime/timestamp')
            return
        for rel, (mode, mtime) in sorted(directory_metadata.items(), reverse=True):
            os.chmod(root / rel, mode)
            os.utime(root / rel, (mtime, mtime))
        result = work / 'signed.tar.gz'
        with tarfile.open(result, 'w:gz', format=tarfile.PAX_FORMAT, dereference=False) as tf:
            tf.add(root, arcname='.')
        output_sha = digest(result)
        report = dict(input_sha256=args.artifact_sha256, output_sha256=output_sha,
                      architecture=match[1], identity=args.sign_app,
                      non_native_files_unchanged=True, symlinks_unchanged=True,
                      native_files=[dict(path=rel, before_sha256=before[rel][1], after_sha256=after[rel][1]) for rel in natives])
        output.parent.mkdir(parents=True, exist_ok=True)
        # Exclusive creation avoids overwriting a source or a concurrent build.
        with output.open('xb') as dst, result.open('rb') as src:
            shutil.copyfileobj(src, dst)
        with Path(str(output) + '.sha256').open('x') as f:
            f.write(f'{output_sha}  {output.name}\n')
        with Path(str(output) + '.signing.json').open('x') as f:
            json.dump(report, f, indent=2)
            f.write('\n')
        print(f'PASS: {output}\nSHA256={output_sha}', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, tarfile.TarError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
