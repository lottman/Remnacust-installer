"""Temporarily suspend an active UFW around Certbot, with independent recovery."""
import argparse
import fcntl
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid


def checked(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=45,
                            env={**os.environ, 'LC_ALL': 'C'})
    if result.returncode:
        raise RuntimeError('Не удалось изменить состояние UFW; проверьте firewall вручную')
    return result.stdout


def run_certificate(command):
    child = subprocess.Popen(command)
    try:
        return child.wait(timeout=540)
    except BaseException:
        child.terminate()
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
        raise


def atomic(path, content, mode):
    if path.is_symlink():
        raise RuntimeError('Небезопасный путь восстановления UFW')
    descriptor, name = tempfile.mkstemp(dir=path.parent, prefix='.ufw-')
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, 'w') as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def reboot_recovery(ufw, systemctl, run, folder=Path('/var/lib/remnacust-ufw-recovery'), unit=Path('/etc/systemd/system/remnacust-ufw-restore.service')):
    if folder.is_symlink():
        raise RuntimeError('Небезопасный каталог восстановления UFW')
    folder.mkdir(mode=0o700, exist_ok=True)
    marker = folder / 'required'
    # This boot-time job survives power loss, unlike systemd's transient timer.
    escaped = ufw.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%')
    atomic(unit, '[Unit]\nDescription=Restore temporarily suspended UFW\nAfter=ufw.service\n'
           'ConditionPathExists=' + str(marker) + '\n\n[Service]\nType=oneshot\n'
           'ExecStart="' + escaped + '" --force enable\nExecStartPost=/usr/bin/rm -f ' + str(marker) +
           '\n\n[Install]\nWantedBy=multi-user.target\n', 0o644)
    run([systemctl, 'daemon-reload'])
    run([systemctl, 'enable', unit.name])
    atomic(marker, 'active\n', 0o600)
    return lambda: marker.unlink(missing_ok=True)


def guarded(command, root, run=None, execute=None, which=shutil.which, recover=None):
    run = run or checked
    execute = execute or run_certificate
    ufw = which('ufw')
    if not ufw:
        return execute(command)
    status = run([ufw, 'status']).strip()
    if status.startswith('Status: inactive'):
        return execute(command)
    if not status.startswith('Status: active'):
        raise RuntimeError('Состояние UFW не определено; Certbot не запущен')
    systemd = which('systemd-run')
    systemctl = which('systemctl')
    if not systemd or not systemctl:
        raise RuntimeError('Для безопасного временного отключения UFW нужен systemd-run')
    disarm_boot = (recover or reboot_recovery)(ufw, systemctl, run)
    unit = 'remnacust-ufw-recover-' + uuid.uuid4().hex
    # Arm recovery before opening the firewall. A killed installer cannot cancel it.
    run([systemd, '--quiet', '--collect', '--unit=' + unit, '--on-active=10m',
         '--timer-property=AccuracySec=1s', ufw, '--force', 'enable'])
    try:
        run([ufw, '--force', 'disable'])
        return execute(command)
    finally:
        # Keep the timer armed when restoration fails.
        run([ufw, '--force', 'enable'])
        if not run([ufw, 'status']).strip().startswith('Status: active'):
            raise RuntimeError('UFW не подтвердил включение; аварийное восстановление оставлено активным')
        disarm_boot()
        run([systemctl, 'stop', unit + '.timer'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or not Path(command[0]).is_absolute():
        raise RuntimeError('Нужен абсолютный путь к Certbot')
    path = Path('/run/remnacust-ufw-acme.lock')
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    def interrupted(signum, frame):
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, signal.SIG_IGN)
        raise KeyboardInterrupt()
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    with os.fdopen(descriptor, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        raise SystemExit(guarded(command, args.root))


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit('Certbot прерван; восстановлено исходное состояние UFW')
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error) if isinstance(error, RuntimeError) else 'Ошибка защиты UFW; проверьте состояние firewall')
