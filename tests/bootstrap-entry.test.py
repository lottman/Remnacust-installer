import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import tarfile
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'bootstrap.sh'
PREFIX = 'Remnacust-installer-1.2.144/'
FAKE_CURL = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
root = pathlib.Path(os.environ['BOOTSTRAP_FIXTURE'])
with (root / 'calls').open('a') as stream:
    stream.write(json.dumps(args) + '\n')
if os.environ.get('FAIL_DOWNLOAD') == '1':
    raise SystemExit(22)
url = next(value for value in args if value.startswith('https://'))
if url == 'https://raw.githubusercontent.com/lottman/Remnacust-installer/main/bootstrap.sh':
    sys.stdout.buffer.write(pathlib.Path(os.environ['BOOTSTRAP_SOURCE']).read_bytes())
elif url == 'https://raw.githubusercontent.com/lottman/Remnacust-installer/main/release-channel.json':
    if os.environ.get('CHANNEL_FAIL', '1') == '1':
        raise SystemExit(22)
    pathlib.Path(args[args.index('--output') + 1]).write_text(os.environ.get('CHANNEL_CONTENT', '{"schema":1,"tag":"v1.2.144"}'))
elif url == 'https://github.com/lottman/Remnacust-installer/releases/latest':
    pathlib.Path(args[args.index('--dump-header') + 1]).write_bytes((root / 'headers').read_bytes())
elif url == 'https://api.github.com/repos/lottman/Remnacust-installer/releases/latest':
    if os.environ.get('API_FAIL', '1') == '1':
        raise SystemExit(22)
    pathlib.Path(args[args.index('--output') + 1]).write_text(json.dumps({'tag_name':'v1.2.144','draft':False,'prerelease':False}))
else:
    if url != 'https://codeload.github.com/lottman/Remnacust-installer/tar.gz/refs/tags/v1.2.144':
        raise SystemExit(19)
    pathlib.Path(args[args.index('--output') + 1]).write_bytes((root / 'archive').read_bytes())
