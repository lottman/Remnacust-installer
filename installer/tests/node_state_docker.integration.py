"""An isolated stopped-container migration; no existing installation is touched."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime


def docker(*args):
    return subprocess.run(['docker', *args], check=True, capture_output=True, text=True, timeout=90)


def stopped_compose_migration(root, image, project):
    deployment = root / 'stopped-deployment'
    deployment.mkdir(mode=0o700)
    primary = deployment / 'docker-compose.yml'
    runtime.write(primary, {'name': project, 'services': {'remnanode': {'image': image, 'network_mode': 'none',
        'environment': {'SECRET_KEY': 'stopped-fixture', 'NODE_PORT': '2222'},
        'command': ['sh', '-c', 'mkdir -p /var/lib/remnanode/quota; printf spent-before-migration > /var/lib/remnanode/quota/ledger.json']}}})
    base = ['compose', '--project-name', project, '--project-directory', str(deployment), '-f', str(primary)]
    installer = Path(__file__).resolve().parents[1] / 'installer.sh'
    registry = root / 'installer-root'
    work = root / 'migration-work'
    work.mkdir(mode=0o700)
    (registry / 'registry').mkdir(mode=0o700, parents=True)
    shell = '''source "$1"
ROOT=$2; WORK=$3; DIRECTORY=$4; HELPER_ROOT=$(dirname "$1"); HELPER=$HELPER_ROOT/runtime.py
LOG=$WORK/log; COMPONENT=node; ACTION=migrate-remnawave-node; YES=true; VERSION=1.2.170
prepare_host(){ :; }
prepare_image(){ docker image inspect "$IMAGE" >/dev/null; }
node_migration_wizard(){ :; }; node_net_admin_wizard(){ :; }; node_migration_finish(){ :; }
verify_node_image_policy(){ :; }; install_cli(){ :; }; cleanup_old_images(){ :; }; completion_summary(){ :; }
release_source(){ IMAGE=$FIXTURE_IMAGE; TAG=v1.2.170; COMPONENT_VERSION=1.1.33; }
helper(){ if [[ ${FAIL_SNAPSHOT:-0} == 1 && $1 == snapshot-node-state ]]; then return 73; fi; python3 "$HELPER" "$@"; }
deploy
'''
    def migrate(fail_snapshot=False):
        return subprocess.run(['bash', '-c', shell, 'test', str(installer), str(registry), str(work), str(deployment)],
                              env={**os.environ, 'REMNACUST_ROOT': str(registry), 'FIXTURE_IMAGE': image,
                                   'FAIL_SNAPSHOT': '1' if fail_snapshot else '0', 'NO_COLOR': '1'},
                              capture_output=True, text=True, timeout=180)
    try:
        docker(*base, 'up', '--no-start', '--no-build', '--pull', 'never', 'remnanode')
        original = docker(*base, 'ps', '--all', '--quiet', 'remnanode').stdout.strip()
        docker('start', '--attach', original)
        assert not json.loads(docker('inspect', original).stdout)[0]['State']['Running']
        drifted = runtime.load(primary)
        drifted['services']['remnanode']['labels'] = {'fixture.pending-edit': 'preserved'}
        runtime.write(primary, drifted)
        original_config = primary.read_bytes()
        result = migrate(fail_snapshot=True)
        assert result.returncode != 0, 'Injected snapshot failure was ignored'
        assert primary.read_bytes() == original_config
        assert docker(*base, 'ps', '--all', '--quiet', 'remnanode').stdout.strip() == original
        assert not json.loads(docker('inspect', original).stdout)[0]['State']['Running']
        retained = root / 'retained-after-snapshot-failure'
        docker('cp', original + ':/var/lib/remnanode/quota/ledger.json', str(retained))
        assert retained.read_text() == 'spent-before-migration'
        result = migrate()
        assert result.returncode == 0, result.stderr
        current_id = docker(*base, 'ps', '--all', '--quiet', 'remnanode').stdout.strip()
        current = json.loads(docker('inspect', current_id).stdout)[0]
        assert current_id != original and not current['State']['Running'] and current['State']['Status'] == 'created'
        quota = next(mount['Source'] for mount in current['Mounts'] if mount['Destination'] == '/var/lib/remnanode')
        ledger = Path(quota) / 'quota/ledger.json'
        assert ledger.read_text() == 'spent-before-migration'
        assert runtime.load(registry / 'registry/node.json')['runningApplications'] == []
        snapshots = set(deployment.glob('.remnacust-node-state-*'))
        result = migrate()
        assert result.returncode == 0, result.stderr
        assert set(deployment.glob('.remnacust-node-state-*')) == snapshots
        current_id = docker(*base, 'ps', '--all', '--quiet', 'remnanode').stdout.strip()
        assert not json.loads(docker('inspect', current_id).stdout)[0]['State']['Running']
        config = runtime.load(primary)
        empty = deployment / 'empty-replacement'
        empty.mkdir(mode=0o700)
        for mount in config['services']['remnanode']['volumes']:
            if mount['target'] == '/var/lib/remnanode':
                mount['source'] = str(empty)
        runtime.write(primary, config)
        unchanged = primary.read_bytes()
        result = migrate()
        assert result.returncode != 0, 'Occupied private state mount was silently repointed'
        assert primary.read_bytes() == unchanged and ledger.read_text() == 'spent-before-migration'
        current = json.loads(docker('inspect', current_id).stdout)[0]
        assert not current['State']['Running']
        assert next(mount['Source'] for mount in current['Mounts'] if mount['Destination'] == '/var/lib/remnanode') == quota
        print('PASS real Compose migration: failed snapshot retains original layer; stopped source, repeat and occupied mounts preserve private state')
    finally:
        subprocess.run(['docker', *base, 'down', '--remove-orphans'], capture_output=True, timeout=30)


def occupied_state_mounts(root, image, name):
    nested = root / 'nested-quota'
    nested.mkdir(mode=0o700)
    volume = name + '-private'
    container_name = name + '-occupied'
    try:
        docker('volume', 'create', volume)
        docker('run', '--name', container_name, '--label', 'com.docker.compose.service=node',
               '--mount', f'type=volume,source={volume},target=/var/lib/remnanode',
               '--mount', f'type=bind,source={nested},target=/var/lib/remnanode/quota', image,
               'sh', '-c', 'printf occupied-spent-credit > /var/lib/remnanode/quota/ledger.json')
        current = json.loads(docker('inspect', container_name).stdout)[0]
        config = {'services': {'node': {'volumes': [
            {'type': 'volume', 'source': 'state', 'target': '/var/lib/remnanode'},
            {'type': 'bind', 'source': str(nested), 'target': '/var/lib/remnanode/quota'}]}},
            'volumes': {'state': {'name': volume, 'external': True}}}
        plan = runtime.plan_node_state(copy.deepcopy(config), current, root)
        assert all(item['source'] != '/var/lib/remnanode' for item in plan['copies'])
        for change in ('volume', 'nested', 'removed'):
            candidate = copy.deepcopy(config)
            if change == 'volume':
                candidate['volumes']['state']['name'] = name + '-wrong'
            elif change == 'nested':
                candidate['services']['node']['volumes'][1]['source'] = str(root / 'wrong')
            else:
                candidate['services']['node']['volumes'].pop()
            try:
                runtime.plan_node_state(candidate, current, root)
            except runtime.ConfigurationError:
                pass
            else:
                raise AssertionError('Occupied state mount drift was accepted: ' + change)
        assert (nested / 'ledger.json').read_text() == 'occupied-spent-credit'
        assert not json.loads(docker('inspect', container_name).stdout)[0]['State']['Running']
        print('PASS real Docker: named state volume and nested quota bind are retained; removal/repointing is rejected')
    finally:
        subprocess.run(['docker', 'rm', '-f', container_name], capture_output=True, timeout=30)
        subprocess.run(['docker', 'volume', 'rm', volume], capture_output=True, timeout=30)


def main():
    name = 'remnacust-state-fixture-' + uuid.uuid4().hex[:12]
    image = name + ':fixture'
    with tempfile.TemporaryDirectory(prefix='remnacust-state-migration-') as directory:
        root = Path(directory).resolve()
        port_state = json.dumps({'version': 2, 'revision': '9', 'enabled': True, 'required': True,
                                 'appliedRevision': '8', 'delivery': {'epoch': '9007199254740993',
                                 'owner': 'f508a5b7-0422-4857-a07e-69aa63b90a09'}, 'pluginDirty': True}, separators=(',', ':'))
        try:
            docker('tag', 'alpine:3.22', image)
            stopped_compose_migration(root, image, name + '-stopped')
            occupied_state_mounts(root, image, name)
            # A disposable container layer reproduces old installs without state
            # mounts. The source stops before the installer copies its state.
            docker('run', '--name', name,
                   '--label', 'com.docker.compose.service=node',
                   '--label', 'com.docker.compose.project.working_dir=' + str(root),
                   '--env', 'SECRET_KEY=isolated-state-fixture', image, 'sh', '-c',
                   "mkdir -p /var/lib/remnacust/run/core-state /var/lib/remnanode/quota /var/lib/remnanode/usage /var/lib/remnanode/core /var/lib/remnawave/core-manager; "
                   "chmod 700 /var/lib/remnanode/core; printf '%s' '" + port_state + "' > /var/lib/remnanode/core/port-plan-state.json; chmod 600 /var/lib/remnanode/core/port-plan-state.json; "
                   "printf 'saved-profile-generation' > /var/lib/remnacust/run/core-state/checkpoint.pb; "
                   "printf 'spent-quota-fixture' > /var/lib/remnanode/quota/ledger.json; "
                   "printf 'pending-receipt-fixture' > /var/lib/remnanode/usage/receipt.json; "
                   "printf '%s' '{\"mode\":\"bundled\",\"paused\":true}' > /var/lib/remnawave/core-manager/state.json")
            before = json.loads(docker('inspect', name).stdout)[0]
            assert not before['State']['Running'] and not before['Mounts']
            compose = {'services': {'node': {'image': image, 'volumes': []}}}
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
            old_config = {'name': 'state-fixture', 'services': {'node': {'image': image}}}
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
            assert restored['image'] == image
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
            subprocess.run(['docker', 'image', 'rm', image], capture_output=True, timeout=30)


if __name__ == '__main__':
    main()
