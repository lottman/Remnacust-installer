import copy
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime


class UpgradeVersionTests(unittest.TestCase):
    def setUp(self):
        self.state = {'component': 'panel', 'project': 'audit', 'mainService': 'app',
                      'applications': ['app', 'worker'], 'version': '1.1.7.99',
                      'image': 'ghcr.io/lottman/remnacust-panel:legacy'}
        self.config = {'services': {'app': {'image': self.state['image']},
                                    'worker': {'image': self.state['image']}}}

    def container(self, version=None, image=None, service='app', project='audit', running=True):
        labels = {'com.docker.compose.project': project, 'com.docker.compose.service': service}
        if version is not None:
            labels['org.opencontainers.image.version'] = version
        return {'Config': {'Image': image or self.state['image'], 'Labels': labels,
                           'Env': ['APP_SECRET=PRIVATE_VALUE_DO_NOT_ECHO']},
                'State': {'Running': running}}

    def check(self, version='1.1.7.100', release='v1.2.148', containers=()):
        return runtime.assert_upgrade_versions(self.config, self.state, version, release, containers)

    def test_state_floor_accepts_equal_and_newer_but_rejects_lower(self):
        self.assertIsNone(self.check('1.1.7.99'))
        self.assertIsNone(self.check())
        with self.assertRaisesRegex(runtime.ConfigurationError,
                                    'Понижение версии компонента запрещено: установлена 1.1.7.99, выбрана 1.1.7.98'):
            self.check('1.1.7.98')

    def test_numeric_parts_compare_as_integers_and_pad_zeroes(self):
        for current, chosen in [('1.1.7.99', '1.1.7.100'), ('1.9', '1.10'),
                                ('1.2', '1.2.0.0'), ('1.2.0.0', '1.2'), ('1.0002.0', '1.2')]:
            with self.subTest(current=current, chosen=chosen):
                self.state['version'] = current
                self.assertIsNone(self.check(chosen))
        self.state['version'] = '1.1.7.100'
        with self.assertRaises(runtime.ConfigurationError):
            self.check('1.1.7.99')

    def test_invalid_targets_fail_even_with_no_known_current_version(self):
        self.state.pop('version')
        invalid = [None, 12, '', '1', 'v1.2.3', '1.2.3.4.5', '1.2-beta', '1.2\n',
                   '1.-2', '١.٢', '9' * 10000 + '.1', '1.1000000000', 'PRIVATE_VALUE_DO_NOT_ECHO']
        for chosen in invalid:
            with self.subTest(chosen=str(chosen)[:40]):
                with self.assertRaises(runtime.ConfigurationError) as caught:
                    self.check(chosen)
                self.assertNotIn('PRIVATE_VALUE_DO_NOT_ECHO', str(caught.exception))
        for release in [None, 12, '', 'v1', 'vv1.2.3', 'v1.2-rc1', '1.2.3.4.5', 'v1.2\n', 'v' + '1' * 10000]:
            with self.subTest(release=str(release)[:40]):
                with self.assertRaises(runtime.ConfigurationError):
                    self.check(release=release)

    def test_marker_component_floor_requires_same_component(self):
        self.config['x-remnacust-release'] = {'component': 'panel', 'version': '1.1.7.101', 'installer': 'v1.2.148'}
        with self.assertRaises(runtime.ConfigurationError):
            self.check()
        for component in ['node', 'subscription-page', None]:
            self.config['x-remnacust-release']['component'] = component
            self.assertIsNone(self.check())

    def test_installer_marker_floor_applies_across_shared_compose_components(self):
        for component in ['panel', 'node', 'subscription-page', None]:
            with self.subTest(component=component):
                self.config['x-remnacust-release'] = {'component': component, 'version': '0.1', 'installer': 'v1.2.148'}
                with self.assertRaisesRegex(runtime.ConfigurationError,
                                            'Понижение версии установщика запрещено: установлена v1.2.148, выбрана v1.2.147'):
                    self.check(release='v1.2.147')
                self.assertIsNone(self.check(release='1.2.148.0'))
                self.assertIsNone(self.check(release='v1.2.149'))

    def test_component_and_installer_floors_are_independent(self):
        self.config['x-remnacust-release'] = {'component': 'panel', 'version': '1.1.7.100', 'installer': 'v1.2.148'}
        with self.assertRaisesRegex(runtime.ConfigurationError, 'версии установщика'):
            self.check('1.1.7.100', 'v1.2.147')
        with self.assertRaisesRegex(runtime.ConfigurationError, 'версии компонента'):
            self.check('1.1.7.99', 'v99.0.0')
        self.assertIsNone(self.check('1.1.7.100', 'v1.2.148'))

    def test_image_tag_sets_separate_component_and_installer_floors(self):
        image = 'ghcr.io/lottman/remnacust-panel:1.1.7.100-v1.2.148-amd64'
        for source in ['config', 'state', 'container']:
            with self.subTest(source=source):
                self.setUp()
                containers = []
                if source == 'config':
                    self.config['services']['app']['image'] = image
                elif source == 'state':
                    self.state['image'] = image
                else:
                    containers = [self.container(image=image)]
                with self.assertRaisesRegex(runtime.ConfigurationError, 'версии компонента'):
                    self.check('1.1.7.99', containers=containers)
                with self.assertRaisesRegex(runtime.ConfigurationError, 'версии установщика'):
                    self.check(release='v1.2.147', containers=containers)
                self.assertIsNone(self.check(containers=containers))

    def test_oci_labels_override_stale_registry_for_running_and_stopped_containers(self):
        for running in [True, False]:
            with self.subTest(running=running):
                container = self.container('1.1.7.101', running=running)
                with self.assertRaisesRegex(runtime.ConfigurationError, 'установлена 1.1.7.101'):
                    self.check(containers=[container])
                self.assertIsNone(self.check('1.1.7.101', containers=[container]))

    def test_oci_version_precedes_container_image_tag_and_invalid_label_uses_pin(self):
        image = 'ghcr.io/lottman/remnacust-panel:1.1.7.101-v1.2.148-arm64'
        self.assertIsNone(self.check(containers=[self.container('1.1.7.100', image)]))
        for label in [None, 'legacy', '1.2.3-rc1']:
            with self.subTest(label=label):
                with self.assertRaises(runtime.ConfigurationError):
                    self.check(containers=[self.container(label, image)])

    def test_missing_container_uses_numeric_compose_pin(self):
        self.state.pop('version')
        for image in ['ghcr.io/lottman/remnacust-panel:1.1.7.101',
                      'registry.example:5000/team/panel:1.1.7.101-v1.2.148-arm64',
                      'panel:1.1.7.101@sha256:' + 'a' * 64]:
            with self.subTest(image=image):
                self.config['services']['app']['image'] = image
                with self.assertRaises(runtime.ConfigurationError):
                    self.check(containers=[])

    def test_explicit_upstream_version_families_do_not_block_migration(self):
        for repository in ['ghcr.io/remnawave/backend', 'remnawave/backend']:
            with self.subTest(repository=repository):
                self.state.update(version='3.7.0', image=repository + ':3.7.0')
                for service in self.config['services'].values():
                    service['image'] = repository + ':3.7.0'
                self.assertIsNone(self.check(containers=[self.container('3.7.0')]))
                self.config['x-remnacust-release'] = {'component': 'panel', 'version': '1.1.7.101'}
                with self.assertRaises(runtime.ConfigurationError):
                    self.check(containers=[self.container('3.7.0')])
                self.config.pop('x-remnacust-release')

    def test_upstream_migration_still_respects_shared_installer_floor(self):
        self.state.update(version='3.7.0', image='remnawave/backend:3.7.0')
        self.config['services'] = {'app': {'image': self.state['image']}}
        self.config['x-remnacust-release'] = {'component': 'node', 'version': '3.7.0', 'installer': 'v1.2.149'}
        with self.assertRaisesRegex(runtime.ConfigurationError, 'версии установщика'):
            self.check(containers=[self.container('3.7.0')])

    def test_similar_repository_names_are_not_treated_as_upstream(self):
        for image in ['evil.example/remnawave/backend:3.7.0', 'ghcr.io/remnawave-custom/backend:3.7.0',
                      'remnawave-fork/backend:3.7.0']:
            with self.subTest(image=image):
                self.state.update(version='3.7.0', image=image)
                with self.assertRaises(runtime.ConfigurationError):
                    self.check()

    def test_only_application_services_in_same_project_contribute_floors(self):
        self.config['services'].update(db={'image': 'postgres:18.4'}, proxy={'image': 'nginx:99.0'},
                                       unrelated={'image': 'panel:99.0'})
        containers = [self.container('99.0', service='db'), self.container('99.0', service='proxy'),
                      self.container('99.0', service='unrelated'), self.container('99.0', project='other'),
                      self.container('99.0', project='')]
        self.assertIsNone(self.check(containers=containers))
        with self.assertRaises(runtime.ConfigurationError):
            self.check(containers=[*containers, self.container('1.1.7.101', service='worker')])

    def test_shared_compose_excludes_other_components_and_database_images(self):
        for name, image, labels in [
                ('page', 'ghcr.io/lottman/remnacust-subscription-page:9.9-v9.9.9-amd64', {}),
                ('node', 'ghcr.io/lottman/remnacust-node:9.9-v9.9.9-amd64', {}),
                ('page-custom', 'custom:9.9-v9.9.9-amd64', {'io.remnacust.service-role': 'subscription-page'}),
                ('db', 'postgres:18.4', {}), ('proxy', 'nginx:99.0', {})]:
            self.config['services'][name] = {'image': image, 'labels': labels}
            self.state['applications'].append(name)
        containers = [self.container('99.0', image=service['image'], service=name)
                      for name, service in self.config['services'].items() if name not in ['app', 'worker']]
        self.assertIsNone(self.check(containers=containers))

    def test_unknown_legacy_versions_are_allowed_without_success_claim_or_mutation(self):
        self.state['version'] = 'legacy'
        self.config['x-remnacust-release'] = {'component': 'panel', 'version': 'old', 'installer': 'main'}
        containers = [self.container('unknown'), {'State': {'Running': False}}]
        original = copy.deepcopy((self.config, self.state, containers))
        output = io.StringIO()
        with patch('sys.stdout', output):
            self.assertIsNone(self.check(containers=containers))
        self.assertEqual(output.getvalue(), '')
        self.assertEqual((self.config, self.state, containers), original)

    def test_error_never_includes_image_credentials_or_environment_secrets(self):
        image = 'PRIVATE_VALUE_DO_NOT_ECHO.example/team/panel:1.1.7.101-v1.2.148-amd64'
        with self.assertRaises(runtime.ConfigurationError) as caught:
            self.check(containers=[self.container(image=image)])
        self.assertNotIn('PRIVATE_VALUE_DO_NOT_ECHO', str(caught.exception))
        self.assertNotIn(image, str(caught.exception))


