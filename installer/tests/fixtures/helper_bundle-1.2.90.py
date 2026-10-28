#!/usr/bin/env python3
"""Bind an installer entry to its own immutable, offline helper cohort."""
import argparse
import base64
import errno
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import tarfile
import tempfile
import uuid

CONTRACT = 'helper-contract.json'
FOOTER = b'\n# REMNACUST_HELPERS_V1\n'
END = b'# END_REMNACUST_HELPERS_V1\n'
ANCHOR = re.compile(rb"(?m)^HELPER_BUNDLE_SHA256='[a-f0-9]{64}'$")
FILES = ('helper_bundle.py', 'runtime.py', 'database.cjs', 'subscription.cjs',
         'marzban.py', 'images.py', 'tls.py', 'update-agent.py', 'image_cleanup.py', 'node_firewall.py',
         'stable_entry.py', 'LICENSE', 'NOTICE.md')
MAX_RAW = 16 * 1024 * 1024
MAX_FILE = 2 * 1024 * 1024


def normalized(data):
    data.decode('utf-8')
    return data.replace(b'\r\n', b'\n')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def version_key(value):
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?', value):
        raise ValueError('Invalid helper version')
    core, _, prerelease = value.partition('-')
    identifiers = tuple((0, int(item)) if item.isdigit() else (1, item)
                        for item in prerelease.split('.') if item)
    return tuple(map(int, core.split('.'))), not bool(prerelease), identifiers


def code(entry):
    entry = normalized(entry)
    if entry.count(FOOTER) > 1:
        raise ValueError('Duplicate helper footer')
    if FOOTER in entry:
        entry, footer = entry.split(FOOTER)
        if not footer.endswith(END):
            raise ValueError('Incomplete helper footer')
        for line in footer[:-len(END)].splitlines():
            if not (line.startswith(b'# DATA ') or re.fullmatch(rb'# CACHE [a-f0-9]{64}(?:-[a-f0-9]{32})?', line)):
                raise ValueError('Unexpected helper footer content')
    if len(ANCHOR.findall(entry)) != 1:
        raise ValueError('Missing installer helper anchor')
    return entry.rstrip(b'\n') + b'\n'


def expected(entry):
    return ANCHOR.findall(code(entry))[0].split(b"'")[1].decode('ascii')


def canonical(entry):
    return ANCHOR.sub(b"HELPER_BUNDLE_SHA256='" + b'0' * 64 + b"'", code(entry))


def read(path, maximum=MAX_FILE):
    if path.is_symlink() or not path.is_file():
        raise ValueError('Helper must be a regular file: ' + str(path))
    with path.open('rb') as stream:
        data = stream.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError('Helper file too large')
    return normalized(data)


def manifest(raw):
    if len(raw) > 32768:
        raise ValueError('Helper manifest too large')
    data = json.loads(raw)
    if set(data) != {'schema', 'version', 'entry_sha256', 'files'} or data['schema'] != 1:
        raise ValueError('Unsupported helper manifest')
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?', data['version']):
        raise ValueError('Invalid helper version')
    if not re.fullmatch(r'[a-f0-9]{64}', data['entry_sha256']):
        raise ValueError('Invalid helper entry hash')
    files = data['files']
    if not isinstance(files, dict) or not set(FILES) <= set(files) or len(files) > 32:
        raise ValueError('Incomplete helper cohort')
    for name, item in files.items():
        if not re.fullmatch(r'(?:[A-Za-z0-9_-]+\.(?:py|cjs)|LICENSE|NOTICE\.md)', name):
            raise ValueError('Invalid helper filename')
        if not isinstance(item, dict) or set(item) != {'sha256', 'bytes'} or not re.fullmatch(r'[a-f0-9]{64}', item['sha256']):
            raise ValueError('Invalid helper identity')
        if type(item['bytes']) is not int or not 0 < item['bytes'] <= MAX_FILE:
            raise ValueError('Invalid helper size')
    if sum(item['bytes'] for item in files.values()) > MAX_RAW:
        raise ValueError('Helper cohort too large')
    return data


def read_files(root, raw, source=False):
    return {name: read(root.parent / name if source and name in {'LICENSE', 'NOTICE.md'} else root / name)
            for name in manifest(raw)['files']}


def validate(entry, raw, files):
    data = manifest(raw)
    if digest(raw) != expected(entry) or digest(canonical(entry)) != data['entry_sha256']:
        raise ValueError('Installer entry and helper cohort do not match')
    if set(files) != set(data['files']):
        raise ValueError('Unexpected helper files')
    for name, item in data['files'].items():
        content = normalized(files[name])
        if len(content) != item['bytes'] or digest(content) != item['sha256']:
            raise ValueError('Helper checksum mismatch: ' + name)
    return data


def snapshot(entry, raw, files, destination):
    validate(entry, raw, files)
    if destination.exists():
        validate(entry, read(destination / CONTRACT, 32768), read_files(destination, raw))
        return
    destination.mkdir(mode=0o700)
    for name, content in {**files, CONTRACT: raw}.items():
        target = destination / name
        target.write_bytes(normalized(content))
        target.chmod(0o600)


