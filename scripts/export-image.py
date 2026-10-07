"""Export the image built by CI and record its exact identity."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--component', required=True, choices=['panel', 'node', 'subscription-page'])
parser.add_argument('--architecture', required=True, choices=['amd64', 'arm64'])
parser.add_argument('--tag', required=True)
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
lock = json.loads((args.source/'component-sources.json').read_text())
pin = lock['node' if args.component == 'node' else 'panel']
name = f'ghcr.io/lottman/remnacust-{args.component}:{pin["version"]}-{args.tag}-{args.architecture}'
image = json.loads(subprocess.check_output(['docker', 'image', 'inspect', name]))[0]
labels = image['Config']['Labels']
assert image['Architecture'] == args.architecture and image['Os'] == 'linux'
assert labels['org.opencontainers.image.version'] == pin['version']
assert labels['org.opencontainers.image.revision'] == pin['commit']
registry = next(value for value in image['RepoDigests'] if value.startswith(f'ghcr.io/lottman/remnacust-{args.component}@sha256:'))
args.output.mkdir(parents=True, exist_ok=True)
filename = f'remnacust-{args.component}-{args.tag}-linux-{args.architecture}.tar.gz'
with (args.output/filename).open('wb') as output:
    save = subprocess.Popen(['docker', 'save', name], stdout=subprocess.PIPE)
    compress = subprocess.run(['gzip', '-1', '-n'], stdin=save.stdout, stdout=output)
    save.stdout.close()
    if save.wait() or compress.returncode:
        raise SystemExit('Docker image export failed')
digest = hashlib.sha256()
with (args.output/filename).open('rb') as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
        digest.update(chunk)
with tarfile.open(args.output/filename, 'r:gz') as archive:
    manifest = json.load(archive.extractfile('manifest.json'))
    assert len(manifest) == 1 and manifest[0]['RepoTags'] == [name]
    config = archive.extractfile(manifest[0]['Config']).read()
    config_id = 'sha256:' + hashlib.sha256(config).hexdigest()
metadata = {'component': args.component, 'version': pin['version'], 'commit': pin['commit'],
            'architecture': args.architecture, 'file': filename, 'image': name, 'registry': registry,
            'imageId': config_id, 'sha256': digest.hexdigest()}
(args.output/f'image-{args.component}-{args.architecture}.json').write_text(json.dumps(metadata, indent=2)+'\n')
print('Verified image:', args.component, args.architecture, pin['version'], registry)
