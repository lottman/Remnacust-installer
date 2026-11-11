import importlib.util
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('promote_latest', ROOT / 'scripts/promote-latest-images.py')
promote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(promote)


def index(platforms=('amd64', 'arm64')):
    return json.dumps({'schemaVersion': 2, 'mediaType': promote.ACCEPT.split(',')[0], 'manifests': [
        {'digest': 'sha256:' + str(i + 1) * 64, 'platform': {'os': 'linux', 'architecture': arch}}
        for i, arch in enumerate(platforms)
    ]}).encode()


class LatestImagesTests(unittest.TestCase):
    def test_both_architectures_and_exact_verified_digests_are_required(self):
        promote.validate_index(index(), {'amd64': 'sha256:' + '1' * 64, 'arm64': 'sha256:' + '2' * 64})
        for raw in [index(('amd64',)), index(('amd64', 'amd64')), b'{}']:
            with self.assertRaises(ValueError):
                promote.validate_index(raw)
        with self.assertRaises(ValueError):
            promote.validate_index(index(), {'amd64': 'sha256:' + '3' * 64, 'arm64': 'sha256:' + '2' * 64})

    def test_old_draft_and_prerelease_cannot_replace_latest(self):
        for release in [{'tag_name': 'v1.2.162', 'draft': False, 'prerelease': False},
                        {'tag_name': 'v1.2.163', 'draft': True, 'prerelease': False},
                        {'tag_name': 'v1.2.163', 'draft': False, 'prerelease': True}]:
            with patch.object(promote, 'request', return_value=(json.dumps(release).encode(), {})):
                with self.assertRaises(ValueError):
                    promote.assert_latest('v1.2.163')

    def test_all_components_are_verified_before_the_first_write_and_dry_run_never_writes(self):
        calls = []
        import hashlib
        raw = index()
        sources = json.loads((ROOT / 'component-sources.json').read_text(encoding='utf-8'))
        expected_urls = {
            'https://ghcr.io/v2/lottman/remnacust-' + component + '/manifests/' +
            sources['panel' if component == 'subscription-page' else component]['version'] + '-v1.2.163'
            for component in promote.COMPONENTS
        }

        def request(url, headers=None, body=None, method='GET'):
            calls.append((url, method))
            if url.startswith('https://api.github.com/'):
                return json.dumps({'tag_name': 'v1.2.163', 'draft': False, 'prerelease': False}).encode(), {}
            if url in expected_urls:
                return raw, {'Docker-Content-Digest': 'sha256:' + hashlib.sha256(raw).hexdigest()}
            raise AssertionError('Unexpected request')

        with patch.object(sys, 'argv', ['promote', '--tag', 'v1.2.163', '--sources', str(ROOT / 'component-sources.json')]), \
             patch.object(promote, 'request', side_effect=request), patch.object(promote, 'token', return_value='fixture-token'):
            promote.main()
        self.assertEqual(len([url for url, _ in calls if '/manifests/' in url]), 3)
        self.assertTrue(all(method == 'GET' for _, method in calls))

    def test_foreign_and_plaintext_registry_endpoints_are_rejected_before_network(self):
        for url in ['http://ghcr.io/v2/', 'https://other.invalid/', 'https://ghcr.io.evil.invalid/']:
            with self.assertRaises(ValueError):
                promote.request(url)


if __name__ == '__main__':
    unittest.main()
