"""Real packet tests run only in an isolated network namespace."""
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import threading
import time
import unittest
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('guard', Path(__file__).parents[1] / 'installer/node_firewall.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class NarrowActions(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.root = self.base / 'guard'
        self.owner = self.base / 'owned installation'
        self.project = 'node-fixture_1'
        self.acme = self.owner / 'acme' / self.project
        self.script = self.acme / 'renew.sh'
        self.certbot = str(self.owner / 'tools/certbot/bin/certbot')
        self.enterContext(patch.object(guard, 'ROOT', self.root))
        self.host = self.enterContext(patch.object(guard, 'run', side_effect=AssertionError('Host commands forbidden')))
        self.process = self.enterContext(patch.object(guard.subprocess, 'run', side_effect=AssertionError('Process execution forbidden')))
        self.spawn = self.enterContext(patch.object(guard.subprocess, 'Popen', side_effect=AssertionError('Process execution forbidden')))
        self.output = self.enterContext(patch('sys.stdout', new_callable=io.StringIO))

    def tearDown(self):
        self.host.assert_not_called()
        self.process.assert_not_called()
        self.spawn.assert_not_called()

    def state(self, **values):
        self.root.mkdir(mode=0o700, exist_ok=True)
        state = {'ownerRoot': str(self.owner.resolve()), 'panel': '192.0.2.10'}
        state.update(values)
        (self.root / 'state.json').write_text(json.dumps(state))
        return state

    def renewal(self, extra=None):
        self.acme.mkdir(mode=0o700, parents=True, exist_ok=True)
        tokens = ['/usr/bin/python3', '-I', str(self.acme / 'ufw_guard.py'), '--root', str(self.owner), '--', self.certbot, 'renew']
        tokens += extra if extra is not None else [
            '--quiet', '--config-dir', str(self.acme / 'certificate config'),
            '--work-dir', str(self.acme / 'work'), '--logs-dir', str(self.acme / 'logs'),
            '--deploy-hook', str(self.acme / 'deploy-hook.sh'),
            '--pre-hook', str(self.acme / 'acme-open.sh'),
            '--post-hook', str(self.acme / 'acme-close.sh')]
        self.script.write_text('#!/usr/bin/env bash\nset -eu\nexec ' + shlex.join(tokens) + '\n')
        self.script.chmod(0o700)
        return tokens

    def test_owned_panel_exact_owner_only_normalized_and_read_only(self):
        for panel, expected in [('192.0.2.10', '192.0.2.10/32'), ('192.0.2.10/24', '192.0.2.0/24'), ('2001:db8::1', '2001:db8::1/128')]:
            self.state(panel=panel)
            before = (self.root / 'state.json').read_bytes()
            with patch.object(sys, 'argv', ['guard.py', 'owned-panel', '--owner-root', str(self.owner)]):
                guard.main()
            self.assertEqual(self.output.getvalue(), expected + '\n')
            self.assertEqual((self.root / 'state.json').read_bytes(), before)
            self.assertEqual(list(self.root.iterdir()), [self.root / 'state.json'])
            self.assertFalse(self.owner.exists())
            self.output.seek(0)
            self.output.truncate()
        self.state(ownerRoot='/different', panel='invalid.example')
        self.assertEqual(guard.owned_panel(str(self.owner)), '')
        state = self.state()
        del state['ownerRoot']
        (self.root / 'state.json').write_text(json.dumps(state))
        self.assertEqual(guard.owned_panel(str(self.base / 'unowned')), '')
        self.assertEqual(self.output.getvalue(), '')

    def test_narrow_cli_missing_files_creates_nothing_and_prints_nothing(self):
        for action, options in [('owned-panel', []), ('detach-renewal', ['--project', self.project])]:
            with patch.object(sys, 'argv', ['guard.py', action, '--owner-root', str(self.owner), *options]):
                guard.main()
            self.assertEqual(list(self.base.iterdir()), [])
            self.assertEqual(self.output.getvalue(), '')

    def test_owned_panel_rejects_unsafe_state_and_invalid_owned_panel(self):
        self.state(panel='0.0.0.0/0')
        with self.assertRaises(ValueError):
            guard.owned_panel(str(self.owner))
        state = self.root / 'state.json'
        state.chmod(0o666)
        with self.assertRaises(ValueError):
            guard.owned_panel(str(self.owner))
        state.unlink()
        target = self.base / 'target'
        target.write_text('{}')
        state.symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            guard.owned_panel(str(self.owner))
        self.assertEqual(self.output.getvalue(), '')
        self.assertFalse((self.root / 'lock').exists())

    def test_kept_tls_renewal_detaches_wrapper_and_exact_hooks_preserving_args(self):
        tokens = self.renewal()
        data = self.acme / 'certificate config' / 'live' / 'leaf.pem'
        data.parent.mkdir(mode=0o700, parents=True)
        data.write_text('private certificate fixture')
        directories = {p: p.stat().st_mode for p in self.owner.rglob('*') if p.is_dir()}
        original_inode = self.script.stat().st_ino
        with patch.object(sys, 'argv', ['guard.py', 'detach-renewal', '--owner-root', str(self.owner), '--project', self.project]):
            guard.main()
        result = self.script.read_text()
        self.assertEqual(result.splitlines()[:2], ['#!/usr/bin/env bash', 'set -eu'])
        self.assertEqual(shlex.split(result.splitlines()[2][5:]), tokens[6:-4])
        self.assertEqual(data.read_text(), 'private certificate fixture')
        self.assertEqual({p: p.stat().st_mode for p in directories}, directories)
        self.assertNotEqual(self.script.stat().st_ino, original_inode)
        self.assertEqual(self.script.stat().st_mode & 0o777, 0o700)
        self.assertEqual(sorted(p.name for p in self.acme.iterdir()), ['certificate config', 'renew.sh'])
        self.assertFalse(self.root.exists())
        inode = self.script.stat().st_ino
        self.output.seek(0)
        self.output.truncate()
        guard.detach_renewal(str(self.owner), self.project)
        self.assertEqual(self.script.read_text(), result)
        self.assertEqual(self.script.stat().st_ino, inode)
        self.assertEqual(self.output.getvalue(), '')

    def test_detach_removes_only_exact_hook_pairs(self):
        extra = ['--pre-hook', '/custom/pre.sh', '--post-hook', str(self.acme / 'acme-close.sh'),
                 '--pre-hook=' + str(self.acme / 'acme-open.sh'), '--cert-name', 'edge.example.test',
                 '--pre-hook', str(self.acme / 'acme-open.sh'), '--post-hook', '/custom/post.sh']
        self.renewal(extra)
        guard.detach_renewal(str(self.owner), self.project)
        actual = shlex.split(self.script.read_text().splitlines()[2][5:])
        self.assertEqual(actual, [self.certbot, 'renew', *extra[:2], *extra[4:7], *extra[9:]])

    def test_direct_certbot_renewal_is_unchanged(self):
        self.renewal()
        text = '#!/usr/bin/env bash\nset -eu\nexec ' + shlex.join([self.certbot, 'renew', '--quiet', '--pre-hook', str(self.acme / 'acme-open.sh')]) + '\n'
        self.script.write_text(text)
        inode = self.script.stat().st_ino
        guard.detach_renewal(str(self.owner), self.project)
        self.assertEqual(self.script.read_text(), text)
        self.assertEqual(self.script.stat().st_ino, inode)
        self.assertEqual(self.output.getvalue(), '')

    def test_custom_scripts_preserved_without_execution_or_content_leaks(self):
        tokens = self.renewal()
        original = self.script.read_text()
        marker = self.base / 'executed'
        secret = 'SECRET_DO_NOT_PRINT'
        prefix = '#!/usr/bin/env bash\nset -eu\nexec '
        custom = [original + f'touch {marker}\n', original.rstrip() + f'; touch {marker}\n',
                  original.rstrip() + f' && touch {marker}\n', original.rstrip() + ' | sh\n',
                  original.rstrip() + f' > {marker}\n', original.rstrip() + f' $(touch {marker})\n',
                  original.rstrip() + f' >> {marker}\n', original.rstrip() + f' &> {marker}\n',
                  original.rstrip() + f' << {secret}\n',
                  original.rstrip() + f' `touch {marker}`\n', original.rstrip() + " 'unterminated\n",
                  prefix + shlex.join([*tokens[:4], '/different-root', *tokens[5:], secret]) + '\n',
                  prefix + 'echo ' + secret + '\n', prefix + shlex.join(tokens) + ' # ' + secret + '\n']
        for text in custom:
            with self.subTest(text=text):
                self.output.seek(0)
                self.output.truncate()
                self.script.write_text(text)
                inode = self.script.stat().st_ino
                guard.detach_renewal(str(self.owner), self.project)
                self.assertEqual(self.script.read_text(), text)
                self.assertEqual(self.script.stat().st_ino, inode)
                self.assertEqual(self.output.getvalue(), 'Renewal script preserved: unmanaged content\n')
                self.assertNotIn(secret, self.output.getvalue())
                self.assertFalse(marker.exists())

    def test_renewal_symlink_and_ancestor_symlink_are_rejected(self):
        self.renewal()
        text = self.script.read_text()
        target = self.base / 'target'
        target.write_text(text)
        self.script.unlink()
        self.script.symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            guard.detach_renewal(str(self.owner), self.project)
        self.assertEqual(target.read_text(), text)
        self.script.unlink()
        self.script.write_text(text)
        alias = self.base / 'alias'
        alias.symlink_to(self.owner, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            guard.detach_renewal(str(alias), self.project)
        old = self.acme.with_name('old-project')
        self.acme.rename(old)
        self.acme.symlink_to(old, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            guard.detach_renewal(str(self.owner), self.project)
        self.assertEqual((old / 'renew.sh').read_text(), text)

    def test_renewal_unsafe_metadata_rejected_before_writing(self):
        self.renewal()
        original = self.script.read_bytes()
        for path in (self.owner, self.owner / 'acme', self.acme, self.script):
            mode = path.stat().st_mode & 0o777
            path.chmod(0o777)
            with self.assertRaises(ValueError):
                guard.detach_renewal(str(self.owner), self.project)
            self.assertEqual(self.script.read_bytes(), original)
            path.chmod(mode)
        for path in (self.owner, self.script):
            os.chown(path, 65534, 65534)
            with self.assertRaises(ValueError):
                guard.detach_renewal(str(self.owner), self.project)
            os.chown(path, 0, 0)
        link = self.acme / 'hardlink'
        os.link(self.script, link)
        with self.assertRaises(ValueError):
            guard.detach_renewal(str(self.owner), self.project)
        link.unlink()
        self.script.write_bytes(b'x' * 16385)
        with self.assertRaises(ValueError):
            guard.detach_renewal(str(self.owner), self.project)
        self.script.unlink()
        os.mkfifo(self.script)
        with self.assertRaises(ValueError):
            guard.detach_renewal(str(self.owner), self.project)

    def test_renewal_project_validation_creates_nothing(self):
        for project in ('', '../node', '/absolute', 'Upper', '-option', 'node;true', 'a' * 64, None):
            with self.assertRaises(ValueError):
                guard.detach_renewal(str(self.owner), project)
            self.assertEqual(list(self.base.iterdir()), [])


class OwnerCleanup(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.root = self.base / 'guard'
        self.unit = self.base / 'guard.service'
        self.dropins = self.base / 'guard.service.d'
        self.site = self.base / 'site'
        self.control = self.base / 'control'
        self.owner = self.base / 'installation'
        self.default_owner = self.base / 'default-installation'
        self.assertEqual(guard.DEFAULT_OWNER_ROOT, '/opt/remnacust')
        self.enterContext(patch.object(guard, 'DEFAULT_OWNER_ROOT', str(self.default_owner)))
        self.calls = []
        self.table = False
        self.unrelated = {'SSH 22', 'SSH 2222', 'Docker', 'admin TCP 9443'}
        self.baseline = self.unrelated.copy()
        for name, value in [('ROOT', self.root), ('UNIT', self.unit), ('SITE_PROFILE', self.site), ('CONTROL_PROFILE', self.control)]:
            self.enterContext(patch.object(guard, name, value))
        self.enterContext(patch.object(guard, 'run', side_effect=self.command))
        self.enterContext(patch.object(guard.shutil, 'which', return_value='/usr/sbin/ufw'))
        self.output = self.enterContext(patch('sys.stdout', new_callable=io.StringIO))

    def command(self, *args, **kwargs):
        self.calls.append((args, kwargs))
        code, output = 0, ''
        if args[:3] == ('nft', 'list', 'table'):
            code = 0 if self.table else 1
            output = 'table inet remnacust_node_guard {}' if self.table else ''
        elif args == ('nft', '-f', '-'):
            data = kwargs.get('data', '')
            if data.startswith('delete table inet remnacust_node_guard\n'):
                self.table = False
            if 'table inet remnacust_node_guard {' in data:
                self.table = True
        return subprocess.CompletedProcess(args, code, output, '')

    def installed(self, **changes):
        self.root.mkdir(mode=0o700, exist_ok=True)
        state = {'ownerRoot': str(self.owner), 'controlPorts': [2222, 8443], 'panel': '192.0.2.1/32', 'sshPorts': [22], 'httpsPort': 443}
        state.update(changes)
        (self.root / 'state.json').write_text(json.dumps(state))
        (self.root / 'guard.py').write_text(Path(guard.__file__).read_text())
        (self.root / 'lock').touch(mode=0o600)
        self.unit.write_text(guard.UNIT_TEXT)
        self.table = True
        return state

    def profiles(self):
        guard.control_access('192.0.2.1', [2222, 8443], self.control)
        guard.site_access(443, self.site)
        self.calls.clear()

    def cleanup(self, **kwargs):
        guard.uninstall(kwargs.get('owner', str(self.owner)), kwargs.get('api', 2222), kwargs.get('https', 443))

    def snapshot(self):
        return {str(p.relative_to(self.base)): (p.lstat().st_mode, p.read_bytes()) for p in self.base.rglob('*') if p.is_file() and not p.is_symlink()}

    def assert_only_lock_remains(self):
        self.assertEqual(list(self.root.iterdir()), [self.root / 'lock'])

    def test_install_uninstall_reinstall_uninstall_is_idempotent(self):
        original_control = guard.control_access
        with patch.object(guard, 'discover', return_value=([22, 72], ['docker0'])), patch.object(guard, 'control_access', side_effect=lambda panel, ports: original_control(panel, ports, self.control)):
            for _ in range(2):
                guard.apply('192.0.2.1', 443, [2222, 8443], str(self.owner))
                guard.site_access(443, self.site)
                self.assertTrue(self.table)
                self.cleanup()
                self.assertFalse(self.table)
                self.assert_only_lock_remains()
                self.assertFalse(self.unit.exists())
                self.assertFalse(self.site.exists())
                self.assertFalse(self.control.exists())
                self.assertEqual(self.unrelated, self.baseline)
                self.calls.clear()
                self.cleanup()
                self.assertEqual(self.calls, [])
        self.assertIn('Owned guard removed', self.output.getvalue())

    def test_owner_or_api_mismatch_has_no_mutations(self):
        self.installed()
        self.profiles()
        before = self.snapshot()
        for kwargs in ({'owner': '/different-install'}, {'api': 7289}, {'api': 0}):
            self.cleanup(**kwargs)
            self.assertEqual(self.calls, [])
            self.assertEqual(self.snapshot(), before)
            self.assertTrue(self.table)
        self.assertIn('ownerRoot mismatch', self.output.getvalue())
        self.assertIn('API port', self.output.getvalue())

    def test_omitted_api_removes_exact_owner_stale_guard_without_unit(self):
        self.installed(controlPorts=[7289])
        self.unit.unlink()
        guard.control_access('192.0.2.1', [7289], self.control)
        guard.site_access(443, self.site)
        self.calls.clear()
        self.cleanup(api=2222)
        self.assertEqual(self.calls, [])
        self.assertTrue(self.table)
        with patch.object(sys, 'argv', ['guard.py', 'uninstall', '--owner-root', str(self.owner)]):
            guard.main()
        self.assertFalse(self.table)
        self.assert_only_lock_remains()
        self.assertFalse(self.control.exists())
        self.assertFalse(self.site.exists())
        self.assertEqual(self.unrelated, self.baseline)
        self.assertIn('exact ownerRoot match; API port omitted', self.output.getvalue())
        self.assertIn(('/usr/sbin/ufw', '--force', 'delete', 'allow', 'from', '192.0.2.1/32', 'to', 'any', 'app', 'Remnacust Node Control'), [args for args, _ in self.calls])
        self.calls.clear()
        guard.uninstall(str(self.owner))
        self.assertEqual(self.calls, [])
        self.assert_only_lock_remains()

    def test_omitted_api_requires_exact_owner_and_valid_tracked_ports(self):
        state = self.installed()
        before = self.snapshot()
        self.cleanup(owner='/different-install', api=None)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.calls, [])
        for ports in ([True], [0], '7289'):
            (self.root / 'state.json').write_text(json.dumps(dict(state, controlPorts=ports)))
            with self.assertRaises(ValueError):
                self.cleanup(api=None)
            self.assertEqual(self.calls, [])
            self.assertTrue(self.table)

    def test_omitted_api_accepts_exact_owner_without_controlports(self):
        state = self.installed()
        del state['controlPorts']
        (self.root / 'state.json').write_text(json.dumps(state))
        guard.uninstall(str(self.owner))
        self.assert_only_lock_remains()
        self.assertFalse(self.table)

    def test_omitted_api_preserves_ownerless_legacy_with_or_without_controlports(self):
        for tracked_ports in (True, False):
            state = self.installed()
            del state['ownerRoot']
            if not tracked_ports:
                del state['controlPorts']
            (self.root / 'state.json').write_text(json.dumps(state))
            before = self.snapshot()
            guard.uninstall(str(self.default_owner))
            self.assertEqual(self.snapshot(), before)
            self.assertEqual(self.calls, [])
            self.assertTrue(self.table)
        self.assertIn('requires an explicit API port', self.output.getvalue())

    def test_omitted_api_without_state_preserves_standalone_site(self):
        guard.site_access(443, self.site)
        self.calls.clear()
        before = self.snapshot()
        guard.uninstall(str(self.owner), https_port=443)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.calls, [])
        self.assertFalse(self.root.exists())
        self.assertFalse(self.owner.exists())

    def test_absent_state_never_creates_root_or_lock_or_runs_commands(self):
        self.cleanup()
        self.assertFalse(self.root.exists())
        self.assertFalse(self.owner.exists())
        self.assertEqual(self.calls, [])
        self.root.mkdir(mode=0o700)
        (self.root / 'admin').write_text('keep')
        before = self.snapshot()
        self.cleanup()
        self.assertEqual(self.calls, [])
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.root / 'lock').exists())

    def test_state_absent_does_not_touch_orphaned_guard_or_control_profile(self):
        self.installed()
        self.profiles()
        (self.root / 'state.json').unlink()
        self.site.unlink()
        before = self.snapshot()
        self.cleanup()
        self.assertEqual(self.calls, [])
        self.assertEqual(self.snapshot(), before)
        self.assertTrue(self.table)

    def test_standalone_site_requires_exact_profile_and_nonzero_expected_port(self):
        guard.site_access(443, self.site)
        self.calls.clear()
        for port in (0, 9443):
            self.cleanup(https=port)
            self.assertTrue(self.site.exists())
            self.assertEqual(self.calls, [])
        self.cleanup()
        self.assertFalse(self.site.exists())
        self.assertEqual([args for args, _ in self.calls], [('/usr/sbin/ufw', '--force', 'delete', 'allow', 'Remnacust Node HTTPS')])
        self.assertFalse(self.root.exists())
        self.calls.clear()
        self.cleanup()
        self.assertEqual(self.calls, [])

    def test_unknown_standalone_site_is_preserved(self):
        self.site.write_text('admin site\nports=443/tcp\n')
        before = self.snapshot()
        self.cleanup()
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.calls, [])

    def test_legacy_ownerless_default_root_and_api_match_are_required(self):
        state = self.installed()
        del state['ownerRoot']
        (self.root / 'state.json').write_text(json.dumps(state))
        self.cleanup()
        self.assertEqual(self.calls, [])
        self.cleanup(owner=str(self.default_owner), api=7289)
        self.assertEqual(self.calls, [])
        self.cleanup(owner=str(self.default_owner))
        self.assertFalse((self.root / 'state.json').exists())
        self.assertIn('default owner and tracked API match', self.output.getvalue())

    def test_pre_controlports_legacy_only_accepts_default_root_and_reports(self):
        state = self.installed()
        del state['ownerRoot']
        del state['controlPorts']
        (self.root / 'state.json').write_text(json.dumps(state))
        self.cleanup()
        self.assertEqual(self.calls, [])
        self.cleanup(owner=str(self.default_owner), api=0)
        self.assert_only_lock_remains()
        self.assertIn('old state has no controlPorts', self.output.getvalue())

    def test_owner_scoped_state_without_ports_fails_closed(self):
        state = self.installed()
        del state['controlPorts']
        (self.root / 'state.json').write_text(json.dumps(state))
        self.cleanup()
        self.assertEqual(self.calls, [])
        self.assertTrue(self.table)

    def test_zero_api_can_only_remove_explicitly_empty_control_ports(self):
        self.installed(controlPorts=[])
        self.cleanup(api=0, https=0)
        self.assert_only_lock_remains()
        self.assertFalse(self.table)

    def test_managed_profiles_use_tracked_ports_and_source_and_keep_admin_rules(self):
        self.installed()
        self.profiles()
        self.cleanup(https=0)
        self.assertEqual(self.unrelated, self.baseline)
        commands = [args for args, _ in self.calls]
        self.assertIn(('systemctl', 'disable', '--now', 'remnacust-node-firewall.service'), commands)
        self.assertIn(('/usr/sbin/ufw', '--force', 'delete', 'allow', 'from', '192.0.2.1/32', 'to', 'any', 'app', 'Remnacust Node Control'), commands)
        self.assertIn(('/usr/sbin/ufw', '--force', 'delete', 'allow', 'Remnacust Node HTTPS'), commands)
        for args, kwargs in self.calls:
            self.assertNotIn('reset', args)
            self.assertNotIn('flush', args)
            self.assertNotIn('flush ruleset', kwargs.get('data', ''))
            if args[:2] == ('nft', '-f'):
                self.assertEqual(kwargs['data'], 'delete table inet remnacust_node_guard\n')

    def test_unmanaged_profiles_unit_helper_and_dropins_are_preserved(self):
        self.installed()
        self.site.write_text('admin site')
        self.control.write_text('admin control')
        self.unit.write_text('admin unit')
        (self.root / 'guard.py').write_text('admin helper')
        (self.root / 'custom.nft').write_text('admin rules')
        self.dropins.mkdir()
        dropin = self.dropins / 'admin.conf'
        dropin.write_text('[Service]\nEnvironment=ADMIN=1\n')
        paths = [self.site, self.control, self.unit, self.root / 'guard.py', self.root / 'custom.nft', dropin]
        before = {p: p.read_bytes() for p in paths}
        self.cleanup()
        self.assertEqual({p: p.read_bytes() for p in paths}, before)
        self.assertFalse((self.root / 'state.json').exists())
        self.assertFalse(self.table)
        self.assertFalse(any(args[0] == '/usr/sbin/ufw' for args, _ in self.calls))

    def relay(self, ip='192.0.2.42'):
        self.dropins.mkdir(exist_ok=True)
        dropin = self.dropins / f'relay-{ip}.conf'
        relay = self.root / f'relay-{ip}.nft'
        dropin.write_text(f'[Service]\nExecStartPost=/usr/sbin/nft -f /etc/remnacust-node-firewall/relay-{ip}.nft\n')
        relay.write_text(f'insert rule inet {guard.TABLE} input ip saddr {ip} tcp dport 443 accept comment "rc-cascade-{ip}-443"\n')
        return dropin, relay

    def test_exact_relay_pair_removed_but_modified_and_unknown_files_preserved(self):
        self.installed()
        exact = self.relay()
        unknown = self.relay('192.0.2.43')
        unknown[1].write_text(unknown[1].read_text() + 'flush ruleset\n')
        foreign = self.dropins / 'override.conf'
        foreign.write_text('[Service]\nEnvironment=ADMIN=1\n')
        before = {p: p.read_bytes() for p in [*unknown, foreign]}
        self.cleanup()
        for p in exact:
            self.assertFalse(p.exists())
        self.assertEqual({p: p.read_bytes() for p in before}, before)
        self.calls.clear()
        self.cleanup()
        self.assertEqual(self.calls, [])

    def relay_variant(self):
        self.dropins.mkdir(exist_ok=True)
        dropin = self.dropins / 'relay-203-0-113-97.conf'
        relay = self.root / 'relay-203-0-113-97.nft'
        dropin.write_text('[Service]\nExecStartPost=/usr/sbin/nft -f /etc/remnacust-node-firewall/relay-203-0-113-97.nft\n')
        relay.write_text('insert rule inet remnacust_node_guard input ip saddr 203.0.113.97 tcp dport 443 ct state != invalid counter accept comment "rc-cascade-203-0-113-97-443"\n')
        return dropin, relay

    def test_exact_hyphenated_relay_variant_removed_and_unmarked_ufw_preserved(self):
        self.installed()
        pair = self.relay_variant()
        self.unrelated.add('allow from 203.0.113.97 to any port 443 proto tcp')
        before = self.unrelated.copy()
        self.cleanup()
        self.assertFalse(self.table)
        for path in pair:
            self.assertFalse(path.exists())
        self.assertFalse(self.dropins.exists())
        self.assert_only_lock_remains()
        self.assertEqual(self.unrelated, before)
        self.assertFalse(any(args[0] == '/usr/sbin/ufw' for args, _ in self.calls))
        self.assertIn('Unmarked UFW relay allow for 203.0.113.97:443 preserved: ownership cannot be verified', self.output.getvalue())

    def test_hyphenated_relay_variant_requires_exact_rule_and_dropin(self):
        self.installed()
        pair = self.relay_variant()
        original = {p: p.read_text() for p in pair}
        for path, change in ((pair[0], lambda value: value + 'Environment=ADMIN=1\n'),
                             (pair[1], lambda value: value + 'flush ruleset\n'),
                             (pair[1], lambda value: value.replace('counter accept', 'accept')),
                             (pair[1], lambda value: value.replace('input ip', 'forward ip')),
                             (pair[1], lambda value: value.replace('203.0.113.97', '203.0.113.98')),
                             (pair[1], lambda value: value.replace('rc-cascade-', 'admin-'))):
            with self.subTest(path=path, content=change(original[path])):
                self.installed()
                for member, content in original.items():
                    member.write_text(content)
                path.write_text(change(original[path]))
                before = {p: p.read_bytes() for p in pair}
                self.cleanup()
                self.assertEqual({p: p.read_bytes() for p in pair}, before)
                self.assertIn('Relay files preserved: unmanaged content', self.output.getvalue())

    def test_cleanup_retains_lock_inode_for_existing_and_new_apply_waiters(self):
        import fcntl
        self.installed()
        lock = self.root / 'lock'
        inode = (lock.stat().st_dev, lock.stat().st_ino)
        waiting = os.open(lock, os.O_RDWR | os.O_NOFOLLOW)
        self.addCleanup(os.close, waiting)
        checked = []
        real = self.command
        def command(*args, **kwargs):
            if args[:3] == ('nft', 'list', 'table'):
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(waiting, fcntl.LOCK_EX | fcntl.LOCK_NB)
                newcomer = os.open(lock, os.O_RDWR | os.O_NOFOLLOW)
                try:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(newcomer, fcntl.LOCK_EX | fcntl.LOCK_NB)
                finally:
                    os.close(newcomer)
                checked.append(True)
            return real(*args, **kwargs)
        with patch.object(guard, 'run', side_effect=command):
            self.cleanup()
        self.assertEqual(checked, [True])
        self.assertEqual((lock.stat().st_dev, lock.stat().st_ino), inode)
        self.assert_only_lock_remains()
        fcntl.flock(waiting, fcntl.LOCK_EX | fcntl.LOCK_NB)
        newcomer = os.open(lock, os.O_RDWR | os.O_NOFOLLOW)
        try:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(newcomer, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(newcomer)
            fcntl.flock(waiting, fcntl.LOCK_UN)
        self.calls.clear()
        self.cleanup()
        self.assertEqual(self.calls, [])
        self.assertEqual((lock.stat().st_dev, lock.stat().st_ino), inode)

    def test_owned_state_without_lock_creates_and_retains_shared_lock(self):
        self.installed()
        lock = self.root / 'lock'
        lock.unlink()
        self.cleanup()
        self.assert_only_lock_remains()
        self.assertEqual(lock.stat().st_mode & 0o777, 0o600)
        self.assertFalse(self.table)

    def test_symlinks_are_rejected_before_commands_or_file_changes(self):
        self.installed()
        self.profiles()
        self.dropins.mkdir()
        target = self.base / 'target'
        target.write_text('unchanged')
        for path in [self.root / 'state.json', self.root / 'guard.py', self.root / 'lock', self.unit, self.site, self.control, self.dropins / 'admin.conf']:
            with self.subTest(path=path):
                old = path.read_bytes() if path.exists() else None
                path.unlink(missing_ok=True)
                path.symlink_to(target)
                before = self.snapshot()
                with self.assertRaisesRegex(ValueError, 'symlink'):
                    self.cleanup()
                self.assertEqual(self.calls, [])
                self.assertEqual(self.snapshot(), before)
                self.assertTrue(self.table)
                path.unlink()
                if old is not None:
                    path.write_bytes(old)

    def test_root_and_ancestor_symlinks_are_rejected(self):
        other = self.base / 'other'
        other.mkdir()
        self.root.symlink_to(other, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            self.cleanup()
        self.root.unlink()
        self.installed()
        alias = self.base / 'alias'
        alias.symlink_to(self.base, target_is_directory=True)
        with patch.object(guard, 'UNIT', alias / self.unit.name):
            with self.assertRaisesRegex(ValueError, 'symlink'):
                self.cleanup()
        with self.assertRaisesRegex(ValueError, 'symlink'):
            self.cleanup(owner=str(alias / 'installation'))
        self.assertEqual(self.calls, [])

    def test_writable_guard_root_and_dropin_directory_are_rejected(self):
        self.installed()
        self.dropins.mkdir()
        before = self.snapshot()
        for directory in (self.root, self.dropins):
            original_mode = directory.stat().st_mode & 0o7777
            for mode in (0o777, 0o1777):
                directory.chmod(mode)
                with self.assertRaises(ValueError):
                    self.cleanup()
                self.assertEqual(self.calls, [])
                self.assertEqual(self.snapshot(), before)
            directory.chmod(original_mode)

    def test_mismatched_managed_profiles_are_preserved(self):
        self.installed()
        guard.control_access('192.0.2.2', [2222, 8443], self.control)
        guard.site_access(9443, self.site)
        self.calls.clear()
        before = {p: p.read_bytes() for p in (self.site, self.control)}
        self.cleanup()
        self.assertEqual({p: p.read_bytes() for p in before}, before)
        self.assertFalse(any(args[0] == '/usr/sbin/ufw' for args, _ in self.calls))
        self.assertIn('profile preserved', self.output.getvalue())

    def test_unsafe_size_permissions_owner_hardlink_and_fifo_fail_before_mutations(self):
        self.installed()
        helper = self.root / 'guard.py'
        original = helper.read_bytes()
        for mode in ('large', 'writable', 'hardlink', 'fifo', 'owner'):
            with self.subTest(mode=mode):
                helper.unlink()
                helper.write_bytes(original)
                link = self.base / 'link'
                if mode == 'large':
                    helper.write_bytes(b'x' * (guard.MAX_FILE_BYTES + 1))
                elif mode == 'writable':
                    helper.chmod(0o666)
                elif mode == 'hardlink':
                    os.link(helper, link)
                elif mode == 'fifo':
                    helper.unlink()
                    os.mkfifo(helper)
                else:
                    os.chown(helper, 65534, 65534)
                with self.assertRaises(ValueError):
                    self.cleanup()
                self.assertEqual(self.calls, [])
                self.assertTrue(self.table)
                link.unlink(missing_ok=True)

    def test_invalid_state_ports_and_json_fail_before_mutations(self):
        state = self.installed()
        for ports in ([True], [0], [65536], [2222, 2222], '2222', [1, 2, 3]):
            (self.root / 'state.json').write_text(json.dumps(dict(state, controlPorts=ports)))
            with self.assertRaises(ValueError):
                self.cleanup()
            self.assertEqual(self.calls, [])
        for value in ('[]', '{}{}', '{"ownerRoot":"x","ownerRoot":"y"}'):
            (self.root / 'state.json').write_text(value)
            with self.assertRaises(ValueError):
                self.cleanup()
            self.assertEqual(self.calls, [])

    def test_disable_failure_preserves_retry_state_and_firewall(self):
        self.installed()
        before = self.snapshot()
        with patch.object(guard, 'run', side_effect=subprocess.CalledProcessError(1, ['systemctl'])):
            with self.assertRaises(subprocess.CalledProcessError):
                self.cleanup()
        self.assertEqual(self.snapshot(), before)
        self.assertTrue(self.table)

    def test_cleanup_after_partial_failure_retries_safely(self):
        self.installed()
        self.profiles()
        real = self.command
        def fail(*args, **kwargs):
            if args[0] == '/usr/sbin/ufw':
                raise RuntimeError('ufw failed')
            return real(*args, **kwargs)
        with patch.object(guard, 'run', side_effect=fail):
            with self.assertRaisesRegex(RuntimeError, 'ufw failed'):
                self.cleanup()
        self.assertFalse(self.table)
        self.assertTrue((self.root / 'state.json').exists())
        self.cleanup()
        self.assert_only_lock_remains()
        self.assertFalse(self.site.exists())
        self.assertFalse(self.control.exists())

    def test_cli_uninstall_and_legacy_manual_remove(self):
        for arguments in (['uninstall', '--owner-root', str(self.owner), '--api-port', '2222', '--https-port', '443'], ['remove']):
            self.installed()
            with patch.object(sys, 'argv', ['guard.py', *arguments]):
                guard.main()
            self.assert_only_lock_remains()
        self.calls.clear()
        with patch.object(sys, 'argv', ['guard.py', 'remove']):
            guard.main()
        self.assert_only_lock_remains()
        self.assertEqual(self.calls, [])


class PolicyValidation(unittest.TestCase):
    def test_public_site_only_opens_selected_tcp_port_in_input_chain(self):
        policy = guard.render('192.0.2.1', [72], [], 4433)
        incoming, forwarding = policy.split('chain forward', 1)
        self.assertIn('tcp dport 4433 accept', incoming)
        self.assertNotIn('dport 4433', forwarding)
        self.assertNotIn('tcp dport 4433 accept', guard.render('192.0.2.1', [72], []))
        for port in (-1, 65536, True, '443'):
            with self.assertRaises(ValueError): guard.render('192.0.2.1', [72], [], port)

    def test_ufw_site_profile_is_scoped_and_does_not_enable_firewall(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory) / 'website'
            calls = []
            with patch.object(guard.shutil, 'which', return_value='/usr/sbin/ufw'), patch.object(guard, 'run', side_effect=lambda *args, **kwargs: calls.append(args)):
                guard.site_access(4433, profile)
                self.assertIn('ports=4433/tcp\n', profile.read_text())
                guard.site_access(9443, profile)
                self.assertIn('ports=9443/tcp\n', profile.read_text())
                guard.site_access(0, profile)
                self.assertFalse(profile.exists())
            self.assertTrue(all('enable' not in args and 'disable' not in args and '22' not in args for args in calls))
            self.assertIn(('/usr/sbin/ufw', 'app', 'update', 'Remnacust Node HTTPS'), calls)

    def test_ufw_site_profile_rejects_unmanaged_content_and_restores_failed_change(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory) / 'website'
            with patch.object(guard.shutil, 'which', return_value='/usr/sbin/ufw'), patch.object(guard, 'run') as run:
                profile.write_text('owner content')
                with self.assertRaises(ValueError): guard.site_access(4433, profile)
                run.assert_not_called()
                profile.unlink()
                guard.site_access(4433, profile)
                original = profile.read_bytes()
                profile.chmod(0o666)
                with self.assertRaises(ValueError): guard.site_access(9443, profile)
                profile.chmod(0o600)
                run.side_effect = [None, RuntimeError('fixture'), None]
                with self.assertRaises(RuntimeError): guard.site_access(9443, profile)
                self.assertEqual(profile.read_bytes(), original)

    def test_acme_window_is_fixed_to_port_80_and_expires(self):
        calls = []
        def fake_run(*args, **kwargs):
            calls.append((args, kwargs))
            return subprocess.CompletedProcess(args, 0, '', '')
        with patch.object(guard, 'run', side_effect=fake_run):
            guard.acme_window(True)
            guard.acme_window(False)
        add = [args for args, _ in calls if args[:3] == ('nft', 'add', 'element')]
        self.assertEqual(len(add), 1)
        self.assertIn('80', add[0])
        self.assertIn('15m', add[0])
        self.assertNotIn('443', add[0])
        self.assertEqual(len([args for args, _ in calls if args[:3] == ('nft', 'delete', 'element')]), 2)

    def test_ufw_control_ports_are_source_scoped_and_undoable(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory) / 'control'
            calls = []
            with patch.object(guard.shutil, 'which', return_value='/usr/sbin/ufw'), patch.object(guard, 'run', side_effect=lambda *args, **kwargs: calls.append(args)):
                undo = guard.control_access('192.0.2.1', [8443, 2222], profile)
                self.assertIn('ports=2222,8443/tcp\n', profile.read_text())
                self.assertIn(('/usr/sbin/ufw', 'allow', 'from', '192.0.2.1/32', 'to', 'any', 'app', 'Remnacust Node Control'), calls)
                old = profile.read_bytes()
                restore = guard.control_access('2001:db8::1', [7289], profile)
                self.assertIn(('/usr/sbin/ufw', '--force', 'delete', 'allow', 'from', '192.0.2.1/32', 'to', 'any', 'app', 'Remnacust Node Control'), calls)
                restore()
                self.assertEqual(profile.read_bytes(), old)
                undo()
                self.assertFalse(profile.exists())
            self.assertTrue(all('enable' not in args and 'disable' not in args and '22' not in args for args in calls))

    def test_ufw_control_removal_requires_exact_owned_source_and_ports(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory) / 'control'
            with patch.object(guard.shutil, 'which', return_value='/usr/sbin/ufw'), patch.object(guard, 'run') as run:
                guard.control_access('192.0.2.1', [2222, 8443], profile)
                original = profile.read_bytes()
                run.reset_mock()
                for panel, ports in [('192.0.2.2', [2222, 8443]), ('192.0.2.1', [7289])]:
                    with self.assertRaises(ValueError): guard.control_access(panel, ports, profile, remove=True)
                    self.assertEqual(profile.read_bytes(), original)
                    run.assert_not_called()
                restore = guard.control_access('192.0.2.1', [2222, 8443], profile, remove=True)
                self.assertFalse(profile.exists())
                restore()
                self.assertEqual(profile.read_bytes(), original)

    def test_ufw_control_rejects_unsafe_profiles_and_restores_failed_change(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory) / 'control'
            with patch.object(guard.shutil, 'which', return_value='/usr/sbin/ufw'), patch.object(guard, 'run') as run:
                for ports in ([], [0], [65536], [True], [2222, 8443, 9443]):
                    with self.assertRaises(ValueError): guard.control_access('192.0.2.1', ports, profile)
                run.assert_not_called()
                profile.write_text('owner content')
                with self.assertRaises(ValueError): guard.control_access('192.0.2.1', [2222], profile)
                run.assert_not_called()
                profile.unlink()
                guard.control_access('192.0.2.1', [2222], profile)
                old = profile.read_bytes()
                run.side_effect = [None, None, RuntimeError('fixture'), None, None, None]
                with self.assertRaises(RuntimeError): guard.control_access('192.0.2.2', [7289], profile)
                self.assertEqual(profile.read_bytes(), old)

    def test_failed_control_rollback_still_restores_nft_and_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'guard'
            root.mkdir(mode=0o700)
            unit = Path(directory) / 'guard.service'
            for name, value in [('guard.py', 'old helper'), ('state.json', '{}')]: (root / name).write_text(value)
            unit.write_text('old unit')
            before = {path: path.read_bytes() for path in [root / 'guard.py', root / 'state.json', unit]}
            restored = []
            def table(value):
                restored.append(value)
                if len(restored) == 1: raise RuntimeError('apply failure')
            def undo(): raise RuntimeError('control rollback failure')
            with patch.object(guard, 'ROOT', root), patch.object(guard, 'UNIT', unit), patch.object(guard, 'discover', return_value=([72], [])), patch.object(guard, 'control_access', return_value=undo), patch.object(guard, 'replace_table', side_effect=table), patch.object(guard, 'run', return_value=subprocess.CompletedProcess([], 0, 'old nft rules', '')):
                with self.assertRaisesRegex(RuntimeError, 'control rollback failure'):
                    guard.apply('192.0.2.1', 443, [2222], directory)
            self.assertEqual(restored[-1], 'old nft rules')
            for path, content in before.items(): self.assertEqual(path.read_bytes(), content)

    def test_control_uninstall_ignores_another_installation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'guard'
            root.mkdir(mode=0o700)
            (root / 'state.json').write_text('{"panel":"192.0.2.1","controlPorts":[2222],"ownerRoot":"/other-installation"}')
            with patch.object(guard, 'ROOT', root), patch.object(sys, 'argv', ['guard.py', 'remove-control', '--api-port', '2222', '--owner-root', directory]), patch.object(guard, 'control_access') as control, patch.object(guard, 'run') as run:
                guard.main()
                control.assert_not_called()
                run.assert_not_called()

    def test_acme_window_fails_closed_if_firewall_cannot_be_inspected(self):
        with patch.object(guard, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'denied')):
            with self.assertRaisesRegex(RuntimeError, 'inspect nftables'):
                guard.acme_window(True)

    def test_invalid_sources_and_interface_injection(self):
        for value in ['0.0.0.0/0', '::/0', '0.0.0.0', '224.0.0.1', 'example.com', '1.2.3.4;drop']:
            with self.assertRaises(ValueError):
                guard.render(value, [22], [])
        for bridges in [['a" accept'], ['a' * 16]]:
            with self.assertRaises(ValueError):
                guard.render('192.0.2.1', [22], bridges)
        self.assertIn('ip6 saddr 2001:db8::1/128 accept', guard.render('2001:db8::1', [2222], []))
        self.assertIn('22, 2222', guard.render('192.0.2.1', [2222], []))
        policy = guard.render('192.0.2.1', [2222], [])
        self.assertIn('set acme_http { type inet_service; flags timeout; }', policy)
        self.assertIn('tcp dport @acme_http accept', policy)

    @unittest.skipUnless(os.environ.get('REMNACUST_ISOLATED_NET') == '1', 'isolated root network test')
    def test_real_input_forwarding_and_outbound_replies(self):
        self.assertNotEqual(os.readlink('/proc/self/ns/net'), os.environ['REMNACUST_PARENT_NET'])
        processes = []
        servers = []
        def call(*args):
            return subprocess.run(args, text=True, capture_output=True, check=True, timeout=10)
        def ns(pid, *args):
            return call('nsenter', '-t', str(pid), '-n', *args)
        def client(number, interface):
            proc = subprocess.Popen(['unshare', '-n', 'sleep', '120'])
            processes.append(proc)
            time.sleep(.05)
            call('ip', 'link', 'add', interface, 'type', 'veth', 'peer', 'name', 'peer' + str(number))
            call('ip', 'link', 'set', 'peer' + str(number), 'netns', str(proc.pid))
            call('ip', 'addr', 'add', f'10.203.{number}.1/24', 'dev', interface)
            call('ip', 'link', 'set', interface, 'up')
            ns(proc.pid, 'ip', 'link', 'set', 'lo', 'up')
            ns(proc.pid, 'ip', 'addr', 'add', f'10.203.{number}.2/24', 'dev', 'peer' + str(number))
            ns(proc.pid, 'ip', 'link', 'set', 'peer' + str(number), 'up')
            ns(proc.pid, 'ip', 'route', 'add', 'default', 'via', f'10.203.{number}.1')
            return proc.pid
        def listening(port, ipv6=False):
            server = socket.socket(socket.AF_INET6 if ipv6 else socket.AF_INET)
            if ipv6:
                server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind(('::' if ipv6 else '0.0.0.0', port)); server.listen()
            servers.append(server)
            def serve():
                while True:
                    try:
                        conn, _ = server.accept()
                        conn.sendall(b'ok'); conn.close()
                    except OSError:
                        return
            threading.Thread(target=serve, daemon=True).start()
        probe = 'import socket,sys;s=socket.create_connection((sys.argv[1],int(sys.argv[2])),timeout=.7);assert s.recv(2)==b"ok"'
        backend_server = 'import socket;s=socket.socket();s.bind(("0.0.0.0",9090));s.listen();\nwhile True:\n c,a=s.accept();c.sendall(b"ok");c.close()'
        try:
            call('ip', 'link', 'set', 'lo', 'up')
            panel = client(0, 'panel0'); other = client(1, 'other0'); backend = client(2, 'docker0')
            for port in [22, 80, 2222, 443]:
                listening(port)
            call('nft', 'add', 'table', 'inet', 'unrelated_sentinel')
            guard.replace_table(guard.render('10.203.0.2', [22, 2222], ['docker0']))
            for port in [22, 2222, 443]:
                ns(panel, sys.executable, '-c', probe, '10.203.0.1', str(port))
            for port in [22, 2222]:
                ns(other, sys.executable, '-c', probe, '10.203.1.1', str(port))
            with self.assertRaises(subprocess.CalledProcessError):
                ns(other, sys.executable, '-c', probe, '10.203.1.1', '443')
            with self.assertRaises(subprocess.CalledProcessError):
                ns(other, sys.executable, '-c', probe, '10.203.1.1', '80')
            guard.acme_window(True)
            ns(other, sys.executable, '-c', probe, '10.203.1.1', '80')
            with self.assertRaises(subprocess.CalledProcessError):
                ns(other, sys.executable, '-c', probe, '10.203.1.1', '443')
            guard.acme_window(False)
            with self.assertRaises(subprocess.CalledProcessError):
                ns(other, sys.executable, '-c', probe, '10.203.1.1', '80')
            ns(panel, 'ping', '-c', '1', '-W', '1', '10.203.0.1')
            with self.assertRaises(subprocess.CalledProcessError):
                ns(other, 'ping', '-c', '1', '-W', '1', '10.203.1.1')
            for pid in [other, backend]:
                processes.append(subprocess.Popen(['nsenter', '-t', str(pid), '-n', sys.executable, '-c', backend_server]))
            time.sleep(.15)
            call(sys.executable, '-c', probe, '10.203.1.2', '9090')
            call('sysctl', '-w', 'net.ipv4.ip_forward=1')
            subprocess.run(['nft', '-f', '-'], input='table ip test_dnat {\n chain pre {\n type nat hook prerouting priority -100;\n tcp dport 8080 dnat to 10.203.2.2:9090\n }\n}\n', text=True, check=True, timeout=10)
            ns(panel, sys.executable, '-c', probe, '10.203.0.1', '8080')
            with self.assertRaises(subprocess.CalledProcessError):
                ns(other, sys.executable, '-c', probe, '10.203.1.1', '8080')
            ns(backend, sys.executable, '-c', probe, '10.203.1.2', '9090')
            guard.replace_table(guard.render('10.203.0.2', [22, 2222], ['docker0']))
            self.assertIn('unrelated_sentinel', call('nft', 'list', 'tables').stdout)
            guard.replace_table(guard.render('10.203.0.2', [22, 2222], ['docker0'], 443))
            ns(other, sys.executable, '-c', probe, '10.203.1.1', '443')
            with self.assertRaises(subprocess.CalledProcessError):
                ns(other, sys.executable, '-c', probe, '10.203.1.1', '80')
            guard.replace_table('')
            ns(other, sys.executable, '-c', probe, '10.203.1.1', '443')
            self.assertIn('unrelated_sentinel', call('nft', 'list', 'tables').stdout)
            for number, pid, interface in [(0, panel, 'panel0'), (1, other, 'other0')]:
                call('ip', '-6', 'addr', 'add', f'fd00:203:{number}::1/64', 'dev', interface, 'nodad')
                ns(pid, 'ip', '-6', 'addr', 'add', f'fd00:203:{number}::2/64', 'dev', 'peer' + str(number), 'nodad')
            listening(22, True); listening(443, True)
            guard.replace_table(guard.render('fd00:203:0::2', [22, 2222], ['docker0']))
            ns(panel, sys.executable, '-c', probe, 'fd00:203:0::1', '443')
            ns(other, sys.executable, '-c', probe, 'fd00:203:1::1', '22')
            with self.assertRaises(subprocess.CalledProcessError):
                ns(other, sys.executable, '-c', probe, 'fd00:203:1::1', '443')
            ns(panel, 'ping', '-6', '-c', '1', '-W', '1', 'fd00:203:0::1')
            with self.assertRaises(subprocess.CalledProcessError):
                ns(other, 'ping', '-6', '-c', '1', '-W', '1', 'fd00:203:1::1')
        finally:
            for proc in reversed(processes):
                proc.terminate()
            for proc in processes:
                proc.wait(timeout=5)
            for server in servers:
                server.close()


if __name__ == '__main__':
    if '--network' in sys.argv:
        env = dict(os.environ, REMNACUST_ISOLATED_NET='1', REMNACUST_PARENT_NET=os.readlink('/proc/self/ns/net'))
        raise SystemExit(subprocess.call(['unshare', '-n', sys.executable, __file__], env=env))
    unittest.main()