class UpgradeVersionCliTests(unittest.TestCase):
    def test_cli_uses_same_floors_and_accepts_missing_inspect_for_legacy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / 'compose.json'
            state = root / 'state.json'
            inspect = root / 'inspect.json'
            config.write_text(json.dumps({'services': {'app': {'image': 'panel:old'}}}), encoding='utf-8')
            state.write_text(json.dumps({'component': 'panel', 'project': 'audit', 'applications': ['app']}), encoding='utf-8')
            inspect.write_text(json.dumps([{'Config': {'Image': 'panel:old', 'Labels': {
                'com.docker.compose.project': 'audit', 'com.docker.compose.service': 'app',
                'org.opencontainers.image.version': '1.1.7.101'}}}]), encoding='utf-8')
            command = [sys.executable, '-X', 'utf8', runtime.__file__, 'check-upgrade', '--source', str(config),
                       '--state', str(state), '--version', '1.1.7.100', '--key', 'v1.2.148']
            result = subprocess.run([*command, '--inspect', str(inspect)], capture_output=True, encoding='utf-8')
            self.assertEqual(result.returncode, 1)
            self.assertIn('Понижение версии компонента запрещено', result.stderr)
            self.assertEqual(result.stdout, '')
            result = subprocess.run(command, capture_output=True, encoding='utf-8')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, '')


class UpgradeVersionCommitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.deployment = self.root / 'deployment'
        self.backup = self.root / 'backup'
        self.deployment.mkdir()
        self.backup.mkdir()
        self.primary = self.deployment / 'compose.yaml'
        self.primary.write_bytes(b'# preserve bytes\r\nservices: {app: {image: old}}\r\n')
        self.state = {'component': 'panel', 'directory': str(self.deployment), 'project': 'audit',
                      'composeFiles': [str(self.primary)], 'applications': ['app'], 'mainService': 'app',
                      'version': '1.1.7.99', 'image': 'panel:legacy'}
        self.state_path = self.root / 'state.json'
        self.candidate_path = self.root / 'candidate.json'
        self.effective = {'services': {'app': {'image': 'panel:old'}},
                          'x-remnacust-release': {'component': 'panel', 'version': '1.1.7.101', 'installer': 'v1.2.148'}}
        self.save(self.state_path, self.state)
        self.save(self.backup / 'state.before.json', self.state)
        self.save(self.backup / 'compose.before.json', self.effective)
        self.save(self.candidate_path, {'services': {'app': {'image': 'panel:new'}}})
        (self.backup / 'SHA256SUMS').write_bytes(b'preserve existing backup checksums\n')

    def save(self, path, value):
        path.write_text(json.dumps(value), encoding='utf-8')

    def commit(self, version='1.1.7.100', release='v1.2.148', preserve_release=False):
        runtime.commit_compose(self.state_path, self.candidate_path, self.backup, version, release,
                               preserve_release=preserve_release)

    def assert_blocked_without_writes(self):
        files = {path.relative_to(self.root): path.read_bytes() for path in self.root.rglob('*') if path.is_file()}
        with patch.object(runtime, 'write', wraps=runtime.write) as write:
            with self.assertRaises(runtime.ConfigurationError):
                self.commit()
            write.assert_not_called()
        self.assertEqual({path.relative_to(self.root): path.read_bytes()
                          for path in self.root.rglob('*') if path.is_file()}, files)

    def test_blocked_effective_marker_leaves_compose_state_candidate_and_backup_unchanged(self):
        self.assert_blocked_without_writes()

    def test_stopped_container_snapshot_blocks_before_backups_are_written(self):
        self.effective.pop('x-remnacust-release')
        self.save(self.backup / 'compose.before.json', self.effective)
        self.save(self.backup / 'container.before.json', [{'State': {'Running': False}, 'Config': {
            'Image': 'panel:old', 'Labels': {'com.docker.compose.project': 'audit',
                                          'com.docker.compose.service': 'app',
                                          'org.opencontainers.image.version': '1.1.7.101'}}}])
        self.assert_blocked_without_writes()

    def test_missing_snapshots_fall_back_to_previous_state(self):
        (self.backup / 'compose.before.json').unlink()
        self.state['version'] = '1.1.7.101'
        self.save(self.backup / 'state.before.json', self.state)
        self.save(self.state_path, {**self.state, 'version': '0.1'})
        self.assert_blocked_without_writes()

    def test_container_snapshot_is_checked_without_effective_compose_snapshot(self):
        (self.backup / 'compose.before.json').unlink()
        self.save(self.backup / 'container.before.json', [{'State': {'Running': False}, 'Config': {
            'Image': 'panel:1.1.7.101', 'Labels': {'com.docker.compose.project': 'audit',
                                               'com.docker.compose.service': 'app'}}}])
        self.assert_blocked_without_writes()

    def test_installer_downgrade_is_blocked_before_writes(self):
        self.effective['x-remnacust-release'].update(version='1.1.7.100', installer='v1.2.149')
        self.save(self.backup / 'compose.before.json', self.effective)
        self.assert_blocked_without_writes()

    def test_equal_and_newer_versions_can_commit(self):
        for version in ['1.1.7.101', '1.1.7.102']:
            with self.subTest(version=version):
                self.setUp()
                with patch('sys.stdout', io.StringIO()):
                    self.commit(version)
                marker = runtime.load(self.primary)['x-remnacust-release']
                self.assertEqual(marker, {'component': 'panel', 'version': version, 'installer': 'v1.2.148'})
                self.assertTrue((self.backup / 'compose-files.before.json').is_file())

    def test_configure_and_rollback_bypass_version_guard(self):
        candidate = runtime.load(self.candidate_path)
        candidate['x-remnacust-release'] = self.effective['x-remnacust-release']
        self.save(self.candidate_path, candidate)
        with patch.object(runtime, 'assert_upgrade_versions', side_effect=AssertionError('guard must be bypassed')):
            with patch('sys.stdout', io.StringIO()):
                self.commit('', '', preserve_release=True)
        self.assertEqual(runtime.load(self.primary), candidate)
        self.assertTrue((self.backup / 'compose-files.before.json').is_file())


if __name__ == '__main__':
    unittest.main()
