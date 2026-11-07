import copy
from contextlib import contextmanager
import ctypes
import errno
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid


WORKTREE = Path(__file__).resolve().parents[2]
SOURCE = WORKTREE / 'installer' / 'node_site.py'


class PowerLoss(BaseException):
    pass


class NodeSiteTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='.node-site-tests-', dir=WORKTREE if os.name == 'nt' else None)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.helper = self.root / 'helpers'
        self.helper.mkdir()
        self.script = self.helper / 'node_site.py'
        shutil.copyfile(SOURCE, self.script)
        self.data = {'schema': 1, 'sites': [self.site(index) for index in range(20)]}
        self.write_catalog()
        spec = importlib.util.spec_from_file_location('node_site_test_' + uuid.uuid4().hex, self.script)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.deploy = self.root / 'node'
        self.backups = self.root / 'backups' / 'node-sites'

    @staticmethod
    def site(index):
        return {'id': 'site-' + str(index), 'title': 'Test publication ' + str(index),
                'description': 'Generic isolated renderer fixture, not catalog content.',
                'files': {'index.html': '<!doctype html><html lang="en"><title>{{DOMAIN}}</title><a href="/about/">About</a></html>',
                          'about/index.html': '<!doctype html><html lang="en"><title>About</title><p>{{DOMAIN}}</p></html>',
                          '404.html': '<!doctype html><html lang="en"><title>Not found</title><a href="/">Home</a></html>',
                          'guide/index.html': '<!doctype html><html lang="en"><title>Guide</title><p>Fixture ' + str(index) + '</p></html>',
                          'styles.css': ':root { color: #173b67; background: #fafcff; }',
                          'app.js': '"use strict"; document.documentElement.dataset.ready = "yes";',
                          'assets/art.svg': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><title>Square</title><path d="M1 1h8v8H1z"/></svg>'}}

    def write_catalog(self):
        self.write_catalog_text(json.dumps(self.data, ensure_ascii=False))

    def write_catalog_text(self, text):
        payload = ('CATALOG_JSON = ' + repr(text) + '\n').encode('utf-8')
        (self.helper / 'node_site_catalog.py').write_bytes(payload)

    def install(self, **kwargs):
        return self.module.install_site(self.deploy, 'node.example.test', backup_root=self.backups, **kwargs)

    def custom(self, content=b'custom public site'):
        website = self.deploy / 'www'
        website.mkdir(parents=True)
        (website / 'index.html').write_bytes(content)
        return website

    def link(self, target, path, directory=False):
        try:
            path.symlink_to(target, target_is_directory=directory)
        except (OSError, NotImplementedError) as error:
            if directory and os.name == 'nt':
                junction = subprocess.run(['cmd', '/c', 'mklink', '/J', str(path), str(target)], capture_output=True)
                if junction.returncode == 0:
                    return
            self.skipTest('Symlinks unavailable: ' + str(error))

    def cli(self, *args):
        return subprocess.run([sys.executable, '-B', str(self.script), *map(str, args)],
                              capture_output=True, text=True, encoding='utf-8', timeout=20)

    def test_catalog_contract_lists_twenty_ids_and_metadata_without_assets(self):
        self.assertEqual(self.module.TEMPLATES, ['site-' + str(index) for index in range(20)])
        self.assertEqual(len(self.module.catalog()), 20)
        self.assertEqual(set(self.module.catalog()[0]), {'id', 'title', 'description'})

    def test_render_is_deterministic_and_substitutes_only_html_through_escape(self):
        with patch.object(self.module.html, 'escape', wraps=self.module.html.escape) as escaped:
            first = self.module.render_site('NODE.example.test', 'site-3')
        escaped.assert_called()
        self.assertEqual(first, self.module.render_site('node.example.test', 'site-3'))
        self.assertEqual(first['app.js'], self.data['sites'][3]['files']['app.js'])
        self.assertIn('node.example.test', first['index.html'])
        self.assertNotIn('{{DOMAIN}}', first['about/index.html'])
        self.assertEqual(set(first), set(self.data['sites'][3]['files']))

    def test_catalog_bytes_are_bounded_inclusively_and_utf8_only(self):
        path = self.helper / 'node_site_catalog.py'
        original = json.dumps(self.data, ensure_ascii=False)
        padding = self.module.MAX_CATALOG_BYTES - len(path.read_bytes())
        self.write_catalog_text(original + ' ' * padding)
        self.assertEqual(path.stat().st_size, self.module.MAX_CATALOG_BYTES)
        self.assertEqual(len(self.module.catalog()), 20)
        self.write_catalog_text(original + ' ' * (padding + 1))
        with self.assertRaisesRegex(ValueError, 'LIMIT'):
            self.module.catalog()
        path.write_bytes(('CATALOG_JSON = ' + repr(original) + '\n').encode('utf-16'))
        with self.assertRaises(ValueError):
            self.module.catalog()

    def test_duplicate_keys_ids_shapes_and_required_pages_are_rejected(self):
        self.write_catalog_text('{"schema":1,"schema":1,"sites":[]}')
        with self.assertRaisesRegex(ValueError, 'DUPLICATE'):
            self.module.catalog()
        original = copy.deepcopy(self.data)
        for change in [lambda data: data.update(schema=True), lambda data: data.update(sites=[]),
                       lambda data: data['sites'].append(copy.deepcopy(data['sites'][0])),
                       lambda data: data['sites'][0]['files'].pop('404.html')]:
            self.data = copy.deepcopy(original)
            change(self.data)
            self.write_catalog()
            with self.assertRaises(ValueError):
                self.module.catalog()

    def test_data_helper_is_only_a_canonical_string_literal_and_never_executes_code(self):
        path = self.helper / 'node_site_catalog.py'
        marker = self.root / 'must-not-exist'
        malicious = "__import__('pathlib').Path(" + repr(str(marker)) + ").write_text('executed')"
        for content in [malicious, 'CATALOG_JSON = ' + malicious + '\n',
                        'import os\nCATALOG_JSON = \'{}\'\n',
                        'CATALOG_JSON = \'{}\'\nOTHER = 1\n',
                        'CATALOG_JSON = \'{}\' # comment\n',
                        'CATALOG_JSON = \'{\' \'}\'\n',
                        'CATALOG_JSON = (\'{}\')\n',
                        'CATALOG_JSON = \'{\' + \'}\'\n',
                        'CATALOG_JSON = b\'{}\'\n', 'CATALOG_JSON = {}\n',
                        'CATALOG_JSON = \'\\ud800\'\n']:
            path.write_bytes(content.encode('utf-8'))
            with self.subTest(content=content), self.assertRaises(ValueError):
                self.module.catalog()
            self.assertFalse(marker.exists())

    def test_data_helper_unicode_crlf_and_escaped_content_preserve_exact_json_values(self):
        self.data['sites'][0]['title'] = 'Заметки о свете'
        self.data['sites'][0]['files']['guide/index.html'] += '<p>Owner\'s \\ path and a line\nnext line</p>'
        self.write_catalog()
        path = self.helper / 'node_site_catalog.py'
        path.write_bytes(path.read_bytes().replace(b'\n', b'\r\n'))
        self.assertEqual(self.module._load_catalog()['site-0']['files'], self.data['sites'][0]['files'])
        self.assertEqual(self.module.catalog()[0]['title'], 'Заметки о свете')

    def test_raw_json_is_not_used_as_an_unverified_fallback(self):
        (self.helper / 'node_site_catalog.py').unlink()
        (self.helper / 'node-sites.json').write_text(json.dumps(self.data), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'SITE_CATALOG_MISSING'):
            self.module.catalog()

    def test_extracted_json_limit_is_enforced_independently_of_helper_size(self):
        self.write_catalog_text(' ' * (self.module.MAX_CATALOG_BYTES + 1))
        with patch.object(self.module, '_read', return_value=(self.helper / 'node_site_catalog.py').read_bytes()):
            with self.assertRaisesRegex(ValueError, 'SITE_CATALOG_LIMIT'):
                self.module.catalog()

    def test_catalog_rejects_traversal_windows_aliases_case_collisions_and_file_parent_collisions(self):
        original = copy.deepcopy(self.data)
        for name in ['../escape.html', '/absolute.html', 'a/../../escape.html', 'a\\escape.js',
                     'a//b.html', './index.html', 'CON.html', 'assets./a.svg', 'x:stream.js', '.env', 'a.exe']:
            self.data = copy.deepcopy(original)
            self.data['sites'][0]['files'][name] = 'fixture'
            self.write_catalog()
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.module.catalog()
        for additions in [{'INDEX.html': 'case alias'}, {'styles.css/nested.js': 'parent alias'}]:
            self.data = copy.deepcopy(original)
            self.data['sites'][0]['files'].update(additions)
            self.write_catalog()
            with self.assertRaises(ValueError):
                self.module.catalog()

    def test_domain_placeholder_outside_html_and_oversized_individual_assets_are_rejected(self):
        self.data['sites'][0]['files']['app.js'] = '{{DOMAIN}}'
        self.write_catalog()
        with self.assertRaisesRegex(ValueError, 'PLACEHOLDER'):
            self.module.catalog()
        self.data['sites'][0]['files']['app.js'] = 'x' * (self.module.MAX_FILE_BYTES + 1)
        self.write_catalog()
        with self.assertRaises(ValueError):
            self.module.catalog()

    def test_invalid_domains_and_relative_deployments_never_create_website(self):
        for domain in ['<script>alert(1)</script>', 'example.test/path', 'example.test:443', 'https://example.test',
                       'a\nb.example', '-bad.example', '', 'a' * 64 + '.test']:
            with self.subTest(domain=domain), self.assertRaises(ValueError):
                self.module.install_site(self.deploy, domain)
        for deployment in [Path('relative'), self.root / '..' / 'outside', Path(self.root.anchor)]:
            with self.assertRaises(ValueError):
                self.module.install_site(deployment, 'node.example.test')
        self.assertFalse(self.deploy.exists())

    def test_random_is_chosen_once_and_state_is_outside_webroot(self):
        with patch.object(self.module.secrets, 'choice', return_value='site-7') as choice:
            first = self.install()
            second = self.install()
            self.data['sites'][7]['files']['index.html'] += '<p>updated bundle</p>'
            self.write_catalog()
            third = self.install()
        choice.assert_called_once_with(['site-' + str(index) for index in range(20)])
        self.assertEqual(first['template'], 'site-7')
        self.assertEqual(second['status'], 'preserved')
        self.assertFalse(second['changed'])
        self.assertIsNone(third['generation'])
        self.assertEqual(first['generation'], self.module._tree(self.deploy / 'www'))
        self.assertTrue((self.deploy / self.module.STATE_NAME).is_file())
        self.assertFalse(any(path.name.startswith('.') for path in (self.deploy / 'www').rglob('*')))
        self.assertNotIn('updated bundle', (self.deploy / 'www/index.html').read_text())
        json.dumps(first)

    def test_custom_content_and_hand_edited_managed_sites_are_preserved(self):
        website = self.custom()
        with patch.object(self.module.secrets, 'choice', side_effect=AssertionError('must not randomize')):
            result = self.install()
        self.assertEqual(result['status'], 'preserved')
        self.assertEqual((website / 'index.html').read_bytes(), b'custom public site')
        installed = self.install(template='site-1', replace=True)
        (website / 'notes.txt').write_text('operator addition')
        (website / 'index.html').write_text('operator modification')
        after = self.install()
        self.assertEqual(after['status'], 'preserved')
        self.assertEqual(after['template'], installed['template'])
        self.assertEqual((website / 'index.html').read_text(), 'operator modification')
        self.assertEqual((website / 'notes.txt').read_text(), 'operator addition')

    def test_only_exact_legacy_stub_without_other_files_is_initialized(self):
        website = self.custom(self.module.OLD_STUB)
        result = self.install(template='site-2')
        self.assertTrue(result['changed'])
        self.assertEqual((Path(result['backup']) / 'www/index.html').read_bytes(), self.module.OLD_STUB)
        for content, extra in [(self.module.OLD_STUB.rstrip(), False), (self.module.OLD_STUB, True)]:
            other = self.root / ('other-' + uuid.uuid4().hex)
            (other / 'www').mkdir(parents=True)
            (other / 'www/index.html').write_bytes(content)
            if extra:
                (other / 'www/keep.txt').write_text('custom')
            response = self.module.install_site(other, 'example.test', backup_root=self.backups)
            self.assertEqual(response['status'], 'preserved')

    def test_explicit_replace_archives_entire_custom_site_but_not_deployment_secrets(self):
        website = self.custom()
        (website / 'private-local-name.txt').write_text('public file with an unusual name')
        (self.deploy / '.env').write_text('SECRET=not-part-of-the-site')
        old = self.module._tree(website)
        result = self.install(template='site-4', replace=True)
        archive = Path(result['backup'])
        self.assertEqual(self.module._tree(archive / 'www'), old)
        self.assertEqual(archive.parent, self.backups)
        self.assertFalse((archive / '.env').exists())
        self.assertEqual((self.deploy / '.env').read_text(), 'SECRET=not-part-of-the-site')
        self.assertEqual(set(result), {'status', 'changed', 'directory', 'template', 'generation', 'backup'})

    def test_empty_directory_initializes_and_explicit_random_replacement_reselects(self):
        (self.deploy / 'www').mkdir(parents=True)
        with patch.object(self.module.secrets, 'choice', side_effect=['site-0', 'site-19']) as choice:
            first = self.install()
            second = self.install(replace=True)
        self.assertEqual(choice.call_count, 2)
        self.assertEqual((first['template'], second['template']), ('site-0', 'site-19'))
        self.assertEqual(self.module._state(Path(second['backup']) / self.module.STATE_NAME)['template'], 'site-0')

    def test_random_replacement_excludes_the_current_selected_id(self):
        self.install(template='site-4')
        def choose(values):
            self.assertEqual(len(values), 19)
            self.assertNotIn('site-4', values)
            return values[0]
        with patch.object(self.module.secrets, 'choice', side_effect=choose):
            result = self.install(replace=True)
        self.assertNotEqual(result['template'], 'site-4')

    def test_default_preserves_large_custom_tree_without_scan_or_hashing(self):
        website = self.custom()
        with (website / 'large.bin').open('wb') as stream:
            stream.truncate(self.module.MAX_EXISTING_BYTES + 1)
        for index in range(self.module.MAX_EXISTING_FILES + 1):
            (website / ('public-' + str(index) + '.txt')).touch()
        original = (website / 'index.html').stat().st_mtime_ns
        with (patch.object(self.module, '_tree', side_effect=AssertionError('full scan on NOOP')),
              patch.object(self.module, '_load_catalog', side_effect=AssertionError('catalog on NOOP'))):
            result = self.install()
        self.assertEqual(result['status'], 'preserved')
        self.assertFalse(result['changed'])
        self.assertIsNone(result['generation'])
        self.assertEqual((website / 'index.html').stat().st_mtime_ns, original)
        self.assertFalse((self.deploy / self.module.LOCK_NAME).exists())
        with self.assertRaisesRegex(ValueError, 'LIMIT'):
            self.install(replace=True)

    def test_default_preserves_child_directory_symlink_without_following_or_scanning(self):
        website = self.custom()
        target = self.root / 'outside'
        target.mkdir()
        (target / 'keep.txt').write_text('do not read or modify')
        self.link(target, website / 'assets', True)
        with (patch.object(self.module, '_tree', side_effect=AssertionError('followed custom tree')),
              patch.object(self.module, '_read', side_effect=AssertionError('read custom leaf'))):
            result = self.install()
        self.assertEqual(result['status'], 'preserved')
        self.assertEqual((target / 'keep.txt').read_text(), 'do not read or modify')

    def test_managed_default_preserves_selection_without_scanning_or_reading_assets(self):
        self.install(template='site-6')
        original = self.module._read
        def bounded_metadata(path, limit):
            self.assertEqual(path, self.deploy / self.module.STATE_NAME)
            self.assertEqual(limit, self.module.MAX_MANIFEST_BYTES)
            return original(path, limit)
        with (patch.object(self.module, '_tree', side_effect=AssertionError('managed scan')),
              patch.object(self.module, '_read', side_effect=bounded_metadata)):
            result = self.install()
        self.assertEqual(result['template'], 'site-6')
        self.assertFalse(result['changed'])

    def test_www_symlink_is_rejected_before_mkdir_or_chmod(self):
        self.deploy.mkdir()
        target = self.root / 'target'
        target.mkdir()
        self.link(target, self.deploy / 'www', True)
        with patch.object(self.module, '_mkdir', side_effect=AssertionError('mkdir before safety')):
            with self.assertRaisesRegex(ValueError, 'SYMLINK'):
                self.install()
        self.assertEqual(list(target.iterdir()), [])
        self.assertFalse((self.deploy / self.module.LOCK_NAME).exists())

    def test_symlinked_ancestor_and_nested_tree_entry_are_rejected(self):
        real = self.root / 'real'
        real.mkdir()
        alias = self.root / 'alias'
        self.link(real, alias, True)
        with self.assertRaisesRegex(ValueError, 'SYMLINK'):
            self.module.install_site(alias / 'node', 'example.test')
        website = self.custom()
        self.link(real, website / 'assets', True)
        with self.assertRaisesRegex(ValueError, 'SYMLINK'):
            self.install(replace=True)
        self.assertEqual((website / 'index.html').read_bytes(), b'custom public site')

    def test_hardlinked_files_and_symlinked_metadata_or_backups_are_rejected(self):
        website = self.custom()
        original = self.root / 'outside.txt'
        original.write_text('must stay untouched')
        os.link(original, website / 'link.txt')
        with self.assertRaisesRegex(ValueError, 'REGULAR'):
            self.install(replace=True)

    def test_metadata_file_symlink_is_never_followed_on_replace(self):
        self.custom()
        original = self.root / 'outside.txt'
        original.write_text('must stay untouched')
        self.link(original, self.deploy / self.module.STATE_NAME)
        with self.assertRaisesRegex(ValueError, 'SYMLINK'):
            self.install(replace=True)
        self.assertEqual(original.read_text(), 'must stay untouched')

    def test_default_does_not_read_hardlinked_index_even_if_it_has_exact_stub_bytes(self):
        self.deploy.mkdir()
        website = self.deploy / 'www'
        website.mkdir()
        target = self.root / 'outside.html'
        target.write_bytes(self.module.OLD_STUB)
        os.link(target, website / 'index.html')
        with (patch.object(self.module, '_read', side_effect=AssertionError('hardlink read')),
              patch.object(self.module, '_tree', side_effect=AssertionError('hardlink scan'))):
            self.assertEqual(self.install()['status'], 'preserved')
        self.assertEqual(target.read_bytes(), self.module.OLD_STUB)

    def test_backup_root_cannot_be_in_webroot_deployment_or_ancestor(self):
        self.custom()
        for path in [self.deploy, self.deploy / 'www/archive', self.deploy / 'backups', self.root]:
            with self.subTest(path=str(path)), self.assertRaises(ValueError):
                self.module.install_site(self.deploy, 'example.test', replace=True, backup_root=path)
        self.assertEqual((self.deploy / 'www/index.html').read_bytes(), b'custom public site')

    def test_manifests_are_bounded_and_cannot_supply_traversal_paths(self):
        self.install(template='site-1')
        state = self.deploy / self.module.STATE_NAME
        original = state.read_bytes()
        state.write_bytes(b'x' * (self.module.MAX_MANIFEST_BYTES + 1))
        self.assertEqual(self.install()['status'], 'preserved')
        with self.assertRaisesRegex(ValueError, 'LIMIT'):
            self.install(replace=True)
        data = json.loads(original)
        data['files']['../outside.txt'] = 'a' * 64
        state.write_text(json.dumps(data))
        self.assertEqual(self.install()['status'], 'preserved')
        with self.assertRaisesRegex(ValueError, 'PATH'):
            self.install(replace=True)

    def test_concurrent_install_fails_closed_without_reselection(self):
        self.install(template='site-0')
        before = self.module._tree(self.deploy / 'www')
        with self.module._locked(self.deploy), self.assertRaisesRegex(ValueError, 'BUSY'):
            self.install(replace=True)
        self.assertEqual(self.module._tree(self.deploy / 'www'), before)

    def test_staging_write_failure_never_changes_public_content(self):
        website = self.custom()
        original = self.module._write
        def fail(path, data, mode=0o600):
            if path.name == 'styles.css':
                raise OSError('isolated disk failure')
            return original(path, data, mode)
        with patch.object(self.module, '_write', side_effect=fail), self.assertRaises(OSError):
            self.install(template='site-0', replace=True)
        self.assertEqual((website / 'index.html').read_bytes(), b'custom public site')

    def test_changes_during_staging_are_not_overwritten(self):
        website = self.custom()
        original = self.module._write
        def changed(path, data, mode=0o600):
            result = original(path, data, mode)
            if path.name == 'styles.css':
                (website / 'index.html').write_text('new operator edit')
            return result
        with patch.object(self.module, '_write', side_effect=changed), self.assertRaisesRegex(ValueError, 'CHANGED'):
            self.install(template='site-0', replace=True)
        self.assertEqual((website / 'index.html').read_text(), 'new operator edit')

    def test_default_initialization_does_not_promote_a_racing_custom_edit_to_an_authorized_replacement(self):
        website = self.custom(self.module.OLD_STUB)
        original = self.module._initial_site
        calls = 0
        def changed(path):
            nonlocal calls
            result = original(path)
            calls += 1
            if calls == 2:
                (website / 'index.html').write_text('operator replaced the stub')
            return result
        with patch.object(self.module, '_initial_site', side_effect=changed):
            result = self.install()
        self.assertEqual(result['status'], 'preserved')
        self.assertFalse(result['changed'])
        self.assertEqual((website / 'index.html').read_text(), 'operator replaced the stub')

    def test_failed_publish_restores_old_www_and_retry_recovers_the_transaction(self):
        website = self.custom()
        original = self.module._move
        def fail(source, destination):
            if source.name.startswith('.node-site-stage-') and destination == website:
                raise OSError('isolated rename failure')
            return original(source, destination)
        with patch.object(self.module, '_exchange', return_value=False), patch.object(self.module, '_move', side_effect=fail):
            with self.assertRaises(OSError):
                self.install(template='site-3', replace=True)
        self.assertEqual((website / 'index.html').read_bytes(), b'custom public site')
        result = self.install()
        self.assertEqual(result['template'], 'site-3')
        self.assertTrue(result['changed'])
        self.assertFalse((self.deploy / self.module.JOURNAL_NAME).exists())

    def test_power_loss_between_renames_recovers_without_another_random_choice(self):
        self.custom()
        original = self.module._move
        def crash(source, destination):
            if source.name.startswith('.node-site-stage-') and destination == self.deploy / 'www':
                raise PowerLoss()
            return original(source, destination)
        with patch.object(self.module, '_exchange', return_value=False), patch.object(self.module, '_move', side_effect=crash):
            with self.assertRaises(PowerLoss):
                self.install(template='site-8', replace=True)
        with patch.object(self.module.secrets, 'choice', side_effect=AssertionError('reselection')):
            result = self.install()
        self.assertEqual(result['template'], 'site-8')
        self.assertTrue(result['changed'])
        self.assertTrue((Path(result['backup']) / 'www/index.html').is_file())

    def test_recovery_refuses_unknown_new_www_occupant(self):
        self.custom()
        original = self.module._move
        def crash(source, destination):
            if source.name.startswith('.node-site-stage-') and destination == self.deploy / 'www':
                raise PowerLoss()
            return original(source, destination)
        with patch.object(self.module, '_exchange', return_value=False), patch.object(self.module, '_move', side_effect=crash):
            with self.assertRaises(PowerLoss):
                self.install(template='site-0', replace=True)
        self.custom(b'appeared after interruption')
        with self.assertRaisesRegex(ValueError, 'CONFLICT'):
            self.install()
        self.assertEqual((self.deploy / 'www/index.html').read_bytes(), b'appeared after interruption')

    def test_fresh_install_recovery_reports_changed_even_without_a_backup(self):
        original = self.module._atomic
        def crash(path, value):
            if path.name == self.module.STATE_NAME:
                raise PowerLoss()
            return original(path, value)
        with patch.object(self.module, '_atomic', side_effect=crash), self.assertRaises(PowerLoss):
            self.install(template='site-5')
        result = self.install()
        self.assertTrue(result['changed'])
        self.assertIsNone(result['backup'])
        self.assertEqual(result['template'], 'site-5')

    def test_guarded_restore_returns_custom_content_and_archives_current_generation(self):
        self.custom()
        result = self.install(template='site-0', replace=True)
        restored = self.module.restore_site(self.deploy, result['backup'], result['generation'], self.backups)
        self.assertEqual(restored['status'], 'restored')
        self.assertIsNone(restored['template'])
        self.assertFalse((self.deploy / self.module.STATE_NAME).exists())
        self.assertEqual((self.deploy / 'www/index.html').read_bytes(), b'custom public site')
        self.assertEqual(self.module._tree(Path(restored['backup']) / 'www'), result['generation'])
        self.assertEqual(self.install()['status'], 'preserved')

    def test_cli_restore_preserves_owner_edited_managed_site_as_unmanaged(self):
        self.install(template='site-2')
        website = self.deploy / 'www'
        (website / 'index.html').write_text('owner edited the managed homepage')
        (website / 'owner-notes.txt').write_text('owner added public content')
        original = self.module._tree(website)
        replaced = self.install(template='site-9', replace=True)
        archive = Path(replaced['backup'])
        self.assertEqual(self.module._tree(archive / 'www'), original)
        self.assertNotEqual(self.module._state(archive / self.module.STATE_NAME)['tree'], original)
        restored = self.cli('--directory', self.deploy, '--restore', archive,
                            '--expected-generation', replaced['generation'], '--backup-root', self.backups)
        self.assertEqual(restored.returncode, 0, restored.stderr)
        result = json.loads(restored.stdout)
        self.assertIsNone(result['template'])
        self.assertEqual(result['generation'], original)
        self.assertEqual(self.module._tree(website), original)
        self.assertFalse((self.deploy / self.module.STATE_NAME).exists())
        self.assertEqual((website / 'index.html').read_text(), 'owner edited the managed homepage')
        self.assertEqual((website / 'owner-notes.txt').read_text(), 'owner added public content')
        self.assertEqual(self.module._tree(Path(result['backup']) / 'www'), replaced['generation'])
        with (patch.object(self.module, '_tree', side_effect=AssertionError('rescanned restored owner content')),
              patch.object(self.module.secrets, 'choice', side_effect=AssertionError('rerandomized owner content'))):
            preserved = self.install()
        self.assertEqual(preserved['status'], 'preserved')
        self.assertIsNone(preserved['template'])

    def test_owner_edited_managed_backup_still_requires_receipt_state_hash_and_expected_generation(self):
        self.install(template='site-1')
        (self.deploy / 'www/index.html').write_text('owner edit before replacement')
        replaced = self.install(template='site-8', replace=True)
        archive = Path(replaced['backup'])
        saved_state = (archive / self.module.STATE_NAME).read_bytes()
        saved_index = (archive / 'www/index.html').read_bytes()
        tampered = json.loads(saved_state)
        tampered['template'] = 'site-7'
        (archive / self.module.STATE_NAME).write_text(json.dumps(tampered))
        with self.assertRaisesRegex(ValueError, 'SITE_BACKUP_CHANGED'):
            self.module.restore_site(self.deploy, archive, replaced['generation'], self.backups)
        self.assertEqual(self.module._tree(self.deploy / 'www'), replaced['generation'])
        (archive / self.module.STATE_NAME).write_bytes(saved_state)
        (archive / 'www/index.html').write_text('archive edit after receipt')
        with self.assertRaisesRegex(ValueError, 'SITE_BACKUP_CHANGED'):
            self.module.restore_site(self.deploy, archive, replaced['generation'], self.backups)
        self.assertEqual(self.module._tree(self.deploy / 'www'), replaced['generation'])
        (archive / 'www/index.html').write_bytes(saved_index)
        (self.deploy / 'www/index.html').write_text('new owner edit after replacement')
        with self.assertRaisesRegex(ValueError, 'SITE_GENERATION_CHANGED'):
            self.module.restore_site(self.deploy, archive, replaced['generation'], self.backups)
        self.assertEqual((self.deploy / 'www/index.html').read_text(), 'new owner edit after replacement')

    def test_owner_edited_managed_restore_recovers_after_publication_interruption(self):
        self.install(template='site-0')
        (self.deploy / 'www/index.html').write_text('owner page retained across recovery')
        original_tree = self.module._tree(self.deploy / 'www')
        replaced = self.install(template='site-3', replace=True)
        original_move = self.module._move
        def crash(source, destination):
            if source.name.startswith('.node-site-stage-') and destination == self.deploy / 'www':
                raise PowerLoss()
            return original_move(source, destination)
        with (patch.object(self.module, '_exchange', return_value=False),
              patch.object(self.module, '_move', side_effect=crash), self.assertRaises(PowerLoss)):
            self.module.restore_site(self.deploy, replaced['backup'], replaced['generation'], self.backups)
        pending = json.loads((self.deploy / self.module.JOURNAL_NAME).read_bytes())
        self.assertIsNone(pending['state'])
        with patch.object(self.module.secrets, 'choice', side_effect=AssertionError('recovery rerandomized')):
            recovered = self.install()
        self.assertEqual(recovered['generation'], original_tree)
        self.assertIsNone(recovered['template'])
        self.assertFalse((self.deploy / self.module.STATE_NAME).exists())
        self.assertEqual((self.deploy / 'www/index.html').read_text(), 'owner page retained across recovery')

    def test_restore_refuses_modified_current_content_or_backup_and_wrong_deployment(self):
        self.custom()
        result = self.install(template='site-1', replace=True)
        (self.deploy / 'www/operator.txt').write_text('new edit')
        with self.assertRaisesRegex(ValueError, 'GENERATION_CHANGED'):
            self.module.restore_site(self.deploy, result['backup'], result['generation'], self.backups)
        (self.deploy / 'www/operator.txt').unlink()
        (Path(result['backup']) / 'www/index.html').write_text('changed archive')
        with self.assertRaisesRegex(ValueError, 'BACKUP_CHANGED'):
            self.module.restore_site(self.deploy, result['backup'], result['generation'], self.backups)
        other = self.root / 'other'
        self.module.install_site(other, 'other.example.test', template='site-1', backup_root=self.backups)
        with self.assertRaisesRegex(ValueError, 'BACKUP'):
            self.module.restore_site(other, result['backup'], self.module._tree(other / 'www'), self.backups)

    def test_restore_managed_selection_persists_and_can_be_reversed_by_generation(self):
        first = self.install(template='site-2')
        second = self.install(template='site-9', replace=True)
        restored = self.module.restore_site(self.deploy, second['backup'], second['generation'], self.backups)
        self.assertEqual(restored['generation'], first['generation'])
        self.assertEqual(self.install()['template'], 'site-2')
        reverse = self.module.restore_site(self.deploy, restored['backup'], restored['generation'], self.backups)
        self.assertEqual(reverse['template'], 'site-9')

    def test_restore_power_loss_recovers_the_original_custom_site_without_reselection(self):
        self.custom()
        installed = self.install(template='site-0', replace=True)
        original = self.module._move
        def crash(source, destination):
            if source.name.startswith('.node-site-stage-') and destination == self.deploy / 'www':
                raise PowerLoss()
            return original(source, destination)
        with (patch.object(self.module, '_exchange', return_value=False),
              patch.object(self.module, '_move', side_effect=crash), self.assertRaises(PowerLoss)):
            self.module.restore_site(self.deploy, installed['backup'], installed['generation'], self.backups)
        with patch.object(self.module.secrets, 'choice', side_effect=AssertionError('restore rerandomized')):
            recovered = self.install()
        self.assertTrue(recovered['changed'])
        self.assertIsNone(recovered['template'])
        self.assertEqual((self.deploy / 'www/index.html').read_bytes(), b'custom public site')

    def test_linux_rename_uses_parent_descriptors_and_no_replace_flag(self):
        source, destination = self.root / 'source', self.root / 'destination'
        source.mkdir()
        calls = []
        @contextmanager
        def parent(path):
            yield 101 if path == source else 102
        def rename(*args):
            calls.append(args)
            ctypes.set_errno(errno.EEXIST)
            return -1
        with (patch.object(self.module.sys, 'platform', 'linux'),
              patch.object(self.module, '_parent', side_effect=parent),
              patch.object(self.module.ctypes, 'CDLL', return_value=SimpleNamespace(renameat2=rename)),
              patch.object(self.module.os, 'rename', side_effect=AssertionError('unsafe fallback')),
              self.assertRaises(OSError)):
            self.module._move(source, destination)
        self.assertEqual(calls, [(101, b'source', 102, b'destination', 1)])
        self.assertTrue(source.exists())

    def test_linux_exchange_uses_nofollow_parent_descriptors(self):
        left, right = self.root / 'left', self.root / 'right'
        calls = []
        @contextmanager
        def parent(path):
            yield 201 if path == left else 202
        def rename(*args):
            calls.append(args)
            return 0
        with (patch.object(self.module.sys, 'platform', 'linux'),
              patch.object(self.module, '_parent', side_effect=parent),
              patch.object(self.module.ctypes, 'CDLL', return_value=SimpleNamespace(renameat2=rename))):
            self.assertTrue(self.module._exchange(left, right))
        self.assertEqual(calls, [(201, b'left', 202, b'right', 2)])

    def test_cli_list_install_preserve_and_restore_are_json_and_never_interactive(self):
        listed = self.cli('--list')
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertEqual(len(json.loads(listed.stdout)), 20)
        self.custom()
        installed = self.cli('--directory', self.deploy, '--domain', 'node.example.test', '--replace', '--backup-root', self.backups)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        data = json.loads(installed.stdout)
        preserved = self.cli('--directory', self.deploy, '--domain', 'node.example.test')
        self.assertEqual(preserved.returncode, 0, preserved.stderr)
        self.assertEqual(json.loads(preserved.stdout)['template'], data['template'])
        restored = self.cli('--directory', self.deploy, '--restore', data['backup'], '--expected-generation', data['generation'], '--backup-root', self.backups)
        self.assertEqual(restored.returncode, 0, restored.stderr)
        self.assertEqual(json.loads(restored.stdout)['status'], 'restored')
        invalid = self.cli('--directory', 'relative', '--domain', 'example.test')
        self.assertEqual(invalid.returncode, 1)
        self.assertIn('error', json.loads(invalid.stderr))


if __name__ == '__main__':
    unittest.main()
