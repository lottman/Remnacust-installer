"""Add prebuilt images and a small runtime bundle to a source release."""
import argparse
import gzip
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile


def runtime_files(source):
    names = ['VERSION', 'component-sources.json', 'images.json', 'LICENSE', 'NOTICE.md',
             'panel/backend/.env.sample']
    names += ['installer/' + name for name in
              ['installer.sh', 'runtime.py', 'database.cjs', 'marzban.py', 'images.py', 'tls.py', 'update-agent.py', 'README.md']]
    return {name: (source/name).read_bytes() for name in names}


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--images', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--tag', required=True)
args = parser.parse_args()
lock = json.loads((args.source/'component-sources.json').read_text())
assert (args.source/'VERSION').read_text().strip() == args.tag[1:]
manifest = {'schema': 1, 'release': args.tag, 'components': {}}
assets = {'repository': 'lottman/Remnacust-installer', 'assets': []}
for metadata_path in sorted(args.images.glob('**/image-*.json')):
    data = json.loads(metadata_path.read_text())
    component, arch = data.pop('component'), data.pop('architecture')
    pin = lock['node' if component == 'node' else 'panel']
    assert data.pop('version') == pin['version'] and data.pop('commit') == pin['commit']
    entry = manifest['components'].setdefault(component, {**{'version': pin['version'], 'commit': pin['commit']}, 'architectures': {}})
    assert arch not in entry['architectures']
    entry['architectures'][arch] = data
    source = metadata_path.parent/data['file']
    assert source.is_file()
    destination = args.output/data['file']
    args.output.mkdir(parents=True, exist_ok=True)
    if source.resolve() != destination.resolve():
        source.replace(destination)
    assets['assets'].append({'name': data['file'], 'size': destination.stat().st_size, 'state': 'uploaded',
        'digest': 'sha256:' + data['sha256'], 'browser_download_url': f'https://github.com/lottman/Remnacust-installer/releases/download/{args.tag}/'+data['file']})
spec = importlib.util.spec_from_file_location('images', args.source/'installer/images.py')
images = importlib.util.module_from_spec(spec)
spec.loader.exec_module(images)
(args.source/'images.json').write_text(json.dumps(manifest, indent=2)+'\n')
images.validate(args.source, args.tag, assets)
for component, entry in manifest['components'].items():
    for arch, data in entry['architectures'].items():
        images.verify_archive(args.output/data['file'], {**data, **{'version': entry['version'], 'commit': entry['commit'], 'architecture': arch}})
files = runtime_files(args.source)
filename = f'remnacust-runtime-{args.tag}.tar.gz'
with (args.output/filename).open('wb') as output, gzip.GzipFile(fileobj=output, mode='wb', filename='', mtime=0) as zipped, tarfile.open(fileobj=zipped, mode='w') as archive:
    for name, content in sorted(files.items()):
        info = tarfile.TarInfo(name)
        info.size, info.mode, info.mtime = len(content), (0o755 if name.endswith('.sh') else 0o644), 0
        archive.addfile(info, io.BytesIO(content))
names = ['installer.sh', f'remnacust-source-{args.tag}.tar.gz', filename] + [a['name'] for a in assets['assets']]
(args.output/'SHA256SUMS').write_text(''.join(images.digest_file(args.output/name)+'  '+name+'\n' for name in names))
print('Validated both architectures for all components; runtime size:', (args.output/filename).stat().st_size)
