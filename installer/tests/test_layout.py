import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime


class LayoutTests(unittest.TestCase):
    def test_map_lists_real_paths_and_never_environment_values(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); deploy = root / 'panel'; deploy.mkdir()
            env = deploy / '.env'; env.write_text('APP_SECRET=PRIVATE_SECRET\n')
            state = {'component': 'panel', 'directory': str(deploy), 'project': 'panel', 'composeFiles': [str(deploy / 'docker-compose.yml')]}
            runtime.write(root / 'registry' / 'panel.json', state)
            with patch.dict(os.environ, REMNACUST_ROOT=str(root)):
                runtime.write_layout(state, {'services': {'api': {'env_file': [str(env)]}, 'worker': {'environment': {'TOKEN': 'PRIVATE_TOKEN'}}}})
            page = (deploy / 'FILES.txt').read_text()
            self.assertIn(str(env), page); self.assertIn(str(deploy / 'docker-compose.yml'), page)
            self.assertNotIn('PRIVATE_SECRET', page); self.assertNotIn('PRIVATE_TOKEN', page)
            self.assertIn(str(deploy), (root / 'FILES.txt').read_text())
            self.assertEqual(env.read_text(), 'APP_SECRET=PRIVATE_SECRET\n')

    def test_operator_file_is_not_replaced_and_fresh_compose_is_discoverable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); deploy = root / 'node'; deploy.mkdir()
            config, state = runtime.fresh('node', str(deploy), 'node', 'fixture:latest', number='2222')
            self.assertEqual(state['composeFiles'], [str(deploy / 'docker-compose.yml')])
            (deploy / 'FILES.txt').write_text('operator notes')
            with patch.dict(os.environ, REMNACUST_ROOT=str(root)):
                runtime.write_layout(state, config)
            self.assertEqual((deploy / 'FILES.txt').read_text(), 'operator notes')


if __name__ == '__main__': unittest.main()
