import os
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / 'installer.sh'


class SelectedAppsWorkflowTests(unittest.TestCase):
    def shell(self, command, *args):
        return subprocess.run([os.environ.get('REMNACUST_TEST_BASH', 'bash'), '-c',
                               'source "$1"; ' + command, 'test', INSTALLER.as_posix(), *args],
                              capture_output=True, text=True, timeout=15,
                              env={**os.environ, 'NO_COLOR': '1', 'REMNACUST_TEST_PYTHON': Path(sys.executable).as_posix()})

    def test_stopped_applications_are_recreated_without_starting_or_touching_dependencies(self):
        for running in ('', 'api', 'api worker'):
            with self.subTest(running=running):
                result = self.shell('APPS=(api worker); read -ra START_APPS <<< "$2"; '
                                    'compose(){ printf "%s\\n" "$*"; }; start_selected_apps', running)
                self.assertEqual(result.returncode, 0, result.stderr)
                lines = result.stdout.splitlines()
                stopped = [name for name in ('api', 'worker') if name not in running.split()]
                expected = []
                if stopped:
                    expected.append('up --no-start --no-deps --no-build --pull never ' + ' '.join(stopped))
                if running:
                    expected.append('up -d --no-deps --no-build --pull never ' + running)
                self.assertEqual(lines, expected)

    def test_recovery_loads_the_original_running_subset_including_an_empty_list(self):
        for running in ([], ['worker']):
            with self.subTest(running=running), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'state.before.json').write_text(json.dumps({'applications': ['api', 'worker'], 'runningApplications': running}))
                result = self.shell('''set +e
COMPONENT=node; CHANGED=true; BACKUP=$2; WORK=$2; LOG=$2/log
APPS=(api worker); START_APPS=(api worker)
python3(){ "$REMNACUST_TEST_PYTHON" -X utf8 -B "$@" | tr -d '\\r'; return "${PIPESTATUS[0]}"; }
helper(){ :; }; load_state(){ :; }; verify_node_image_policy(){ :; }
compose(){ printf '%s\\n' "$*" >> "$WORK/events"; }
wait_ready(){ :; }; helper_file_copy(){ :; }
(exit 7); recover''', root.as_posix())
                self.assertEqual(result.returncode, 7, result.stderr)
                lines = (root / 'events').read_text().splitlines()
                self.assertEqual(lines[0], 'stop api worker')
                self.assertTrue(any('--no-start' in line for line in lines))
                active = [line for line in lines if line.startswith('up -d ')]
                self.assertEqual(active, ['up -d --no-deps --no-build --pull never worker'] if running else [])

    def test_healthy_container_is_rejected_when_node_readiness_fails(self):
        result = self.shell('''COMPONENT=node; START_APPS=(node)
compose(){ printf fixture; }; get(){ printf node; }; sleep(){ :; }
failed=false
docker(){ if [[ $* == *RestartCount* ]]; then printf 0; elif $failed; then printf unhealthy; else printf healthy; fi; }
node_application_ready(){ failed=true; return 1; }
if wait_ready; then exit 42; fi''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_incomplete_snapshot_never_recreates_the_original_private_container_layer(self):
        for running, unavailable, corrupt in ((True, False, False), (False, False, False),
                                               (True, True, False), (True, False, True)):
            with self.subTest(running=running, unavailable=unavailable, corrupt=corrupt), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                original = 'a' * 64
                (root / 'state.before.json').write_text(json.dumps({'applications': ['node'], 'runningApplications': ['node'] if running else []}))
                (root / 'container.before.json').write_text(json.dumps([{'Id': original}]))
                (root / 'node-state-plan.json').write_text('{bad' if corrupt else json.dumps({'copies': [{'source': '/var/lib/remnanode'}]}))
                (root / 'compose-files.before.json').write_text('{}')
                result = self.shell('''set +e
COMPONENT=node; CHANGED=true; BACKUP=$2; WORK=$2; LOG=$2/log; APPS=(node); START_APPS=(node)
python3(){ "$REMNACUST_TEST_PYTHON" -X utf8 -B "$@" | tr -d '\\r'; return "${PIPESTATUS[0]}"; }
helper(){ :; }; load_state(){ :; }; get(){ printf node; }
verify_node_image_policy(){ printf unsafe-probe >> "$WORK/events"; }
compose(){ printf 'compose:%s\\n' "$*" >> "$WORK/events"; }
docker(){ if [[ $1 == inspect ]]; then printf '%s' "$4"; else printf 'docker:%s\\n' "$*" >> "$WORK/events"; fi; }
if [[ $3 == missing ]]; then docker(){ return 1; }; fi
wait_ready(){ :; }; helper_file_copy(){ :; }
(exit 7); recover''', root.as_posix(), 'missing' if unavailable else 'available')
                self.assertEqual(result.returncode, 7, result.stderr)
                events = (root / 'events').read_text()
                self.assertNotIn('unsafe-probe', events)
                self.assertNotIn('compose:up', events)
                self.assertEqual(('docker:start ' + original) in events, running and not unavailable and not corrupt,
                                 (events, result.stdout, (root / 'log').read_text(), (root / 'restore-applications').read_bytes()))

    def test_interruption_after_switch_runs_recovery_with_signal_exit_code(self):
        result = self.shell('''CHANGED=true; BACKUP=fixture
recover(){ printf 'recovery:%s' "$1"; exit "$1"; }
trap 'operation_interrupted TERM 143' TERM
kill -TERM "$BASHPID"''')
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertEqual(result.stdout, 'recovery:143')

    def test_interruption_before_switch_does_not_run_recovery(self):
        result = self.shell('''CHANGED=false; BACKUP=fixture
recover(){ printf unexpected-recovery; }
operation_interrupted INT 130''')
        self.assertEqual(result.returncode, 130, result.stderr)
        self.assertEqual(result.stdout, '')


class NodeReadinessTests(unittest.TestCase):
    def probe(self, **fixture):
        code = re.search(r"node_application_ready\(\).*?node -e '\n(.*?)\n' \"\$NODE_CORE_REQUIRED\"", INSTALLER.read_text(encoding='utf-8'), re.S)[1]
        wrapper = r'''
const vm=require('node:vm'), fixture=JSON.parse(process.argv[1]), exits=[], calls=[];
let statusCalls=0;
const context={
 process:{argv:['node',fixture.required?'true':'false'],getuid:()=>0,env:fixture.legacy?{XTLS_API_SOCKET_PATH:'xtls-api-abcdefghij'}:{XTLS_API_SOCKET_PATH:'/run/remnacust-xray-abcdefghij/api.sock',REMNACUST_NODE_RUNTIME:'1'},exit:code=>exits.push(code)},
 setTimeout:()=>{},
 require:name=>{
  if(name==='node:fs')return {
   existsSync:path=>path.endsWith('state.json')?!!fixture.selection:path.endsWith('checkpoint.pb')?!!fixture.cached:true,
   readFileSync:()=>fixture.corrupt?'broken':JSON.stringify(fixture.selection),
   lstatSync:path=>({isDirectory:()=>!path.endsWith('api.sock'),isSocket:()=>path.endsWith('api.sock'),mode:fixture.publicSocket?0o777:0o700,uid:0})
  };
  if(name==='node:child_process')return {execFileSync:(file,args)=>{
   calls.push([file,args]);
   if(file==='/command/s6-svstat'){statusCalls++;return fixture.down?'false -1':fixture.changed&&statusCalls>1?'true 99':'true 42';}
   if(fixture.statsFail)throw Error();
   return fixture.invalidStats?'null':'{}';
  }};
  if(name==='node:net')return {connect:()=>({destroy(){},on(event,fn){if(event===(fixture.apiFail?'error':'connect'))fn();}})};
  if(name==='node:path')return require(name);
  throw Error(name);
 }
};
vm.runInNewContext(process.argv[2],context,{timeout:2000});
console.log(JSON.stringify({exits,calls}));
'''
        result = subprocess.run(['node', '-e', wrapper, json.dumps(fixture), code], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_open_node_api_does_not_hide_a_failed_or_restarting_required_core(self):
        for fixture in ({'down': True}, {'statsFail': True}, {'changed': True}, {'invalidStats': True}):
            with self.subTest(fixture=fixture):
                self.assertEqual(self.probe(required=True, **fixture)['exits'], [1])

    def test_saved_checkpoint_requires_core_readiness_even_without_source_probe(self):
        self.assertEqual(self.probe(cached=True, down=True)['exits'], [1])
        self.assertEqual(self.probe(cached=True)['exits'], [0])

    def test_upstream_rollback_uses_the_abstract_socket_without_weakening_remnacust_checks(self):
        result = self.probe(required=True, legacy=True)
        self.assertEqual(result['exits'], [0])
        self.assertTrue(any('--server=unix-abstract:xtls-api-abcdefghij' in args for file, args in result['calls']))

    def test_paused_and_unconfigured_nodes_do_not_require_an_active_core(self):
        for fixture in ({'selection': {'paused': True}, 'required': True}, {}):
            result = self.probe(**fixture)
            self.assertEqual(result['exits'], [0])
            self.assertEqual(result['calls'], [])

    def test_api_failure_or_corrupt_core_selection_is_rejected(self):
        self.assertEqual(self.probe(apiFail=True)['exits'], [1])
        self.assertEqual(self.probe(selection={}, corrupt=True)['exits'], [1])
        self.assertEqual(self.probe(required=True, publicSocket=True)['exits'], [1])
        self.assertEqual(self.probe(required=True, selection={'operation': {'status': 'running'}})['exits'], [1])

class NodePolicySelectionTests(unittest.TestCase):
    def probe(self, **fixture):
        code = re.search(r"verify_node_image_policy\(\).*?--entrypoint node .*? -e '\n(.*?)\n'\n}", INSTALLER.read_text(encoding='utf-8'), re.S)[1]
        wrapper = r'''
const vm=require('node:vm'),crypto=require('node:crypto'),fixture=JSON.parse(process.argv[1]);
const markers='remnacust-quota-reserves-v1 remnacust-unreserved-usage-v1';
const managed=Buffer.from(fixture.managed===false?'legacy':markers),digest=fixture.corrupt?'d'.repeat(64):crypto.createHash('sha256').update(managed).digest('hex');
const root='/var/lib/remnawave/core-manager',selection={mode:'managed',paused:false,binary:{path:root+'/'+digest,sha256:digest}};
let state=selection;
if(fixture.default)state={mode:'bundled',paused:false,binary:{path:'/usr/local/bin/xray-default',sha256:'b'.repeat(64)}};
if(fixture.recover)state={mode:'managed',paused:false,binary:{path:root+'/'+'f'.repeat(64),sha256:'f'.repeat(64)},operation:{status:'running'},recovery:selection};
const files=new Map([
 ['/var/lib/remnanode/host-policy.json',Buffer.from(JSON.stringify({offlineReserves:'remnacust-quota-reserves-v1'}))],
 [root+'/state.json',Buffer.from(JSON.stringify(state))],
 [root+'/'+digest,managed],
 ['/usr/local/bin/xray',Buffer.from(fixture.bundled===false?'legacy':markers)],
 ['/usr/local/bin/xray-default',Buffer.from(markers)]
]);
function info(path){
 if(path===root)return {isFile:()=>false,isDirectory:()=>true,isSymbolicLink:()=>false,mode:0o700,uid:0};
 if(!files.has(path))throw Object.assign(Error(),{code:'ENOENT'});
 return {isFile:()=>true,isDirectory:()=>false,isSymbolicLink:()=>false,size:files.get(path).length,mode:0o600,uid:0,dev:1,ino:1};
}
const fs={constants:require('node:fs').constants,lstatSync:info,statSync:info,fstatSync:info,
 openSync:path=>{info(path);return path;},closeSync:()=>{},
 readFileSync:(path,encoding)=>{info(path);return encoding?files.get(path).toString():files.get(path);},
 readSync:(path,buffer,offset,length,position)=>files.get(path).copy(buffer,offset,position,position+length)
};
let result=0;
try{vm.runInNewContext(process.argv[2],{Buffer,process:{getuid:()=>0,exit:code=>{throw {exit:code};}},require:name=>name==='node:fs'?fs:require(name)},{timeout:2000});}
catch(error){if(error.exit===undefined)throw error;result=error.exit;}
console.log(result);
'''
        result = subprocess.run(['node', '-e', wrapper, json.dumps(fixture), code], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return int(result.stdout)

    def test_supported_bundled_binary_does_not_hide_an_unsupported_managed_core(self):
        self.assertNotEqual(self.probe(managed=False), 0)

    def test_supported_managed_core_is_checked_instead_of_the_bundled_binary(self):
        self.assertEqual(self.probe(bundled=False), 0)

    def test_managed_core_digest_must_match(self):
        self.assertNotEqual(self.probe(corrupt=True), 0)

    def test_interrupted_operation_checks_its_recovery_core(self):
        self.assertEqual(self.probe(recover=True, bundled=False), 0)
        self.assertNotEqual(self.probe(recover=True, managed=False), 0)

    def test_bundled_default_selection_checks_the_default_binary(self):
        self.assertEqual(self.probe(default=True, bundled=False), 0)


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
load_restore_apps(){ return 0; }
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
