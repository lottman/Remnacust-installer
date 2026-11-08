"""Real packet tests run only in an isolated network namespace."""
import importlib.util
import os
from pathlib import Path
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
