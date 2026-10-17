"""Exercise the actual Bash image-policy gate without exposing any ports."""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import uuid


def main():
    installer = Path(__file__).resolve().parents[1] / 'installer.sh'
    project = 'remnacust-policy-probe-' + uuid.uuid4().hex[:12]
    with tempfile.TemporaryDirectory(prefix='remnacust-policy-probe-') as temporary:
        root = Path(temporary)
        policy = root / 'policy'
        policy.mkdir(mode=0o700)
        binary = root / 'core-marker'
        checkpoint_root = root / 'core-state'
        checkpoint_root.mkdir(mode=0o700)
        binary.write_text('legacy-core-fixture')
        compose = root / 'compose.json'
        configuration = {'services': {'node': {
            'image': 'node:24.21-trixie-slim', 'network_mode': 'none',
            'volumes': [str(policy) + ':/var/lib/remnanode:ro', str(binary) + ':/usr/local/bin/xray:ro', str(checkpoint_root) + ':/var/lib/remnacust/run/core-state:ro'],
        }}}
        compose.write_text(json.dumps(configuration))
        # Function positional parameters are separate from the script's argv.
        shell = '''source "$1"
test_compose=$2
test_project=$3
get() { printf '%s' node; }
compose() { docker compose --project-name "$test_project" -f "$test_compose" "$@"; }
verify_node_image_policy
'''
        def probe():
            return subprocess.run(['bash', '-c', shell, 'test', str(installer), str(compose), project],
                                  env={**os.environ, 'REMNACUST_ROOT': str(root / 'installer-root'), 'NO_COLOR': '1'},
                                  capture_output=True, text=True, timeout=90)
        try:
            (policy / 'host-policy.json').write_text('{"version":"xera-host-policy-v2"}')
            result = probe()
            assert result.returncode == 0, result.stderr
            (policy / 'host-policy.json').write_text('{"version":"xera-host-policy-v2","offlineReserves":"remnacust-quota-reserves-v1"}')
            assert probe().returncode != 0, 'Legacy core was allowed to ignore issued reserves'
            binary.write_text('remnacust-quota-reserves-v1')
            assert probe().returncode != 0, 'Reserve support alone cannot preserve outside-grant usage'
            binary.write_text('remnacust-quota-reserves-v1 remnacust-unreserved-usage-v1')
            result = probe()
            assert result.returncode == 0, result.stderr
            (policy / 'host-policy.json').write_text('{"version":"xera-host-policy-v2","offlineReserves":"remnacust-quota-reserves-v1","groups":{"a":{"fenceAll":true}}}')
            assert probe().returncode != 0, 'A quota core without soft fences was allowed to ignore the pending transition'
            binary.write_text('remnacust-quota-reserves-v1 remnacust-quota-fences-v1 remnacust-unreserved-usage-v1')
            assert probe().returncode == 0, 'A core enforcing both quota and soft fences should be accepted'
            (policy / 'usage').mkdir(mode=0o700)
            assert probe().returncode != 0, 'A saved usage stream cannot downgrade to a core without replayable receipts'
            binary.write_text('remnacust-quota-reserves-v1 remnacust-quota-fences-v1 remnacust-usage-receipts-v1 remnacust-unreserved-usage-v1')
            assert probe().returncode == 0, 'A receipt-capable core should preserve the stream'
            (policy / 'host-policy.json').unlink()
            binary.write_text('legacy-core-fixture')
            assert probe().returncode != 0, 'A missing policy cannot hide an existing usage stream'
            binary.write_text('remnacust-quota-reserves-v1 remnacust-quota-fences-v1 remnacust-usage-receipts-v1 remnacust-unreserved-usage-v1')
            assert probe().returncode == 0
            user_quota = 'remnacust-user-quota-reserves-v1'
            quota_directory = policy / 'quota'
            quota_directory.mkdir(mode=0o700)
            (quota_directory / 'user-quota-required').write_text(user_quota + '\n')
            (quota_directory / 'user-quota-required').chmod(0o600)
            assert probe().returncode != 0, 'Lost policy hid a mandatory user quota'
            (policy / 'host-policy.json').write_text(json.dumps({'userQuota': user_quota}))
            assert probe().returncode != 0, 'A legacy core ignored mandatory global quotas'
            binary.write_text('remnacust-usage-receipts-v1 ' + user_quota)
            assert probe().returncode != 0, 'User quota support alone ignores outside-grant debt'
            binary.write_text('remnacust-usage-receipts-v1 remnacust-unreserved-usage-v1 ' + user_quota)
            assert probe().returncode == 0
            (quota_directory / 'user-quota-required').unlink()
            payload = b'compiled-checkpoint-fixture'
            record = b'REMNACUST-CORE-STATE-2-USER-QUOTA\n' + hashlib.sha256(payload).hexdigest().encode() + b'\n' + payload
            (checkpoint_root / 'checkpoint.pb').write_bytes(record)
            (checkpoint_root / 'checkpoint.pb').chmod(0o600)
            assert probe().returncode == 0
            (policy / 'host-policy.json').unlink()
            assert probe().returncode != 0, 'Lost marker and policy hid a mandatory native checkpoint'
            (policy / 'host-policy.json').write_text(json.dumps({'userQuota': user_quota}))
            (checkpoint_root / 'checkpoint.pb').write_bytes(record + b'corrupt')
            assert probe().returncode != 0, 'A damaged checkpoint authorized replacement'
            (checkpoint_root / 'checkpoint.pb').unlink()
            with binary.open('r+b') as oversized:
                oversized.truncate(192 * 1024 * 1024 + 1)
            assert probe().returncode != 0, 'Oversized core must be rejected before reading it into memory'
            (policy / 'host-policy.json').write_text('{broken')
            assert probe().returncode != 0, 'Corrupt persisted policy was treated as a fresh installation'
            (policy / 'host-policy.json').unlink()
            (policy / 'usage').rmdir()
            core = policy / 'core'
            core.mkdir(mode=0o700)
            saved = core / 'port-plan-state.json'
            def save(state):
                saved.write_text(json.dumps(state))
                saved.chmod(0o600)
            state = {'version': 1, 'revision': '8', 'enabled': True, 'required': True, 'appliedRevision': '7'}
            save(state)
            binary.write_text('legacy-core-fixture')
            assert probe().returncode != 0, 'An old core ignored a live port plan'
            binary.write_text('remnacust-live-ports-v1')
            assert probe().returncode == 0, 'Compatible version 1 state must remain supported'
            state.update(version=2, delivery={'epoch': '9007199254740993', 'owner': 'f508a5b7-0422-4857-a07e-69aa63b90a09'},
                         pluginDirty=True, appliedInputsHash='a' * 64, desiredPluginHash='b' * 64)
            save(state)
            assert probe().returncode != 0, 'An old Node image ignored persisted delivery ownership'
            node_source = Path(os.environ.get('REMNACUST_NODE_SOURCE', str(Path(__file__).resolve().parents[3] / 'Remnacust-node')))
            boot = node_source / 'node/docker/rootfs/etc/s6-overlay/scripts/core-boot.cjs'
            assert boot.is_file(), 'Set REMNACUST_NODE_SOURCE to the sibling Node checkout for the delivery-v2 image gate test'
            bundle = root / 'main.js'
            bundle.write_text('remnacust-port-plan-delivery-v2')
            configuration['services']['node']['volumes'].extend([
                str(boot) + ':/etc/s6-overlay/scripts/core-boot.cjs:ro', str(bundle) + ':/opt/app/dist/main.js:ro'])
            compose.write_text(json.dumps(configuration))
            result = probe()
            assert result.returncode == 0, result.stderr
            bundle.write_text('legacy Node bundle')
            assert probe().returncode != 0, 'A new boot script cannot hide an old application bundle'
            bundle.write_text('remnacust-port-plan-delivery-v2')
            save({**state, 'delivery': {**state['delivery'], 'epoch': '9223372036854775808'}})
            assert probe().returncode != 0, 'An invalid delivery counter authorized image replacement'
            save({**state, 'enabled': False, 'required': False, 'appliedRevision': state['revision']})
            binary.write_text('legacy core after confirmed disable')
            assert probe().returncode == 0
            registered = 'remnacust-quota-registrations-v1'
            (policy / 'host-policy.json').write_text(json.dumps({'offlineReserves': 'remnacust-quota-reserves-v1', 'quotaRegistrations': registered}))
            payload = json.dumps({'version': registered, 'instance': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'entries': {}}, separators=(',', ':'))
            ledger = quota_directory / 'ledger.json'
            ledger.write_text('{"payload":' + payload + ',"sha256":"' + hashlib.sha256(payload.encode()).hexdigest() + '"}\n')
            ledger.chmod(0o600)
            assert probe().returncode != 0, 'Registered credit cannot downgrade to a legacy core'
            binary.write_text('remnacust-quota-reserves-v1 remnacust-unreserved-usage-v1 ' + registered)
            assert probe().returncode != 0, 'A compatible core cannot hide an old Node application'
            bundle.write_text('remnacust-port-plan-delivery-v2 ' + registered)
            result = probe()
            assert result.returncode == 0, result.stderr
            (policy / 'host-policy.json').unlink()
            assert probe().returncode != 0, 'Lost policy hid the registered journal requirement'
            (policy / 'host-policy.json').write_text(json.dumps({'offlineReserves': 'remnacust-quota-reserves-v1', 'quotaRegistrations': registered}))
            ledger.write_text('{broken')
            assert probe().returncode != 0, 'Corrupt journal authorized image replacement'
            watermark = 'remnacust-quota-watermarks-v1'
            def save_journal(sequence, checkpoint):
                payload = json.dumps({'version': watermark, 'instance': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'sequence': sequence, 'checkpoint': checkpoint, 'entries': {}}, separators=(',', ':'))
                ledger.write_text('{"payload":' + payload + ',"sha256":"' + hashlib.sha256(payload.encode()).hexdigest() + '"}\n')
            save_journal(10, 8)
            checkpoint_policy = {'offlineReserves': 'remnacust-quota-reserves-v1', 'quotaRegistrations': registered,
                                 'quotaCheckpoint': {'instance': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'sequence': '9'}}
            (policy / 'host-policy.json').write_text(json.dumps(checkpoint_policy))
            assert probe().returncode != 0, 'Watermarked credit cannot use a registration-only core or bundle'
            binary.write_text('remnacust-quota-reserves-v1 remnacust-unreserved-usage-v1 ' + registered + ' ' + watermark)
            assert probe().returncode != 0, 'Watermarked journal requires Node application support'
            bundle.write_text('remnacust-port-plan-delivery-v2 ' + registered + ' ' + watermark)
            result = probe()
            assert result.returncode == 0, result.stderr
            save_journal(7, 0)
            assert probe().returncode != 0, 'Restored journal behind the saved checkpoint authorized replacement'
            save_journal(10, 8)
            checkpoint_policy['quotaCheckpoint']['sequence'] = '7'
            (policy / 'host-policy.json').write_text(json.dumps(checkpoint_policy))
            assert probe().returncode != 0, 'Saved policy moved behind the journal checkpoint'
            del checkpoint_policy['quotaCheckpoint']
            (policy / 'host-policy.json').write_text(json.dumps(checkpoint_policy))
            assert probe().returncode != 0, 'A missing checkpoint authorized downgrade'
            print('PASS actual installer image gate: journal high-water mark survives compatible image updates and rejects restored state')
            ledger.unlink()
            (policy / 'host-policy.json').unlink()
            bundle.write_text('remnacust-port-plan-delivery-v2')
            binary.write_text('legacy core after confirmed disable')
            print('PASS actual installer image gate: registered journal requires compatible boot, Node bundle, core and saved policy')
            recovery = 'remnacust-quota-recovery-fence-v1'
            first = {'version': recovery, 'generation': '11111111-1111-4111-8111-111111111111',
                     'token': '22222222-2222-4222-8222-222222222222', 'state': 'FENCED', 'sequence': '1', 'previous': None,
                     'digest': 'a956d69b330b83f9d303c91064f5f9cbb7728c1df810bbf11a122dcc52e0fc8b'}
            requirement = quota_directory / 'recovery-required.json'
            requirement.write_text(json.dumps(first)); requirement.chmod(0o600)
            assert probe().returncode != 0, 'An immutable pause cannot downgrade to a legacy core'
            binary.write_text(recovery)
            assert probe().returncode != 0, 'A new core cannot hide an old Node application'
            bundle.write_text('remnacust-port-plan-delivery-v2 ' + recovery)
            result = probe(); assert result.returncode == 0, result.stderr
            mutable = quota_directory / 'recovery.json'; mutable.write_text('{}'); mutable.chmod(0o600)
            result = probe(); assert result.returncode == 0, result.stderr
            requirement.write_text('{}'); assert probe().returncode != 0, 'A damaged immutable pause cannot authorize image replacement'
            requirement.unlink(); mutable.unlink()
            binary.write_text('legacy core after confirmed disable'); bundle.write_text('remnacust-port-plan-delivery-v2')
            print('PASS actual installer image gate: recovery pause and restrictive fallback require compatible core, boot and Node application')
            configuration['services']['node']['volumes'] = configuration['services']['node']['volumes'][:-2]
            compose.write_text(json.dumps(configuration))
            assert probe().returncode != 0, 'Disabling ports does not authorize losing delivery fencing'
            print('PASS actual installer image gate: legacy policy works, unsupported quota downgrade and corrupt state remain stopped')
            print('PASS actual installer image gate: port state and delivery ownership verified before replacing a running node')
        finally:
            subprocess.run(['docker', 'compose', '--project-name', project, '-f', str(compose), 'down', '--remove-orphans'],
                           capture_output=True, timeout=30)


if __name__ == '__main__':
    main()
