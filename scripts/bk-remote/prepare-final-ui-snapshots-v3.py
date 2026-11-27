#!/usr/bin/env python3
"""第三次界面增量：九项白名单、两项新增，保留全部已验证原生字节。"""
import argparse, datetime, hashlib, importlib.util, json, os, re
from pathlib import Path
import runpy, shutil, stat, subprocess, sys, types, uuid

ROOT = Path(r'D:\demo2\bk-remote-toolchains') if os.name == 'nt' else Path('/mnt/d/demo2/bk-remote-toolchains')
REPO = Path(r'D:\demo2\rustdesk') if os.name == 'nt' else Path('/mnt/d/demo2/rustdesk')
SCRIPT = Path(__file__).resolve()
OLD_FILE = SCRIPT.with_name('prepare-android-ui-snapshot.py')
OLD = types.SimpleNamespace(**runpy.run_path(str(OLD_FILE)))
A_RUN = ROOT / 'android-g2-continuation-20261127-231142'
W_RUN = ROOT / 'windows-g2-stable-20261127-224312'
W_MANIFEST = 'b77faff81604cf107b82f67d7944679d8f0f428f91658dd2c03e8554fc31399a'
W_LIBS = {'librustdesk.dll':'af2fc259e367cf13bffcac74af9afc182e8b93261ba01df1c753d2a9e30ec221',
          'dylib_virtual_display.dll':'0e20712adad0149ea26b3e23b9a8f74e66f7ae8449e0d8b0a208ac1ddf39555d'}
UI = {
 'flutter/lib/models/server_model.dart':'d4d596792ff9c72cb30fc12997be62eb3869ca4f9d3f709b99e2b67e32ae441c',
 'flutter/lib/mobile/pages/server_page.dart':'e286bc41dec0883a02d654e24e4284c85883150f9374dcc0e987b697c9d5b343',
 'flutter/lib/mobile/widgets/gesture_help.dart':'3bda1d85789acf18c36d064159767d80465f12e7a686aa9f4a2fb977df21c46b',
 'flutter/test/bk_remote_service_lifecycle_test.dart':'3bb4fe5163d62e5f6ea35c36188186d6afdd0a0123f374377df2b39b042e05b9',
 'flutter/lib/common/widgets/dialog.dart':'4c121fd8453b014199286c1fc8289733ca0ea908353a218db81ac16e5d9beed7',
 'flutter/lib/desktop/pages/desktop_setting_page.dart':'317b7f52ea33e0338f8dd13c046fa0a9b3e6629b06312243005b85cda784342a',
 'flutter/lib/common/bk_remote_device_time.dart':'bdd1f81c49cdb56a6c5295ada04b00f996f0a628cd79dce49884562a6f0fa307',
 'flutter/lib/common/widgets/bk_remote_devices_page.dart':'bac38764a7c91b33d18e5e84fc7833ecc9fd6c586faaafdbbf9ad1b53b56637f',
 'flutter/test/bk_remote_device_time_test.dart':'645edd2e595fd47e4b0cb6b7abf074dd3e9db1023b01344e2e4e0a68471f9b81',
}
NEW = frozenset({'flutter/lib/common/bk_remote_device_time.dart','flutter/test/bk_remote_device_time_test.dart'})
TEST_PATH = 'src/platform/windows/installer_handoff/directory.rs'
TEST_SHA = '7854585779b35ca535684124c3df83fa46094d0762445b56ee8423ac0bc6a1ed'
STEPS = ('prepare-windows-flutter-project.py','ensure-windows-plugin-junctions.py',
         'prepare-windows-ui-build-links.py','build-windows-flutter.py',
         'build-windows-portable-candidate.py','verify-windows-package.py')
GENERATED = {'flutter/'+platform+'/flutter/'+name for platform in ('windows','linux','macos')
             for name in ('generated_plugin_registrant.cc','generated_plugin_registrant.h',
                          'generated_plugin_registrant.swift','generated_plugins.cmake')}
