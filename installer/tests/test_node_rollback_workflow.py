import os
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipIf(os.name == 'nt', 'Installer rollback runs on Linux')
class NodeRollbackWorkflowTests(unittest.TestCase):
    def run_recovery(self, failure):
        with tempfile.TemporaryDirectory(prefix='remnacust-rollback-') as directory:
            root = Path(directory)
            script = Path(__file__).resolve().parents[1] / 'installer.sh'
            command = '''source "$1"
set +e
COMPONENT=node;CHANGED=true;BACKUP=$2;LOG=$2/log
APPS=(node);START_APPS=(node)
events=$2/events
failure=$3
info(){ printf 'info %s\n' "$*" >> "$events"; }
helper(){ printf 'restore\n' >> "$events";return 0; }
load_state(){ return 0; }
compose(){
 printf '%s\n' "$1" >> "$events"
 [[ $failure != "$1" ]]
}
verify_node_image_policy(){ printf 'probe\n' >> "$events";[[ $failure != probe ]]; }
wait_ready(){ printf 'ready\n' >> "$events";[[ $failure != ready ]]; }
helper_file_copy(){ printf 'registry\n' >> "$events";[[ $failure != registry ]]; }
(exit 7)
recover
'''
            result = subprocess.run(['bash', '-c', command, 'test', str(script), str(root), failure],
                                    env={**os.environ, 'REMNACUST_ROOT': str(root), 'NO_COLOR': '1'},
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 7, result.stderr)
            return (root / 'events').read_text().splitlines()

    def test_old_image_is_verified_before_start_and_ready_before_reporting_success(self):
        events = self.run_recovery('none')
        self.assertEqual(events[:6], ['stop', 'restore', 'probe', 'up', 'ready', 'registry'])
        self.assertTrue(events[6].startswith('info '))

    def test_stop_failure_does_not_start_another_instance(self):
        events = self.run_recovery('stop')
        self.assertNotIn('restore', events)
        self.assertNotIn('up', events)

    def test_unsupported_old_core_never_restarts_with_issued_reserves(self):
        events = self.run_recovery('probe')
        self.assertEqual(events[:3], ['stop', 'restore', 'probe'])
        self.assertNotIn('up', events)

    def test_start_and_readiness_failures_are_not_reported_as_success(self):
        for failure in ['up', 'ready', 'registry']:
            events = self.run_recovery(failure)
            self.assertFalse(any('Возвращена предыдущая конфигурация' in event for event in events))


if __name__ == '__main__':
    unittest.main()
