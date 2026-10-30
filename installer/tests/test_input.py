import errno
import os
from pathlib import Path
import pty
import re
import select
import subprocess
import tempfile
import time
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / 'installer.sh'
CONFIRM_PROMPT = 'Продолжить? y/n [n]: '
COLORED_CHOICES = '\x1b[1;32my\x1b[0m/\x1b[1;31mn\x1b[0m [\x1b[1;31mn\x1b[0m]: '


class InputWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='remnacust-input-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def terminal(self, command, exchanges, locale='C.UTF-8', script=None, color=False):
        master, slave = pty.openpty()
        env = {**os.environ, 'LC_ALL': locale, 'NO_COLOR': '1', 'REMNACUST_ROOT': str(self.root)}
        if color:
            env.pop('NO_COLOR', None)
            env['TERM'] = 'xterm-256color'
        process = subprocess.Popen(['bash', '-c', command, 'test', str(script or INSTALLER), str(self.root)],
                                   stdin=slave, stdout=slave, stderr=slave,
                                   env=env)
        os.close(slave)
        output = b''
        pending = b''
        stage = 0
        deadline = time.monotonic() + 20
        try:
            while time.monotonic() < deadline:
                if select.select([master], [], [], .05)[0]:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            break
                        raise
                    if not chunk:
                        break
                    output += chunk
                    pending += chunk
                    if stage < len(exchanges):
                        expected, reply = exchanges[stage]
                        expected = expected.encode()
                        if expected in pending:
                            pending = pending.split(expected, 1)[1]
                            os.write(master, reply.encode() if isinstance(reply, str) else reply)
                            stage += 1
                if process.poll() is not None:
                    break
            self.assertEqual(stage, len(exchanges), output.decode(errors='replace'))
            return process.wait(timeout=1), output.decode(errors='replace')
        finally:
            os.close(master)
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_confirmation_accepts_short_english_and_russian_with_both_locales(self):
        for locale in ['C', 'C.UTF-8']:
            for answer in ['y', 'Y', 'yes', 'YeS', 'д', 'Д', 'да', 'ДА', 'дА', '  д  ', '\ty\r']:
                with self.subTest(locale=locale, answer=answer):
                    code, output = self.terminal('source "$1"; confirm "Тест"; printf ACTION-CONFIRMED',
                                                 [(CONFIRM_PROMPT, answer + '\n')], locale=locale)
                    self.assertEqual(code, 0, output)
                    self.assertIn('ACTION-CONFIRMED', output)

    def test_node_secret_is_visible_and_preserved_without_printing_it_again(self):
        secret = 'Local-fixture-key+/=='
        command = 'source "$1"; ask_node_secret; [[ $REMNACUST_NODE_SECRET == "Local-fixture-key+/==" ]] && printf KEY-ACCEPTED'
        code, output = self.terminal(command, [('SECRET_KEY из панели: ', secret + '\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('KEY-ACCEPTED', output)
        self.assertEqual(output.count(secret), 1)

    def test_node_secret_eof_stops_the_operation(self):
        code, output = self.terminal('source "$1"; ask_node_secret || exit 1; printf UNEXPECTED-ACTION',
                                     [('SECRET_KEY из панели: ', b'\x04')])
        self.assertNotEqual(code, 0, output)
        self.assertNotIn('UNEXPECTED-ACTION', output)

    def test_domain_confirmation_defaults_to_yes_and_normalizes_case(self):
        command = ('source "$1"; HELPER="$(dirname "$1")/runtime.py"; '
                   'value=$(ask_confirmed_domain "Домен сайта"); printf "DOMAIN=%s" "$value"')
        code, output = self.terminal(command, [('Домен сайта: ', ' Fivp.Top \n'),
                                              ('Использовать домен Fivp.Top? y/n [y]: ', '\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('DOMAIN=fivp.top', output)

    def test_domain_rejection_reprompts_instead_of_using_the_typo(self):
        command = ('source "$1"; HELPER="$(dirname "$1")/runtime.py"; '
                   'value=$(ask_confirmed_domain "Домен сайта"); printf "DOMAIN=%s" "$value"')
        code, output = self.terminal(command, [('Домен сайта: ', 'fivp.tip\n'),
                                              ('Использовать домен fivp.tip? y/n [y]: ', 'n\n'),
                                              ('Домен сайта: ', 'fivp.top\n'),
                                              ('Использовать домен fivp.top? y/n [y]: ', 'y\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('DOMAIN=fivp.top', output)
        self.assertNotIn('DOMAIN=fivp.tip', output)

    def test_domain_validation_repeats_and_confirmation_eof_cancels(self):
        command = ('source "$1"; HELPER="$(dirname "$1")/runtime.py"; '
                   'value=$(ask_confirmed_domain "Домен сайта") || exit 1; printf "DOMAIN=%s" "$value"')
        code, output = self.terminal(command, [('Домен сайта: ', 'https://invalid.example/path\n'),
                                              ('Домен сайта: ', 'sub.example.com\n'),
                                              ('Использовать домен sub.example.com? y/n [y]: ', b'\x04')])
        self.assertNotEqual(code, 0, output)
        self.assertNotIn('DOMAIN=', output)

    def test_node_domain_confirmation_eof_does_not_continue_without_tls(self):
        command = ('source "$1"; HELPER="$(dirname "$1")/runtime.py"; COMPONENT=node; PORT=2222; PANEL_IP=1.1.1.1; '
                   'if certificate_wizard; then printf UNEXPECTED-CONTINUATION; fi')
        code, output = self.terminal(command, [('Настроить TLS/XHTTP на ноде? y/n [n]: ', 'y\n'),
                                              ('Домен ноды: ', 'node.example.com\n'),
                                              ('Использовать домен node.example.com? y/n [y]: ', b'\x04')])
        self.assertNotIn('UNEXPECTED-CONTINUATION', output)

    def test_explicit_automation_domain_does_not_need_a_terminal(self):
        command = ('source "$1"; HELPER="$(dirname "$1")/runtime.py"; '
                   'ask_confirmed_domain "Домен сайта" "sub.example.com" </dev/null')
        code, output = self.terminal(command, [])
        self.assertEqual(code, 0, output)
        self.assertIn('sub.example.com', output)
        self.assertNotIn('y/n', output)

    def test_required_text_repeats_after_multiple_empty_answers_and_trims_spaces(self):
        prompt = 'Обязательное поле: '
        code, output = self.terminal('source "$1"; value=$(ask_required "Обязательное поле"); printf "RESULT=%s" "$value"',
            [(prompt, '\n'), (prompt, '   \n'), (prompt, ' valid.example.com  \n')])
        self.assertEqual(code, 0, output)
        self.assertIn('RESULT=valid.example.com', output)
        self.assertEqual(output.count('пустой ответ'), 2)

    def test_required_text_eof_terminates_instead_of_looping(self):
        code, output = self.terminal('source "$1"; value=$(ask_required "Обязательное поле"); printf UNEXPECTED-ACTION',
            [('Обязательное поле: ', b'\x04')])
        self.assertNotEqual(code, 0, output)
        self.assertNotIn('UNEXPECTED-ACTION', output)

    def test_email_repeats_empty_and_invalid_answers_without_advancing_tls_wizard(self):
        command = 'source "$1"; WORK="$2"; COMPONENT=node; PORT=2222; PANEL_IP=1.1.1.1; NODE_DOMAIN=edge.example.com; TLS_METHOD=http; certificate_wizard; printf "EMAIL=%s" "$EMAIL"'
        prompt = "Email для Let's Encrypt: "
        code, output = self.terminal(command, [(prompt, '\n'), (prompt, '\n'), (prompt, 'invalid\n'), (prompt, ' test@example.com  \n')])
        self.assertEqual(code, 0, output)
        self.assertIn('EMAIL=test@example.com', output)

    def test_migration_accepts_explicit_subscription_opt_in_and_opt_out(self):
        for flag, value in [('--subscription-page', 'true'), ('--no-subscription-page', 'false')]:
            code, output = self.terminal(f'source "$1"; parse_args migrate-remnawave-panel {flag}; printf "SUBPAGE=%s" "$SUBSCRIPTION_PAGE"', [])
            self.assertEqual(code, 0, output)
            self.assertIn('SUBPAGE=' + value, output)

    def test_panel_net_admin_prompt_accepts_enable_decline_and_default(self):
        command = 'source "$1"; COMPONENT=panel; HELPER="${1%/*}/runtime.py"; panel_net_admin_wizard; printf "NET-ADMIN=%s" "$PANEL_NET_ADMIN"'
        for reply, enabled in [('y\n', 'true'), ('n\n', 'false'), ('\n', 'false')]:
            with self.subTest(reply=reply):
                code, output = self.terminal(command, [('Добавить NET_ADMIN контейнеру панели? y/n [n]: ', reply)])
                self.assertEqual(code, 0, output)
                self.assertIn('NET-ADMIN=' + enabled, output)

    def test_panel_net_admin_explicit_flags_skip_prompt_and_reject_other_actions(self):
        for flag, enabled in [('--net-admin', 'true'), ('--no-net-admin', 'false')]:
            command = f'source "$1"; parse_args install-panel {flag}; COMPONENT=panel; HELPER="${{1%/*}}/runtime.py"; panel_net_admin_wizard; printf "NET-ADMIN=%s" "$PANEL_NET_ADMIN"'
            code, output = self.terminal(command, [])
            self.assertEqual(code, 0, output)
            self.assertIn('NET-ADMIN=' + enabled, output)
            self.assertNotIn('Добавить NET_ADMIN', output)
        for args in ['upgrade-panel --net-admin',
                     'migrate-remnawave-panel --no-net-admin', 'install-panel --net-admin --no-net-admin']:
            code, output = self.terminal(f'source "$1"; parse_args {args}; printf UNEXPECTED-ACTION', [])
            self.assertNotEqual(code, 0, output)
            self.assertNotIn('UNEXPECTED-ACTION', output)

    def test_node_net_admin_prompt_and_explicit_flags(self):
        for reply, enabled in [('y\n', 'true'), ('n\n', 'false'), ('\n', 'false')]:
            command = 'source "$1"; COMPONENT=node; node_net_admin_wizard; printf "NET-ADMIN=%s" "$NODE_NET_ADMIN"'
            code, output = self.terminal(command, [('Добавить NET_ADMIN контейнеру ноды? y/n [n]: ', reply)])
            self.assertEqual(code, 0, output)
            self.assertIn('NET-ADMIN=' + enabled, output)
        for flag, enabled in [('--net-admin', 'true'), ('--no-net-admin', 'false')]:
            command = f'source "$1"; parse_args install-node {flag}; COMPONENT=node; node_net_admin_wizard; printf "NET-ADMIN=%s" "$NODE_NET_ADMIN"'
            code, output = self.terminal(command, [])
            self.assertEqual(code, 0, output)
            self.assertIn('NET-ADMIN=' + enabled, output)
            self.assertNotIn('Добавить NET_ADMIN', output)

    def test_node_net_admin_upgrade_preserves_enabled_without_prompt(self):
        command = 'source "$1"; COMPONENT=node; helper() { printf yes; }; node_effective_net_admin() { printf yes; }; STATE=unused; node_net_admin_wizard unused; printf "NET-ADMIN=%s" "$NODE_NET_ADMIN"'
        code, output = self.terminal(command, [])
        self.assertEqual(code, 0, output)
        self.assertIn('NET-ADMIN=true', output)
        self.assertNotIn('Добавить NET_ADMIN', output)

    def test_declared_but_missing_node_capability_still_prompts(self):
        command = 'source "$1"; COMPONENT=node; helper() { printf yes; }; node_effective_net_admin() { printf no; }; STATE=unused; node_net_admin_wizard unused; printf "NET-ADMIN=%s" "$NODE_NET_ADMIN"'
        code, output = self.terminal(command, [('Добавить NET_ADMIN контейнеру ноды? y/n [n]: ', 'y\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('NET-ADMIN=true', output)
        self.assertIn('не подтверждено', output)

    def test_unattended_node_install_does_not_add_net_admin_without_opt_in(self):
        command = 'source "$1"; COMPONENT=node; node_net_admin_wizard; printf "NET-ADMIN=%s" "$NODE_NET_ADMIN"'
        result = subprocess.run(['bash', '-c', command, 'test', str(INSTALLER)],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('NET-ADMIN=false', result.stdout)

    def test_panel_net_admin_without_terminal_defaults_off_and_old_release_rejects_enable(self):
        command = 'source "$1"; COMPONENT=panel; panel_net_admin_wizard; printf "NET-ADMIN=%s" "$PANEL_NET_ADMIN"'
        result = subprocess.run(['bash', '-c', command, 'test', str(INSTALLER)],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('NET-ADMIN=false', result.stdout)
        command = 'source "$1"; COMPONENT=panel; PANEL_NET_ADMIN=true; PANEL_NET_ADMIN_SET=true; HELPER=/dev/null; panel_net_admin_wizard; printf UNEXPECTED-ACTION'
        result = subprocess.run(['bash', '-c', command, 'test', str(INSTALLER)],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Выберите latest', result.stderr)
        self.assertNotIn('UNEXPECTED-ACTION', result.stdout)

    def test_menu_design_preserves_every_action_and_no_color(self):
        code, output = self.terminal('source "$1"; component_installed() { return 1; }; show_menu', [])
        self.assertEqual(code, 0, output)
        self.assertNotIn('\x1b', output)
        for action in ['install-panel', 'install-node', 'upgrade-panel', 'upgrade-node',
                       'migrate-remnawave-panel', 'migrate-remnawave-node', '--check-release',
                       'status', 'migrate-marzban-panel', 'uninstall-panel', 'uninstall-node', 'uninstall-subscription-page']:
            self.assertIn(action, output)
        self.assertIn('Обслуживание', output)

    def test_banner_uses_coral_and_fits_narrow_terminal(self):
        for width in [24, 32, 40, 80]:
            with self.subTest(width=width):
                command = f'source "$1"; COLUMNS={width}; component_installed() {{ return 1; }}; show_menu'
                code, output = self.terminal(command, [], color=True)
                self.assertEqual(code, 0, output)
                self.assertIn('\x1b[38;2;231;111;122m', output)
                self.assertEqual(output.count('REMNACUST'), 1)
                plain = re.sub(r'\x1b\[[0-9;]*m', '', output)
                self.assertTrue(all(len(line) <= width for line in plain.splitlines()), plain)
                self.assertEqual([int(number) for number in re.findall(r'^\s+(\d+)  ', plain, re.M)],
                                 [*range(1, 17), 0])

    def test_no_color_progress_has_no_terminal_control_codes(self):
        command = 'source "$1"; LOG="$2/progress.log"; step "Проверка" sleep .15'
        code, output = self.terminal(command, [])
        self.assertEqual(code, 0, output)
        self.assertNotIn('\x1b', output)
        self.assertIn('✓ Проверка', output)

    def test_server_values_cannot_emit_terminal_control_codes(self):
        code, output = self.terminal('source "$1"; terminal_value "Система" $\'safe\\033[31m\\nvalue\'', [])
        self.assertEqual(code, 0, output)
        self.assertNotIn('\x1b', output)
        self.assertIn('safe[31mvalue', output)

    def test_negative_answers_and_enter_cancel_without_running_action(self):
        for answer in ['', '   ', 'n', 'N', 'no', 'No', 'н', 'Н', 'нет', 'НЕТ', 'нЕт', 'неТ']:
            with self.subTest(answer=answer):
                code, output = self.terminal('source "$1"; confirm "Тест"; printf UNEXPECTED-ACTION',
                                             [(CONFIRM_PROMPT, answer + '\n')], locale='C')
                self.assertEqual(code, 0, output)
                self.assertIn('Действие отменено', output)
                self.assertNotIn('UNEXPECTED-ACTION', output)

    def test_subscription_prompt_normalizes_two_addresses_and_retries_invalid_input(self):
        prompt = 'Домены сайта подписки: '
        command = ('source "$1"; DOMAIN=panel.example.com; HELPER="$(dirname "$1")/runtime.py"; '
                   'subscription_wizard; printf "RESULT=%s" "$SUBSCRIPTION_URLS"')
        code, output = self.terminal(command, [('Установить сайт подписки? y/n [n]: ', 'y\n'),
                                             (prompt, 'http://sub.example.com\n'),
                                             (prompt, ' Sub.Example.com/, https://other.example.com/ \n'),
                                             ('Использовать адреса сайта подписки: sub.example.com, other.example.com? y/n [y]: ', '\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('RESULT=https://sub.example.com,https://other.example.com', output)
        self.assertIn('Адрес подписки:', output)
        self.assertNotIn('Установка и обслуживание', output)

    def test_subscription_prompt_enter_keeps_panel_endpoint_and_eof_cancels(self):
        prompt = 'Установить сайт подписки? y/n [n]: '
        command = ('source "$1"; DOMAIN=panel.example.com; HELPER="$(dirname "$1")/runtime.py"; '
                   'subscription_wizard; printf "RESULT=%s" "$SUBSCRIPTION_URLS"')
        code, output = self.terminal(command, [(prompt, '\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('RESULT=https://panel.example.com/api/sub', output)
        code, output = self.terminal(command, [(prompt, b'\x04')])
        self.assertNotEqual(code, 0, output)
        self.assertNotIn('RESULT=', output)

    def test_yes_mode_never_prompts_for_optional_subscription_site(self):
        command = ('source "$1"; DOMAIN=panel.example.com; YES=true; HELPER="$(dirname "$1")/runtime.py"; '
                   'subscription_wizard; printf "RESULT=%s|%s" "$SUBSCRIPTION_PAGE" "$SUBSCRIPTION_URLS"')
        code, output = self.terminal(command, [])
        self.assertEqual(code, 0, output)
        self.assertIn('RESULT=false|https://panel.example.com/api/sub', output)
        self.assertNotIn('y/n', output)

    def test_yes_mode_requires_a_domain_when_subscription_site_is_selected(self):
        command = ('source "$1"; DOMAIN=panel.example.com; YES=true; SUBSCRIPTION_PAGE=true; SUBSCRIPTION_PAGE_SET=true; '
                   'HELPER="$(dirname "$1")/runtime.py"; subscription_wizard')
        code, output = self.terminal(command, [])
        self.assertNotEqual(code, 0, output)
        self.assertIn('Исправьте --subscription-urls', output)
        self.assertNotIn('Домены сайта подписки:', output)

    def test_subscription_port_retries_reserved_panel_and_https_ports(self):
        command = ('source "$1"; HELPER="$(dirname "$1")/runtime.py"; port_free() { return 0; }; '
                   'value=$(choose_subscription_port 3000 3000); printf "PORT=%s" "$value"')
        code, output = self.terminal(command, [('Свободный порт страницы подписки: ', '443\n'),
                                             ('Свободный порт страницы подписки: ', '3011\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('PORT=3011', output)

    def test_yes_mode_optional_panel_features_use_explicit_or_safe_defaults(self):
        command = ('source "$1"; YES=true; COMPONENT=panel; DOMAIN=panel.example.com; EMAIL=test@example.com; '
                   'HELPER="$(dirname "$1")/runtime.py"; certificate_wizard; panel_net_admin_wizard; '
                   'printf "RESULT=%s|%s|%s" "$PROXY" "$TLS_METHOD" "$PANEL_NET_ADMIN"')
        code, output = self.terminal(command, [])
        self.assertEqual(code, 0, output)
        self.assertIn('RESULT=caddy|auto|false', output)
        self.assertNotIn('y/n', output)
        self.assertNotIn('Reverse proxy [', output)

    def test_yes_mode_optional_node_features_do_not_wait_for_terminal_input(self):
        command = ('source "$1"; YES=true; COMPONENT=node; HELPER="$(dirname "$1")/runtime.py"; '
                   'certificate_wizard; node_net_admin_wizard; printf "RESULT=%s|%s" "$NODE_DOMAIN" "$NODE_NET_ADMIN"')
        code, output = self.terminal(command, [])
        self.assertEqual(code, 0, output)
        self.assertIn('RESULT=|false', output)
        self.assertNotIn('y/n', output)

    def test_both_prompts_show_only_bold_green_y_and_bold_red_n(self):
        commands = [('source "$1"; confirm "Тест"; printf ACTION-CONFIRMED', 'Продолжить? ', 'ACTION-CONFIRMED'),
                    ('source "$1"; WORK="$2"; COMPONENT=node; PORT=2222; PANEL_IP=1.1.1.1; '
                     'certificate_wizard; printf "NODE-DOMAIN=%s" "${NODE_DOMAIN:-none}"',
                     'Настроить TLS/XHTTP на ноде? ', 'NODE-DOMAIN=none')]
        for command, prompt, result in commands:
            with self.subTest(prompt=prompt):
                reply = 'y\n' if result == 'ACTION-CONFIRMED' else 'n\n'
                code, output = self.terminal(command, [(prompt + COLORED_CHOICES, reply)], color=True)
                self.assertEqual(code, 0, output)
                self.assertIn(result, output)
                self.assertNotIn('yes/y', output)
                self.assertNotIn('no/n', output)

    def test_colored_default_cancels_and_invalid_answer_repeats_colored_choices(self):
        prompt = 'Продолжить? ' + COLORED_CHOICES
        code, output = self.terminal('source "$1"; confirm "Тест"; printf UNEXPECTED-ACTION',
                                     [(prompt, 'wrong\n'), (prompt, '\n')], color=True)
        self.assertEqual(code, 0, output)
        self.assertIn('Введите \x1b[1;32my\x1b[0m/\x1b[1;31mn\x1b[0m.', output)
        self.assertIn('Действие отменено', output)
        self.assertNotIn('UNEXPECTED-ACTION', output)

    def test_invalid_confirmation_repeats_question_in_place(self):
        code, output = self.terminal('source "$1"; confirm "Тест"; printf ACTION-CONFIRMED',
                                     [(CONFIRM_PROMPT, 'maybe\n'), (CONFIRM_PROMPT, 'д\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('ACTION-CONFIRMED', output)
        self.assertNotIn('Установка и обслуживание', output)

    def test_confirmation_and_menu_eof_exit_without_looping(self):
        for command, prompt in [('source "$1"; confirm "Тест"; printf UNEXPECTED-ACTION', CONFIRM_PROMPT),
                                ('bash "$1"', 'Действие: ')]:
            script = self.menu_fixture() if command.startswith('bash') else None
            code, output = self.terminal(command, [(prompt, b'\x04')], script=script)
            self.assertNotEqual(code, 0, output)
            self.assertLessEqual(output.count('Установка и обслуживание'), 1)
            self.assertNotIn('UNEXPECTED-ACTION', output)

    def test_maintenance_eof_stops_before_showing_another_prompt(self):
        code, output = self.terminal('bash "$1"', [('Действие: ', '13\n'), ('Действие: ', b'\x04')],
                                     script=self.menu_fixture())
        self.assertNotEqual(code, 0, output)
        self.assertEqual(output.count('Установка и обслуживание'), 1)
        self.assertNotIn('  1 status', output)

    def test_management_menu_selects_component_and_domain_operation(self):
        for choice, component in [('1', 'panel'), ('2', 'node'), ('3', 'subscription-page')]:
            command = 'source "$1"; management_menu; printf "ACTION=%s COMPONENT=%s" "$ACTION" "$COMPONENT"'
            code, output = self.terminal(command, [('Действие: ', choice + '\n'), ('Действие: ', '7\n')])
            self.assertEqual(code, 0, output)
            self.assertIn('ACTION=change-domain COMPONENT=' + component, output)

    def test_management_back_and_eof_do_not_run_an_action(self):
        for reply in ('0\n', b'\x04'):
            command = 'source "$1"; management_menu || exit 1; [[ -z $ACTION ]] || printf UNEXPECTED-ACTION'
            code, output = self.terminal(command, [('Действие: ', reply)])
            self.assertNotIn('UNEXPECTED-ACTION', output)
            self.assertEqual(code == 0, isinstance(reply, str), output)

    def test_repeat_page_install_opens_management_before_host_preparation(self):
        import hashlib
        import json
        directory = self.root / 'subscription-page'; directory.mkdir()
        compose = directory / 'docker-compose.yml'; compose.write_text('{"services":{"subscription-page":{"image":"fixture"}}}')
        item = {'directory': str(directory), 'project': 'remnacust-subscription-page', 'service': 'subscription-page',
                'composeFiles': [str(compose)], 'domain': 'fivp.tip'}
        identity = hashlib.sha256(('\0'.join(str(item[k]) for k in ('directory', 'project', 'service'))).encode()).hexdigest()[:24]
        registry = self.root / 'registry/subscription-pages'; registry.mkdir(parents=True)
        (registry / (identity + '.json')).write_text(json.dumps(item))
        binary = self.root / 'bin'; binary.mkdir()
        docker = binary / 'docker'; docker.write_text('#!/bin/sh\nexit 0\n'); docker.chmod(0o755)
        command = ('source "$1"; WORK="$2"; export PATH="$2/bin:$PATH"; '
                   'HELPER_ROOT="$(dirname "$1")"; installed_helper() { :; }; lock_operation() { :; }; '
                   'prepare_host() { printf UNEXPECTED-DOWNLOAD; exit 99; }; '
                   'component_menu() { printf OPENED-MANAGEMENT; ACTION=""; }; '
                   'ACTION=install-subscription-page; subscription_page_action')
        code, output = self.terminal(command, [])
        self.assertEqual(code, 0, output)
        self.assertIn('OPENED-MANAGEMENT', output)
        self.assertIn('fivp.tip', output)
        self.assertNotIn('UNEXPECTED-DOWNLOAD', output)

    def test_new_page_can_use_another_port_without_stopping_the_existing_service(self):
        command = ('source "$1"; HELPER="$(dirname "$1")/runtime.py"; '
                   'port_free() { [[ $1 == 3011 ]]; }; '
                   'value=$(choose_subscription_port 3010) || exit 1; printf "PORT=%s" "$value"')
        code, output = self.terminal(command, [('Свободный порт страницы подписки: ', 'invalid\n'),
                                              ('Свободный порт страницы подписки: ', '3011\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('PORT=3011', output)
        self.assertNotIn('PORT=3010', output)

    def test_busy_port_in_automation_fails_without_prompt_or_implicit_replacement(self):
        command = ('source "$1"; HELPER="$(dirname "$1")/runtime.py"; '
                   'port_free() { return 1; }; '
                   'choose_subscription_port 3010 </dev/null || exit 1; printf UNEXPECTED-CONTINUATION')
        code, output = self.terminal(command, [])
        self.assertNotEqual(code, 0, output)
        self.assertNotIn('Свободный порт страницы подписки:', output)
        self.assertNotIn('UNEXPECTED-CONTINUATION', output)

    def test_real_occupied_port_is_reported_and_existing_listener_stays_bound(self):
        import socket
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen(1)
            port = listener.getsockname()[1]
            command = ('source "$1"; HELPER="$(dirname "$1")/runtime.py"; '
                       f'choose_subscription_port {port} </dev/null || exit 1; printf UNEXPECTED-CONTINUATION')
            code, output = self.terminal(command, [])
            self.assertNotEqual(code, 0, output)
            self.assertIn('Порт занят: ' + str(port), output)
            self.assertEqual(listener.getsockname()[1], port)
            self.assertNotIn('UNEXPECTED-CONTINUATION', output)

    def test_subscription_management_has_separate_uninstall_action(self):
        command = 'source "$1"; COMPONENT=subscription-page; component_menu; printf "ACTION=%s" "$ACTION"'
        code, output = self.terminal(command, [('Действие: ', '8\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('ACTION=uninstall-subscription-page', output)

    def test_subscription_uninstall_defaults_to_cancel_before_mutation(self):
        command = ('source "$1"; ACTION=uninstall-subscription-page; '
                   'lock_operation() { :; }; installed_helper() { :; }; '
                   'select_managed_page() { PAGE_ID=aaaaaaaaaaaaaaaaaaaaaaaa; }; '
                   'subscription_page_action; printf UNEXPECTED-CONTINUATION')
        code, output = self.terminal(command, [(CONFIRM_PROMPT, '\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('Действие отменено', output)
        self.assertNotIn('UNEXPECTED-CONTINUATION', output)

    def test_page_management_cli_accepts_registered_component(self):
        command = 'source "$1"; parse_args change-domain --component subscription-page --page-id abc --domain sub.example.test; printf "ACTION=%s COMPONENT=%s" "$ACTION" "$COMPONENT"'
        code, output = self.terminal(command, [])
        self.assertEqual(code, 0, output)
        self.assertIn('ACTION=change-domain COMPONENT=subscription-page', output)

    def menu_fixture(self, action=False):
        script = self.root / 'installer.sh'
        overrides = '''
component_installed() { return 1; }
run_action() { printf UNEXPECTED-ACTION; exit 33; }
main "$@"
'''
        if action:
            overrides = overrides.replace('printf UNEXPECTED-ACTION; exit 33', 'sleep .1; printf "ACTION-RAN\\n"')
        script.write_text(INSTALLER.read_text().replace('if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi', overrides))
        return script

    def test_pasted_logs_are_discarded_without_redrawing_menu_or_running_queued_action(self):
        paste = 'old log\n' * 150 + '\n1\n'
        code, output = self.terminal('bash "$1"', [('Действие: ', paste), ('Действие: ', '0\n')], script=self.menu_fixture())
        self.assertEqual(code, 0, output)
        self.assertEqual(output.count('Установка и обслуживание'), 1, output)
        self.assertEqual(output.count('Выберите номер от 0 до 16.'), 1, output)
        self.assertNotIn('UNEXPECTED-ACTION', output)

    def test_return_from_action_does_not_execute_leftover_paste(self):
        code, output = self.terminal('bash "$1"', [('Действие: ', '8\n1\n1\n1\n'), ('Действие: ', '0\n')],
                                     script=self.menu_fixture(action=True))
        self.assertEqual(code, 0, output)
        self.assertEqual(output.count('ACTION-RAN'), 1, output)
        self.assertEqual(output.count('Установка и обслуживание'), 2, output)

    def test_successful_deployments_exit_the_menu_with_zero_status(self):
        script = self.menu_fixture(action=True)
        text = script.read_text().replace('sleep .1; printf "ACTION-RAN\\n"',
                                          'printf "ACTION-RAN\\n"; printf completed >&3')
        script.write_text(text)
        for choice in ['1', '2', '3', '4', '5', '6']:
            with self.subTest(choice=choice):
                code, output = self.terminal('bash "$1"', [('Действие: ', choice + '\n')], script=script)
                self.assertEqual(code, 0, output)
                self.assertEqual(output.count('ACTION-RAN'), 1, output)
                self.assertEqual(output.count('Установка и обслуживание'), 1, output)
                self.assertNotIn('Возврат в меню', output)

    def test_cancellation_and_external_exit_code_20_return_to_menu(self):
        for action, exchanges in [
            ('confirm "Тест"', [('Действие: ', '1\n'), (CONFIRM_PROMPT, 'n\n'), ('Действие: ', '0\n')]),
            ('printf completed >&3; exit 20', [('Действие: ', '1\n'), ('Действие: ', '0\n')]),
        ]:
            script = self.menu_fixture()
            script.write_text(script.read_text().replace('printf UNEXPECTED-ACTION; exit 33', action))
            code, output = self.terminal('bash "$1"', exchanges, script=script)
            self.assertEqual(code, 0, output)
            self.assertEqual(output.count('Установка и обслуживание'), 2, output)

    def test_menu_trims_spaces_and_retries_without_python(self):
        code, output = self.terminal('source "$1"; command() { return 1; }; choice=$(ask_menu_choice 10); printf "CHOICE=%s" "$choice"',
                                     [('Действие: ', 'wrong\nold log\n'), ('Действие: ', ' 08 \n')])
        self.assertEqual(code, 0, output)
        self.assertIn('CHOICE=8', output)
        self.assertEqual(output.count('Выберите номер от 0 до 10.'), 1, output)

    def test_node_tls_prompt_uses_the_same_yes_no_answers(self):
        command = ('source "$1"; WORK="$2"; HELPER="$(dirname "$1")/runtime.py"; COMPONENT=node; PORT=2222; PANEL_IP=1.1.1.1; TLS_METHOD=existing; '
                   'CERT_FILE=/test/cert; KEY_FILE=/test/key; certificate_wizard; printf "NODE-DOMAIN=%s" "$NODE_DOMAIN"')
        code, output = self.terminal(command, [('Настроить TLS/XHTTP на ноде? y/n [n]: ', 'д\n'),
                                              ('Домен ноды: ', 'edge.example.com\n'),
                                              ('Использовать домен edge.example.com? y/n [y]: ', '\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('NODE-DOMAIN=edge.example.com', output)


if __name__ == '__main__':
    unittest.main()
