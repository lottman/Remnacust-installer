"""Offline regression checks for the split-repository source release."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('package_release',Path(__file__).resolve().parents[1]/'scripts/package-source-release.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.parent=Path(self.temp.name)
        self.root=self.parent/'Remnacust-installer';self.root.mkdir()
        self.lock={}
        for kind in module.REPOSITORIES:
            directory=self.parent/('Remnacust-'+kind);directory.mkdir()
            files={'VERSION':'1.1.1\n'}
            if kind=='panel':
                files.update({p+'/package.json':'{"version":"1.1.1"}' for p in ['panel/frontend','panel/backend','subscription-page/frontend','subscription-page/backend']})
                files.update({'panel/Dockerfile':'FROM scratch\n','panel/backend/.env.sample':'SAMPLE=example\n'})
            elif kind=='node':
                files.update({'node/package.json':'{"version":"1.1.1"}','node/docker/Dockerfile':'FROM scratch\n','node/docker/remnacust-core.tar.gz':'fixture','node/docker/remnacust-core.tar.gz.sha256':hashlib.sha256(b'fixture').hexdigest()+'  remnacust-core.tar.gz\n'})
            else:
                files.update({'xray/core/core.go':'package core\nvar (Version_x byte = 1; Version_y byte = 1; Version_z byte = 1)\n','xray/LICENSE':'fixture license\n'})
            self.write(directory,files);self.init(directory)
            self.lock[kind]={'repository':module.REPOSITORIES[kind],'commit':self.git(directory,'rev-parse','HEAD').strip()}
        own={'VERSION':'1.1.1\n','LICENSE':'fixture license\n','NOTICE.md':'fixture notice\n','component-sources.json':json.dumps(self.lock),**{'installer/'+p:'fixture\n' for p in ['installer.sh','runtime.py','database.cjs','marzban.py']}}
        self.write(self.root,own);self.init(self.root);self.git(self.root,'tag','v1.1.1')
    def tearDown(self):self.temp.cleanup()
    def write(self,root,files):
        for name,data in files.items():
            path=root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text(data,encoding='utf-8',newline='\n')
    def git(self,root,*args):return subprocess.check_output(['git',*args],cwd=root,text=True,stderr=subprocess.DEVNULL)
    def init(self,root):
        self.git(root,'init','-b','main');self.git(root,'config','core.autocrlf','false');self.git(root,'config','user.name','Release fixture');self.git(root,'config','user.email','fixture@example.invalid')
        self.git(root,'add','-f','.');self.git(root,'commit','-m','Fixture')
    def retag(self):
        self.git(self.root,'add','-f','.');self.git(self.root,'commit','-m','Changed fixture');self.git(self.root,'tag','-f','v1.1.1')
    def test_pinned_sources_and_reproducible_output(self):
        destination=module.package(self.root,'v1.1.1',self.parent)
        first=(destination/'remnacust-source-v1.1.1.tar.gz').read_bytes()
        module.package(self.root,'v1.1.1',self.parent)
        self.assertEqual(first,(destination/'remnacust-source-v1.1.1.tar.gz').read_bytes())
    def test_untracked_secret_and_local_changes_are_excluded(self):
        self.write(self.root,{'.env':'private','installer/installer.sh':'local change'})
        destination=module.package(self.root,'v1.1.1',self.parent)
        self.assertEqual((destination/'installer.sh').read_text(),'fixture\n')
    def test_committed_environment_is_rejected(self):
        self.write(self.root,{'.env':'private'});self.retag()
        with self.assertRaisesRegex(ValueError,'Working environment'):module.package(self.root,'v1.1.1',self.parent)
    def test_wrong_version_is_rejected(self):
        self.write(self.root,{'VERSION':'1.1.2\n'});self.retag()
        with self.assertRaisesRegex(ValueError,'version mismatch'):module.package(self.root,'v1.1.1',self.parent)
    def test_unexpected_repository_is_rejected(self):
        self.lock['panel']['repository']='other/unsafe';self.write(self.root,{'component-sources.json':json.dumps(self.lock)});self.retag()
        with self.assertRaisesRegex(ValueError,'Invalid pinned'):module.package(self.root,'v1.1.1',self.parent)
    def test_runtime_data_is_rejected(self):
        self.write(self.root,{'backups/database.dump':'fixture'});self.retag()
        with self.assertRaisesRegex(ValueError,'Runtime data'):module.package(self.root,'v1.1.1',self.parent)
    def test_backup_api_contract_is_source_code(self):
        self.write(self.root,{'panel/frontend/vendor/backend-contract/build/backend/commands/backups/create-backup.command.d.ts':'export declare class CreateBackup {}\n'})
        self.retag()
        module.package(self.root,'v1.1.1',self.parent,check=True)

if __name__=='__main__':unittest.main()
