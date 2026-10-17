"""Exercise Docker cleanup against unique images created by this test only."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch
import uuid

spec = importlib.util.spec_from_file_location('cleanup', Path(__file__).parents[1] / 'image_cleanup.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
suffix = 'qa-cleanup-' + uuid.uuid4().hex
references = []
container = None


def execute(*args, check=True):
    return subprocess.run(['docker', *args], check=check, capture_output=True, text=True).stdout.strip()


try:
    with tempfile.TemporaryDirectory(prefix='remnacust-cleanup-fixture-') as root:
        root = Path(root)
        identifiers = []
        for index in range(5):
            repository = 'ghcr.io/lottman/remnacust-panel' if index < 4 else 'remnacust-cleanup-foreign'
            tag = repository + ':' + suffix + '-' + str(index)
            references.append(tag)
            (root / 'Dockerfile').write_text('FROM scratch\nLABEL fixture="' + tag + '"\nCMD ["true"]\n')
            execute('build', '-q', '-t', tag, str(root))
            identifiers.append(execute('image', 'inspect', '--format', '{{.Id}}', tag))
        old_alias = 'remnacust-panel:' + suffix + '-old'
        execute('tag', identifiers[3], old_alias)
        references.append(old_alias)
        container = execute('create', '--name', suffix, references[2])
        before = root / 'before.json'
        before.write_text(json.dumps([{'Image': identifiers[1]}]))
        original = m.docker
        allowed = set(references)
        for identifier in identifiers:
            data = json.loads(execute('image', 'inspect', identifier))[0]
            allowed.update(data.get('RepoDigests') or [])

        def bounded_docker(*args, **kwargs):
            if args[:2] == ('image', 'ls'):
                return '\n'.join(identifiers)
            if args[:2] == ('image', 'rm'):
                assert all(ref in allowed for ref in args[2:]), 'Test removal must stay inside its own fixtures'
            return original(*args, **kwargs)

        with patch.object(m, 'docker', side_effect=bounded_docker):
            m.cleanup('panel', str(before), [references[0]])
        for index in [0, 1, 2, 4]:
            assert execute('image', 'inspect', '--format', '{{.Id}}', references[index]) == identifiers[index]
        assert subprocess.run(['docker', 'image', 'inspect', references[3]], capture_output=True).returncode != 0
        assert subprocess.run(['docker', 'image', 'inspect', old_alias], capture_output=True).returncode != 0
        print('PASS cleanup: current, previous, stopped-container and foreign images retained; superseded aliases removed')
finally:
    if container:
        execute('rm', container, check=False)
    for reference in references:
        assert suffix in reference
        execute('image', 'rm', reference, check=False)
