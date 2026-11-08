import argparse
import json
from pathlib import Path
import re


def stable_channel(release, source_version):
    if not isinstance(release, dict) or release.get('draft') is not False or release.get('prerelease') is not False:
        raise ValueError('A published stable release is required')
    tag = release.get('tag_name')
    if not isinstance(tag, str) or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag):
        raise ValueError('Invalid release tag')
    if source_version.strip() != tag[1:]:
        raise ValueError('Release version does not match its source')
    return {'schema': 1, 'tag': tag}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--release-file', required=True, type=Path)
    parser.add_argument('--source-version', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    raw = args.release_file.read_bytes()
    if len(raw) > 1048576 or args.source_version.stat().st_size > 128:
        raise ValueError('Release metadata is too large')
    channel = stable_channel(json.loads(raw), args.source_version.read_text(encoding='ascii'))
    args.output.write_text(json.dumps(channel, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
