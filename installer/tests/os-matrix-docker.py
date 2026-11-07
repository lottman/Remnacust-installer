import argparse
from pathlib import Path
import shutil
import subprocess
import uuid


SYSTEMS = {
    'ubuntu22': ('ubuntu:22.04', 'ubuntu', '22.04', 'jammy'),
    'ubuntu24': ('ubuntu:24.04', 'ubuntu', '24.04', 'noble'),
    'ubuntu26': ('ubuntu:26.04', 'ubuntu', '26.04', 'resolute'),
    'debian12': ('debian:12-slim', 'debian', '12', 'bookworm'),
    'debian13': ('debian:13-slim', 'debian', '13', 'trixie'),
}
root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--os', choices=SYSTEMS, required=True)
parser.add_argument('--unit-tests', action='store_true')
parser.add_argument('--https-apt', action='store_true')
args = parser.parse_args()
ca_bundle = Path('/etc/ssl/certs/ca-certificates.crt')
if args.https_apt and not ca_bundle.is_file():
    raise SystemExit('A trusted system CA bundle is required for HTTPS APT tests')
image, distro, version, codename = SYSTEMS[args.os]
images = ['mirror.gcr.io/library/' + image, image]
node = shutil.which('node')
if args.unit_tests and not node:
    raise SystemExit('Node.js 26 is required for the userspace test matrix')
for image in images:
    if subprocess.run(['docker', 'image', 'inspect', image], capture_output=True, timeout=15).returncode == 0:
        break
    try:
        if subprocess.run(['docker', 'pull', image], timeout=180).returncode == 0:
            break
    except subprocess.TimeoutExpired:
        pass
else:
    raise SystemExit('Cannot load the official image for ' + args.os)
script = r'''
set -Eeuo pipefail
if [[ $RUN_UNIT_TESTS == 1 ]]; then
    export DEBIAN_FRONTEND=noninteractive
    if [[ $HTTPS_APT == 1 ]]; then
        find /etc/apt -type f \( -name '*.sources' -o -name '*.list' \) -exec sed -i 's|http://|https://|g' {} +
        printf 'Acquire::https::CAInfo "/audit-tools/ca.crt";\n' > /etc/apt/apt.conf.d/90audit-ca
    fi
    apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=30 -o APT::Update::Error-Mode=any update -qq
    apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=30 install -y --no-install-recommends python3 openssl ca-certificates curl util-linux libstdc++6 libatomic1 git
    export PATH=/audit-tools:$PATH PYTHONDONTWRITEBYTECODE=1
    node --version | grep -q '^v26\.'
    python3 -m unittest discover -s /source/installer/tests -p 'test_*.py'
fi
source /source/installer/installer.sh
[[ $(supported_os_codename) == "$EXPECTED_CODENAME" ]]
[[ $(. /etc/os-release; printf '%s' "$ID") == "$EXPECTED_ID" ]]
[[ $(. /etc/os-release; printf '%s' "$VERSION_ID") == "$EXPECTED_VERSION" ]]
WORK=$(mktemp -d)
LOG=$WORK/log
installed=false
installed_helper() { :; }
package_step() { if [[ $* == *'docker-ce docker-ce-cli'* ]]; then installed=true; fi; }
download() {
    [[ $1 == "https://download.docker.com/linux/$EXPECTED_ID/gpg" ]]
    printf 'fixture-key' > "$2"
}
command() {
    if [[ $# == 2 && $1 == -v && $2 == docker && $installed == false ]]; then return 1; fi
    builtin command "$@"
}
docker() { [[ $installed == true ]]; }
systemctl() { [[ $* == 'enable --now docker' ]]; }
prepare_host
grep -Fq "https://download.docker.com/linux/$EXPECTED_ID $EXPECTED_CODENAME stable" /etc/apt/sources.list.d/remnacust-docker.list
grep -Fq "arch=$(dpkg --print-architecture)" /etc/apt/sources.list.d/remnacust-docker.list
printf 'PASS %s %s: actual userspace, Docker source and architecture\n' "$EXPECTED_ID" "$EXPECTED_VERSION"
'''
container = f'remnacust-os-audit-{args.os}-{uuid.uuid4().hex[:12]}'
command = ['docker', 'run', '--rm', '--name', container, '-i', '--memory=768m', '--cpus=1',
           '--mount', f'type=bind,source={root},target=/source,readonly',
           '-e', f'EXPECTED_ID={distro}', '-e', f'EXPECTED_VERSION={version}',
           '-e', f'EXPECTED_CODENAME={codename}',
           '-e', f'HTTPS_APT={int(args.https_apt)}',
           '-e', f'RUN_UNIT_TESTS={int(args.unit_tests)}']
if args.https_apt:
    command += ['--mount', f'type=bind,source={ca_bundle},target=/audit-tools/ca.crt,readonly']
if args.unit_tests:
    command += ['--mount', f'type=bind,source={Path(node).resolve()},target=/audit-tools/node,readonly']
try:
    subprocess.run(command + [image, 'bash', '-s'], input=script, text=True,
                   check=True, timeout=600)
finally:
    subprocess.run(['docker', 'rm', '-f', container], capture_output=True, timeout=30)
