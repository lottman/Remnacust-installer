"""Build a reproducible installer bundle from a tag and pinned component commits."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
import urllib.request

REPOSITORIES = {kind: f'lottman/Remnacust-{kind}' for kind in ('panel', 'node', 'core')}
PREFIXES = {'panel': ('panel/', 'subscription-page/', 'images/'),
            'node': ('node/',), 'core': ('xray/', 'editor/', 'vendor/olcrtc/')}


def read_archive(data, strip_root=False):
    files = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as archive:
        members = archive.getmembers()
        total = sum(m.size for m in members)
        if total > 768 * 1024 * 1024 or len(members) > 30000:
            raise ValueError('Source archive is too large')
        for member in members:
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or '\\' in member.name:
                raise ValueError('Unsafe source path: ' + member.name)
            if member.isdir():
                continue
            if not member.isfile():
                raise ValueError('Source archive contains a link or special file: ' + member.name)
            parts = path.parts[1:] if strip_root else path.parts
            if not parts:
                raise ValueError('Missing source path')
            name = '/'.join(parts)
            if name in files:
                raise ValueError('Duplicate source path: ' + name)
            files[name] = archive.extractfile(member).read()
    return files


def git_files(directory, revision):
    return read_archive(subprocess.check_output(
        ['git', 'archive', '--format=tar', revision], cwd=directory))


def component_files(kind, commit, local_sources):
    if local_sources:
        directory = local_sources / f'Remnacust-{kind}'
        resolved = subprocess.check_output(['git', 'rev-parse', commit+'^{commit}'], cwd=directory, text=True).strip()
        if resolved != commit:
            raise ValueError('Component commit does not match lock')
        return git_files(directory, commit)
    url = f'https://codeload.github.com/{REPOSITORIES[kind]}/tar.gz/{commit}'
    request = urllib.request.Request(url, headers={'User-Agent': 'Remnacust-source-release'})
    with urllib.request.urlopen(request, timeout=180) as response:
        if not response.url.startswith('https://codeload.github.com/'):
            raise ValueError('Unexpected component download location')
        data = response.read(256 * 1024 * 1024 + 1)
        if len(data) > 256 * 1024 * 1024:
            raise ValueError('Component download is too large')
    return read_archive(data, strip_root=True)


def validate(files, version):
    for name, data in files.items():
        path = PurePosixPath(name)
        if path.name.startswith('.env') and path.name not in {'.env.sample', '.env.example'}:
            raise ValueError('Working environment in source: ' + name)
        if any(p in {'.git', 'node_modules', 'dist', 'coverage', '__pycache__', '.cache'} for p in path.parts):
            raise ValueError('Runtime or build output in source: ' + name)
        code_root = path.parts[:3] in {('panel', 'backend', 'src'), ('panel', 'backend', 'libs'), ('panel', 'frontend', 'src')} or path.parts[:2] in {('node', 'src'), ('node', 'libs')} or path.parts[:5] == ('panel', 'frontend', 'vendor', 'backend-contract', 'build')
        if not code_root and any(p in {'dumps', 'backups', 'release'} for p in path.parts):
            raise ValueError('Runtime data in source: ' + name)
        if path.suffix == '.sh' and b'\r' in data:
            raise ValueError('Shell script requires LF: ' + name)
    for folder in ['panel/backend', 'panel/frontend', 'node', 'subscription-page/backend', 'subscription-page/frontend']:
        if json.loads(files[folder+'/package.json']).get('version') != version:
            raise ValueError('Package version mismatch: ' + folder)
    if files['VERSION'].decode().strip() != version:
        raise ValueError('Installer version mismatch')
    core = files['xray/core/core.go'].decode()
    numbers = [re.search(rf'Version_{axis}\s+byte\s*=\s*(\d+)', core) for axis in 'xyz']
    if not all(numbers) or '.'.join(m.group(1) for m in numbers) != version.split('-')[0]:
        raise ValueError('Core version mismatch')
    for name in ['installer/installer.sh', 'installer/runtime.py', 'installer/database.cjs', 'installer/marzban.py',
                 'panel/Dockerfile', 'panel/backend/.env.sample', 'node/docker/Dockerfile', 'xray/LICENSE', 'LICENSE', 'NOTICE.md']:
        if name not in files:
            raise ValueError('Missing release source: ' + name)
    name = 'node/docker/remnacust-core.tar.gz'
    digest = files[name+'.sha256'].decode().split()[0]
    if hashlib.sha256(files[name]).hexdigest() != digest:
        raise ValueError('Bundled node core checksum mismatch')


def package(root, tag, local_sources=None, check=False):
    if not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?', tag):
        raise ValueError('Use a vMAJOR.MINOR.PATCH tag')
    own = git_files(root, 'refs/tags/'+tag)
    lock = json.loads(own['component-sources.json'])
    if set(lock) != set(REPOSITORIES):
        raise ValueError('Component lock must name panel, node and core')
    files = dict(own)
    for kind in REPOSITORIES:
        entry = lock[kind]
        if entry.get('repository') != REPOSITORIES[kind] or not re.fullmatch(r'[0-9a-f]{40}', entry.get('commit', '')):
            raise ValueError('Invalid pinned repository or commit: ' + kind)
        source = component_files(kind, entry['commit'], local_sources)
        if source['VERSION'].decode().strip() != tag[1:]:
            raise ValueError('Component VERSION mismatch: ' + kind)
        for name, data in source.items():
            if name.startswith(PREFIXES[kind]):
                if name in files:
                    raise ValueError('Overlapping source: ' + name)
                files[name] = data
    validate(files, tag[1:])
    if check:
        print(f'PASS {tag}: {len(files)} pinned source files, versions and archive paths')
        return None
    destination = root / 'release'
    destination.mkdir(exist_ok=True)
    name = f'remnacust-source-{tag}.tar.gz'
    with (destination/name).open('wb') as stream, gzip.GzipFile(fileobj=stream, filename='', mtime=0, mode='wb') as zipped, tarfile.open(fileobj=zipped, mode='w') as archive:
        for filename, data in sorted(files.items()):
            member = tarfile.TarInfo(filename)
            member.size, member.mode, member.mtime = len(data), (0o755 if filename.endswith('.sh') else 0o644), 0
            archive.addfile(member, io.BytesIO(data))
    (destination/'installer.sh').write_bytes(files['installer/installer.sh'])
    checksums = ''.join(f'{hashlib.sha256((destination/f).read_bytes()).hexdigest()}  {f}\n' for f in [name, 'installer.sh'])
    (destination/'SHA256SUMS').write_text(checksums, encoding='utf-8', newline='\n')
    print(f'PASS {tag}: {len(files)} pinned source files; release assets in {destination}')
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--local-sources', type=Path)
    parser.add_argument('tag')
    args = parser.parse_args()
    package(Path(__file__).resolve().parents[1], args.tag, args.local_sources, args.check)
