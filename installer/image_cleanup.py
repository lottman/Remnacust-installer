"""Remove superseded component images after a verified successful deployment."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import time

REPOSITORIES = {
    'panel': {'ghcr.io/lottman/remnacust-panel', 'remnacust-panel',
              'ghcr.io/lottman/remnacust-subscription-page', 'remnacust-subscription-page'},
    'node': {'ghcr.io/lottman/remnacust-node', 'remnacust-node'},
}
SOURCES = {'panel': {'https://github.com/lottman/Remnacust-panel'},
           'node': {'https://github.com/lottman/Remnacust-node'}}
IMAGE_ID = re.compile(r'sha256:[0-9a-f]{64}')
DEADLINE = None


def repository(reference):
    if '@' in reference:
        return reference.split('@', 1)[0]
    return reference.rsplit(':', 1)[0]


def removal_plan(images, protected, component):
    result = []
    for image in images:
        identifier = image.get('Id', '')
        if not IMAGE_ID.fullmatch(identifier) or identifier in protected:
            continue
        references = (image.get('RepoTags') or []) + (image.get('RepoDigests') or [])
        own = [ref for ref in references if repository(ref) in REPOSITORIES[component]]
        if own:
            tagged_repositories = {repository(ref) for ref in own if '@' not in ref}
            # Removing the final tag of a repository also removes its digest aliases.
            # Avoid asking Docker to remove an alias it just removed itself.
            own = [ref for ref in own if '@' not in ref or repository(ref) not in tagged_repositories]
            result.append((identifier, list(dict.fromkeys(own))))
        elif not references:
            source = (image.get('Config', {}).get('Labels') or {}).get('org.opencontainers.image.source')
            if source in SOURCES[component]:
                result.append((identifier, [identifier]))
    return result


def docker(*args, json_output=False):
    remaining = 30 if DEADLINE is None else DEADLINE - time.monotonic()
    if remaining <= 0:
        raise TimeoutError('Image cleanup deadline reached')
    process = subprocess.run(['docker', *args], check=True, capture_output=True, text=True, timeout=min(30, remaining))
    if len(process.stdout) > 64 * 1024 * 1024:
        raise ValueError('Docker response exceeds cleanup limit')
    return json.loads(process.stdout) if json_output else process.stdout


def batches(values):
    for start in range(0, len(values), 100):
        yield values[start:start + 100]


def used_images():
    ids = docker('ps', '--all', '--quiet').splitlines()
    protected = set()
    for group in batches(ids):
        protected.update(docker('inspect', '--format', '{{.Image}}', *group).splitlines())
    return protected


def cleanup(component, before_path, keep):
    global DEADLINE
    DEADLINE = time.monotonic() + 120
    protected = used_images()
    if before_path:
        snapshots = json.loads(Path(before_path).read_text())
        if not isinstance(snapshots, list):
            raise ValueError('Previous container snapshot is invalid')
        protected.update(item['Image'] for item in snapshots
                         if isinstance(item, dict) and IMAGE_ID.fullmatch(item.get('Image', '')))
    for reference in keep:
        protected.update(item['Id'] for item in docker('image', 'inspect', reference, json_output=True))
    identifiers = list(dict.fromkeys(docker('image', 'ls', '--all', '--quiet', '--no-trunc').splitlines()))
    if len(identifiers) > 10000:
        raise ValueError('Too many images for bounded cleanup')
    images = []
    for group in batches(identifiers):
        images.extend(docker('image', 'inspect', *group, json_output=True))
    removed = 0
    for identifier, references in removal_plan(images, protected, component):
        if time.monotonic() >= DEADLINE:
            print('Remaining images retained: cleanup deadline reached', file=sys.stderr)
            break
        try:
            if identifier in used_images():
                continue
            # Docker refuses in-use image deletion; no force, global prune or volumes.
            docker('image', 'rm', *references)
            removed += 1
        except (OSError, ValueError, subprocess.SubprocessError):
            print('Image retained: Docker could not safely remove it', file=sys.stderr)
    print(f'Cleaned {removed} superseded Remnacust images; current and previous images retained')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--component', choices=REPOSITORIES, required=True)
    parser.add_argument('--before', default='')
    parser.add_argument('--keep', action='append', default=[])
    args = parser.parse_args()
    cleanup(args.component, args.before, args.keep)


if __name__ == '__main__':
    main()
