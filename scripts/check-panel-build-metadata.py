"""Reject release images whose runtime metadata does not match the pinned source."""
import argparse
from datetime import datetime
import json
import re
import subprocess


def validate(config, version, commit, branch, build_time, build_number):
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Invalid source commit')
    if branch != 'main' or not re.fullmatch(r'[1-9][0-9]*', build_number):
        raise ValueError('Invalid release branch or build number')
    if not build_time.endswith('Z'):
        raise ValueError('Build time must be UTC')
    datetime.fromisoformat(build_time.replace('Z', '+00:00'))
    env = dict(value.split('=', 1) for value in config.get('Env', []) if '=' in value)
    expected = {'VERSION': version, 'GIT_BACKEND_COMMIT': commit, 'GIT_FRONTEND_COMMIT': commit,
                'GIT_BRANCH': branch, 'BUILD_TIME': build_time, 'BUILD_NUMBER': build_number}
    for key, value in expected.items():
        if env.get('__RW_METADATA_' + key) != value:
            raise ValueError('Runtime build metadata mismatch: ' + key)
    labels = config.get('Labels') or {}
    if labels.get('org.opencontainers.image.revision') != commit or labels.get('org.opencontainers.image.version') != version:
        raise ValueError('Image labels differ from runtime metadata')
    if labels.get('org.opencontainers.image.source') != 'https://github.com/lottman/Remnacust-panel':
        raise ValueError('Image source must point to the panel repository')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['image', 'version', 'commit', 'branch', 'build-time', 'build-number']:
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    images = json.loads(subprocess.check_output(['docker', 'image', 'inspect', args.image]))
    if len(images) != 1:
        raise ValueError('Expected exactly one image')
    validate(images[0]['Config'], args.version, args.commit, args.branch, args.build_time, args.build_number)
    print('PASS panel image contains its real GitHub commit, branch, build time and build number')
