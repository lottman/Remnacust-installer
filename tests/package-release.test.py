"""Offline regression checks for the split-repository source release."""
import ast
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
    def test_private_and_development_files_are_rejected(self):
        files=module.git_files(self.root,'HEAD')
        versions={kind:'1.1.1' for kind in module.REPOSITORIES}
        for kind, entry in self.lock.items():
            for name, data in module.component_files(kind,entry['commit'],self.parent).items():
                if name.startswith(module.PREFIXES[kind]):files[name]=data
        for name in ['.private/review.md','.playwright-cli/page.yml','playwright-report/index.html',
                     'test-results/result.json','panel/frontend/.audit-preview.tsx',
                     'panel/frontend/.superdesign/resume.json','audit-review/report.md',
                     'panel/frontend/audit-current.json','installer/debug.log','installer/failed.tmp',
                     'installer/runtime.pyc','installer/runtime.py.bak','installer/runtime.py.orig',
                     'installer/runtime.py.rej','installer/runtime.py~',
                     'installer/backup-password.txt','installer/.backup-key']:
            with self.subTest(path=name):
                with self.assertRaisesRegex(ValueError,'artifact|Private or temporary'):
                    module.validate({**files,name:b'fixture'},'1.1.1',versions)
        files['panel/backend/src/modules/backups/backup.service.ts']=b'export class Backup {}'
        files['panel/frontend/i18n-tools/audit-ui-strings.mjs']=b'export {}'
        module.validate(files,'1.1.1',versions)
    def test_windows_checkout_preferences_do_not_change_release_bytes(self):
        self.write(self.root,{'.gitattributes':'* text=auto\n*.sh text eol=lf\n'})
        self.git(self.root,'config','core.eol','crlf');self.retag()
        destination=module.package(self.root,'v1.1.1',self.parent)
        contents=module.read_archive((destination/'remnacust-source-v1.1.1.tar.gz').read_bytes())
        self.assertEqual(contents['NOTICE.md'],b'fixture notice\n')
    def test_installer_patch_keeps_pinned_application_versions(self):
        for entry in self.lock.values():entry['version']='1.1.1'
        self.write(self.root,{'VERSION':'1.1.2\n','component-sources.json':json.dumps(self.lock)})
        self.retag();self.git(self.root,'tag','v1.1.2')
        module.package(self.root,'v1.1.2',self.parent,check=True)
    def test_incorrect_pinned_version_is_rejected(self):
        self.lock['node']['version']='1.1.0';self.write(self.root,{'component-sources.json':json.dumps(self.lock)});self.retag()
        with self.assertRaisesRegex(ValueError,'Component VERSION mismatch'):module.package(self.root,'v1.1.1',self.parent)

    def test_panel_four_part_version_is_preserved(self):
        directory=self.parent/'Remnacust-panel'
        files={'VERSION':'1.1.7.1\n', **{p+'/package.json':'{"version":"1.1.7.1"}' for p in ['panel/frontend','panel/backend','subscription-page/frontend','subscription-page/backend']}}
        self.write(directory,files);self.git(directory,'add','.');self.git(directory,'commit','-m','Panel patch')
        self.lock['panel'].update(version='1.1.7.1',commit=self.git(directory,'rev-parse','HEAD').strip())
        self.write(self.root,{'component-sources.json':json.dumps(self.lock)});self.retag()
        module.package(self.root,'v1.1.1',self.parent,check=True)

    def test_node_four_part_version_is_rejected(self):
        self.lock['node']['version']='1.1.7.1'
        self.write(self.root,{'component-sources.json':json.dumps(self.lock)});self.retag()
        with self.assertRaisesRegex(ValueError,'Invalid pinned version: node'):module.package(self.root,'v1.1.1',self.parent)

class RuntimeFilesTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        tree=ast.parse((Path(__file__).resolve().parents[1]/'scripts/package-docker-release.py').read_text(encoding='utf-8'))
        function=next(node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name=='runtime_files')
        scope={};exec(compile(ast.Module(body=[function],type_ignores=[]),'runtime_files','exec'),scope)
        self.read_files=scope['runtime_files']
        self.names=['VERSION','component-sources.json','images.json','LICENSE','NOTICE.md','panel/backend/.env.sample']
        self.names+=['installer/'+name for name in ['installer.sh','runtime.py','database.cjs','marzban.py','images.py','tls.py','update-agent.py','README.md']]
        for name in self.names+['installer/debug.txt','installer/backup-password.txt','installer/.private/review.md']:
            path=self.root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(name.encode())
    def tearDown(self):self.temp.cleanup()
    def test_only_runtime_dependencies_are_included(self):
        self.assertEqual(self.read_files(self.root),{name:name.encode() for name in self.names})
    def test_missing_runtime_dependency_is_rejected(self):
        (self.root/'installer/tls.py').unlink()
        with self.assertRaises(FileNotFoundError):self.read_files(self.root)

if __name__=='__main__':unittest.main()
