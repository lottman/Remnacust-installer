import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import deployment_layout as layout
import runtime


class CanonicalLayoutTests(unittest.TestCase):
    def test_only_paths_change_not_credentials_or_named_resources(self):
        old, new = Path('/opt/remnacust/panel-20261007093515-240659'), Path('/opt/remnacust/panel')
        before = {'services': {'api': {'image': 'panel:fixed', 'environment': {'APP_SECRET': 'unchanged'}, 'env_file': [{'path': str(old / '.env')}], 'volumes': [{'type': 'bind', 'source': str(old / 'certs'), 'target': '/certs'}, {'type': 'volume', 'source': 'database', 'target': '/data'}]}}, 'volumes': {'database': {'name': 'original-database'}}}
        after = layout.compose_paths(before, old, new)
        self.assertEqual(after['services']['api']['environment'], before['services']['api']['environment'])
        self.assertEqual(after['volumes'], before['volumes'])
        self.assertEqual(after['services']['api']['env_file'][0]['path'], str(new / '.env'))
        self.assertEqual(after['services']['api']['volumes'][0]['source'], str(new / 'certs'))
        self.assertEqual(before['services']['api']['volumes'][0]['source'], str(old / 'certs'))

    def test_other_projects_and_stopped_containers_protect_referenced_paths(self):
        path = Path('/opt/remnacust/node')
        container = {'Config': {'Labels': {'com.docker.compose.project': 'shared-proxy'}}, 'Mounts': [{'Source': str(path / 'certs')}], 'State': {'Running': False}}
        self.assertTrue(layout.referenced(path, [container], 'node'))
        self.assertFalse(layout.referenced(Path('/opt/remnacust/node-other'), [container]))

    def test_only_known_unreferenced_old_directories_are_archived(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old = root / 'panel-20261007093515-240659'; old.mkdir(); (old / '.env').write_text('secret=preserved')
            custom = root / 'panel-custom'; custom.mkdir()
            protected = root / 'panel-20261007125352-343161'; protected.mkdir()
            containers = [{'Config': {'Labels': {'com.docker.compose.project.working_dir': str(protected)}}}]
            layout.archive_unused(root, 'panel', containers)
            self.assertTrue(custom.exists())
            self.assertTrue(protected.exists())
            self.assertFalse(old.exists())
            self.assertEqual((root / 'backups/retired-layout' / old.name / '.env').read_text(), 'secret=preserved')

    def test_custom_deployments_are_not_silently_moved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); custom = root / 'operator-custom'; custom.mkdir()
            state = {'component': 'node', 'directory': str(custom)}
            runtime.write(root / 'registry/node.json', state)
            with patch.object(layout, 'inventory', return_value=[]):
                self.assertEqual(layout.normalize(root, 'node'), state)
            self.assertTrue(custom.is_dir())


if __name__ == '__main__':
    unittest.main()
