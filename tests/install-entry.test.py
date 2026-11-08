import importlib.util
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('install_entry', ROOT / 'scripts/build-install-entry.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


@unittest.skipIf(os.name == 'nt', 'Requires Linux Bash')
class InstallEntryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rc-install-entry-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        tools = self.root / 'bin'
        tools.mkdir()
        for name, body in [('sudo', '#!/bin/sh\nexec "$@"\n'), ('curl', '#!/bin/sh\nexit 97\n')]:
            path = tools / name
            path.write_text(body)
            path.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(tools) + os.pathsep + os.environ['PATH'], 'REMNACUST_ROOT': str(self.root / 'state'), 'ENTRY_FIXTURE': str(self.root)}

    def run_entry(self, args, payload=None):
        entry = ROOT / 'Install.sh'
        if payload is not None:
            entry = self.root / 'Install.sh'
            entry.write_bytes(builder.render_entry(payload))
        return subprocess.run(['bash', '-c', 'bash <(cat "$1") "${@:2}"', 'fixture', str(entry), *args], env=self.env, capture_output=True, text=True, timeout=20)

    def test_generated_entry_matches_verified_source(self):
        self.assertEqual((ROOT / 'Install.sh').read_bytes(), builder.build(ROOT))

    def test_real_bundled_help_runs_through_process_substitution_without_network(self):
        result = self.run_entry(('@', '--help'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('migrate-remnawave-node', result.stdout)
        self.assertNotIn('Нужен', result.stderr)

    def test_menu_alias_is_forwarded_as_no_arguments(self):
        result = self.run_entry(('@', 'install'), b'printf "ARGUMENTS=%s" "$#"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'ARGUMENTS=0')

    def test_component_action_and_operator_arguments_are_preserved(self):
        result = self.run_entry(('@', 'migrate-remnawave-node', '--container', 'node-fixture'), b'printf "<%s>" "$@"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '<migrate-remnawave-node><--container><node-fixture>')

    def test_error_status_propagates_and_temporary_script_is_removed(self):
        result = self.run_entry(('@', '--help'), b'printf "%s" "$BASH_SOURCE" > "$ENTRY_FIXTURE/path"\nexit 31\n')
        self.assertEqual(result.returncode, 31)
        self.assertFalse(Path((self.root / 'path').read_text()).parent.exists())

    def test_real_menu_accepts_operator_input_through_process_substitution(self):
        master, slave = pty.openpty()
        process = subprocess.Popen(['bash', '-c', 'bash <(cat "$1") @ install', 'fixture', str(ROOT / 'Install.sh')], stdin=slave, stdout=slave, stderr=slave, env=self.env)
        os.close(slave)
        output = b''
        answered = False
        try:
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and process.poll() is None:
                if select.select([master], [], [], .05)[0]:
                    try: output += os.read(master, 65536)
                    except OSError: break
                    if not answered and 'Действие: '.encode() in output:
                        os.write(master, b'0\n')
                        answered = True
            self.assertTrue(answered, output.decode(errors='replace'))
            self.assertEqual(process.wait(timeout=5), 0, output.decode(errors='replace'))
        finally:
            if process.poll() is None: process.kill(); process.wait()
            os.close(master)

    def test_delimiter_collision_is_rejected(self):
        with self.assertRaises(ValueError):
            builder.render_entry(('\n' + builder.MARKER + '\n').encode())


if __name__ == '__main__':
    unittest.main()
