import importlib.util
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

spec = importlib.util.spec_from_file_location('entry', Path(__file__).parents[1] / 'installer/stable_entry.py')
entry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(entry)


class EntryTests(unittest.TestCase):
    def test_invalid_config_never_reaches_haproxy(self):
        base = {'listenPort': 443, 'strategy': 'priority', 'backends': [{'address': '192.0.2.1', 'port': 443}]}
        for change in [{'listenPort': 22}, {'strategy': 'x\nfrontend injected'},
                       {'backends': []}, {'backends': [{'address': '127.0.0.1', 'port': 443}]},
                       {'backends': [{'address': 'a.test;bad', 'port': 443}]},
                       {'backends': [{'address': '192.0.2.1', 'port': True}]}]:
            with self.assertRaises(ValueError):
                entry.render({**base, **change})
        self.assertIn('backup', entry.render({**base, 'backends': base['backends'] + [{'address': '192.0.2.2', 'port': 443}]}))

    @unittest.skipUnless(os.environ.get('REMNACUST_ISOLATED_NET') == '1', 'isolated root network test')
    def test_real_haproxy_connection_selection_priority_failover_and_graceful_reload(self):
        self.assertNotEqual(os.readlink('/proc/self/ns/net'), os.environ['REMNACUST_PARENT_NET'])
        subprocess.run(['ip', 'link', 'set', 'lo', 'up'], check=True)
        for address in ['10.204.0.1/32', '10.204.0.2/32']:
            subprocess.run(['ip', 'addr', 'add', address, 'dev', 'lo'], check=True)
        listeners = []
        def server(address, label):
            sock = socket.socket(); sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind((address, 43001)); sock.listen(); sock.settimeout(.1)
            stop = threading.Event(); listeners.append((sock, stop))
            def handle(conn):
                with conn:
                    try:
                        while payload := conn.recv(4096):
                            conn.sendall(label + payload)
                    except OSError:
                        pass
            def accept():
                while not stop.is_set():
                    try:
                        conn, _ = sock.accept()
                        threading.Thread(target=handle, args=(conn,), daemon=True).start()
                    except socket.timeout:
                        continue
                    except OSError:
                        break
            threading.Thread(target=accept, daemon=True).start()
            return sock, stop
        first, stop_first = server('10.204.0.1', b'A')
        server('10.204.0.2', b'B')
        def connect():
            return socket.create_connection(('127.0.0.1', 43100), timeout=1)
        def request():
            with connect() as sock:
                sock.sendall(b'x'); return sock.recv(2)
        def wait(expected, seconds=10):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                try:
                    if request() == expected:
                        return
                except OSError:
                    pass
                time.sleep(.1)
            self.fail(f'Expected {expected!r} from live HAProxy')
        config = {'listenPort': 43100, 'strategy': 'roundRobin', 'backends': [
            {'address': '10.204.0.1', 'port': 43001}, {'address': '10.204.0.2', 'port': 43001}]}
        process = None
        try:
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'haproxy.cfg'; path.write_text(entry.render(config))
                subprocess.run(['haproxy', '-c', '-f', str(path)], check=True, capture_output=True)
                process = subprocess.Popen(['haproxy', '-Ws', '-db', '-f', str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                wait(b'Ax')
                self.assertEqual(set(request() for _ in range(8)), {b'Ax', b'Bx'}, 'one static config selects at connection time')
                config['strategy'] = 'priority'; path.write_text(entry.render(config)); process.send_signal(signal.SIGUSR2)
                time.sleep(.6); wait(b'Ax')
                held = connect(); held.sendall(b'q'); self.assertEqual(held.recv(2), b'Aq')
                config['backends'] = [config['backends'][1]]
                path.write_text(entry.render(config)); process.send_signal(signal.SIGUSR2)
                time.sleep(.6); wait(b'Bx')
                held.sendall(b'z'); self.assertEqual(held.recv(2), b'Az', 'reload preserves established backend connection')
                held.close()
                config['backends'].insert(0, {'address': '10.204.0.1', 'port': 43001})
                path.write_text(entry.render(config)); process.send_signal(signal.SIGUSR2)
                time.sleep(.6); wait(b'Ax')
                stop_first.set(); first.close()
                wait(b'Bx', 12)
        finally:
            if process:
                process.terminate()
                try:
                    process.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=4)
            for sock, stop in listeners:
                stop.set(); sock.close()


if __name__ == '__main__':
    if '--network' in sys.argv:
        env = dict(os.environ, REMNACUST_ISOLATED_NET='1', REMNACUST_PARENT_NET=os.readlink('/proc/self/ns/net'))
        raise SystemExit(subprocess.call(['unshare', '-n', sys.executable, __file__], env=env))
    unittest.main()