require, digest, file_digest = OLD.require, OLD.digest, OLD.file_digest
write_json, scan_tree = OLD.write_json, OLD.scan_tree

def local(value):
    if os.name != 'nt' and len(value)>2 and value[1]==':':
        return Path('/mnt/'+value[0].lower()+value[2:].replace('\\','/'))
    return Path(value)

def record(path):
    if path.is_symlink(): return {'type':'symlink','target':os.readlink(path)}
    require(path.is_file(), 'Missing regular input: '+str(path))
    return {'type':'file','sha256':file_digest(path)}

def repo_inventory():
    names={x.decode() for x in OLD.git(REPO,'ls-files','--cached','--others','--exclude-standard','-z').split(b'\0') if x}
    names.discard('libs/hbb_common')
    names.update('libs/hbb_common/'+x.decode() for x in OLD.git(REPO/'libs/hbb_common','ls-files','--cached','--others','--exclude-standard','-z').split(b'\0') if x)
    return {OLD.safe_relative(n):record(REPO/n) for n in sorted(names) if not n.startswith(('docs/','scripts/bk-remote/'))}

def reviewed_test_difference(original):
    current=(REPO/TEST_PATH).read_bytes(); before=(original/TEST_PATH).read_bytes()
    require(digest(current)==TEST_SHA,'Reviewed test-only worktree input changed')
    mark=b'#[cfg(test)]\nmod tests'
    a,b=before.replace(b'\r\n',b'\n'),current.replace(b'\r\n',b'\n')
    require(a.count(mark)==b.count(mark)==1,'Ambiguous test module boundary')
    pa,pb=a.split(mark,1)[0],b.split(mark,1)[0]
    require(pa==pb,'Production prefix changed in directory fixture')
    marker=br'\#\[cfg\(test\)\]\r?\nmod tests'
    old_marks,new_marks=list(re.finditer(marker,before)),list(re.finditer(marker,current))
    require(len(old_marks)==len(new_marks)==1,'Ambiguous raw test module boundary')
    raw_old,raw_new=before[:old_marks[0].start()],current[:new_marks[0].start()]
    return {'path':TEST_PATH,'original_raw_sha256':digest(before),'current_raw_sha256':digest(current),
            'original_lf_sha256':digest(a),'current_lf_sha256':digest(b),
            'production_prefix_original_raw_sha256':digest(raw_old),'production_prefix_current_raw_sha256':digest(raw_new),
            'production_prefix_raw_equal':raw_old==raw_new,
            'production_prefix_original_lf_sha256':digest(pa),'production_prefix_current_lf_sha256':digest(pb),
            'production_prefix_equal_after_line_endings_only':True,
            'current_imported':False,'snapshot_policy':'Keep original frozen native bytes; reviewed current difference is confined to cfg(test).'}

def windows_parent():
    require((W_RUN/'exit-code.txt').read_text().strip()=='0','Sixth native build not successful')
    parent=W_RUN/'source-manifest.json'
    require(file_digest(parent)==W_MANIFEST,'Unexpected sixth native input manifest')
    manifest=json.loads(parent.read_text())
    source=local((W_RUN/'snapshot-path.txt').read_text().strip())
    require(source.name=='w6' and source.is_dir(),'Unexpected sixth native source')
    entries={x['path']:x for x in manifest['copied_files']}
    require(len(entries)==len(manifest['copied_files'])==1205,'Native source path count changed')
    for name,item in entries.items():
        OLD.safe_relative(name)
        require(not (source/name).is_symlink() and file_digest(source/name)==item['sha256'],'Sixth native source drift: '+name)
    products=json.loads((W_RUN/'preserved-native-output.json').read_text())
    require(set(products)==set(W_LIBS),'Unexpected native products')
    for name,item in products.items():
        p=local(item['path'])
        require(p.resolve()==(W_RUN/'native-artifacts'/name).resolve(),'Native product must come from preserved archive')
        require(file_digest(p)==item['sha256']==W_LIBS[name],'Preserved native library changed')
    return source,manifest,products