'''


@unittest.skipIf(os.name == 'nt', 'Requires Linux Bash')
class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='rc-bootstrap-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'bin').mkdir()
        for name, content in [('curl', FAKE_CURL), ('sudo', '#!/bin/sh\nexec "$@"\n')]:
            path = self.root / 'bin' / name
            path.write_text(content)
            path.chmod(0o755)
        self.headers = b'HTTP/1.1 302 Found\r\nLocation: https://github.com/lottman/Remnacust-installer/releases/tag/v1.2.144\r\n\r\n'
        self.entry = b"#!/usr/bin/env bash\nHELPER_BUNDLE_SHA256='" + b'0' * 64 + b"'\nprintf '%s\\n' \"$@\" > \"$BOOTSTRAP_FIXTURE/entry\"\nexit \"${ENTRY_STATUS:-0}\"\n"
        helpers = {'helper_bundle.py': b'fixture verifier\n', 'runtime.py': b'fixture runtime\n'}
        contract = {'schema': 1, 'version': '1.2.144',
                    'entry_sha256': hashlib.sha256(self.entry).hexdigest(),
                    'files': {name: {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
                              for name, data in helpers.items()}}
        raw = json.dumps(contract).encode()
        self.files = {'VERSION': b'1.2.144\n', 'installer/helper-contract.json': raw,
                      'installer/installer.sh': self.entry.replace(b'0' * 64, hashlib.sha256(raw).hexdigest().encode()),
                      **{'installer/' + name: data for name, data in helpers.items()}}

    def run_bootstrap(self, args=('@', 'install'), special=None, process_substitution=False, **environment):
        (self.root / 'headers').write_bytes(self.headers)
        with tarfile.open(self.root / 'archive', 'w:gz') as archive:
            for name, content in self.files.items():
                info = tarfile.TarInfo(PREFIX + name)
                info.size = len(content)
                archive.addfile(info, io.BytesIO(content))
            if special:
                archive.addfile(special)
        env = {**os.environ, 'PATH': str(self.root / 'bin') + os.pathsep + os.environ['PATH'],
               'BOOTSTRAP_SOURCE': str(SOURCE), 'BOOTSTRAP_FIXTURE': str(self.root), **environment}
        if process_substitution:
            command = ['bash', '-c', 'bash <(curl -fsSL https://raw.githubusercontent.com/lottman/Remnacust-installer/main/bootstrap.sh) "$@"', 'fixture', *args]
        else:
            command = ['bash', str(SOURCE), *args]
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=15)
        calls = [json.loads(line) for line in (self.root / 'calls').read_text().splitlines()]
        for call in calls:
            if '--dump-header' in call:
                self.assertFalse(Path(call[call.index('--dump-header') + 1]).parent.exists(), 'private bootstrap files leaked')
            if '--output' in call and call[call.index('--output') + 1] != '/dev/null':
                self.assertFalse(Path(call[call.index('--output') + 1]).parent.exists(), 'private bootstrap files leaked')
        return result

    def assert_rejected(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / 'entry').exists())

    def test_menu_alias_through_actual_process_substitution(self):
        result = self.run_bootstrap(process_substitution=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'entry').read_text(), '\n')

    def test_public_api_can_resolve_latest_without_release_download_url(self):
        result = self.run_bootstrap(('@', '--help'), process_substitution=True, API_FAIL='0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'entry').read_text().splitlines(), ['--help'])

    def test_action_arguments_forwarded_through_process_substitution(self):
        result = self.run_bootstrap(('@', 'install-node', '--node-domain', 'node.example.test'), process_substitution=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'entry').read_text().splitlines(), ['install-node', '--node-domain', 'node.example.test'])

    def test_raw_channel_does_not_call_api_or_github_release_page(self):
        result = self.run_bootstrap(('@', '--help'), process_substitution=True, CHANNEL_FAIL='0')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / 'calls').read_text()
        self.assertNotIn('api.github.com', calls)
        self.assertNotIn('github.com/lottman/Remnacust-installer/releases/latest', calls)

    def test_invalid_raw_channel_uses_checked_fallback(self):
        result = self.run_bootstrap(CHANNEL_FAIL='0', CHANNEL_CONTENT='{"schema":1,"tag":"../../evil"}', API_FAIL='0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('api.github.com', (self.root / 'calls').read_text())

    def test_metadata_requests_have_no_retries_and_eight_second_bound(self):
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in (self.root / 'calls').read_text().splitlines()]
        for call in calls:
            if not any(url.endswith('/releases/latest') or url.endswith('/release-channel.json') for url in call):
                continue
            self.assertEqual(call[len(call) - 1 - call[::-1].index('--retry') + 1], '0')
            self.assertEqual(call[len(call) - 1 - call[::-1].index('--max-time') + 1], '8')

    def test_channel_publisher_only_accepts_published_matching_stable_release(self):
        publish = runpy.run_path(str(SOURCE.parent / 'scripts/release-channel.py'))['stable_channel']
        release = {'draft': False, 'prerelease': False, 'tag_name': 'v1.2.144'}
        self.assertEqual(publish(release, '1.2.144\n'), {'schema': 1, 'tag': 'v1.2.144'})
        for invalid, version in [(dict(release, draft=True), '1.2.144'),
                                 (dict(release, prerelease=True), '1.2.144'),
                                 (dict(release, draft=0), '1.2.144'),
                                 (dict(release, tag_name='v1.2.144-rc1'), '1.2.144-rc1'),
                                 (dict(release, tag_name='../../evil'), '../../evil'),
                                 (release, '1.2.145'), (None, '1.2.144')]:
            with self.subTest(invalid=invalid, version=version), self.assertRaises(ValueError):
                publish(invalid, version)

    def test_installer_error_propagates(self):
        result = self.run_bootstrap(('@', '--help'), ENTRY_STATUS='17')
        self.assertEqual(result.returncode, 17)

    def test_download_failure_does_not_execute(self):
        self.assert_rejected(self.run_bootstrap(FAIL_DOWNLOAD='1'))

    def test_wrong_redirect_repository_is_rejected(self):
        self.headers = self.headers.replace(b'lottman/Remnacust-installer', b'other/unsafe')
        self.assert_rejected(self.run_bootstrap())

    def test_duplicate_redirects_are_rejected(self):
        self.headers += self.headers
        self.assert_rejected(self.run_bootstrap())

    def test_modified_helper_is_rejected_before_execution(self):
        self.files['installer/runtime.py'] = b'changed\n'
        self.assert_rejected(self.run_bootstrap())

    def test_modified_entry_is_rejected_before_execution(self):
        self.files['installer/installer.sh'] += b'echo modified\n'
        self.assert_rejected(self.run_bootstrap())

    def test_version_mismatch_is_rejected(self):
        self.files['VERSION'] = b'1.2.143\n'
        self.assert_rejected(self.run_bootstrap())

    def test_archive_traversal_is_rejected(self):
        self.files['../outside'] = b'bad'
        self.assert_rejected(self.run_bootstrap())

    def test_archive_symlink_is_rejected(self):
        link = tarfile.TarInfo(PREFIX + 'linked')
        link.type, link.linkname = tarfile.SYMTYPE, '/etc'
        self.assert_rejected(self.run_bootstrap(special=link))

    def test_oversized_member_is_rejected(self):
        self.files['too-big'] = b'x' * (2 * 1024 * 1024 + 1)
        self.assert_rejected(self.run_bootstrap())


if __name__ == '__main__':
    unittest.main()
