import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / 'installer.sh'
SHELL = r'''
source "$1"
ROOT="$2"; WORK="$2"; STATE="$2/node.json"; HELPER_ROOT="$2/helpers"
COMPONENT=node; PORT=2222; PANEL_IP="$3"; NODE_SITE_MODE="$4"
get() { [[ $1 == apiPort ]] || return 93; printf '2222\n'; }
nft() { return 94; }
package_step() { return 95; }
node_acl
'''
HELPER = '''import json,os,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
with (root/'calls').open('a') as stream:stream.write(json.dumps(sys.argv[1:])+'\\n')
if os.environ.get('ACL_CLEANUP_FAIL') and sys.argv[1]=='uninstall':raise SystemExit(23)
if sys.argv[1]=='prepare':print(root/'plan.json')
'''


@unittest.skipIf(os.name == 'nt', 'Requires POSIX Bash')
class NodeAclCliTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='rc-node-acl-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'helpers').mkdir()
        (self.root / 'helpers/node_firewall.py').write_text(HELPER)
        (self.root / 'helpers/management.py').write_text(HELPER)

    def run_acl(self, panel='', mode='', state=None, fail=False):
        if state is not None:
            (self.root / 'node.json').write_text(json.dumps(state))
        environment = {**os.environ, 'REMNACUST_ROOT': str(self.root)}
        environment.pop('ACL_CLEANUP_FAIL', None)
        if fail:
            environment['ACL_CLEANUP_FAIL'] = '1'
        return subprocess.run(['bash', '-c', SHELL, 'test', str(INSTALLER), str(self.root), panel, mode],
                              capture_output=True, text=True, env=environment, timeout=10)

    def calls(self):
        path = self.root / 'calls'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_empty_panel_fresh_does_not_add_any_rule(self):
        result = self.run_acl()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [['uninstall', '--owner-root', str(self.root)]])
        self.assertIn('правила доступа не добавляются', result.stdout)

    def test_empty_panel_standalone_does_not_add_site_allow(self):
        result = self.run_acl(mode='standalone', state={'apiPort': 2222, 'nodeSiteMode': 'standalone', 'nodeSitePort': 4433})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [
            ['uninstall', '--owner-root', str(self.root)],
            ['uninstall', '--owner-root', str(self.root), '--api-port', '2222', '--https-port', '4433']])
        self.assertFalse(any(call[0] in ('site', 'apply') for call in self.calls()))

    def test_empty_panel_cleans_by_owner_before_considering_current_api(self):
        result = self.run_acl(state={'apiPort': 2222})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls()[0], ['uninstall', '--owner-root', str(self.root)])
        self.assertIn('--api-port', self.calls()[1])

    def test_cleanup_failure_stops_without_success_or_new_rule(self):
        result = self.run_acl(fail=True)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(len(self.calls()), 1)
        self.assertNotIn('правила доступа не добавляются', result.stdout)

    def test_explicit_panel_applies_only_tracked_api_and_inbound_ports(self):
        result = self.run_acl('192.0.2.10', 'standalone', {'apiPort': 2222, 'nodeSiteMode': 'standalone',
                                                       'nodeSitePort': 4433, 'nodeInboundPort': 8444})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [
            ['site', '--https-port', '4433'],
            ['apply', '--panel', '192.0.2.10', '--https-port', '4433', '--owner-root', str(self.root),
             '--api-port', '2222', '--inbound-port', '8444']])

    def test_kept_tls_migration_detaches_old_firewall_renewal_hooks(self):
        (self.root / 'node.json').write_text(json.dumps({'apiPort': 2222}))
        command = SHELL.removesuffix('node_acl\n') + r'''
ACTION=migrate-remnawave-node
get() { case "$1" in project) printf fixture-node;; apiPort) printf 2222;; *) return 96;; esac; }
node_migration_finish
'''
        result = subprocess.run(['bash', '-c', command, 'test', str(INSTALLER), str(self.root), '', ''],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(['detach-renewal', '--owner-root', str(self.root), '--project', 'fixture-node'], self.calls())
        self.assertFalse(any(call[0] in ('site', 'apply', 'owned-panel') for call in self.calls()))

    def test_tls_migration_prepares_standalone_site_without_firewall_or_adopting_other_guard(self):
        command = SHELL.removesuffix('node_acl\n') + r'''
ACTION=change-domain; NODE_MIGRATION_TLS=true; NODE_DOMAIN=node.example.test
NODE_SITE_MODE=standalone; TLS_METHOD=existing; CERT_FILE=/fixture/cert; KEY_FILE=/fixture/key
domain_plan_value() {
    case "$1" in method) printf existing;; project) printf fixture-node;; directory) printf '%s/node' "$ROOT";;
    tlsComponent) printf node;; certificateDomain) printf node.example.test;; tlsState) printf '{}';;
    certificateSubscriptions) :;; *) return 96;; esac
}
schedule_certificate_renewal() { :; }
manage_component_action
'''
        result = subprocess.run(['bash', '-c', command, 'test', str(INSTALLER), str(self.root), '', 'standalone'],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        prepare = next(call for call in self.calls() if call[0] == 'prepare')
        self.assertIn('--no-firewall', prepare)
        self.assertFalse(any(call[0] in ('site', 'owned-panel', 'acme-open') for call in self.calls()))


if __name__ == '__main__':
    unittest.main()
