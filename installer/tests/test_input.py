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
CONFIRM_PROMPT = 'Продолжить? yes/y/да/д или no/n/нет/н [no]: '


class InputWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='remnacust-input-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def terminal(self, command, exchanges, locale='C.UTF-8', script=None):
        master, slave = pty.openpty()
        process = subprocess.Popen(['bash', '-c', command, 'test', str(script or INSTALLER), str(self.root)],
                                   stdin=slave, stdout=slave, stderr=slave,
                                   env={**os.environ, 'LC_ALL': locale, 'NO_COLOR': '1', 'REMNACUST_ROOT': str(self.root)})
        os.close(slave)
        output = b''
        pending = b''
        stage = 0
        deadline = time.monotonic() + 8
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

    def test_negative_answers_and_enter_cancel_without_running_action(self):
        for answer in ['', '   ', 'n', 'N', 'no', 'No', 'н', 'Н', 'нет', 'НЕТ', 'нЕт', 'неТ']:
            with self.subTest(answer=answer):
                code, output = self.terminal('source "$1"; confirm "Тест"; printf UNEXPECTED-ACTION',
                                             [(CONFIRM_PROMPT, answer + '\n')], locale='C')
                self.assertEqual(code, 0, output)
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
        code, output = self.terminal('bash "$1"', [('Действие: ', '9\n'), ('Компонент: panel или node [panel]: ', b'\x04')],
                                     script=self.menu_fixture())
        self.assertNotEqual(code, 0, output)
        self.assertEqual(output.count('Установка и обслуживание'), 1)
        self.assertNotIn('  1 status', output)

    def menu_fixture(self, action=False):
        script = self.root / 'installer.sh'
        overrides = '''
component_installed() { return 1; }
component_retained() { return 1; }
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
        self.assertEqual(output.count('Выберите номер от 0 до 10.'), 1, output)
        self.assertNotIn('UNEXPECTED-ACTION', output)

    def test_return_from_action_does_not_execute_leftover_paste(self):
        code, output = self.terminal('bash "$1"', [('Действие: ', '8\n1\n1\n1\n'), ('Действие: ', '0\n')],
                                     script=self.menu_fixture(action=True))
        self.assertEqual(code, 0, output)
        self.assertEqual(output.count('ACTION-RAN'), 1, output)
        self.assertEqual(output.count('Установка и обслуживание'), 2, output)

    def test_menu_trims_spaces_and_retries_without_python(self):
        code, output = self.terminal('source "$1"; command() { return 1; }; choice=$(ask_menu_choice 10); printf "CHOICE=%s" "$choice"',
                                     [('Действие: ', 'wrong\nold log\n'), ('Действие: ', ' 08 \n')])
        self.assertEqual(code, 0, output)
        self.assertIn('CHOICE=8', output)
        self.assertEqual(output.count('Выберите номер от 0 до 10.'), 1, output)

    def test_node_tls_prompt_uses_the_same_yes_no_answers(self):
        command = ('source "$1"; WORK="$2"; COMPONENT=node; PORT=2222; PANEL_IP=1.1.1.1; TLS_METHOD=existing; '
                   'CERT_FILE=/test/cert; KEY_FILE=/test/key; certificate_wizard; printf "NODE-DOMAIN=%s" "$NODE_DOMAIN"')
        code, output = self.terminal(command, [('Настроить TLS/XHTTP на ноде? yes/y/да/д или no/n/нет/н [no]: ', 'д\n'),
                                              ('Домен ноды: ', 'edge.example.com\n')])
        self.assertEqual(code, 0, output)
        self.assertIn('NODE-DOMAIN=edge.example.com', output)


if __name__ == '__main__':
    unittest.main()
