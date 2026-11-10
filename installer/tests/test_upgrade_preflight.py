import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / 'installer.sh'
SHELL = r'''
source "$1"
ROOT="$2"; WORK="$2"; DIRECTORY="$2"; STATE="$2/state.json"; HELPER="$(dirname "$1")/runtime.py"; LOG=/dev/null
ACTION="upgrade-$3"; COMPONENT="$3"; YES=true
choose_version() { VERSION="${TARGET_RELEASE:-latest}"; }
prepare_host() { :; }; lock_operation() { :; }; prepare_image() { :; }
release_source() { COMPONENT_VERSION="$TARGET_VERSION"; TAG="$TARGET_RELEASE"; IMAGE=fixture; SOURCE="$WORK/source"; }
find_existing() { :; }
node_migration_wizard() { printf 'REACHED-MUTATION-BOUNDARY'; return 91; }
recover() { exit 1; }
deploy
'''


@unittest.skipIf(os.name == 'nt', 'Requires POSIX Bash')
class UpgradePreflightTests(unittest.TestCase):
    def run_upgrade(self, component, current, target, release='v1.2.149'):
        with tempfile.TemporaryDirectory(prefix='rc-upgrade-preflight-') as directory:
            root = Path(directory)
            state = {'component': component, 'project': 'fixture', 'directory': directory,
                     'mainService': 'app', 'applications': ['app'], 'version': current}
            config = {'services': {'app': {'image': 'ghcr.io/lottman/remnacust-' + component + ':' + current}},
                      'x-remnacust-release': {'component': component, 'version': current, 'installer': 'v1.2.148'}}
            for name, value in [('state.json', state), ('compose.before.json', config), ('project-containers.json', [])]:
                (root / name).write_text(json.dumps(value))
            (root / '.env').write_text('UNCHANGED=fixture-only\n')
            before = {path.name: path.read_bytes() for path in root.iterdir()}
            environment = {**os.environ, 'REMNACUST_ROOT': directory,
                           'TARGET_VERSION': target, 'TARGET_RELEASE': release}
            result = subprocess.run(['bash', '-c', SHELL, 'test', str(INSTALLER), directory, component],
                                    capture_output=True, text=True, env=environment, timeout=15)
            self.assertEqual({path.name: path.read_bytes() for path in root.iterdir()}, before)
            return result

    def test_lower_component_stops_before_migration_backup_and_mutation_even_with_yes(self):
        for component, current, target in [('node', '1.1.26', '1.1.25'), ('panel', '1.1.7.100', '1.1.7.99')]:
            with self.subTest(component=component):
                result = self.run_upgrade(component, current, target)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Понижение', result.stderr)
                self.assertNotIn('REACHED-MUTATION-BOUNDARY', result.stdout)

    def test_lower_installer_release_stops_even_with_same_component(self):
        result = self.run_upgrade('node', '1.1.26', '1.1.26', 'v1.2.147')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Понижение', result.stderr)
        self.assertNotIn('REACHED-MUTATION-BOUNDARY', result.stdout)

    def test_equal_or_newer_versions_pass_preflight(self):
        for target in ('1.1.7.100', '1.1.7.101'):
            with self.subTest(target=target):
                result = self.run_upgrade('panel', '1.1.7.100', target)
                self.assertIn('REACHED-MUTATION-BOUNDARY', result.stdout, result.stderr)
                self.assertNotIn('Понижение', result.stderr)


if __name__ == '__main__':
    unittest.main()
