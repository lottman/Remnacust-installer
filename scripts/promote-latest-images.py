import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.parse
import urllib.request


COMPONENTS = ('node', 'panel', 'subscription-page')
ACCEPT = 'application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request(url, headers=None, body=None, method='GET'):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != 'https' or parsed.hostname not in {'ghcr.io', 'api.github.com'}:
        raise ValueError('Unexpected registry endpoint')
    req = urllib.request.Request(url, data=body, headers=headers or {}, method=method)
    with urllib.request.build_opener(NoRedirect()).open(req, timeout=30) as response:
        raw = response.read(2 * 1024 * 1024 + 1)
        if len(raw) > 2 * 1024 * 1024:
            raise ValueError('Registry response is too large')
        return raw, response.headers


def assert_latest(tag):
    raw, _ = request('https://api.github.com/repos/lottman/Remnacust-installer/releases/latest',
                     {'User-Agent': 'Remnacust-image-promotion', 'Cache-Control': 'no-cache'})
    release = json.loads(raw)
    if release.get('tag_name') != tag or release.get('draft') is not False or release.get('prerelease') is not False:
        raise ValueError('Only the latest published stable release can update latest images')


def token(repository, write=False):
    headers = {}
    if write:
        actor, secret = os.environ.get('GITHUB_ACTOR', ''), os.environ.get('GH_TOKEN', '')
        if not actor or not secret:
            raise ValueError('Registry write credentials are unavailable')
        headers['Authorization'] = 'Basic ' + base64.b64encode((actor + ':' + secret).encode()).decode()
    scope = 'repository:' + repository + (':pull,push' if write else ':pull')
    url = 'https://ghcr.io/token?' + urllib.parse.urlencode({'service': 'ghcr.io', 'scope': scope})
    raw, _ = request(url, headers)
    result = json.loads(raw).get('token')
    if not isinstance(result, str) or not result:
        raise ValueError('Registry did not grant access')
    return result


def validate_index(raw, expected=None):
    index = json.loads(raw)
    if index.get('schemaVersion') != 2 or index.get('mediaType') not in ACCEPT.split(','):
        raise ValueError('A multi-architecture image index is required')
    platforms = {}
    for item in index.get('manifests', []):
        platform = item.get('platform') or {}
        arch = platform.get('architecture')
        if platform.get('os') != 'linux' or arch not in {'amd64', 'arm64'}:
            continue
        digest = item.get('digest', '')
        if arch in platforms or not re.fullmatch(r'sha256:[a-f0-9]{64}', digest):
            raise ValueError('Invalid platform image descriptor')
        platforms[arch] = digest
    if set(platforms) != {'amd64', 'arm64'}:
        raise ValueError('Both supported architectures are required')
    if expected is not None and platforms != expected:
        raise ValueError('Platform images differ from the verified release')
    return index['mediaType']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--tag', required=True)
    parser.add_argument('--sources', type=Path, default=Path('component-sources.json'))
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', args.tag):
        raise ValueError('Invalid stable release tag')
    sources = json.loads(args.sources.read_text(encoding='utf-8'))
    manifest = json.loads(args.manifest.read_text(encoding='utf-8')) if args.manifest else None
    if manifest is not None and manifest.get('release') != args.tag:
        raise ValueError('Unexpected release manifest')
    assert_latest(args.tag)
    plan = []
    for component in COMPONENTS:
        version = sources['panel' if component == 'subscription-page' else component]['version']
        if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){2,3}', version):
            raise ValueError('Invalid component version')
        repository = 'lottman/remnacust-' + component
        url = 'https://ghcr.io/v2/' + repository + '/manifests/'
        raw, headers = request(url + version + '-' + args.tag,
                               {'Authorization': 'Bearer ' + token(repository), 'Accept': ACCEPT})
        expected = None
        if manifest is not None:
            entry = manifest['components'][component]
            if entry['version'] != version:
                raise ValueError('Component version differs from verified release')
            expected = {arch: entry['architectures'][arch]['registry'].split('@', 1)[1]
                        for arch in ('amd64', 'arm64')}
        media_type = validate_index(raw, expected)
        digest = 'sha256:' + hashlib.sha256(raw).hexdigest()
        if headers.get('Docker-Content-Digest') != digest:
            raise ValueError('Registry manifest checksum mismatch')
        plan.append((component, repository, url, raw, media_type, digest))
        print(component + ': verified ' + version + '-' + args.tag + ' ' + digest, flush=True)
    if not args.apply:
        return
    for component, repository, url, raw, media_type, digest in plan:
        assert_latest(args.tag)
        request(url + 'latest', {'Authorization': 'Bearer ' + token(repository, True),
                                'Content-Type': media_type}, raw, 'PUT')
        copied, _ = request(url + 'latest', {'Authorization': 'Bearer ' + token(repository),
                                           'Accept': ACCEPT, 'Cache-Control': 'no-cache'})
        if 'sha256:' + hashlib.sha256(copied).hexdigest() != digest:
            raise ValueError('Published latest does not match the verified manifest')
        print(component + ': anonymous latest verified ' + digest, flush=True)


if __name__ == '__main__':
    try:
        main()
    except urllib.error.HTTPError as error:
        raise SystemExit('Registry operation failed: HTTP ' + str(error.code)) from None
