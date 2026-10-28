"""An isolated stopped-container migration; no existing installation is touched."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime


def docker(*args):
    return subprocess.run(['docker', *args], check=True, capture_output=True, text=True, timeout=90)


def main():
    name = 'remnacust-state-fixture-' + uuid.uuid4().hex[:12]
    with tempfile.TemporaryDirectory(prefix='remnacust-state-migration-') as directory:
        root = Path(directory).resolve()
        port_state = json.dumps({'version': 2, 'revision': '9', 'enabled': True, 'required': True,
                                 'appliedRevision': '8', 'delivery': {'epoch': '9007199254740993',
                                 'owner': 'f508a5b7-0422-4857-a07e-69aa63b90a09'}, 'pluginDirty': True}, separators=(',', ':'))
        try:
            # A disposable container layer reproduces old installs without state
            # mounts. The source stops before the installer copies its state.
            docker('run', '--name', name,
                   '--label', 'com.docker.compose.service=node',
                   '--label', 'com.docker.compose.project.working_dir=' + str(root),
                   '--env', 'SECRET_KEY=isolated-state-fixture', 'alpine:3.22', 'sh', '-c',
                   "mkdir -p /var/lib/remnacust/run/core-state /var/lib/remnanode/quota /var/lib/remnanode/usage /var/lib/remnanode/core /var/lib/remnawave/core-manager; "
                   "chmod 700 /var/lib/remnanode/core; printf '%s' '" + port_state + "' > /var/lib/remnanode/core/port-plan-state.json; chmod 600 /var/lib/remnanode/core/port-plan-state.json; "
                   "printf 'saved-profile-generation' > /var/lib/remnacust/run/core-state/checkpoint.pb; "
                   "printf 'spent-quota-fixture' > /var/lib/remnanode/quota/ledger.json; "
                   "printf 'pending-receipt-fixture' > /var/lib/remnanode/usage/receipt.json; "
                   "printf '%s' '{\"mode\":\"bundled\",\"paused\":true}' > /var/lib/remnawave/core-manager/state.json")
            before = json.loads(docker('inspect', name).stdout)[0]
            assert not before['State']['Running'] and not before['Mounts']
            compose = {'services': {'node': {'image': 'alpine:3.22', 'volumes': []}}}
            plan = runtime.plan_node_state(compose, before, root)
            runtime.snapshot_node_state(plan)
            assert len(plan['copies']) == 3
            for item in plan['copies']:
                target = Path(item['target'])
                assert target.is_relative_to(root) and target.stat().st_mode & 0o777 == 0o700
            mounts = compose['services']['node']['volumes']
            arguments = []
            for mount in mounts:
                arguments.extend(['--mount', 'type=bind,source=' + mount['source'] + ',target=' + mount['target'] + ',readonly'])
            result = docker('run', '--rm', *arguments, 'alpine:3.22', 'sh', '-c',
                            'cat /var/lib/remnacust/run/core-state/checkpoint.pb; echo; '
                            'cat /var/lib/remnanode/quota/ledger.json; echo; '
                            'cat /var/lib/remnanode/usage/receipt.json; echo; '
                            'cat /var/lib/remnawave/core-manager/state.json; echo; cat /var/lib/remnanode/core/port-plan-state.json')
            assert result.stdout.splitlines() == ['saved-profile-generation', 'spent-quota-fixture', 'pending-receipt-fixture', '{"mode":"bundled","paused":true}', port_state]
            # Rollback still has its untouched original layer, not an emptied copy.
            original = root / 'original-ledger.json'
            docker('cp', name + ':/var/lib/remnanode/quota/ledger.json', str(original))
            assert original.read_text() == 'spent-quota-fixture'
            # Reproduce a readiness failure AFTER the new instance has written
            # more usage. Rollback changes the image, never the journal contents.
            backup = root / 'backup'
            backup.mkdir(mode=0o700)
            primary = root / 'compose.json'
            old_config = {'name': 'state-fixture', 'services': {'node': {'image': 'alpine:3.22'}}}
            runtime.write(primary, old_config)
            state = {'directory': str(root), 'component': 'node', 'project': 'state-fixture',
                     'mainService': 'node', 'applications': ['node'], 'composeFiles': [str(primary)]}
            runtime.write(backup / 'state.before.json', state)
            runtime.write(backup / 'container.before.json', [before])
            runtime.write(backup / 'env-files.json', {})
            runtime.write(backup / 'compose.before.json', old_config)
            runtime.write(backup / 'original-0', primary.read_text())
            candidate = root / 'candidate.json'
            compose['name'] = 'state-fixture'
            compose['services']['node']['image'] = 'alpine:3.21'
            runtime.write(candidate, compose)
            state_file = root / 'state.json'
            runtime.write(state_file, state)
            runtime.commit_compose(state_file, candidate, backup, '1.1.10', 'v1.2.58')
            plan_file = root / 'state-plan.json'
            runtime.write(plan_file, plan)
            runtime.preserve_node_state_rollback(plan_file, backup)
            quota = next(Path(item['target']) for item in plan['copies'] if item['source'] == '/var/lib/remnanode')
            (quota / 'quota/ledger.json').write_text('spent-after-new-start')
            (quota / 'usage/receipt.json').write_text('pending-after-new-start')
            runtime.restore_compose(backup)
            primary = Path(runtime.load(backup / 'state.before.json')['composeEntryPoint'])
            assert primary == root / 'docker-compose.yml'
            assert runtime.load(root / 'compose.json')['services'] == {}
            restored = runtime.load(primary)['services']['node']
            assert restored['image'] == 'alpine:3.22'
            assert restored['volumes'] == mounts
            runtime.verify_backup(backup, component='node')
            mounted = []
            for mount in restored['volumes']:
                mounted.extend(['--mount', 'type=bind,source=' + mount['source'] + ',target=' + mount['target'] + ',readonly'])
            latest = docker('run', '--rm', *mounted, 'alpine:3.22', 'sh', '-c',
                            'cat /var/lib/remnanode/quota/ledger.json; echo; cat /var/lib/remnanode/usage/receipt.json; echo; cat /var/lib/remnanode/core/port-plan-state.json')
            assert latest.stdout.splitlines() == ['spent-after-new-start', 'pending-after-new-start', port_state]
            intact = primary.read_bytes()
            (backup / 'node-state-rollback.json').write_text('{}')
            try:
                runtime.restore_compose(backup)
            except runtime.ConfigurationError:
                pass
            else:
                raise AssertionError('Tampered persistent rollback was accepted')
            assert primary.read_bytes() == intact
            print('PASS real Docker: rollback returns the previous image with the newest quota journal, without reissuing spent credit')
            empty = name + '-empty'
            docker('run', '--name', empty,
                   '--label', 'com.docker.compose.service=node',
                   '--label', 'com.docker.compose.project.working_dir=' + str(root),
                   'alpine:3.22', 'true')
            empty_container = json.loads(docker('inspect', empty).stdout)[0]
            empty_plan = runtime.plan_node_state({'services': {'node': {}}}, empty_container, root)
            runtime.snapshot_node_state(empty_plan)
            assert all(not list(Path(item['target']).iterdir()) for item in empty_plan['copies'])
            print('PASS real Docker: cached profile, spent quota and pause survive persistent-state migration; rollback source remains intact')
            print('PASS real Docker: absent legacy state is distinguished from copy/daemon failures')
        finally:
            subprocess.run(['docker', 'rm', '-f', name, name + '-empty'], capture_output=True, timeout=30)


if __name__ == '__main__':
    main()
