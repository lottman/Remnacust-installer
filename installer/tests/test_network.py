import errno
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / 'installer.sh'


class NetworkWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='remnacust-network-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def shell(self, body, success=True):
        result = subprocess.run(['bash', '-c', 'source "$1"; WORK="$2"; LOG="$2/log"; ' + body,
                                 'test', str(INSTALLER), str(self.root)], capture_output=True, text=True, timeout=15)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_matching_addresses_and_ipv6_normalization(self):
        self.shell("SERVER_IPS='93.184.216.34,2606:4700:4700:0000::1111'; "
                   "dns_addresses() { printf '93.184.216.34\\n2606:4700:4700::1111\\n'; }; check_dns panel.example.com")

    def test_wrong_ipv6_rejects_even_with_matching_ipv4(self):
        result = self.shell("SERVER_IPS=93.184.216.34; dns_addresses() { printf '93.184.216.34\\n2606:4700:4700::1111\\n'; }; "
                            "check_dns panel.example.com", success=False)
        self.assertIn('включая IPv6', result.stderr)

    def test_wrong_a_or_missing_dns_is_rejected(self):
        self.shell("SERVER_IPS=93.184.216.34; dns_addresses() { printf 1.1.1.1; }; check_dns panel.example.com", success=False)
        self.shell("dns_addresses() { return 1; }; server_addresses() { touch \"$WORK/unexpected\"; }; check_dns panel.example.com", success=False)
        self.assertFalse((self.root / 'unexpected').exists())

    def public_dns_fixture(self, mode):
        # Fixture the HTTPS transport while exercising real query construction and DNS parsing.
        (self.root / 'sitecustomize.py').write_text('''
import io,json,os,urllib.request
class Response(io.BytesIO):
    pass
class Opener:
    def open(self,request,timeout):
        mode=os.environ['DNS_MODE']; url=request.full_url
        assert url.startswith(('https://dns.google/resolve?','https://cloudflare-dns.com/dns-query?'))
        assert timeout==5
        if mode=='fallback' and 'dns.google' in url:raise OSError('provider unavailable')
        kind=28 if 'type=28' in url else 1
        data={'Status':0,'TC':False,'Answer':[{'type':5,'data':'target.example.com.'},{'type':kind,'data':'2606:4700:4700::1111' if kind==28 else '93.184.216.34'}]}
        if mode=='incomplete' and kind==28:data={'Status':2,'TC':False}
        if mode=='empty':data={'Status':3,'TC':False}
        if mode=='wrong-family' and kind==28:data['Answer'][1]['data']='93.184.216.34'
        return Response(json.dumps(data).encode())
urllib.request.build_opener=lambda *a:Opener()
''')
        return f'export PYTHONPATH="{self.root}" DNS_MODE={mode}; '

    def test_public_resolver_includes_a_aaaa_cname_and_fallback(self):
        result = self.shell(self.public_dns_fixture('fallback') + 'dns_addresses panel.example.com')
        self.assertEqual(set(result.stdout.splitlines()), {'93.184.216.34', '2606:4700:4700::1111'})

    def test_incomplete_aaaa_nxdomain_and_invalid_domain_fail_closed(self):
        for mode in ['incomplete', 'empty', 'wrong-family']:
            self.shell(self.public_dns_fixture(mode) + 'dns_addresses panel.example.com', success=False)
        self.shell(self.public_dns_fixture('fallback') + 'dns_addresses https://panel.example.com/', success=False)

    def test_unknown_server_address_fails_closed_and_nat_override_works(self):
        self.shell("python3() { if [[ $* == '-' ]]; then :; else command python3 \"$@\"; fi; }; "
                   "curl() { return 1; }; server_addresses", success=False)
        self.shell("SERVER_IPS='93.184.216.34'; server_addresses")
        self.shell("SERVER_IPS='127.0.0.1'; server_addresses", success=False)

    def test_detection_includes_interfaces_and_nat_for_both_families(self):
        self.shell("python3() { if [[ $* == '-' ]]; then printf '93.184.216.34'; else command python3 \"$@\"; fi; }; "
                   "curl() { if [[ $1 == -4 ]]; then printf 1.1.1.1; else printf '2606:4700:4700::1111'; fi; }; "
                   "a=$(server_addresses); [[ $a == *93.184.216.34* && $a == *1.1.1.1* && $a == *2606:4700:4700::1111* ]]")

    def test_external_proxy_and_dns_challenges_keep_their_different_frontend(self):
        self.shell("check_dns() { return 99; }; COMPONENT=panel; PROXY=existing; TLS_METHOD=auto; dns_preflight; "
                   "PROXY=caddy; TLS_METHOD=cloudflare; dns_preflight; TLS_METHOD=gcore; dns_preflight; "
                   "COMPONENT=node; TLS_METHOD=''; dns_preflight")
        self.shell("check_dns() { return 99; }; COMPONENT=node; TLS_METHOD=http; NODE_DOMAIN=node.example.com; dns_preflight", success=False)

    def test_https_wait_retries_certificate_delay_and_checks_api_contract(self):
        body = '''
DOMAIN=panel.example.com; HTTPS_TIMEOUT=4; count=0
sleep() { :; }
curl() {
    [[ $* != *--insecure* && $* != *' -k '* && $* == *--proto* && $* == *--max-time* ]] || return 99
    count=$((count+1))
    if ((count==1)); then printf 'certificate not ready' >&2; return 60; fi
    if ((count==2)); then printf '<html>wrong proxy</html>' > "$WORK/https-status.json"; return; fi
    printf '{"response":{"isLoginAllowed":false,"isRegisterAllowed":true}}' > "$WORK/https-status.json"
}
wait_panel_https; [[ $count == 3 ]]
'''
        self.shell(body)

    def test_bad_https_and_wrong_backend_never_report_success(self):
        start = time.monotonic()
        self.shell('DOMAIN=panel.example.com; HTTPS_TIMEOUT=1; curl() { printf "TLS failed" >&2; return 60; }; wait_panel_https', success=False)
        self.assertLess(time.monotonic() - start, 5)
        result = self.shell('DOMAIN=panel.example.com; HTTPS_TIMEOUT=1; curl() { printf \'{"response":{"isLoginAllowed":"false","isRegisterAllowed":true}}\' > "$WORK/https-status.json"; }; wait_panel_https', success=False)
        self.assertIn('не вернул ответ панели', result.stderr)

    def test_check_panel_is_read_only(self):
        state = self.root / 'registry/panel.json'
        state.parent.mkdir()
        state.write_text('{"component":"panel","panelDomain":"panel.example.com","proxy":"existing","directory":"unused",'
                         '"project":"fixture","applications":["remnawave"],"composeFiles":["unused/compose.json"]}')
        before = state.read_bytes()
        self.shell('ROOT="$WORK"; ACTION=check-panel; COMPONENT=panel; '
                   'lock_operation() { :; }; compose() { return 99; }; docker() { return 99; }; '
                   'curl() { printf \'{"response":{"isLoginAllowed":true,"isRegisterAllowed":false}}\' > "$WORK/https-status.json"; }; '
                   'HELPER="$(dirname "$1")/runtime.py"; installed_helper() { :; }; service_action')
        self.assertEqual(state.read_bytes(), before)

    def menu_fixture(self):
        # Real menu and deploy functions; only host/release/installation dependencies are fixtures.
        script = self.root / 'installer.sh'
        overrides = '''
component_installed() { return 1; }
component_retained() { return 1; }
assert_fresh_target() { :; }
select_fresh_target() { :; }
prepare_host() { :; }
lock_operation() { :; }
certificate_wizard() { DOMAIN=panel.example.com; COMPONENT=panel; PROXY=caddy; TLS_METHOD=auto; PORT=3000; }
release_source() { HELPER="$TEST_RUNTIME"; TAG=v1.2.4; }
port_free() { :; }
certificate_preflight() { :; }
dns_addresses() { printf 1.1.1.1; }
server_addresses() { printf 93.184.216.34; }
prepare_image() { touch "$REMNACUST_ROOT/forbidden-image"; }
fresh_files() { touch "$REMNACUST_ROOT/forbidden-compose"; }
run_action() {
    WORK=$(mktemp -d); touch "$WORK/.installer-owned"; trap cleanup EXIT
    LOG="$REMNACUST_ROOT/log"; COMPONENT=panel; deploy
}
main "$@"
'''
        script.write_text(INSTALLER.read_text().replace('if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi', overrides))
        return script

    def test_dns_failure_returns_to_interactive_menu_without_creating_installation(self):
        script = self.menu_fixture()
        master, slave = pty.openpty()
        env = {**os.environ, 'REMNACUST_ROOT': str(self.root), 'TEST_RUNTIME': str(INSTALLER.with_name('runtime.py')), 'NO_COLOR': '1'}
        process = subprocess.Popen(['bash', str(script)], stdin=slave, stdout=slave, stderr=slave, env=env)
        os.close(slave)
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        output = b''
        stage = 0
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if select.select([master], [], [], .1)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output += chunk
                expected = ['Действие: ', 'Версия установки [latest]: ', 'Продолжить? yes/y/да/д или no/n/нет/н [no]: ', 'Действие: '][min(stage, 3)].encode()
                if stage < 4 and expected in output:
                    os.write(master, [b'1\n', b'\n', b'yes\n', b'0\n'][stage])
                    stage += 1
                    output = output.replace(expected, b'', 1)
            if process.poll() is not None:
                break
        os.close(master)
        self.assertEqual(stage, 4, output.decode(errors='replace'))
        self.assertEqual(process.wait(timeout=3), 0, output.decode(errors='replace'))
        self.assertIn('Исправьте указанную причину'.encode(), output)
        self.assertFalse((self.root / 'forbidden-image').exists())
        self.assertFalse((self.root / 'forbidden-compose').exists())

    def test_explicit_failed_command_keeps_nonzero_exit_for_automation(self):
        script = self.menu_fixture()
        result = subprocess.run(['bash', str(script), 'install-panel', '--yes'],
                                env={**os.environ, 'REMNACUST_ROOT': str(self.root), 'TEST_RUNTIME': str(INSTALLER.with_name('runtime.py'))},
                                capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Установка и обслуживание', result.stdout)


if __name__ == '__main__':
    unittest.main()