def tool_hashes(windows=False):
    result={str(SCRIPT):file_digest(SCRIPT),str(OLD_FILE):file_digest(OLD_FILE),
            str(SCRIPT.with_name('verify-android-native.py')):file_digest(SCRIPT.with_name('verify-android-native.py'))}
    if windows:
        for name in (*STEPS,'windows_ui_context.py','windows-bundle-supplements.json'):
            result[str(ROOT/name)]=file_digest(ROOT/name)
    return result

def check_tools(receipt):
    require(receipt['allowed_ui_files']==sorted(UI) and receipt['new_paths']==sorted(NEW),'Receipt path approval differs')
    expected=tool_hashes(receipt['schema']=='bk-final-ui-windows-v3')
    require(receipt['tool_sha256']==expected,'Packaging tool set or checksum differs')
    for name,value in receipt['tool_sha256'].items():
        require(file_digest(local(name))==value,'Packaging tool drift: '+name)

def approve(output):
    require(os.name!='nt','Approval baseline inspection runs in the existing Linux build environment')
    _,original,manifest,records=OLD.load_native(A_RUN)
    baseline=scan_tree(original)
    OLD.check_native_archive(REPO,original,manifest,baseline)
    require(NEW.isdisjoint(baseline),'New UI paths already present in native source')
    inventory=repo_inventory()
    for name,value in UI.items():
        require(inventory.get(name)=={'type':'file','sha256':value},'Reviewed UI hash differs: '+name)
    drift=reviewed_test_difference(original)
    for name,item in inventory.items():
        if name in UI or name==TEST_PATH: continue
        require(name in baseline,'Unapproved new worktree source: '+name)
        expected=baseline[name]
        if item['type']=='symlink':
            require(expected['type']=='symlink' and item['target']==expected['target'],'Worktree link differs: '+name)
        else:
            data=(REPO/name).read_bytes(); value=digest(data)
            if value!=expected.get('sha256') and name not in manifest['bridges'] and b'\0' not in data:
                data.decode('utf-8'); value=digest(data.replace(b'\r\n',b'\n'))
            require(expected['type']=='file' and value==expected['sha256'],'Unapproved non-UI source difference: '+name)
    wsource,_,_=windows_parent()
    approval={'schema':'bk-final-ui-approval-v3','ui_sha256':UI,'new_paths':sorted(NEW),
              'head':OLD.git(REPO,'rev-parse','HEAD').decode().strip(),'workspace_inputs':inventory,
              'reviewed_test_only_differences':{'android':drift,'windows':reviewed_test_difference(wsource)},
              'native_android_records':records,'native_windows_manifest_sha256':W_MANIFEST,
              'created_utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
    require(repo_inventory()==inventory,'Worktree changed during approval capture')
    write_json(output,approval)
    print(json.dumps({'approval':str(output),'sha256':file_digest(output),'ui_count':len(UI),
                      'workspace_inputs':len(inventory),'reviewed_test_only_differences':approval['reviewed_test_only_differences']},indent=2))

def load_approval(path,check_worktree=False):
    data=json.loads(path.read_text())
    require(data['schema']=='bk-final-ui-approval-v3' and data['ui_sha256']==UI and data['new_paths']==sorted(NEW),'Approval contract differs')
    if check_worktree:
        require(OLD.git(REPO,'rev-parse','HEAD').decode().strip()==data['head'],'Approved worktree HEAD changed')
        require(repo_inventory()==data['workspace_inputs'],'Approved worktree bytes changed')
    return data

def ui_bytes():
    result={}
    for name,value in UI.items():
        raw=(REPO/name).read_bytes()
        require(digest(raw)==value,'UI changed after review: '+name)
        raw.decode('utf-8'); require(b'\0' not in raw,'Binary UI input')
        result[name]=(raw,raw.replace(b'\r\n',b'\n'))
    return result

def import_ui(source,before,inputs):
    deltas={}
    for name,(raw,data) in inputs.items():
        p=source/name
        if name in NEW:
            require(name not in before and not p.exists() and p.parent.is_dir(),'Unexpected new UI destination')
        else:
            require(name in before and p.is_file(),'Existing reviewed UI input missing')
        p.write_bytes(data)
        deltas[name]={'source_sha256':digest(raw),'snapshot_sha256':digest(data),
                      'before_sha256':before.get(name,{}).get('sha256'),'added':name in NEW}
    return deltas

def validate_delta(before,after,deltas):
    require(set(after)==set(before)|NEW,'Unexpected source path addition/deletion')
    require({p for p in before if before[p]!=after[p]}<=set(UI),'Non-UI frozen input changed')
    require(set(deltas)==set(UI),'Missing reviewed UI provenance')
    for name,value in deltas.items():
        require(after[name]['type']=='file' and after[name]['sha256']==value['snapshot_sha256'],'UI delta bytes differ')
        require(value['source_sha256']==UI[name] and value['added']==(name in NEW),'UI approval differs')
        if name not in NEW:
            require(value['before_sha256']==before[name]['sha256'],'Original UI checksum differs')
            require(after[name]['mode']==before[name]['mode'],'Existing UI file mode changed')
        else:
            require(value['before_sha256'] is None,'New UI input claims an original hash')

def new_receipt(kind,approval,source,native_source):
    return {'schema':'bk-final-ui-'+kind+'-v3','native_recompiled':False,'ui_source':str(source),
            'native_source':str(native_source),'allowed_ui_files':sorted(UI),'new_paths':sorted(NEW),
            'approval_sha256':file_digest(approval),'tool_sha256':tool_hashes(kind=='windows')}

def prepare_android(approval):
    require(os.name!='nt','Android preparation requires Linux build environment')
    approved=load_approval(approval,True)
    native,original,manifest,records=OLD.load_native(A_RUN)
    require(records==approved['native_android_records'],'Native source provenance changed')
    baseline=scan_tree(original); OLD.check_native_archive(REPO,original,manifest,baseline)
    require(reviewed_test_difference(original)==approved['reviewed_test_only_differences']['android'],'Test drift proof changed')
    inputs=ui_bytes()
    tag=datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+uuid.uuid4().hex[:6]
    run=ROOT/('android-ui-snapshot-v3-'+tag)
    source=Path('/home/ai/bk-remote-build')/('android-ui-v3-'+tag+'-source')
    require(not run.exists() and not source.exists(),'Destination already exists')
    run.mkdir()
    shutil.copytree(original,source,copy_function=shutil.copy2,symlinks=True)
    require(scan_tree(source,True)==baseline,'Independent copy differs')
    deltas=import_ui(source,baseline,inputs)
    tree=scan_tree(source,True); validate_delta(baseline,tree,deltas)
    require(scan_tree(original)==baseline,'Original source changed during copy')
    require(OLD.load_native(A_RUN)[3]==records,'Native output changed')
    load_approval(approval,True)
    (run/'approval.json').write_bytes(approval.read_bytes())
    write_json(run/'native-tree.json',baseline);write_json(run/'ui-tree.json',tree)
    inspection=OLD.inspect_native(native);write_json(run/'native-inspection.json',inspection)
    receipt=new_receipt('android',approval,source,original)
    receipt.update(native_run=str(native),native_records=records,ui_inputs=deltas,
                   native_tree_sha256=file_digest(run/'native-tree.json'),ui_tree_sha256=file_digest(run/'ui-tree.json'))
    write_json(run/'receipt.json',receipt);(run/'snapshot-path.txt').write_text(str(source)+'\n')
    verify_android(run,native)
    print('PREPARED_ANDROID_UI_V3='+str(run))

def verify_android(run,native,binary_report=None):
    receipt=json.loads((run/'receipt.json').read_text())
    require(receipt['schema']=='bk-final-ui-android-v3' and receipt['native_recompiled'] is False,'Invalid Android receipt')
    check_tools(receipt)
    require(file_digest(run/'approval.json')==receipt['approval_sha256'],'Approval evidence drift')
    load_approval(run/'approval.json')
    actual_native,original,_,records=OLD.load_native(native)
    require(actual_native.resolve()==A_RUN.resolve() and records==receipt['native_records'],'Wrong native artifacts')
    require(str(original)==receipt['native_source'],'Wrong original source')
    before=json.loads((run/'native-tree.json').read_text());after=json.loads((run/'ui-tree.json').read_text())
    require(file_digest(run/'native-tree.json')==receipt['native_tree_sha256'] and file_digest(run/'ui-tree.json')==receipt['ui_tree_sha256'],'Inventory drift')
    require(scan_tree(original)==before,'Original native tree changed')
    source=Path(receipt['ui_source'])
    require(source!=original and not source.is_relative_to(original) and not original.is_relative_to(source),'Overlapping snapshots')
    require((run/'snapshot-path.txt').read_text().splitlines()==[str(source)],'Snapshot pointer drift')
    require(scan_tree(source,True)==after,'Prepared UI tree changed')
    validate_delta(before,after,receipt['ui_inputs'])
    for name,item in after.items():
        if item['type']=='file' and name in before:
            a,b=(source/name).stat(),(original/name).stat()
            require((a.st_dev,a.st_ino)!=(b.st_dev,b.st_ino),'Copied source shares an inode')
    OLD.inspect_native(actual_native,binary_report)
    print('FINAL_ANDROID_UI_V3_VERIFIED: '+str(source))

def prepare_windows(approval):
    require(os.name=='nt','Windows preparation requires the existing Windows Python runtime')
    approved=load_approval(approval,True)
    original,manifest,products=windows_parent()
    require(reviewed_test_difference(original)==approved['reviewed_test_only_differences']['windows'],'Test drift proof changed')
    source=ROOT/'w6u3'
    run=ROOT/('windows-g2-final-ui-v3-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    require(not source.exists() and not run.exists(),'Windows source/evidence destination already exists')
    source.mkdir();run.mkdir()
    inputs=ui_bytes();parent_files={}
    for item in manifest['copied_files']:
        name=item['path'];p=source/name;p.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(original/name,p);parent_files[name]={'sha256':item['sha256']}
    before=scan_tree(source,True)
    require(NEW.isdisjoint(before),'New files exist in old source')
    deltas=import_ui(source,before,inputs)
    after=scan_tree(source,True);validate_delta(before,after,deltas)
    load_approval(approval,True);windows_parent()
    (run/'approval.json').write_bytes(approval.read_bytes())
    write_json(run/'native-tree.json',before);write_json(run/'ui-tree.json',after)
    (run/'source-manifest.json').write_bytes((W_RUN/'source-manifest.json').read_bytes())
    (run/'snapshot-path.txt').write_text(str(original))
    (run/'ui-snapshot-path.txt').write_text(str(source))
    files=[{'path':name,'sha256':item['sha256'],'size':item['size']} for name,item in after.items() if item['type']=='file']
    changes=[{'path':name,'parent_sha256':value['before_sha256'],'ui_sha256':value['snapshot_sha256'],
              'main_raw_sha256':value['source_sha256']} for name,value in deltas.items() if value['added'] or value['before_sha256']!=value['snapshot_sha256']]
    write_json(run/'ui-source-manifest.json',{'schema':'bk-final-ui-windows-v3','source':str(source),'native_parent':str(original),
               'parent_manifest_sha256':W_MANIFEST,'allowed_ui_files':sorted(UI),'new_paths':sorted(NEW),
               'ui_only_changes':changes,'copied_files':files})
    write_json(run/'native-reference.json',{'native_run':str(W_RUN),'native_source_manifest_sha256':W_MANIFEST,
               'native_exit_code':0,'note':'No native main-library compilation; preserved sixth native libraries reused.'})
    for name in ('capture-vs-env.cmd','preserved-native-output.json','toolchain.json'):
        (run/name).write_bytes((W_RUN/name).read_bytes())
    for name,item in products.items():
        target=run/'ui-native-target/release'/name;target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(Path(item['path']),target)
        require(file_digest(target)==W_LIBS[name],'Isolated native copy differs')
    receipt=new_receipt('windows',approval,source,original)
    receipt.update(native_run=str(W_RUN),ui_inputs=deltas,native_tree_sha256=file_digest(run/'native-tree.json'),
                   ui_tree_sha256=file_digest(run/'ui-tree.json'),ui_manifest_sha256=file_digest(run/'ui-source-manifest.json'))
    write_json(run/'receipt.json',receipt)
    (run/'native-reference-exit-code.txt').write_text('0')
    verify_windows(run,False)
    print('PREPARED_WINDOWS_UI_V3='+str(run))

def verify_windows(run,generated=False):
    receipt=json.loads((run/'receipt.json').read_text())
    require(receipt['schema']=='bk-final-ui-windows-v3' and receipt['native_recompiled'] is False,'Invalid Windows receipt')
    require(run.resolve().is_relative_to(ROOT.resolve()),'Evidence outside product toolchains')
    check_tools(receipt)
    require(file_digest(run/'approval.json')==receipt['approval_sha256'],'Approval evidence drift')
    load_approval(run/'approval.json')
    original,parent_manifest,products=windows_parent()
    require(str(original)==receipt['native_source'] and Path(receipt['native_run'])==W_RUN,'Wrong native parent')
    require(file_digest(run/'source-manifest.json')==W_MANIFEST,'Native manifest copy drift')
    require(json.loads((run/'preserved-native-output.json').read_text())==products,'Native artifact reference drift')
    for name,value in W_LIBS.items():
        require(file_digest(run/'ui-native-target/release'/name)==value,'Isolated native archive changed')
    source=Path(receipt['ui_source'])
    require(source==ROOT/'w6u3' and (run/'ui-snapshot-path.txt').read_text().strip()==str(source),'Wrong Windows UI source')
    require(file_digest(run/'ui-source-manifest.json')==receipt['ui_manifest_sha256'],'UI manifest drift')
    require(file_digest(run/'native-tree.json')==receipt['native_tree_sha256'] and file_digest(run/'ui-tree.json')==receipt['ui_tree_sha256'],'Inventory drift')
    before=json.loads((run/'native-tree.json').read_text());after=json.loads((run/'ui-tree.json').read_text())
    parent_files={x['path']:x['sha256'] for x in parent_manifest['copied_files']}
    require({name:item['sha256'] for name,item in before.items() if item['type']=='file'}==parent_files,'Native inventory does not match verified parent')
    require(all(item['type'] in ('file','directory') for item in before.values()),'Unexpected native inventory entry')
    manifest=json.loads((run/'ui-source-manifest.json').read_text())
    manifest_files={x['path']:x['sha256'] for x in manifest['copied_files']}
    require(len(manifest_files)==len(manifest['copied_files']) and manifest_files=={name:item['sha256'] for name,item in after.items() if item['type']=='file'},'UI manifest and complete inventory differ')
    require(manifest['allowed_ui_files']==sorted(UI) and manifest['new_paths']==sorted(NEW),'UI manifest path approval differs')
    validate_delta(before,after,receipt['ui_inputs'])
    changes=[]
    if not generated:
        require(scan_tree(source,True)==after,'Prepared Windows tree changed')
    for name,item in after.items():
        if item['type']!='file':continue
        p=source/name
        require(p.is_file() and not p.is_symlink() and p.resolve().is_relative_to(source.resolve()),'Unsafe source file')
        actual=file_digest(p)
        if actual!=item['sha256']:
            require(generated and name in GENERATED,'Frozen Windows source drift: '+name)
            changes.append({'path':name,'frozen_sha256':item['sha256'],'generated_sha256':actual})
        if name in before:
            a,b=p.stat(),(original/name).stat()
            require((a.st_dev,a.st_ino)!=(b.st_dev,b.st_ino),'Windows copy shares native inode')
    return source,changes

def windows_context(run):
    legacy=types.SimpleNamespace(**runpy.run_path(str(ROOT/'windows_ui_context.py')))
    module=types.ModuleType('windows_ui_context')
    module.ui_run=lambda root:run
    for name in ('ui_source','ui_manifest','native_products'):
        setattr(module,name,getattr(legacy,name))
    def validate(target):
        require(Path(target)==run,'Cross-run context request')
        source,changes=verify_windows(run,True)
        (run/'ui-effective-generated-inputs.json').write_text(json.dumps({'source_manifest_sha256':file_digest(run/'ui-source-manifest.json'),'generated_only_differences':changes},indent=2))
        return source
    module.validate_ui_source=validate
    def native_ready(target):
        require(Path(target)==run,'Cross-run native reference')
        windows_parent()
        require(json.loads((run/'preserved-native-output.json').read_text())==legacy.native_products(W_RUN),'Wrong native product references')
        return True
    module.native_ready=native_ready
    return module

def windows_step(run,step):
    require(step in STEPS,'Unapproved packaging step')
    receipt=json.loads((run/'receipt.json').read_text());check_tools(receipt)
    sys.modules['windows_ui_context']=windows_context(run)
    runpy.run_path(str(ROOT/step),run_name='__main__')

def windows_build(run,phase):
    require(os.name=='nt','Windows wrapper requires Windows')
    verify_windows(run,phase=='package')
    steps=STEPS[:4] if phase=='build' else STEPS[4:] if phase=='package' else STEPS
    if phase=='package':
        require((run/'final-ui-pipeline-exit-code.txt').read_text().strip()=='0','UI build prerequisite not complete')
    marker=run/('v3-'+phase+'-pipeline.pid')
    with marker.open('x') as stream:stream.write(str(os.getpid()))
    results=[]
    try:
        for step in steps:
            with (run/('v3-'+step+'.log')).open('x',encoding='utf-8') as log:
                result=subprocess.run([sys.executable,'-B',str(SCRIPT),'windows-step',str(run),step],stdout=log,stderr=subprocess.STDOUT)
            results.append({'script':step,'exit_code':result.returncode})
            (run/'v3-pipeline-results.json').write_text(json.dumps(results,indent=2))
            require(result.returncode==0,'Packaging step failed: '+step)
            if step=='build-windows-flutter.py':(run/'final-ui-pipeline-exit-code.txt').write_text('0')
        (run/('v3-'+phase+'-exit-code.txt')).write_text('0')
    except Exception:
        (run/('v3-'+phase+'-exit-code.txt')).write_text('1')
        raise

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    subs=parser.add_subparsers(dest='command',required=True)
    p=subs.add_parser('approve');p.add_argument('output',type=Path)
    for command in ('prepare-android','prepare-windows'):
        p=subs.add_parser(command);p.add_argument('approval',type=Path)
    p=subs.add_parser('verify-android');p.add_argument('run',type=Path);p.add_argument('--native-run',required=True,type=Path);p.add_argument('--binary-report',type=Path)
    p=subs.add_parser('verify-windows');p.add_argument('run',type=Path)
    p=subs.add_parser('windows-build');p.add_argument('run',type=Path);p.add_argument('--phase',choices=('build','package','all'),default='all')
    p=subs.add_parser('windows-step');p.add_argument('run',type=Path);p.add_argument('step',choices=STEPS)
    args=parser.parse_args()
    if args.command=='approve':approve(args.output)
    elif args.command=='prepare-android':prepare_android(args.approval)
    elif args.command=='prepare-windows':prepare_windows(args.approval)
    elif args.command=='verify-android':verify_android(args.run,args.native_run,args.binary_report)
    elif args.command=='verify-windows':verify_windows(args.run,False);print('FINAL_WINDOWS_UI_V3_VERIFIED')
    elif args.command=='windows-build':windows_build(args.run,args.phase)
    else:windows_step(args.run,args.step)

if __name__=='__main__':
    try:main()
    except Exception as error:
        print('FINAL_UI_V3_FAILED: '+str(error),file=sys.stderr)
        raise SystemExit(1)
