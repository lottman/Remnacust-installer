import copy
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime


class PanelRestoreTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.directory = self.root / 'panel'
        self.directory.mkdir()
        self.primary = self.directory / 'compose.json'
        self.layer = self.directory / 'compose.override.yaml'
        self.primary.write_text('original compose', encoding='utf-8')
        self.layer.write_text('active override', encoding='utf-8')
        self.env = self.directory / '.env'
        self.env.write_text('APP_SECRET=current-key-remains-in-env-file', encoding='utf-8')
        self.custom_env = self.directory / 'workers.env'
        self.custom_env.write_text('CUSTOM_SETTING=preserve', encoding='utf-8')
        self.image = 'sha256:' + 'a' * 64
        self.secret = 'backup-signing-key-$-with-literal-dollar-' + 'b' * 32
        self.url = 'postgresql://user:current-password@database:5432/current'
        self.state = dict(component='panel', directory=str(self.directory), project='restore-audit',
                          version='1.1.9', image='current:1.1.9', mainService='api',
                          applications=['api', 'worker', 'standby', 'page'],
                          composeFiles=[str(self.primary), str(self.layer)],
                          subscriptionPage=True, subscriptionTokenUuid='12345678-1234-4234-8234-123456789012')
        self.archived = dict(component='panel', version='1.1.2', mainService='old-api',
                             applications=['old-api', 'worker', 'standby', 'page'],
                             runningApplications=['old-api', 'worker', 'page'], subscriptionPage=True,
                             subscriptionTokenUuid='22345678-1234-4234-8234-123456789012',
                             directory='/old-server', project='old-project')
        self.config = dict(name='restore-audit', services={
            'api': dict(image='current:1.1.9', build='.', environment=dict(DATABASE_URL=self.url, APP_SECRET='${APP_SECRET}', KEEP='$$HOME'), env_file=[str(self.env)]),
            'worker': dict(image='stale:1.1.7', environment=['INSTANCE_TYPE=JOB', 'APP_SECRET=${APP_SECRET}'], env_file=[dict(path=str(self.custom_env), required=True)]),
            'standby': dict(image='stale:1.1.7'),
            'page': dict(image='subscription:2.0', environment=dict(REMNAWAVE_API_TOKEN='stale-token', CUSTOM_PAGE='preserve'), labels={'io.remnacust.service-role': 'subscription-page'}),
            'database': dict(image='postgres:18.4', volumes=['current-db:/var/lib/postgresql']),
            'cache': dict(image='valkey/valkey:9-alpine'),
            'proxy': dict(image='caddy:2.9', ports=['443:443'])},
            networks=dict(default=dict(name='existing-network')), volumes=dict(current_db=dict(external=True)))
        self.container = dict(Config=dict(Env=['APP_SECRET=' + self.secret]))
        self.active = dict(Config=dict(Env=['DATABASE_URL=' + self.url, 'APP_SECRET=current-key']))

    def plan(self, **kwargs):
        return runtime.plan_panel_data_restore(self.config, self.state, self.archived, self.container,
                                               self.image, active=self.active, **kwargs)

    def test_restore_keeps_installed_version_infrastructure_and_only_pins_panel_writers(self):
        original = copy.deepcopy(self.config)
        plan = self.plan()
        self.assertEqual(plan['state']['version'], '1.1.9')
        self.assertEqual(plan['state']['directory'], str(self.directory))
        self.assertEqual(plan['state']['runningApplications'], ['api', 'worker', 'page'])
        self.assertEqual(plan['state']['subscriptionTokenUuid'], self.archived['subscriptionTokenUuid'])
        for service in ['api', 'worker', 'standby']:
            self.assertEqual(plan['config']['services'][service]['image'], self.image)
            self.assertEqual(plan['config']['services'][service]['environment']['APP_SECRET'], self.secret.replace('$', '$$'))
            self.assertNotIn('build', plan['config']['services'][service])
        for service in ['database', 'cache', 'proxy', 'page']:
            self.assertEqual(plan['config']['services'][service], original['services'][service])
        self.assertEqual(plan['config']['networks'], original['networks'])
        self.assertEqual(plan['config']['volumes'], original['volumes'])
        self.assertEqual(plan['config']['services']['api']['environment']['KEEP'], '$$HOME')
        self.assertEqual(plan['config']['services']['worker']['env_file'], original['services']['worker']['env_file'])
        self.assertEqual(plan['database'], dict(DATABASE_URL=self.url, APP_SECRET=self.secret))
        self.assertEqual(self.config, original)

    @unittest.skipIf(os.name == 'nt', 'Standalone Bash restore runs on Linux')
    def test_new_standalone_restores_with_old_adjacent_helpers_without_network_or_old_compose(self):
        import helper_bundle
        entry, raw, files = helper_bundle.source_bundle(Path(__file__).resolve().parents[2])
        cli = self.root / 'old-installation'
        cli.mkdir()
        script = cli / 'installer.sh'
        script.write_bytes(helper_bundle.render(entry, raw, files))
        for name in ['runtime.py', 'database.cjs', 'subscription.cjs']:
            (cli / name).write_text('LEGACY_HELPER_MUST_NOT_EXECUTE\n')
        work = self.root / 'work'; work.mkdir()
        backup = self.root / 'old-backup'; backup.mkdir()
        runtime.write(backup / 'state.before.json', self.archived)
        runtime.write(backup / 'container.before.json', [self.container])
        runtime.write(self.root / 'config.json', self.config)
        runtime.write(self.root / 'current-state.json', self.state)
        runtime.write(self.root / 'active.json', [self.active])
        plan = self.root / 'restore-plan.json'
        command = r'''source "$1"; WORK=$2;shift 2
download(){ echo UNEXPECTED_NETWORK >&2;return 99; }
docker(){ echo UNEXPECTED_DOCKER >&2;return 99; }
installed_helper;helper "$@"
'''
        args = ['plan-panel-data-restore', '--directory', str(backup), '--source', str(self.root / 'config.json'),
                '--state', str(self.root / 'current-state.json'), '--current-inspect', str(self.root / 'active.json'),
                '--roles', str(self.root / 'config.json'), '--environment-source', str(self.root / 'config.json'),
                '--image', self.image, '--plan', str(plan), '--target', str(self.root / 'next-compose.json')]
        result = subprocess.run(['bash', '-c', command, 'test', str(script), str(work), *args], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('UNEXPECTED_', result.stdout + result.stderr)
        actual = runtime.load(plan)
        self.assertEqual(actual['config'], self.plan()['config'])
        self.assertEqual(actual['state']['version'], '1.1.9')
        self.assertEqual(actual['database']['APP_SECRET'], self.secret)
        before_env = self.env.read_bytes()
        result = subprocess.run(['bash', '-c', command, 'test', str(script), str(work),
            'commit-panel-data-restore', '--source', str(plan), '--state', str(self.root / 'restored-state.json')],
            capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('UNEXPECTED_', result.stdout + result.stderr)
        self.assertEqual(runtime.load(self.primary), actual['config'])
        self.assertEqual(runtime.load(self.root / 'restored-state.json'), actual['state'])
        self.assertEqual(self.env.read_bytes(), before_env)

    def test_commit_replaces_active_layers_but_never_overwrites_env_or_archived_configuration(self):
        plan = self.plan()
        output = self.root / 'state.json'
        before = self.env.read_bytes()
        archived = copy.deepcopy(self.archived)
        runtime.commit_panel_data_restore(plan, output)
        self.assertEqual(runtime.load(self.primary), plan['config'])
        self.assertEqual(runtime.load(self.layer), dict(services={}))
        self.assertEqual(runtime.load(output), plan['state'])
        self.assertEqual(self.env.read_bytes(), before)
        self.assertEqual(self.archived, archived)
        if os.name != 'nt':
            self.assertEqual(os.stat(self.primary).st_mode & 0o777, 0o600)

    def test_all_stopped_and_legacy_backup_running_semantics(self):
        self.archived['runningApplications'] = []
        self.assertEqual(self.plan()['state']['runningApplications'], [])
        del self.archived['runningApplications']
        self.assertEqual(self.plan()['state']['runningApplications'], ['api', 'worker', 'standby', 'page'])

    def test_newer_backup_refused_before_any_file_changes_and_legacy_unknown_accepted(self):
        for version in ['1.1.10', '1.1.9.1', 'broken']:
            self.archived['version'] = version
            with self.assertRaises(runtime.ConfigurationError): self.plan()
            self.assertEqual(self.primary.read_text(), 'original compose')
        del self.archived['version']
        self.assertEqual(self.plan()['state']['version'], '1.1.9')

    def test_missing_or_ambiguous_workers_and_unmanaged_page_are_refused(self):
        self.archived['runningApplications'].append('absent-worker')
        self.archived['applications'].append('absent-worker')
        with self.assertRaises(runtime.ConfigurationError): self.plan()
        self.archived['runningApplications'].pop()
        self.archived['applications'].pop()
        self.state['subscriptionPage'] = False
        with self.assertRaises(runtime.ConfigurationError): self.plan()

    def test_invalid_backup_key_and_wrong_live_database_are_refused_without_secret_diagnostics(self):
        for secret in ['short', 'x' * 32 + '\n', 'x' * 4097]:
            self.container['Config']['Env'] = ['APP_SECRET=' + secret]
            with self.assertRaises(runtime.ConfigurationError) as failure: self.plan()
            self.assertNotIn(secret, str(failure.exception))
        self.container['Config']['Env'] = ['APP_SECRET=' + self.secret]
        self.active['Config']['Env'][0] += '-changed'
        with self.assertRaises(runtime.ConfigurationError) as failure: self.plan()
        self.assertNotIn(self.url, str(failure.exception))

    def test_operator_edits_to_any_layer_or_environment_abort_before_commit(self):
        for path in [self.primary, self.layer, self.env, self.custom_env]:
            original = path.read_bytes()
            plan = self.plan()
            path.write_bytes(original + b'changed')
            with self.assertRaises(runtime.ConfigurationError):
                runtime.commit_panel_data_restore(plan, self.root / 'state.json')
            self.assertFalse((self.root / 'state.json').exists())
            path.write_bytes(original)

    def test_optional_absent_env_file_appearance_and_resolved_environment_paths_are_guarded(self):
        self.config['services']['worker']['env_file'] = [{'path': '${WORKER_FILE}', 'required': False}]
        expanded = copy.deepcopy(self.config)
        missing = self.directory / 'optional.env'
        expanded['services']['worker']['env_file'][0]['path'] = str(missing)
        plan = self.plan(environment_config=expanded)
        missing.write_text('appeared')
        with self.assertRaises(runtime.ConfigurationError): runtime.validate_panel_data_restore(plan)

    def test_subscription_token_refresh_preserves_page_settings_and_never_starts_it(self):
        plan = self.plan()
        runtime.commit_panel_data_restore(plan, self.root / 'state.json')
        runtime.restore_panel_subscription_token(plan, 'header.payload.signature')
        actual = runtime.load(self.primary)
        expected = copy.deepcopy(plan['config'])
        expected['services']['page']['environment']['REMNAWAVE_API_TOKEN'] = 'header.payload.signature'
        self.assertEqual(actual, expected)
        self.assertEqual(actual['services']['page']['image'], 'subscription:2.0')
        with self.assertRaises(runtime.ConfigurationError): runtime.restore_panel_subscription_token(plan, 'new.payload.signature')

    def test_subscription_refresh_refuses_invalid_token_or_concurrent_compose_change(self):
        plan = self.plan()
        runtime.commit_panel_data_restore(plan, self.root / 'state.json')
        for token in ['', 'bad token', 'header.payload.signature\n', 'a.b.' + 'c' * 16384]:
            with self.assertRaises(runtime.ConfigurationError): runtime.restore_panel_subscription_token(plan, token)
        changed = runtime.load(self.primary)
        changed['services']['api']['image'] = 'operator-edit'
        runtime.write(self.primary, changed)
        with self.assertRaises(runtime.ConfigurationError): runtime.restore_panel_subscription_token(plan, 'header.payload.signature')
        self.assertEqual(runtime.load(self.primary), changed)

    @unittest.skipIf(os.name == 'nt', 'Installer orchestration runs on Linux')
    def test_subscription_workflow_uses_backup_uuid_and_private_environment_without_starting_services(self):
        plan = self.plan()
        state = self.root / 'restored-state.json'
        runtime.commit_panel_data_restore(plan, state)
        runtime.write(self.root / 'panel-restore-plan.json', plan)
        (self.root / 'database.network').write_text('current-database-network')
        (self.root / 'database.env').write_text('APP_SECRET=' + self.secret + '\nDATABASE_URL=' + self.url + '\n')
        command = r'''source "$1/installer.sh"
HELPER="$1/runtime.py";WORK=$2;STATE=$3
get(){ python3 "$HELPER" get --state "$STATE" --key "$1"; }
helper(){ python3 "$HELPER" "$@"; }
docker(){ printf '%s\n' "$*" >> "$WORK/docker-events"; cat >/dev/null; printf 'header.payload.signature\n'; }
refresh_restored_subscription_page
'''
        installer = Path(__file__).resolve().parents[1]
        result = subprocess.run(['bash', '-c', command, 'test', str(installer), str(self.root), str(state)], capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        events = (self.root / 'docker-events').read_text()
        self.assertIn('--network current-database-network', events)
        self.assertIn('--env-file ' + str(self.root / 'database.env'), events)
        self.assertIn('REMNACUST_SUBSCRIPTION_TOKEN_UUID=' + self.archived['subscriptionTokenUuid'], events)
        self.assertNotIn(self.secret, result.stdout + result.stderr + events)
        self.assertNotIn('header.payload.signature', result.stdout + result.stderr)
        self.assertNotIn('compose', events)
        self.assertFalse((self.root / 'subscription-token.txt').exists())
        self.assertEqual(runtime.load(self.primary)['services']['page']['environment']['REMNAWAVE_API_TOKEN'], 'header.payload.signature')

    def test_legacy_shadow_file_is_consolidated_into_existing_primary(self):
        shadow = self.directory / 'compose.remnacust-20261010T120000Z-72.json'
        shadow.write_text('{}')
        self.layer.unlink()
        self.state['composeFiles'] = [str(shadow)]
        plan = self.plan()
        self.assertEqual(plan['primary'], str(self.primary))
        runtime.commit_panel_data_restore(plan, self.root / 'state.json')
        self.assertEqual(runtime.load(shadow), dict(services={}))

    def test_repeated_restore_accepts_only_empty_consolidated_override_and_guards_it(self):
        runtime.write(self.layer, {'services': {}})
        self.state['composeFiles'] = [str(self.primary)]
        plan = self.plan()
        runtime.write(self.layer, {'services': {'api': {'image': 'operator-image'}}})
        with self.assertRaises(runtime.ConfigurationError): runtime.validate_panel_data_restore(plan)
        with self.assertRaises(runtime.ConfigurationError): self.plan()
        runtime.write(self.layer, {'services': {}})
        plan = self.plan()
        runtime.commit_panel_data_restore(plan, self.root / 'state.json')
        self.assertEqual(runtime.load(self.layer), {'services': {}})

    def test_unregistered_database_writer_or_managed_page_is_refused_before_stopping_apps(self):
        for service in [dict(image='custom-worker', environment={'DATABASE_URL': self.url}),
                        dict(image='custom-worker', environment={'INSTANCE_TYPE': 'scheduler'}),
                        dict(image='current:1.1.9'),
                        dict(image='custom-page', labels={'io.remnacust.service-role': 'subscription-page'})]:
            self.config['services']['forgotten-service'] = service
            with self.assertRaises(runtime.ConfigurationError): self.plan()
            self.assertEqual(self.primary.read_text(), 'original compose')

    def test_infrastructure_cannot_be_classified_as_a_panel_writer(self):
        self.state['applications'].append('database')
        with self.assertRaises(runtime.ConfigurationError): self.plan()


if __name__ == '__main__':
    unittest.main()