def embedded(entry):
    code(entry)
    if FOOTER not in entry:
        return None
    footer = entry.split(FOOTER, 1)[1][:-len(END)]
    encoded = b''.join(line[7:] for line in footer.splitlines() if line.startswith(b'# DATA '))
    if not encoded or len(encoded) > 6 * 1024 * 1024:
        raise ValueError('Invalid embedded helper size')
    zipped = base64.b64decode(encoded, validate=True)
    with gzip.GzipFile(fileobj=io.BytesIO(zipped)) as stream:
        raw = stream.read(MAX_RAW + 1)
    if len(raw) > MAX_RAW:
        raise ValueError('Embedded helpers too large')
    files = {}
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:') as archive:
        members = archive.getmembers()
        if len(members) > 33:
            raise ValueError('Too many embedded helpers')
        for member in members:
            if not member.isfile() or member.size > MAX_FILE or member.name in files or '/' in member.name or '\\' in member.name:
                raise ValueError('Unsafe embedded helper archive')
            files[member.name] = archive.extractfile(member).read()
    raw_manifest = files.pop(CONTRACT)
    validate(entry, raw_manifest, files)
    return raw_manifest, files


def render(entry, raw, files, cache=None):
    validate(entry, raw, files)
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w') as archive:
        for name, content in sorted({**files, CONTRACT: raw}.items()):
            info = tarfile.TarInfo(name)
            info.size, info.mode, info.mtime = len(content), 0o644, 0
            archive.addfile(info, io.BytesIO(content))
    encoded = base64.b64encode(gzip.compress(output.getvalue(), mtime=0))
    footer = FOOTER
    if cache:
        if not re.fullmatch(r'[a-f0-9]{64}(?:-[a-f0-9]{32})?', cache):
            raise ValueError('Invalid helper cache name')
        footer += b'# CACHE ' + cache.encode('ascii') + b'\n'
    footer += b''.join(b'# DATA ' + encoded[index:index + 100] + b'\n' for index in range(0, len(encoded), 100))
    return code(entry) + footer + END


def source_bundle(root, entry=None):
    entry = normalized(entry if entry is not None else (root / 'installer/installer.sh').read_bytes())
    raw = read(root / 'installer' / CONTRACT, 32768)
    if manifest(raw)['version'] != (root / 'VERSION').read_text().strip():
        raise ValueError('Helper version and release version do not match')
    files = {name: read(root / name if name in {'LICENSE', 'NOTICE.md'} else root / 'installer' / name) for name in manifest(raw)['files']}
    validate(entry, raw, files)
    return entry, raw, files


def sync(root):
    path = root / 'installer/installer.sh'
    entry = code(path.read_bytes())
    files = {name: read(root / name if name in {'LICENSE', 'NOTICE.md'} else root / 'installer' / name) for name in FILES}
    version = (root / 'VERSION').read_text().strip()
    data = {'schema': 1, 'version': version, 'entry_sha256': digest(canonical(entry)),
            'files': {name: {'sha256': digest(content), 'bytes': len(content)} for name, content in sorted(files.items())}}
    raw = (json.dumps(data, sort_keys=True, indent=2) + '\n').encode()
    manifest(raw)
    entry = ANCHOR.sub(b"HELPER_BUNDLE_SHA256='" + digest(raw).encode() + b"'", entry)
    path.write_bytes(entry)
    (root / 'installer' / CONTRACT).write_bytes(raw)


def install(entry, cohort, cache_root, output):
    raw = read(cohort / CONTRACT, 32768)
    files = read_files(cohort, raw)
    validate(entry, raw, files)
    if any(c in str(cache_root) for c in '\r\n\x00') or cache_root.is_symlink():
        raise ValueError('Invalid helper cache directory')
    cache_root.mkdir(parents=True, exist_ok=True, mode=0o755)
    target = cache_root / digest(raw)
    if target.exists():
        try:
            if target.is_symlink() or not target.is_dir():
                raise ValueError('Invalid helper generation')
            validate(entry, read(target / CONTRACT, 32768), read_files(target, raw))
        except (OSError, ValueError, KeyError):
            # Preserve the damaged generation. Running agents may still refer
            # to its path; replacement gets a different immutable directory.
            target = cache_root / (digest(raw) + '-' + uuid.uuid4().hex)
    if not target.exists():
        temporary = Path(tempfile.mkdtemp(prefix='.helpers-', dir=cache_root))
        try:
            for name, content in {**files, CONTRACT: raw}.items():
                (temporary / name).write_bytes(content)
                (temporary / name).chmod(0o644)
            temporary.chmod(0o755)
            try:
                os.rename(temporary, target)
            except OSError as error:
                if error.errno not in {errno.EEXIST, errno.ENOTEMPTY}:
                    raise
                # Another installer can publish the same generation while this
                # process stages it. Reuse only a complete, identical cohort.
                if target.is_symlink() or not target.is_dir():
                    raise ValueError('Invalid concurrent helper generation') from error
                validate(entry, read(target / CONTRACT, 32768), read_files(target, raw))
        finally:
            if temporary.exists():
                if temporary.is_symlink() or temporary.parent.resolve() != cache_root.resolve() or not temporary.name.startswith('.helpers-'):
                    raise ValueError('Unsafe helper staging cleanup')
                shutil.rmtree(temporary)
    output.write_bytes(render(entry, raw, files, target.name))
    output.chmod(0o600)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['sync', 'check', 'install'])
    parser.add_argument('--root', type=Path)
    parser.add_argument('--entry', type=Path)
    parser.add_argument('--cohort', type=Path)
    parser.add_argument('--cache-root', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.operation == 'sync':
        sync(args.root)
    elif args.operation == 'check':
        source_bundle(args.root)
    else:
        print(install(args.entry.read_bytes(), args.cohort, args.cache_root, args.output))


if __name__ == '__main__':
    main()
