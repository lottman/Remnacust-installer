"""Installer/helper coherence; every write stays in a disposable fixture."""
import base64
from concurrent.futures import ThreadPoolExecutor
import gzip
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('helper_bundle', INSTALLER / 'helper_bundle.py')
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / 'source'
        (self.source / 'installer').mkdir(parents=True)
        for name in bundle.FILES:
            source = INSTALLER.parent / name if name in {'LICENSE', 'NOTICE.md'} else INSTALLER / name
            target = self.source / name if name in {'LICENSE', 'NOTICE.md'} else self.source / 'installer' / name
            target.write_bytes(source.read_bytes())
        (self.source / 'VERSION').write_text('1.2.57\n')
        (self.source / 'installer/installer.sh').write_bytes((INSTALLER / 'installer.sh').read_bytes())
        bundle.sync(self.source)
        self.entry, self.manifest, self.files = bundle.source_bundle(self.source)

    def tearDown(self):
        self.temporary.cleanup()

    def test_source_and_standalone_have_the_same_bound_cohort_and_license(self):
        entry = bundle.render(self.entry, self.manifest, self.files)
        raw, files = bundle.embedded(entry)
        self.assertEqual(raw, self.manifest)
        self.assertEqual(files, self.files)
        self.assertEqual(bundle.canonical(entry), bundle.canonical(self.entry))
        self.assertEqual(bundle.render(self.entry, self.manifest, self.files), entry)
        self.assertIn('LICENSE', files)
        self.assertIn('image_cleanup.py', files)

    def test_modified_entry_manifest_and_each_helper_are_rejected(self):
        for entry, raw, files in [
            (self.entry + b'# incompatible entry\n', self.manifest, self.files),
            (self.entry, self.manifest + b' ', self.files),
            (self.entry, self.manifest, {**self.files, 'runtime.py': b'bad'}),
            (self.entry, self.manifest, {**self.files, 'update-agent.py': b'bad'}),
            (self.entry, self.manifest, {k: v for k, v in self.files.items() if k != 'database.cjs'}),
        ]:
            with self.assertRaises(ValueError):
                bundle.validate(entry, raw, files)

    def test_newlines_normalize_without_weakening_other_bytes(self):
        entry = self.entry.replace(b'\n', b'\r\n')
        files = {k: v.replace(b'\n', b'\r\n') for k, v in self.files.items()}
        bundle.validate(entry, self.manifest, files)
        destination = self.root / 'snapshot'
        bundle.snapshot(entry, self.manifest, files, destination)
        self.assertEqual((destination / 'runtime.py').read_bytes(), self.files['runtime.py'])

    def test_old_component_files_cannot_replace_current_helpers(self):
        old = self.root / 'old-application' / 'installer'
        old.mkdir(parents=True)
        (old / 'runtime.py').write_text('raise RuntimeError("old helper executed")\n')
        destination = self.root / 'work'
        bundle.snapshot(self.entry, self.manifest, self.files, destination)
        rendered = self.root / 'installed.sh'
        cache = bundle.install(self.entry, destination, self.root / 'cache', rendered)
        self.assertEqual((cache / 'runtime.py').read_bytes(), self.files['runtime.py'])
        self.assertIsNotNone(bundle.embedded(rendered.read_bytes()))

    def test_repeated_install_reuses_healthy_generation_and_preserves_broken_cache(self):
        work = self.root / 'work'
        bundle.snapshot(self.entry, self.manifest, self.files, work)
        target = self.root / 'installed.sh'
        first = bundle.install(self.entry, work, self.root / 'cache', target)
        self.assertEqual(bundle.install(self.entry, work, self.root / 'cache', target), first)
        (first / 'runtime.py').write_text('old or damaged helper')
        second = bundle.install(self.entry, work, self.root / 'cache', target)
        self.assertNotEqual(first, second)
        self.assertEqual((first / 'runtime.py').read_text(), 'old or damaged helper')
        self.assertEqual((second / 'runtime.py').read_bytes(), self.files['runtime.py'])
        self.assertEqual(bundle.embedded(target.read_bytes())[1], self.files)

    def test_snapshot_detects_a_modified_existing_work_directory(self):
        work = self.root / 'work'
        bundle.snapshot(self.entry, self.manifest, self.files, work)
        (work / 'database.cjs').write_text('wrong generation')
        with self.assertRaises(ValueError):
            bundle.snapshot(self.entry, self.manifest, self.files, work)

    def test_version_order_handles_numeric_prereleases_and_stable_releases(self):
        versions = ['1.2.9', '1.3.0-alpha', '1.3.0-alpha.2', '1.3.0-alpha.10',
                    '1.3.0-beta', '1.3.0-rc.2', '1.3.0-rc.10', '1.3.0', '1.3.1']
        self.assertEqual(sorted(reversed(versions), key=bundle.version_key), versions)

    def test_concurrent_installs_publish_one_complete_generation(self):
        work = self.root / 'work'
        bundle.snapshot(self.entry, self.manifest, self.files, work)
        source_entry = self.root / 'entry.sh'
        source_entry.write_bytes(self.entry)
        def install(index):
            return subprocess.run([sys.executable, '-I', str(work / 'helper_bundle.py'), 'install',
                '--entry', str(source_entry), '--cohort', str(work), '--cache-root', str(self.root / 'cache'),
                '--output', str(self.root / ('entry-' + str(index) + '.sh'))], capture_output=True, text=True, timeout=30)
        with ThreadPoolExecutor(max_workers=4) as executor:
            results = list(executor.map(install, range(4)))
        for index, result in enumerate(results):
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(bundle.embedded((self.root / ('entry-' + str(index) + '.sh')).read_bytes())[1], self.files)
        self.assertEqual(len({result.stdout.strip() for result in results}), 1)
        self.assertFalse(list((self.root / 'cache').glob('.helpers-*')))

    def test_archive_paths_links_duplicates_and_excess_size_are_rejected(self):
        for name, kind, size in [('../runtime.py', tarfile.REGTYPE, 1),
                                 ('runtime.py', tarfile.SYMTYPE, 0),
                                 ('runtime.py', tarfile.REGTYPE, bundle.MAX_FILE + 1)]:
            output = io.BytesIO()
            with tarfile.open(fileobj=output, mode='w') as archive:
                member = tarfile.TarInfo(name)
                member.type, member.size = kind, size
                archive.addfile(member, io.BytesIO(b'x' * size) if size else None)
            payload = base64.b64encode(gzip.compress(output.getvalue()))
            entry = bundle.code(self.entry) + bundle.FOOTER + b'# DATA ' + payload + b'\n' + bundle.END
            with self.assertRaises((ValueError, KeyError)):
                bundle.embedded(entry)

    @unittest.skipIf(os.name == 'nt', 'Bash deployment runs on Linux')
    def test_standalone_ignores_poisoned_adjacent_legacy_helpers_offline(self):
        entry = self.root / 'standalone.sh'
        entry.write_bytes(bundle.render(self.entry, self.manifest, self.files))
        (self.root / 'runtime.py').write_text('raise RuntimeError("legacy helper executed")')
        work = self.root / 'work'
        work.mkdir()
        command = r'''source "$1"; WORK=$2; download(){ echo UNEXPECTED_NETWORK >&2; return 99; }; installed_helper; helper --help; printf '\nPAIRED=%s\n' "$HELPER_ROOT"'''
        result = subprocess.run(['bash', '-c', command, 'fixture', str(entry), str(work)], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('legacy helper executed', result.stdout + result.stderr)
        self.assertNotIn('UNEXPECTED_NETWORK', result.stdout + result.stderr)
        self.assertIn('plan-panel-data-restore', result.stdout)

    @unittest.skipIf(os.name == 'nt', 'Bash deployment runs on Linux')
    def test_raw_new_entry_with_only_legacy_helpers_fails_before_operations(self):
        entry = self.root / 'new-entry.sh'
        entry.write_bytes(bundle.code(self.entry))
        (self.root / 'runtime.py').write_text('raise RuntimeError("legacy helper executed")')
        work = self.root / 'work'
        work.mkdir()
        result = subprocess.run(['bash', '-c', 'source "$1";WORK=$2;download(){ echo NETWORK >&2; };installed_helper;touch "$2/SQL_OR_DOCKER"', 'fixture', str(entry), str(work)], capture_output=True, text=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((work / 'SQL_OR_DOCKER').exists())
        self.assertNotIn('legacy helper executed', result.stdout + result.stderr)
        self.assertNotIn('NETWORK', result.stdout + result.stderr)
        if os.geteuid() == 0:
            command = r'''source "$1";WORK=$2
supported_ubuntu_codename(){ printf noble; }
command(){ if [[ $1 == -v ]];then return 0;else builtin command "$@";fi; }
step(){ echo UNEXPECTED_PACKAGES >&2;return 99; }
docker(){ echo UNEXPECTED_DOCKER >&2;return 99; }
prepare_host;touch "$2/SQL_OR_DOCKER"
'''
            result = subprocess.run(['bash', '-c', command, 'fixture', str(entry), str(work)], capture_output=True, text=True, timeout=20)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Не найден проверенный комплект', result.stderr)
            self.assertFalse((work / 'SQL_OR_DOCKER').exists())
            self.assertNotIn('UNEXPECTED_', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
