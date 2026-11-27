#!/usr/bin/env python3
"""Prepare/verify one-use Flutter-only input while reusing a successful native build.

No compilation, package build, existing snapshot mutation, hard links, or cleanup.
The original native source is checked against its Git archives and recorded delta.
Only the six explicitly reviewed Dart files may be imported from the worktree.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import runpy
import shutil
import stat
import subprocess
import sys
import tarfile
import uuid

BASE = 'a0c0963c483fc8f1aeed4547787d1673adcb583c'
COMMON = '450cc1d7b729cfa8d19b5a7527c9cc2fe54cf5eb'
UI_FILES = frozenset({
    'flutter/lib/models/server_model.dart',
    'flutter/lib/mobile/pages/server_page.dart',
    'flutter/lib/mobile/widgets/gesture_help.dart',
    'flutter/test/bk_remote_service_lifecycle_test.dart',
    'flutter/lib/common/widgets/dialog.dart',
    'flutter/lib/desktop/pages/desktop_setting_page.dart',
})
TEXT_SUFFIXES = {'.rs', '.dart', '.kt', '.sh', '.ps1', '.py', '.json', '.md',
                 '.xml', '.gradle', '.toml', '.lock', '.rc', '.cmake', '.txt',
                 '.h', '.cpp', '.c', '.yaml', '.yml', '.svg', '.bat', '.patch', '.diff'}
NATIVE_OUTPUTS = {'liblibrustdesk.so', 'libc++_shared.so'}
NATIVE_RECORDS = {'exit-code.txt', 'snapshot-path.txt', 'source-manifest.json',
                  'native-output.sha256', 'native.log', 'lock.before.sha256'}
SCHEMA = 'bk-android-ui-snapshot-v1'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def safe_relative(value):
    require(isinstance(value, str) and value != '' and '\\' not in value,
            'Invalid relative path')
    path = PurePosixPath(value)
    require(not path.is_absolute() and all(x not in ('', '.', '..') for x in value.split('/')),
            'Unsafe relative path: ' + value)
    return value


def normal_bytes(name, data):
    if Path(name).suffix.lower() in TEXT_SUFFIXES and b'\0' not in data:
        return data.replace(b'\r\n', b'\n')
    return data


def real_directory(path):
    path = Path(path).absolute()
    require(not path.is_symlink() and path.is_dir(), 'Expected an existing real directory: ' + str(path))
    return path.resolve()


def write_json(path, value):
    with path.open('x', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write('\n')


def scan_tree(root, independent=False):
    """Do not follow links. Include directories, modes, bytes, and link targets."""
    root = real_directory(root)
    result = {}
    def visit(directory):
        for path in sorted(directory.iterdir()):
            rel = safe_relative(path.relative_to(root).as_posix())
            value = path.lstat()
            mode = stat.S_IMODE(value.st_mode)
            if stat.S_ISLNK(value.st_mode):
                target = os.readlink(path)
                require(not os.path.isabs(target), 'Absolute symbolic link: ' + rel)
                require(path.resolve().is_relative_to(root), 'External symbolic link: ' + rel)
                result[rel] = {'type': 'symlink', 'target': target, 'mode': mode}
            elif stat.S_ISDIR(value.st_mode):
                result[rel] = {'type': 'directory', 'mode': mode}
                visit(path)
            elif stat.S_ISREG(value.st_mode):
                if independent:
                    require(value.st_nlink == 1, 'Hard-linked prepared file: ' + rel)
                result[rel] = {'type': 'file', 'sha256': file_digest(path),
                               'size': value.st_size, 'mode': mode}
            else:
                raise ValueError('Unsupported filesystem entry: ' + rel)
    visit(root)
    return result


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args])


def archive_entries(repo, commit, prefix=''):
    result = {}
    process = subprocess.Popen(['git', '-C', str(repo), 'archive', '--format=tar', commit],
                               stdout=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=process.stdout, mode='r|') as archive:
            for item in archive:
                if item.isdir():
                    continue
                name = safe_relative(prefix + item.name)
                if item.issym():
                    result[name] = {'type': 'symlink', 'target': item.linkname}
                elif item.isfile():
                    stream = archive.extractfile(item)
                    require(stream is not None, 'Missing archived file: ' + name)
                    result[name] = {'type': 'file', 'sha256': digest(stream.read())}
                else:
                    raise ValueError('Unsupported archive member: ' + name)
        require(process.wait() == 0, 'Git archive failed')
    finally:
        process.stdout.close()
        if process.poll() is None:
            process.terminate()
            process.wait()
    return result


def load_native(native):
    native = real_directory(native)
    for name in sorted(NATIVE_RECORDS | NATIVE_OUTPUTS):
        path = native / name
        require(path.is_file() and not path.is_symlink(), 'Missing native evidence: ' + name)
    require((native / 'exit-code.txt').read_text().strip() == '0', 'Native build has not succeeded')
    require('ANDROID_NATIVE_BUILD_PASS' in (native / 'native.log').read_text(),
            'Native build success marker is absent')
    paths = (native / 'snapshot-path.txt').read_text().splitlines()
    require(len(paths) == 1 and Path(paths[0]).is_absolute(), 'Invalid original snapshot path')
    source = real_directory(paths[0])
    records = {}
    for line in (native / 'native-output.sha256').read_text().splitlines():
        match = re.fullmatch(r'([0-9a-fA-F]{64}) [ *]([^/\\]+)', line)
        require(match is not None, 'Malformed native output checksum line')
        value, name = match.groups()
        require(name in NATIVE_OUTPUTS and name not in records, 'Unexpected native output name')
        require(file_digest(native / name) == value.lower(), 'Native output checksum differs: ' + name)
        records[name] = value.lower()
    require(set(records) == NATIVE_OUTPUTS, 'Incomplete native output checksums')
    manifest = json.loads((native / 'source-manifest.json').read_text())
    require(manifest.get('baseline') == BASE, 'Unexpected native source baseline')
    for item in manifest['changed']:
        name = safe_relative(item['path'])
        require(file_digest(source / name) == item['snapshot_sha256'], 'Native source delta differs: ' + name)
    for name, value in manifest['bridges'].items():
        safe_relative(name)
        require(file_digest(source / name) == value, 'Native generated bridge differs: ' + name)
    records.update({name: file_digest(native / name) for name in sorted(NATIVE_RECORDS)})
    return native, source, manifest, records


def check_native_archive(repo, source, manifest, actual):
    require(git(repo, 'rev-parse', 'HEAD').decode().strip() == BASE, 'Worktree baseline changed')
    common = repo / 'libs/hbb_common'
    require(git(common, 'rev-parse', 'HEAD').decode().strip() == COMMON, 'Fixed submodule changed')
    expected = archive_entries(repo, BASE)
    expected.update(archive_entries(common, COMMON, 'libs/hbb_common/'))
    recorded = {}
    for item in manifest['changed']:
        name = safe_relative(item['path'])
        value = item['snapshot_sha256']
        require(name not in recorded or recorded[name] == value, 'Conflicting native delta entries')
        recorded[name] = value
        expected[name] = {'type': 'file', 'sha256': value}
    for name, value in manifest['bridges'].items():
        expected[safe_relative(name)] = {'type': 'file', 'sha256': value}
    # build.rs invokes the fixed hbb_common::gen_version. This is a generated
    # native-build output, not an imported worktree source or a new compilation.
    version = source / 'src/version.rs'
    lines = (source / 'Cargo.toml').read_text().splitlines()
    wanted = next(line.split('=', 1)[1].strip() for line in lines
                  if line.split('=', 1)[0].strip() == 'version')
    pattern = (r'pub const VERSION: &str = ' + re.escape(wanted) +
               r';\n#\[allow\(dead_code\)\]\npub const BUILD_DATE: &str = "'
               r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}";\n')
    require(re.fullmatch(pattern, version.read_text()) is not None, 'Unexpected generated native version source')
    expected['src/version.rs'] = {'type': 'file', 'sha256': file_digest(version)}
    files = {name: value for name, value in actual.items() if value['type'] != 'directory'}
    require(set(files) == set(expected), 'Native snapshot path set differs from frozen archives/delta: ' +
            repr(sorted(set(files) ^ set(expected))[:12]))
    for name, value in expected.items():
        require(all(files[name].get(key) == entry for key, entry in value.items()),
                'Native archived input differs: ' + name)


def check_workspace(repo, baseline, manifest):
    # Documentation and this orchestration script are never imported. Their old
    # frozen bytes remain in the new tree; changes here cannot rebuild native code.
    ignored = ('docs/', 'scripts/bk-remote/')
    names = set(x.decode() for x in git(repo, 'ls-files', '--cached', '--others',
                                       '--exclude-standard', '-z').split(b'\0') if x)
    names.discard('libs/hbb_common')
    common = repo / 'libs/hbb_common'
    names.update('libs/hbb_common/' + x.decode() for x in
                 git(common, 'ls-files', '--cached', '--others', '--exclude-standard', '-z').split(b'\0') if x)
    names.update(manifest['bridges'])
    for name in sorted(names):
        safe_relative(name)
        if name in UI_FILES or name.startswith(ignored):
            continue
        path = repo / name
        require(name in baseline, 'Unapproved new worktree source: ' + name)
        entry = baseline[name]
        if entry['type'] == 'symlink':
            require(path.is_symlink() and os.readlink(path) == entry['target'], 'Worktree link differs: ' + name)
        else:
            require(entry['type'] == 'file' and path.is_file() and not path.is_symlink(),
                    'Worktree source type differs: ' + name)
            data = path.read_bytes()
            # Worktree checkout may contain CRLF even for extensionless text.
            # No such normalization is applied to copied frozen inputs or bridges.
            current = digest(data)
            if current != entry['sha256'] and name not in manifest['bridges'] and b'\0' not in data:
                try:
                    data.decode('utf-8')
                except UnicodeDecodeError:
                    pass
                else:
                    current = digest(data.replace(b'\r\n', b'\n'))
            require(current == entry['sha256'], 'Non-UI worktree source differs: ' + name)


def inspect_native(native, output=None):
    tool = Path(__file__).resolve().with_name('verify-android-native.py')
    inspect = runpy.run_path(str(tool))['inspect']
    report = {'native_run': str(native), 'verifier_sha256': file_digest(tool),
              'files': [], 'errors': [], 'passed': False,
              'scope': 'Reinspection of existing native output; no new native compilation or device acceptance.'}
    for name in sorted(NATIVE_OUTPUTS):
        try:
            item, errors = inspect(native / name)
            report['files'].append(item)
            report['errors'].extend(name + ': ' + error for error in errors)
        except Exception as error:
            report['errors'].append(name + ': ' + str(error))
    report['passed'] = not report['errors'] and len(report['files']) == 2
    if output is not None:
        write_json(Path(output), report)
    require(report['passed'], 'Native binary inspection failed: ' + repr(report['errors']))
    return report


def verify(evidence, native_argument, binary_report=None):
    evidence = real_directory(evidence)
    receipt = json.loads((evidence / 'receipt.json').read_text())
    require(receipt.get('schema') == SCHEMA and receipt.get('native_recompiled') is False,
            'Unrecognized UI-only receipt')
    require(receipt['allowed_ui_files'] == sorted(UI_FILES), 'UI allowlist differs')
    inspector = Path(__file__).resolve().with_name('verify-android-native.py')
    require(file_digest(inspector) == receipt['native_inspector_sha256'], 'Native inspection tool changed')
    require(file_digest(Path(__file__).resolve()) == receipt['preparer_sha256'], 'Preparation tool changed')
    require(real_directory(native_argument) == Path(receipt['native_run']), 'Native run does not match receipt')
    native, original, manifest, records = load_native(native_argument)
    require(str(original) == receipt['native_source'] and records == receipt['native_records'],
            'Original native provenance differs')
    require(file_digest(evidence / 'native-tree.json') == receipt['native_tree_sha256'], 'Baseline inventory changed')
    require(file_digest(evidence / 'ui-tree.json') == receipt['ui_tree_sha256'], 'UI inventory changed')
    baseline = json.loads((evidence / 'native-tree.json').read_text())
    expected = json.loads((evidence / 'ui-tree.json').read_text())
    require(scan_tree(original) == baseline, 'Original frozen source changed after preparation')
    paths = (evidence / 'snapshot-path.txt').read_text().splitlines()
    require(paths == [receipt['ui_source']], 'Prepared snapshot path differs')
    source = real_directory(paths[0])
    require(source != original and not source.is_relative_to(original) and not original.is_relative_to(source),
            'Prepared source overlaps native source')
    actual = scan_tree(source, independent=True)
    require(actual == expected, 'Prepared source paths/bytes/links/modes differ')
    require(set(baseline) == set(actual), 'Prepared snapshot added or removed a source path')
    changed = {name for name in baseline if baseline[name] != actual[name]}
    require(changed <= UI_FILES, 'Prepared snapshot changed non-UI source')
    require(set(receipt['ui_inputs']) == UI_FILES, 'Missing UI input provenance')
    for name in UI_FILES:
        entry = receipt['ui_inputs'][name]
        require(actual[name]['type'] == 'file' and baseline[name]['type'] == 'file', 'UI input is not a file')
        require(entry['before_sha256'] == baseline[name]['sha256'] and
                entry['snapshot_sha256'] == actual[name]['sha256'], 'UI delta checksum differs: ' + name)
        require(actual[name]['mode'] == baseline[name]['mode'], 'UI input mode changed: ' + name)
    for name, item in actual.items():
        if item['type'] == 'file':
            left, right = (original / name).stat(), (source / name).stat()
            require((left.st_dev, left.st_ino) != (right.st_dev, right.st_ino), 'Native/prepared files share an inode')
    inspect_native(native, binary_report)
    print('UI_ONLY_FROZEN_INPUTS_VERIFIED: ' + str(source))
    return source


def prepare(native_argument, repo, toolchains, source_parent):
    repo, toolchains, source_parent = map(real_directory, (repo, toolchains, source_parent))
    native, original, manifest, records = load_native(native_argument)
    inspection = inspect_native(native)
    baseline = scan_tree(original)
    check_native_archive(repo, original, manifest, baseline)
    check_workspace(repo, baseline, manifest)
    inputs = {}
    for name in sorted(UI_FILES):
        path = repo / name
        require(path.is_file() and not path.is_symlink() and baseline.get(name, {}).get('type') == 'file',
                'Missing regular reviewed UI file: ' + name)
        data = path.read_bytes()
        data.decode('utf-8')
        require(b'\0' not in data, 'Binary data in Dart input: ' + name)
        inputs[name] = data
    tag = datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8]
    evidence = toolchains / ('android-ui-snapshot-' + tag)
    source = source_parent / ('android-ui-snapshot-' + tag + '-source')
    require(not source.exists() and not evidence.exists(), 'Snapshot destination already exists')
    require(not source.is_relative_to(original) and not original.is_relative_to(source), 'Overlapping source trees')
    evidence.mkdir()
    try:
        shutil.copytree(original, source, symlinks=True, copy_function=shutil.copy2)
        require(scan_tree(source, independent=True) == baseline, 'Independent native source copy differs')
        deltas = {}
        for name, data in inputs.items():
            output = normal_bytes(name, data)
            (source / name).write_bytes(output)
            deltas[name] = {'source_sha256': digest(data), 'snapshot_sha256': digest(output),
                            'before_sha256': baseline[name]['sha256'],
                            'changed': digest(output) != baseline[name]['sha256']}
        require(scan_tree(original) == baseline, 'Original source changed during copy')
        require(load_native(native)[3] == records, 'Native artifacts changed during preparation')
        check_workspace(repo, baseline, manifest)
        for name, data in inputs.items():
            require((repo / name).read_bytes() == data, 'UI worktree changed during snapshot: ' + name)
        tree = scan_tree(source, independent=True)
        require(set(tree) == set(baseline), 'Copy changed source path set')
        require({p for p in tree if tree[p] != baseline[p]} <= UI_FILES, 'Copy changed an unapproved source')
        write_json(evidence / 'native-inspection.json', inspection)
        write_json(evidence / 'native-tree.json', baseline)
        write_json(evidence / 'ui-tree.json', tree)
        receipt = {'schema': SCHEMA, 'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   'native_recompiled': False, 'baseline': BASE, 'submodule': COMMON,
                   'native_run': str(native), 'native_source': str(original), 'ui_source': str(source),
                   'native_records': records, 'allowed_ui_files': sorted(UI_FILES), 'ui_inputs': deltas,
                   'preparer_sha256': file_digest(Path(__file__).resolve()),
                   'native_inspector_sha256': inspection['verifier_sha256'],
                   'native_tree_sha256': file_digest(evidence / 'native-tree.json'),
                   'ui_tree_sha256': file_digest(evidence / 'ui-tree.json'),
                   'native_generated_metadata': 'src/version.rs',
                   'boundary': 'One-use packaging snapshot; original native run and source remain unchanged. No new native compilation.'}
        write_json(evidence / 'receipt.json', receipt)
        (evidence / 'snapshot-path.txt').write_text(str(source) + '\n')
        verify(evidence, native)
        print('PREPARED_UI_EVIDENCE=' + str(evidence))
    except Exception as error:
        write_json(evidence / 'preparation-failed.json', {'error': str(error), 'source': str(source)})
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    setup = commands.add_parser('prepare')
    setup.add_argument('native_run')
    setup.add_argument('--repo', default='/mnt/d/demo2/rustdesk')
    setup.add_argument('--toolchains', default='/mnt/d/demo2/bk-remote-toolchains')
    setup.add_argument('--source-parent', default='/home/ai/bk-remote-build')
    check = commands.add_parser('verify')
    check.add_argument('evidence')
    check.add_argument('--native-run', required=True)
    check.add_argument('--binary-report', type=Path)
    args = parser.parse_args()
    if args.command == 'prepare':
        prepare(args.native_run, args.repo, args.toolchains, args.source_parent)
    else:
        verify(args.evidence, args.native_run, args.binary_report)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('ANDROID_UI_SNAPSHOT_FAILED: ' + str(error), file=sys.stderr)
        sys.exit(1)
