"""Exercise the installer gate with a real Node CLI and no Docker daemon."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / 'installer.sh'
PRIVATE = 'CONTINUITY-PRIVATE-SENTINEL'
HARNESS = r'''
source "$CONTINUITY_INSTALLER"
WORK=$CONTINUITY_FIXTURE
LOG=$WORK/installer.log
ACTION=${TEST_ACTION:-upgrade-panel}; COMPONENT=${TEST_COMPONENT:-panel}
ALLOW_DISRUPTION=${TEST_ALLOW_DISRUPTION:-false}; YES=true
CONTAINER=explicit-current-container
timeout() {
    printf 'timeout %s %s\n' "$1" "$2" >> "$WORK/trace"
    [[ $1 == --kill-after=5s && ( $2 == 10s || $2 == 130s ) ]] || exit 98
    shift 2
    "$@"
}
docker() {
    if [[ $1 == compose ]]; then printf '{}'; return; fi
    [[ $# == 5 && $1 == exec && $2 == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa && $3 == node && $4 == -e ]] || exit 97
    local script=$5 phase=detect
    [[ $script != *spawnSync* ]] || phase=check
    printf '%s\n' "$phase" >> "$WORK/trace"
    if [[ ${TEST_DOCKER_FAILURE:-} == "$phase" ]]; then
        printf '%s\n' "$CONTINUITY_PRIVATE"; printf '%s\n' "$CONTINUITY_PRIVATE" >&2
        return 124
    fi
    script=${script//\/opt\/app\/dist\/cli.js/$WORK/cli.js}
    # Exercise actual child termination without making a regression wait two minutes.
    if [[ ${TEST_FAST_TIMEOUT:-false} == true ]]; then
        script=${script/timeout: 120000/timeout: 100}
    fi
    node -e "$script"
}
if [[ ${TEST_DEPLOY:-false} == true ]]; then
    choose_version() { :; }; confirm() { :; }; prepare_host() { :; }; lock_operation() { :; }
    release_source() { TAG=v1.2.110; }; prepare_image() { :; }; find_existing() { :; }
    database_environment() { :; }; check_writers() { :; }; database_run() { :; }
    report_update_progress() { :; }; backup_current() { :; }; configure_panel_updates() { :; }
    step() { shift; "$@"; }
    helper() { [[ $1 != commit-compose ]] || printf 'commit\n' >> "$WORK/trace"; }
    load_state() { APPS=(api worker scheduler); }
    compose() {
        if [[ $1 == stop ]]; then printf 'stop %s\n' "${*:2}" >> "$WORK/trace"; exit 0; fi
        printf '{}'
    }
    recover() { printf 'recovery\n' >> "$WORK/trace"; exit 96; }
    deploy
else
    panel_continuity_preflight
fi
'''


@unittest.skipUnless(shutil.which('bash') and shutil.which('node'), 'Bash and Node required')
class PanelContinuityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='remnacust-continuity-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.cli = self.root / 'cli.js'
        (self.root / 'container.before.json').write_text(json.dumps([{'Id': 'a' * 64}]))
        (self.root / 'compose.after.json').write_text('{}')

    def run_gate(self, body, marker=True, **options):
        self.cli.write_text(('// check-node-continuity\n' if marker else '') + body)
        trace = self.root / 'trace'
        trace.unlink(missing_ok=True)
        result = subprocess.run(
            ['bash', '-c', HARNESS], capture_output=True, text=True, timeout=15,
            env={**os.environ, 'REMNACUST_ROOT': str(self.root / 'root'),
                 'CONTINUITY_INSTALLER': str(INSTALLER), 'CONTINUITY_FIXTURE': str(self.root),
                 'CONTINUITY_PRIVATE': PRIVATE, **options},
        )
        self.assertNotIn(PRIVATE, result.stdout + result.stderr)
        return result, trace.read_text().splitlines() if trace.exists() else []

    def test_ready_counts_and_private_cli_stderr(self):
        for count in [0, 3]:
            with self.subTest(count=count):
                result, trace = self.run_gate(
                    'console.error(process.env.CONTINUITY_PRIVATE);'
                    f'console.log(JSON.stringify({{ready:true,nodeCount:{count},private:process.env.CONTINUITY_PRIVATE}}));'
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f': {count}.', result.stdout)
                self.assertEqual(trace, ['timeout --kill-after=5s 10s', 'detect',
                                         'timeout --kill-after=5s 130s', 'check'])

    def test_cli_receives_exact_noninteractive_command_and_closed_stdin(self):
        result, _ = self.run_gate(
            'const fs=require("node:fs");'
            'if(process.argv.length!==3 || process.argv[2]!=="check-node-continuity" ||'
            'fs.readFileSync(0).length!==0) process.exit(9);'
            'console.log(JSON.stringify({ready:true,nodeCount:1}));'
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_failure_invalid_json_and_invalid_counts_fail_closed_without_leaks(self):
        cases = [
            'console.log(JSON.stringify({ready:true,nodeCount:1}));process.exit(1);',
            'console.log(JSON.stringify({ready:false,nodeCount:1}));',
            'console.log(process.env.CONTINUITY_PRIVATE);',
            'console.log("log line");console.log(JSON.stringify({ready:true,nodeCount:1}));',
            'console.log("x".repeat(20000)+process.env.CONTINUITY_PRIVATE);',
            *['console.log(JSON.stringify({ready:true,nodeCount:' + value + '}));'
              for value in ['-1', '0.5', 'true', '"1"', 'null', '9007199254740992']],
            'console.log(JSON.stringify({ready:true}));',
            'console.log("null");',
        ]
        for body in cases:
            with self.subTest(body=body):
                result, _ = self.run_gate(body)
                self.assertEqual(result.returncode, 1)
                self.assertIn('--allow-disruption', result.stderr)

    def test_legacy_marker_is_checked_without_executing_an_interactive_cli(self):
        result, trace = self.run_gate(
            'require("node:fs").writeFileSync(__dirname+"/interactive", "bad");', marker=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(trace, ['timeout --kill-after=5s 10s', 'detect'])
        self.assertFalse((self.root / 'interactive').exists())
        self.assertIn('--allow-disruption', result.stderr)

    def test_actual_child_timeout_and_docker_failures_are_generic(self):
        result, _ = self.run_gate('setInterval(()=>{},1000);', TEST_FAST_TIMEOUT='true')
        self.assertEqual(result.returncode, 1)
        for phase in ['detect', 'check']:
            with self.subTest(phase=phase):
                result, _ = self.run_gate('console.log("{}");', TEST_DOCKER_FAILURE=phase)
                self.assertEqual(result.returncode, 1)
                self.assertIn('--allow-disruption', result.stderr)

    def test_missing_or_invalid_current_container_never_executes_cli(self):
        for data in ['', '[]', json.dumps([{'Id': PRIVATE}])]:
            with self.subTest(data=data):
                (self.root / 'container.before.json').write_text(data)
                result, trace = self.run_gate('console.log("{}");')
                self.assertEqual(result.returncode, 1)
                self.assertEqual(trace, [])

    def test_only_explicit_override_bypasses_and_other_actions_are_untouched(self):
        result, trace = self.run_gate('', TEST_ALLOW_DISRUPTION='true')
        self.assertEqual(result.returncode, 0)
        self.assertIn('--allow-disruption', result.stdout)
        self.assertEqual(trace, [])
        for action, component in [('upgrade-node', 'node'), ('install-panel', 'panel'),
                                  ('migrate-remnawave-panel', 'panel')]:
            result, trace = self.run_gate('', TEST_ACTION=action, TEST_COMPONENT=component)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(trace, [])

    def test_deploy_refuses_before_compose_commit_or_any_application_stop(self):
        result, trace = self.run_gate('console.log("{}");', TEST_DEPLOY='true')
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('commit', trace)
        self.assertFalse(any(row.startswith('stop ') for row in trace))
        self.assertNotIn('recovery', trace)

    def test_deploy_success_checks_before_commit_and_all_application_stops(self):
        result, trace = self.run_gate('console.log(JSON.stringify({ready:true,nodeCount:2}));',
                                      TEST_DEPLOY='true')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace[-3:], ['check', 'commit', 'stop api worker scheduler'])

    def test_override_is_scoped_to_panel_upgrade_and_yes_does_not_enable_it(self):
        for action in ['install-panel', 'upgrade-node', 'stop', 'migrate-remnawave-panel']:
            result = subprocess.run(
                ['bash', str(INSTALLER), action, '--allow-disruption', '--yes'],
                env={**os.environ, 'REMNACUST_ROOT': str(self.root / 'root')},
                capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn('--allow-disruption', result.stderr)
        result, _ = self.run_gate('console.log("{}");')
        self.assertEqual(result.returncode, 1)  # HARNESS already sets YES=true.


if __name__ == '__main__':
    unittest.main()
